import AVFoundation
import CoreMedia

enum Quality: String, Codable, CaseIterable, Identifiable {
    case standard, high, max
    var id: String { rawValue }
    var label: String { ["standard": "Standard", "high": "High", "max": "Maximum"][rawValue]! }

    /* HEVC constant quality, 0 to 1, per track. A/B test of 2026-11-16 on the Insta360 Link 2C Pro
       in 4K, low light, against an uncompressed capture of the same 12 s (VMAF, full 4K):
           0.65   8 Mb/s  90.3      0.75  24 Mb/s  94.1      0.80  35 Mb/s  95.4
           0.85  48 Mb/s  96.4      0.90  82 Mb/s  97.2
       A visible difference starts around six points; on a 100% crop of the face, 0.75 and 0.85
       could not be told apart. 0.75 halves the camera for 2.3 points, so it is the default.
       The screen stays at 0.85 in every mode: it costs 1 to 4 Mb/s and its text must stay crisp
       (scrolling zone: 0.75 = 96.2 at 2.1 Mb/s, 0.85 = 96.8 at 4.0 Mb/s). */
    var camera: Double { ["standard": 0.75, "high": 0.85, "max": 0.90][rawValue]! }
    var screen: Double { self == .max ? 0.90 : 0.85 }
}

enum ScreenMode: String, Codable { case display, region }

struct RecSettings: Codable, Equatable {
    var folder = (NSHomeDirectory() as NSString).appendingPathComponent("Movies/Duv Rec")
    var screenOn = true
    var screenMode = ScreenMode.display
    var displayID: UInt32 = CGMainDisplayID()
    /// The drawn zone, in its display's points, origin top-left.
    var region: CGRect?
    var regionDisplayID: UInt32 = 0
    var hideMenuBar = true
    var showCursor = true
    var showClicks = false
    var fps = 30
    var quality = Quality.standard
    var cameraOn = true
    var cameraID: String?
    /// The devices picked by hand. `cameraID` and `micID` are what is in use now, which falls back to
    /// another device while the wanted one is unplugged and comes back to it when it returns.
    var cameraWanted: String?
    var micWanted: String?
    var camera4K = true
    var micOn = true
    var micID: String?
    var systemAudio = false

    init() {}

    /// Every key optional: a setting added in a later version keeps its default instead of resetting the rest.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RecSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? fallback }
        folder = v(.folder, d.folder)
        screenOn = v(.screenOn, d.screenOn)
        screenMode = v(.screenMode, d.screenMode)
        displayID = v(.displayID, d.displayID)
        region = try? c.decodeIfPresent(CGRect.self, forKey: .region)
        regionDisplayID = v(.regionDisplayID, d.regionDisplayID)
        hideMenuBar = v(.hideMenuBar, d.hideMenuBar)
        showCursor = v(.showCursor, d.showCursor)
        showClicks = v(.showClicks, d.showClicks)
        fps = v(.fps, d.fps)
        quality = v(.quality, d.quality)
        cameraOn = v(.cameraOn, d.cameraOn)
        cameraID = try? c.decodeIfPresent(String.self, forKey: .cameraID)
        cameraWanted = try? c.decodeIfPresent(String.self, forKey: .cameraWanted)
        micWanted = try? c.decodeIfPresent(String.self, forKey: .micWanted)
        camera4K = v(.camera4K, d.camera4K)
        micOn = v(.micOn, d.micOn)
        micID = try? c.decodeIfPresent(String.self, forKey: .micID)
        systemAudio = v(.systemAudio, d.systemAudio)
    }

    /// The zone, if the zone mode is on and one has been drawn.
    var activeRegion: CGRect? { screenMode == .region ? region : nil }

    static func load() -> RecSettings {
        guard let d = UserDefaults.standard.data(forKey: "settings"),
              let s = try? JSONDecoder().decode(RecSettings.self, from: d) else { return RecSettings() }
        return s
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "settings") }
    }
}

/// One take: its folder, its tracks, and the start and end every track is cut to.
///
/// Every track is cut to the same window of the host clock, [T0, T1]. A video track starts its
/// file at T0 exactly (the frame on screen at T0 is repeated there if nothing moved), an audio
/// track drops the samples before T0. So the files line up as they are, no offset to apply.
final class RecordingSession {
    let folder: URL
    let t0: CMTime
    private(set) var t1: CMTime?
    let screen: VideoTrackWriter?
    let camera: VideoTrackWriter?
    let mic: AudioTrack?
    let system: AudioTrack?
    private let cameraClock: CMClock
    private var lastScreenFrame: CMSampleBuffer?
    private let lock = NSLock()
    var meta: [String: Any]

    init(folder: URL, t0: CMTime, screen: VideoTrackWriter?, camera: VideoTrackWriter?, cameraClock: CMClock,
         mic: AudioTrack?, system: AudioTrack?, meta: [String: Any]) {
        self.folder = folder
        self.t0 = t0
        self.windowStart = t0
        self.screen = screen
        self.camera = camera
        self.cameraClock = cameraClock
        self.mic = mic
        self.system = system
        self.meta = meta
    }

    private var end: CMTime? { lock.lock(); defer { lock.unlock() }; return t1 }

    /* ── Pause ────────────────────────────────────────────────────────
       A pause is cut OUT of the files: nothing is written between pause and resume, and
       everything after is written earlier by the total time paused (`offset`). One file per
       track still, with no hole, and the tracks stay aligned because all of them are cut at
       the same two instants of the host clock. */
    private var pausedAt: CMTime?
    private var windowStart: CMTime
    private var offset = CMTime.zero
    private(set) var pauses = 0

    private struct Window { let end: CMTime?; let pausedAt: CMTime?; let start: CMTime; let offset: CMTime }
    private var window: Window {
        lock.lock(); defer { lock.unlock() }
        return Window(end: t1, pausedAt: pausedAt, start: windowStart, offset: offset)
    }

    /// Seconds recorded so far in the files, pauses left out.
    var pausedTotal: Double { lock.lock(); defer { lock.unlock() }; return CMTimeGetSeconds(offset) }

    func pause(at t: CMTime) {
        lock.lock(); pausedAt = t; lock.unlock()
        mic?.pause(at: hostSeconds(t))
        system?.pause(at: hostSeconds(t))
    }

    func resume(at r: CMTime, screenQueue: DispatchQueue) {
        lock.lock()
        guard let p = pausedAt else { lock.unlock(); return }
        offset = CMTimeAdd(offset, CMTimeSubtract(r, p))
        windowStart = r
        pausedAt = nil
        pauses += 1
        let shift = offset
        lock.unlock()
        mic?.resume(at: hostSeconds(r))
        system?.resume(at: hostSeconds(r))
        // What the screen shows now may have changed during the pause without a new frame since
        // (a still screen sends none): write the latest picture at the resume point.
        screenQueue.async { [self] in
            flushHeld()
            guard let screen, screen.started, let last = lastScreenFrame else { return }
            // At least 1/120 s after the last frame written: closer than that, two frames share one
            // timestamp once rounded by a player or by ffmpeg ("non monotonically increasing dts").
            var at = CMTimeSubtract(r, shift)
            if screen.lastPTS.isValid { at = CMTimeMaximum(at, CMTimeAdd(screen.lastPTS, Self.minGap)) }
            held = (last, at)
        }
    }

    /* The picture held at a resume is written only once it is known not to collide with the first
       real frame after it: that frame usually comes a millisecond or two later, and then it simply
       replaces the held one. With a still screen no frame comes, and the held picture is written
       at the next resume or at the end of the take. Screen queue only. */
    private var held: (frame: CMSampleBuffer, at: CMTime)?
    private static let minGap = CMTime(value: 1, timescale: 120)

    private func flushHeld(before next: CMTime? = nil) {
        guard let h = held, let screen else { return }
        held = nil
        if let next, CMTimeSubtract(next, h.at) < Self.minGap { return }
        if let frame = retimed(h.frame, to: h.at) { screen.append(frame) }
    }

    private func shifted(_ sb: CMSampleBuffer, _ pts: CMTime, _ offset: CMTime) -> CMSampleBuffer? {
        offset == .zero ? sb : retimed(sb, to: CMTimeSubtract(pts, offset))
    }

    // Screen queue.
    func screenFrame(_ sb: CMSampleBuffer) {
        guard let screen else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let w = window
        if let end = w.end, pts > end { return }
        if let p = w.pausedAt, pts > p { lastScreenFrame = sb; return }
        if !screen.started {
            if pts < t0 { lastScreenFrame = sb; return }
            startScreen()
        }
        lastScreenFrame = sb
        if pts < w.start { return } // a frame from the pause, delivered after the resume
        flushHeld(before: CMTimeSubtract(pts, w.offset))
        if let frame = shifted(sb, pts, w.offset) { screen.append(frame) }
    }

    /// Opens the screen file at T0, on the frame showing then. Called by the first frame after T0,
    /// or by a timer when the screen is still and macOS sends nothing new.
    func startScreen() {
        guard let screen, !screen.started else { return }
        screen.start(at: t0)
        if let last = lastScreenFrame, let frame = retimed(last, to: t0) { screen.append(frame) }
    }

    // Camera queue. Camera times are on the capture session's clock: brought to the host clock,
    // so every track is written on the same timeline.
    func cameraFrame(_ sb: CMSampleBuffer) {
        guard let camera else { return }
        let pts = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sb), from: cameraClock, to: CMClockGetHostTimeClock())
        let w = window
        if pts < t0 || pts < w.start { return }
        if let end = w.end, pts > end { return }
        if let p = w.pausedAt, pts > p { return }
        if !camera.started { camera.start(at: t0) }
        if let frame = retimed(sb, to: CMTimeSubtract(pts, w.offset)) { camera.append(frame) }
    }

    // Mic queue.
    func micBuffer(_ sb: CMSampleBuffer) {
        guard let mic, let a = floatSamples(sb, outChannels: 1) else { return }
        let pts = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sb), from: cameraClock, to: CMClockGetHostTimeClock())
        mic.handle(a.samples, frames: a.frames, rate: a.rate, ptsHost: hostSeconds(pts))
    }

    // System audio queue (ScreenCaptureKit, host clock).
    func systemBuffer(_ sb: CMSampleBuffer) {
        guard let system, let a = floatSamples(sb, outChannels: 2) else { return }
        system.handle(a.samples, frames: a.frames, rate: a.rate, ptsHost: hostSeconds(CMSampleBufferGetPresentationTimeStamp(sb)))
    }

    /// Ends the take at `t`, or at the pause if it is stopped while paused.
    func markEnd(_ t: CMTime) {
        lock.lock()
        let e = pausedAt ?? t
        t1 = e
        lock.unlock()
        mic?.end(at: hostSeconds(e))
        system?.end(at: hostSeconds(e))
    }

    /// Closes every file on its own queue, then calls `done` on the main queue.
    func finish(rig: CaptureRig, screenQueue: DispatchQueue, systemQueue: DispatchQueue, done: @escaping () -> Void) {
        guard let e = end else { return }
        // The files end on their own timeline: the end of the take minus the time paused.
        let t1 = CMTimeSubtract(e, window.offset)
        let group = DispatchGroup()
        if let screen {
            group.enter()
            screenQueue.async { [self] in
                startScreen()
                flushHeld()
                screen.finish(at: t1) { group.leave() }
            }
        }
        if let camera {
            group.enter()
            rig.cameraQueue.async { [self] in
                camera.finish(at: t1) { group.leave() }
            }
        }
        if let mic {
            group.enter()
            rig.micQueue.async { mic.close(); group.leave() }
        }
        if let system {
            group.enter()
            systemQueue.async { system.close(); group.leave() }
        }
        group.notify(queue: .main, execute: done)
    }

    /// The first track that can no longer be written (disk full, volume gone), if any.
    var failure: String? {
        for w in [screen, camera].compactMap({ $0 }) { if let f = w.failure { return "\(w.url.lastPathComponent): \(f)" } }
        for a in [mic, system].compactMap({ $0 }) { if let f = a.failure { return "\(a.url.lastPathComponent): \(f)" } }
        return nil
    }

    /// session.json: what was recorded and how, written at the start (status "recording") and at
    /// the end ("complete"). A take that crashed keeps "recording", and its files are still readable.
    func writeMeta(status: String) {
        var m = meta
        m["status"] = status
        m["t0_host"] = hostSeconds(t0)
        if let t1 = end {
            m["t1_host"] = hostSeconds(t1)
            m["duration"] = hostSeconds(t1) - hostSeconds(t0) - pausedTotal
            m["pauses"] = pauses
            m["paused_seconds"] = pausedTotal
        }
        var tracks = (m["tracks"] as? [String: [String: Any]]) ?? [:]
        if let screen {
            tracks["screen"]?["frames"] = screen.frames
            tracks["screen"]?["dropped"] = screen.dropped
        }
        if let camera {
            tracks["camera"]?["frames"] = camera.frames
            tracks["camera"]?["dropped"] = camera.dropped
        }
        if let mic {
            tracks["mic"]?["samples"] = mic.frames
            tracks["mic"]?["sample_rate"] = mic.sampleRate
            if let f = mic.firstSampleHost { tracks["mic"]?["first_sample_host"] = f }
            tracks["mic"]?["gaps_filled"] = mic.gaps
        }
        if let system {
            tracks["system"]?["samples"] = system.frames
            tracks["system"]?["sample_rate"] = system.sampleRate
            tracks["system"]?["gaps_filled"] = system.gaps
        }
        m["tracks"] = tracks
        if let d = try? JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: folder.appendingPathComponent("session.json"), options: .atomic)
        }
    }
}
