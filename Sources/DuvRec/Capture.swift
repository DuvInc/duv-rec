import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Seconds on the host clock, the one clock every track is cut against.
func hostSeconds(_ t: CMTime) -> Double { CMTimeGetSeconds(t) }
var hostNow: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

func nsScreen(for id: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
}

private func even(_ v: CGFloat) -> Int { Int(v.rounded()) & ~1 }

// MARK: - Screen (ScreenCaptureKit)

/// The display, at its native pixel size, optionally without the menu bar (and the notch).
/// The pointer is drawn in by macOS when asked; this app's own windows are never in the picture.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let videoQueue = DispatchQueue(label: "rec.screen", qos: .userInitiated)
    let audioQueue = DispatchQueue(label: "rec.system-audio", qos: .userInitiated)
    var onFrame: ((CMSampleBuffer) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onStop: ((Error) -> Void)?
    private var stream: SCStream?
    private(set) var width = 0
    private(set) var height = 0

    /// The screen in its mode (a whole display, or a drawn zone). With the screen off, the stream
    /// still runs when the Mac's sound is wanted (ScreenCaptureKit carries it), on a tiny picture nobody keeps.
    func start(settings: RecSettings) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let region = settings.activeRegion
        let wanted = region != nil ? settings.regionDisplayID : settings.displayID
        // A drawn area belongs to one display: never fall back to another one, the area would show something else.
        if region != nil, !content.displays.contains(where: { $0.displayID == wanted }) {
            throw RecError("The display of the selected area is not connected. Select the area again.")
        }
        guard let display = content.displays.first(where: { $0.displayID == wanted }) ?? content.displays.first else {
            throw RecError("No display to record")
        }
        let me = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let ns = nsScreen(for: display.displayID)
        let scale = ns?.backingScaleFactor ?? 2
        var rect = CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
        if let region {
            rect = region.intersection(rect)
            if rect.isNull || rect.width < 16 || rect.height < 16 {
                throw RecError("The selected area is no longer on this display. Select it again.")
            }
        } else if settings.hideMenuBar, let ns {
            let top = max(ns.frame.maxY - ns.visibleFrame.maxY, ns.safeAreaInsets.top)
            rect.origin.y = top
            rect.size.height -= top
        }
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = rect
        if settings.screenOn {
            cfg.width = even(rect.width * scale)
            cfg.height = even(rect.height * scale)
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
        } else {
            cfg.width = 64
            cfg.height = 64
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        }
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        // The file is tagged Rec. 709: ask for sRGB pixels. Left to its default, the stream delivers
        // the display's own space (P3 on a MacBook) and every colour plays back a little dull.
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = settings.showCursor
        if #available(macOS 15.0, *) { cfg.showMouseClicks = settings.showClicks }
        cfg.queueDepth = 8
        if settings.systemAudio {
            cfg.capturesAudio = true
            cfg.sampleRate = 48000
            cfg.channelCount = 2
            cfg.excludesCurrentProcessAudio = true
        }
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if settings.systemAudio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
        try await s.startCapture()
        stream = s
        width = cfg.width
        height = cfg.height
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        switch type {
        case .screen:
            // Only complete frames carry a picture; idle ones just say "nothing changed".
            guard let info = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            onFrame?(sb)
        case .audio:
            onAudio?(sb)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop?(error) }
}

// MARK: - Camera and microphone (AVFoundation)

struct DeviceChoice: Identifiable, Hashable {
    let id: String
    let name: String
    /// Plugged in by USB or Thunderbolt, as opposed to built in, Bluetooth or virtual.
    var wired = false
    /// A virtual device only relays another one (a vendor's "Virtual Camera", OBS).
    var virtual = false

    init(id: String, name: String, wired: Bool = false, virtual: Bool = false) {
        self.id = id
        self.name = name
        self.wired = wired
        self.virtual = virtual || name.localizedCaseInsensitiveContains("virtual")
    }

    /* Device types do not tell a USB microphone from the built-in one (both are `.microphone`),
       the transport does: a four-character code, 'usb ', 'thun', 'bltn', 'blue', 'virt'... */
    init(_ d: AVCaptureDevice) {
        let t = UInt32(truncatingIfNeeded: d.transportType)
        let code = String(bytes: [24, 16, 8, 0].map { UInt8((t >> $0) & 0xff) }, encoding: .ascii) ?? ""
        self.init(id: d.uniqueID, name: d.localizedName, wired: code == "usb " || code == "thun", virtual: code == "virt")
    }
}

/// Webcam and microphone in one capture session, so both share its clock. It runs whenever the
/// app is open: the preview and the level meter are how a take is set up before it starts.
final class CaptureRig: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let cameraQueue = DispatchQueue(label: "rec.camera", qos: .userInitiated)
    let micQueue = DispatchQueue(label: "rec.mic", qos: .userInitiated)
    private let control = DispatchQueue(label: "rec.rig")
    private let videoOut = AVCaptureVideoDataOutput()
    private let audioOut = AVCaptureAudioDataOutput()
    private var lastLevel = Date.distantPast
    private var applied = ""

    var onCamera: ((CMSampleBuffer) -> Void)?
    var onMic: ((CMSampleBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?
    private(set) var cameraWidth = 0
    private(set) var cameraHeight = 0
    private(set) var cameraFPS = 30
    private(set) var cameraName = ""
    private(set) var micName = ""

    var clock: CMClock { session.synchronizationClock ?? CMClockGetHostTimeClock() }

    /* The preview shows the frames being recorded, through a display layer fed from here.
       Not AVCaptureVideoPreviewLayer: attached to the session, it stopped the data output after
       its first frame (MacBook camera), and the camera track came out empty. */
    let previewLayer = AVSampleBufferDisplayLayer()
    private var lastPreview = Date.distantPast

    /// Off during a take: the preview is not on screen then, no reason to draw it.
    var previewOn = true

    private func showInPreview(_ sb: CMSampleBuffer) {
        guard previewOn, Date().timeIntervalSince(lastPreview) > 1.0 / 15 else { return }
        lastPreview = Date()
        if let a = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(a) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(a, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = previewLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sb)
    }

    override init() {
        super.init()
        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        videoOut.alwaysDiscardsLateVideoFrames = false
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor
        videoOut.setSampleBufferDelegate(self, queue: cameraQueue)
        // Lossless 48 kHz float, mono: the voice as the microphone delivers it.
        audioOut.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
        ]
        audioOut.setSampleBufferDelegate(self, queue: micQueue)
        // The session stopping by itself (device error, another app taking the camera) must be said, not silent.
        NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.onTrouble?("Camera or microphone error: \(error?.localizedDescription ?? "capture stopped").")
            // One restart, not a loop: a device that keeps failing would otherwise spin here.
            guard let self, Date().timeIntervalSince(self.lastRestart) > 5 else { return }
            self.lastRestart = Date()
            self.control.async { if !self.session.isRunning, !self.session.inputs.isEmpty { self.session.startRunning() } }
        }
    }

    var onTrouble: ((String) -> Void)?
    private var lastRestart = Date.distantPast

    static func cameras() -> [DeviceChoice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera],
                                         mediaType: .video, position: .unspecified)
            .devices.map(DeviceChoice.init)
    }

    /// With no camera picked by hand: a plugged-in camera over the built-in one (whoever plugs a
    /// webcam in wants it), and never a virtual camera: it relays another one and showed a
    /// "camera off" card instead of a picture.
    static func defaultCamera(_ cameras: [DeviceChoice]) -> DeviceChoice? {
        let real = cameras.filter { !$0.virtual }
        return real.first { $0.wired } ?? real.first ?? cameras.first
    }

    /// With no microphone picked by hand: a plugged-in microphone that is not part of a webcam (a
    /// USB microphone is plugged in to be used; a webcam's own microphone is usually the worst one
    /// in the room), then the system default, then any real one.
    static func defaultMic(_ mics: [DeviceChoice], cameras: [DeviceChoice], systemDefault: String?) -> DeviceChoice? {
        let real = mics.filter { !$0.virtual }
        let webcams = Set(cameras.map(\.name))
        return real.first { $0.wired && !webcams.contains($0.name) }
            ?? mics.first { $0.id == systemDefault } ?? real.first ?? mics.first
    }

    static func microphones() -> [DeviceChoice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map(DeviceChoice.init)
    }

    /// Rebuilds the session for these devices. Blocking work runs off the main thread.
    func configure(cameraID: String?, want4K: Bool, micID: String?, done: @escaping (String?) -> Void) {
        control.async { [self] in
            // Same devices as now: nothing to do. Re-adding inputs to a RUNNING session (it happened
            // twice at launch) left the camera delivering one frame and then nothing, so a real change
            // stops the session, rebuilds it, and starts it again.
            let wanted = "\(cameraID ?? "-")|\(want4K)|\(micID ?? "-")"
            if wanted == applied && session.isRunning { DispatchQueue.main.async { done(nil) }; return }
            applied = wanted
            if session.isRunning { session.stopRunning() }
            var problem: String?
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            cameraWidth = 0; cameraHeight = 0; cameraName = ""; micName = ""
            if let cameraID, let cam = AVCaptureDevice(uniqueID: cameraID) {
                do {
                    let input = try AVCaptureDeviceInput(device: cam)
                    if session.canAddInput(input) { session.addInput(input) }
                    if session.canAddOutput(videoOut) { session.addOutput(videoOut) }
                    pickFormat(cam, want4K: want4K)
                    let dims = CMVideoFormatDescriptionGetDimensions(cam.activeFormat.formatDescription)
                    cameraWidth = Int(dims.width)
                    cameraHeight = Int(dims.height)
                    cameraName = cam.localizedName
                } catch { problem = "Camera: \(error.localizedDescription)" }
            }
            if let micID, let mic = AVCaptureDevice(uniqueID: micID) {
                do {
                    let input = try AVCaptureDeviceInput(device: mic)
                    if session.canAddInput(input) { session.addInput(input) }
                    if session.canAddOutput(audioOut) { session.addOutput(audioOut) }
                    micName = mic.localizedName
                } catch { problem = "Microphone: \(error.localizedDescription)" }
            }
            session.commitConfiguration()
            if !session.inputs.isEmpty { session.startRunning() }
            /* Again once the session runs. Measured on an Insta360 Link 2C Pro: chosen
               only before the start, the format and rate are overridden by the session (1080p or
               25 i/s came out); applied again on the running session they hold, 4K at 30 i/s. The
               camera restarts its stream for it, hence the pause before saying the rig is ready. */
            if let cameraID, cameraWidth > 0, let cam = AVCaptureDevice(uniqueID: cameraID) {
                pickFormat(cam, want4K: want4K)
                let dims = CMVideoFormatDescriptionGetDimensions(cam.activeFormat.formatDescription)
                cameraWidth = Int(dims.width)
                cameraHeight = Int(dims.height)
                Thread.sleep(forTimeInterval: 2)
            }
            DispatchQueue.main.async { done(problem) }
        }
    }

    /// The largest 16:9 format up to 4K (or 1080p) that does 30 fps. 16:9 only: the MacBook camera
    /// also offers a 1552×1552 Center Stage format that delivers no frame to a capture output.
    private func pickFormat(_ cam: AVCaptureDevice, want4K: Bool) {
        let maxH: Int32 = want4K ? 2160 : 1080
        let candidates = cam.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let ratio = Double(d.width) / Double(max(1, d.height))
            return d.height <= maxH && abs(ratio - 16.0 / 9.0) < 0.02
                && f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30.01 && $0.maxFrameRate >= 29.9 }
        }
        guard let best = candidates.max(by: {
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return Int(a.width) * Int(a.height) < Int(b.width) * Int(b.height)
        }) else { return }
        do {
            try cam.lockForConfiguration()
            cam.activeFormat = best
            // A frame duration outside the format's own ranges raises an exception Swift cannot catch
            // (a camera that tops out at 29.97 would crash the app on exactly 1/30).
            let thirty = CMTime(value: 1, timescale: 30)
            let ranges = best.videoSupportedFrameRateRanges
            if ranges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                cam.activeVideoMinFrameDuration = thirty
                cam.activeVideoMaxFrameDuration = thirty
                cameraFPS = 30
            } else if let r = ranges.filter({ $0.minFrameRate <= 30.01 && $0.maxFrameRate >= 29.9 }).min(by: { $0.maxFrameRate < $1.maxFrameRate }) {
                // The Insta360 Link 2C Pro declares fixed rates, 30.00003 among them: take the range as it is.
                cam.activeVideoMinFrameDuration = r.minFrameDuration
                cam.activeVideoMaxFrameDuration = r.minFrameDuration
                cameraFPS = Int(r.maxFrameRate.rounded())
            }
            cam.unlockForConfiguration()
        } catch {}
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOut {
            onCamera?(sb)
            showInPreview(sb)
        } else {
            onMic?(sb)
            if let onLevel, Date().timeIntervalSince(lastLevel) > 0.08, let a = floatSamples(sb, outChannels: 1) {
                lastLevel = Date()
                let peak = a.samples.reduce(Float(0)) { max($0, abs($1)) }
                onLevel(20 * log10(max(peak, 1e-6)))
            }
        }
    }
}
