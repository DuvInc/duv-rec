import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import SwiftUI

struct DisplayChoice: Identifiable, Hashable {
    let id: UInt32
    let name: String
}

enum RecState: Equatable { case idle, starting, recording, stopping }

final class Recorder: ObservableObject {
    static let shared = Recorder()

    @Published var settings = RecSettings.load() {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            // Choosing "Zone" with no zone yet opens the picker straight away.
            if settings.screenMode == .region && oldValue.screenMode != .region && settings.region == nil {
                DispatchQueue.main.async { [weak self] in self?.drawRegion() }
            }
            if settings.cameraOn != oldValue.cameraOn || settings.cameraID != oldValue.cameraID
                || settings.camera4K != oldValue.camera4K || settings.micOn != oldValue.micOn || settings.micID != oldValue.micID {
                configureRig()
            }
        }
    }
    @Published var displays: [DisplayChoice] = []
    @Published var cameras: [DeviceChoice] = []
    @Published var mics: [DeviceChoice] = []
    @Published var state = RecState.idle
    @Published var elapsed: TimeInterval = 0
    /// A take on hold: nothing is written until it resumes, and the pause is left out of the files.
    @Published var paused = false
    @Published var micLevel: Float = -120
    @Published var micPeak: Float = -120
    @Published var problem: String?
    @Published var lastFolder: URL?
    @Published var freeGB: Double = 0
    @Published var cameraInfo = ""
    /// macOS grants screen recording per app, and only takes effect after a relaunch.
    @Published var screenAccess = CGPreflightScreenCaptureAccess()

    let rig = CaptureRig()
    let screen = ScreenCapture()
    private var session: RecordingSession?
    private let sessionLock = NSLock()
    private var ticker: Timer?
    private var startedAt = Date()
    private var banked: TimeInterval = 0
    private(set) var restarting = false
    private var streaming = false
    private var rigReady = false
    /// Held during a take: without it macOS may nap the app or put the Mac to sleep mid-recording.
    private var activity: NSObjectProtocol?
    private let border = RegionBorder()

    var hasSource: Bool { settings.screenOn || settings.cameraOn || settings.micOn || settings.systemAudio }

    /// Opens the zone picker over every screen; the zone is kept only when confirmed.
    func drawRegion() {
        let display = settings.region != nil ? settings.regionDisplayID : settings.displayID
        RegionPicker.pick(display: display, region: settings.region) { [weak self] result in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            guard let (id, rect) = result else { return }
            self.settings.regionDisplayID = id
            self.settings.region = rect
            self.settings.screenMode = .region
        }
    }

    /// The zone's size in pixels, for the labels.
    var regionPixels: String? {
        guard let r = settings.region else { return nil }
        let scale = NSScreen.screens.first { displayID(of: $0) == settings.regionDisplayID }?.backingScaleFactor ?? 2
        return "\(Int((r.width * scale).rounded()) & ~1)×\(Int((r.height * scale).rounded()) & ~1)"
    }

    init() {
        rig.onLevel = { [weak self] db in
            DispatchQueue.main.async {
                guard let self else { return }
                self.micLevel = db
                self.micPeak = max(db, self.micPeak - 0.6)
            }
        }
        rig.onCamera = { [weak self] sb in self?.current?.cameraFrame(sb) }
        rig.onMic = { [weak self] sb in self?.current?.micBuffer(sb) }
        screen.onFrame = { [weak self] sb in self?.current?.screenFrame(sb) }
        screen.onAudio = { [weak self] sb in self?.current?.systemBuffer(sb) }
        rig.onTrouble = { [weak self] message in self?.problem = message }
        screen.onStop = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.state == .recording else { return }
                self.problem = "Screen recording stopped: \(error.localizedDescription). The take is saved."
                self.stop()
            }
        }
        NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshDevices() }
        NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.state == .recording { self.problem = "A device was disconnected during the take. The other tracks keep recording." }
            self.refreshDevices()
        }
        refreshDevices()
        refreshDisplays()
        updateFreeSpace()
        requestAccess()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.screenAccess = CGPreflightScreenCaptureAccess()
            if self.screenAccess, self.displays.isEmpty { self.refreshDisplays() }
        }
        // `open -a "Duv Rec" --args --test-take 20`: a take of 20 s with the saved settings, to test without clicking.
        let args = CommandLine.arguments
        // `--pick-region`: opens the zone picker at launch, to test it without clicking.
        if args.contains("--pick-region") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.drawRegion() } }
        if let i = args.firstIndex(of: "--test-take"), i + 1 < args.count, let seconds = Double(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.start()
                // `--test-pause 3`: pauses for 3 s a third of the way in. `--test-restart`: restarts at that point instead.
                if let j = args.firstIndex(of: "--test-pause"), j + 1 < args.count, let hold = Double(args[j + 1]) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1 + seconds / 3) { self?.pause() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1 + seconds / 3 + hold) { self?.resume() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1 + seconds + hold) { self?.stop() }
                    return
                }
                if args.contains("--test-stop-paused") { // pauses a third of the way in, stops 3 s later without resuming
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1 + seconds / 3) { self?.pause() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4 + seconds / 3) { self?.stop() }
                    return
                }
                if args.contains("--test-restart") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1 + seconds / 3) { self?.restart() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6 + seconds * 4 / 3) { self?.stop() }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1 + seconds) { self?.stop() }
            }
        }
    }

    private var current: RecordingSession? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return session
    }

    private func setSession(_ s: RecordingSession?) {
        sessionLock.lock(); session = s; sessionLock.unlock()
    }

    // MARK: Devices

    func refreshDevices() {
        cameras = CaptureRig.cameras()
        mics = CaptureRig.microphones()
        // Never during a take: the devices of a take are fixed when it starts.
        guard state == .idle else { return }
        var s = settings
        // The device picked by hand when it is there; otherwise the best one present. Re-evaluated at
        // every plug and unplug, so a hand-picked device is taken back as soon as it returns.
        if let w = s.cameraWanted, cameras.contains(where: { $0.id == w }) {
            s.cameraID = w
        } else {
            s.cameraID = CaptureRig.defaultCamera(cameras)?.id
        }
        if let w = s.micWanted, mics.contains(where: { $0.id == w }) {
            s.micID = w
        } else {
            s.micID = CaptureRig.defaultMic(mics, cameras: cameras, systemDefault: AVCaptureDevice.default(for: .audio)?.uniqueID)?.id
        }
        if s != settings { settings = s } else { configureRig() }
    }

    func refreshDisplays() {
        Task { @MainActor in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
            displays = content.displays.map { d in
                DisplayChoice(id: d.displayID, name: nsScreen(for: d.displayID)?.localizedName ?? "Display \(d.displayID)")
            }
            if !displays.contains(where: { $0.id == settings.displayID }), let first = displays.first { settings.displayID = first.id }
        }
    }

    func chooseCamera(_ id: String?) { settings.cameraWanted = id; settings.cameraID = id }
    func chooseMic(_ id: String?) { settings.micWanted = id; settings.micID = id }

    private func configureRig() {
        guard state == .idle else { return }
        rigReady = false
        rig.configure(cameraID: settings.cameraOn ? settings.cameraID : nil, want4K: settings.camera4K,
                      micID: settings.micOn ? settings.micID : nil) { [weak self] problem in
            guard let self else { return }
            self.rigReady = true
            if let problem { self.problem = problem }
            self.cameraInfo = self.rig.cameraWidth > 0 ? "\(self.rig.cameraWidth)×\(self.rig.cameraHeight)" : ""
            if !self.settings.micOn { self.micLevel = -120; self.micPeak = -120 }
        }
    }

    /// macOS errors in plain words, for the ones a person can act on.
    static func explain(_ error: Error) -> String {
        let e = error as NSError
        if e.domain == SCStreamErrorDomain && e.code == SCStreamError.userDeclined.rawValue {
            return "macOS does not allow Duv Rec to record the screen yet."
        }
        return error.localizedDescription
    }

    func openScreenSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// The grant only applies to a fresh process: reopen the app and quit this one.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func requestAccess() {
        AVCaptureDevice.requestAccess(for: .video) { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    }

    func updateFreeSpace() {
        let url = URL(fileURLWithPath: settings.folder).deletingLastPathComponent()
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        // The "important usage" figure is 0 on volumes that do not support it (many external disks).
        let important = v?.volumeAvailableCapacityForImportantUsage ?? 0
        freeGB = Double(important > 0 ? important : Int64(v?.volumeAvailableCapacity ?? 0)) / 1e9
    }

    // MARK: Recording

    func toggle() {
        switch state {
        case .idle: start()
        case .recording: stop()
        default: break
        }
    }

    /// A take that could not start: say why, and bring the window back if a restart had hidden it.
    private func fail(_ message: String) {
        problem = message
        restarting = false
        showMainWindow(true)
    }

    func start() {
        guard state == .idle else { return }
        problem = nil
        updateFreeSpace()
        if freeGB < 5 { fail("Less than 5 GB free: free up some space before recording."); return }
        if !hasSource { fail("Turn on at least one source: screen, camera or sound."); return }
        if settings.screenOn && settings.screenMode == .region && settings.region == nil {
            fail("Select the area to record first."); return
        }
        // A source that is on but not delivering would be left out of the take without a word.
        if settings.cameraOn || settings.micOn {
            if !rigReady {
                // A restart comes right after a stop, while the devices are being checked again: wait for them.
                if restarting {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.start() }
                    return
                }
                fail("Camera and microphone are still starting. Try again in a second."); return
            }
            if settings.cameraOn && rig.cameraWidth == 0 { fail("No camera available: connect one or turn Camera off."); return }
            if settings.micOn && rig.micName.isEmpty { fail("No microphone available: connect one or turn it off."); return }
        }
        restarting = false
        state = .starting
        elapsed = 0
        banked = 0
        paused = false
        let s = settings
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folder = URL(fileURLWithPath: s.folder).appendingPathComponent(stamp.string(from: Date()))
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

                // ScreenCaptureKit runs for the screen, and for the Mac's sound even without the screen.
                let usesStream = s.screenOn || s.systemAudio
                if usesStream { try await screen.start(settings: s) }
                streaming = usesStream
                let screenWriter = s.screenOn ? try VideoTrackWriter(url: folder.appendingPathComponent("screen.mov"),
                    width: screen.width, height: screen.height, fps: s.fps, quality: s.quality.screen) : nil
                var cameraWriter: VideoTrackWriter?
                if s.cameraOn, rig.cameraWidth > 0 {
                    cameraWriter = try VideoTrackWriter(url: folder.appendingPathComponent("camera.mov"),
                        width: rig.cameraWidth, height: rig.cameraHeight, fps: rig.cameraFPS, quality: s.quality.camera)
                }
                // Half a second for every source to be flowing: T0 is the same instant for all tracks.
                let t0 = CMTimeAdd(hostNow, CMTime(value: 1, timescale: 2))
                let mic = s.micOn && !rig.micName.isEmpty ? AudioTrack(url: folder.appendingPathComponent("mic.wav"), channels: 1, t0: hostSeconds(t0)) : nil
                let system = s.systemAudio ? AudioTrack(url: folder.appendingPathComponent("system.wav"), channels: 2, t0: hostSeconds(t0)) : nil

                var tracks: [String: [String: Any]] = [:]
                if screenWriter != nil {
                    var t: [String: Any] = ["file": "screen.mov", "width": screen.width, "height": screen.height, "fps": s.fps,
                                            "codec": "hevc", "quality": s.quality.screen, "cursor": s.showCursor]
                    if let r = s.activeRegion {
                        t["mode"] = "region"
                        t["region_points"] = [r.minX, r.minY, r.width, r.height]
                        t["display"] = displays.first { $0.id == s.regionDisplayID }?.name ?? ""
                    } else {
                        t["mode"] = "display"
                        t["menu_bar_hidden"] = s.hideMenuBar
                        t["display"] = displays.first { $0.id == s.displayID }?.name ?? ""
                    }
                    tracks["screen"] = t
                }
                if let cameraWriter {
                    tracks["camera"] = ["file": "camera.mov", "width": cameraWriter.width, "height": cameraWriter.height,
                                        "fps": rig.cameraFPS, "codec": "hevc", "quality": s.quality.camera, "device": rig.cameraName]
                }
                if mic != nil { tracks["mic"] = ["file": "mic.wav", "format": "wav float32 mono", "device": rig.micName] }
                if system != nil { tracks["system"] = ["file": "system.wav", "format": "wav float32 stereo"] }
                let meta: [String: Any] = [
                    "app": "Duv Rec 0.2.0",
                    "started_at": ISO8601DateFormatter().string(from: Date()),
                    "tracks": tracks,
                    "sync": "every track starts at t0_host and ends at t1_host (host clock); mic drift: compare samples with duration × sample_rate",
                ]
                let rec = RecordingSession(folder: folder, t0: t0, screen: screenWriter, camera: cameraWriter,
                                           cameraClock: rig.clock, mic: mic, system: system, meta: meta)
                rec.writeMeta(status: "recording")
                setSession(rec)
                // A still screen sends no frame: open its file at T0 on the last picture anyway.
                screen.videoQueue.asyncAfter(deadline: .now() + 0.7) { rec.startScreen() }

                if s.screenOn, let r = s.activeRegion { border.show(region: r, display: s.regionDisplayID) }
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .idleDisplaySleepDisabled, .idleSystemSleepDisabled], reason: "Recording a take")
                rig.previewOn = false
                lastFolder = folder
                startedAt = Date().addingTimeInterval(0.5)
                state = .recording
                startTicker()
            } catch {
                if streaming { await screen.stop(); streaming = false }
                setSession(nil)
                // Nothing was recorded: do not leave an empty folder behind (rmdir only removes an empty one).
                rmdir(folder.path)
                screenAccess = CGPreflightScreenCaptureAccess()
                state = .idle
                fail(Recorder.explain(error))
            }
        }
    }

    func pause() {
        guard state == .recording, !paused, let rec = current else { return }
        rec.pause(at: hostNow)
        banked += max(0, Date().timeIntervalSince(startedAt))
        elapsed = banked
        paused = true
    }

    func resume() {
        guard state == .recording, paused, let rec = current else { return }
        rec.resume(at: hostNow, screenQueue: screen.videoQueue)
        startedAt = Date()
        paused = false
    }

    /// Throws the current take away (to the Trash, not deleted) and starts a new one with the same settings.
    func restart() {
        guard state == .recording else { return }
        restarting = true   // keeps the window hidden between the two takes
        stop(reveal: false) { [weak self] in
            guard let self else { return }
            if let folder = self.lastFolder { try? FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
            self.lastFolder = nil
            self.start()
        }
    }

    func stop(reveal: Bool = true, then: (() -> Void)? = nil) {
        guard state == .recording, let rec = current else { return }
        state = .stopping
        ticker?.invalidate()
        rec.markEnd(hostNow)
        // Let the buffers already in flight up to T1 land before closing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            rec.finish(rig: rig, screenQueue: screen.videoQueue, systemQueue: screen.audioQueue) { [self] in
                if let f = rec.failure {
                    problem = "\(f). The rest of the take is saved."
                } else if let w = [rec.screen, rec.camera].compactMap({ $0 }).first(where: { $0.dropped * 100 > max(1, $0.frames) }) {
                    problem = "\(w.url.lastPathComponent): \(w.dropped) frames could not be written in time (the Mac was too busy)."
                }
                rec.writeMeta(status: "complete")
                setSession(nil)
                Task { @MainActor in
                    border.hide()
                    rig.previewOn = true
                    if let activity { ProcessInfo.processInfo.endActivity(activity) }
                    activity = nil
                    if streaming { await screen.stop(); streaming = false }
                    paused = false
                    state = .idle
                    refreshDevices()
                    // The folder of the take is what comes to the front; the window is back, behind it.
                    if reveal {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSWorkspace.shared.activateFileViewerSelecting([rec.folder]) }
                    }
                    then?()
                }
            }
        }
    }

    private func startTicker() {
        ticker?.invalidate()
        var beats = 0
        // In the common run loop modes: a timer in the default mode stops while a menu is open, so the
        // time froze as long as the menu bar menu was down and jumped ahead at the click on Pause.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.state == .recording else { return }
            if !self.paused { self.elapsed = self.banked + max(0, Date().timeIntervalSince(self.startedAt)) }
            beats += 1
            // A file that can no longer be written: stop now, what is on disk is kept.
            if self.current?.failure != nil { self.stop(); return }
            if beats % 20 == 0 { // every 10 s
                self.current?.writeMeta(status: "recording")
                self.updateFreeSpace()
                if self.freeGB < 2 {
                    self.problem = "Disk almost full: the take was stopped and saved."
                    self.stop()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }
}
