import AVFoundation
import CoreMedia

struct RecError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/* ── Crash safety ─────────────────────────────────────────────────────

   A take must never be lost whole. Two mechanisms, one per kind of file:

   - Video (.mov, HEVC): the writer emits a movie FRAGMENT every 2 s. A file
     cut off mid-write (crash, kill, power loss) still opens up to its last
     fragment: at most 2 s are lost, not the take.
   - Audio (.wav, 32-bit float): the samples go straight to disk and the WAV
     header (which holds the length) is rewritten every second. A crash
     leaves a valid file missing at most one second.

   No chunk rotation: one file per track is simpler to cut and cannot leave
   a gap or a doubled frame at a seam. */

/// One HEVC track (screen or camera), encoded by the Mac's media engine.
final class VideoTrackWriter {
    let url: URL
    let width: Int
    let height: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private(set) var lastPTS = CMTime.invalid
    private(set) var started = false
    private(set) var frames = 0
    private(set) var dropped = 0

    init(url: URL, width: Int, height: Int, fps: Int, quality: Double) throws {
        self.url = url
        self.width = width
        self.height = height
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(value: 2, timescale: 1)
        let compression: [String: Any] = [
            AVVideoQualityKey: quality,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
            AVVideoAllowFrameReorderingKey: false,
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecError("Cannot write \(url.lastPathComponent)") }
        writer.add(input)
    }

    var failure: String? { writer.status == .failed ? (writer.error?.localizedDescription ?? "write error") : nil }

    func start(at t: CMTime) {
        guard !started, writer.startWriting() else { return }
        writer.startSession(atSourceTime: t)
        started = true
    }

    func append(_ sb: CMSampleBuffer) {
        guard started, writer.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if lastPTS.isValid && pts <= lastPTS { return }
        if input.isReadyForMoreMediaData && input.append(sb) {
            frames += 1
            lastPTS = pts
        } else {
            dropped += 1
        }
    }

    /// Ends the track at `t`: the last frame is held until then, so every track has the same length.
    func finish(at t: CMTime, _ done: @escaping () -> Void) {
        guard started, writer.status == .writing else { done(); return }
        input.markAsFinished()
        writer.endSession(atSourceTime: t)
        writer.finishWriting(completionHandler: done)
    }
}

/// A sample buffer moved to another time, same picture (the frame on screen at the start).
func retimed(_ sb: CMSampleBuffer, to t: CMTime) -> CMSampleBuffer? {
    // The frame keeps its own duration: without one, the writer cannot hold the last frame up to the end of the take.
    var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sb), presentationTimeStamp: t, decodeTimeStamp: .invalid)
    var out: CMSampleBuffer?
    CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1,
                                          sampleTimingArray: &timing, sampleBufferOut: &out)
    return out
}

/// Lossless audio: 32-bit float WAV, header refreshed every second.
/// Every write throws instead of raising: FileHandle's older `write(_:)` raises an Objective-C
/// exception on a full or unplugged disk, which Swift cannot catch and which kills the app.
final class WavWriter {
    let url: URL
    let sampleRate: Int
    let channels: Int
    private let handle: FileHandle
    private(set) var frames: Int64 = 0
    private var lastHeader = Date()

    init(url: URL, sampleRate: Int, channels: Int) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw RecError("Cannot create \(url.lastPathComponent)")
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: header())
    }

    /// Sizes are 32-bit in a WAV: past 4 GB (6 h of mono voice, 3 h of stereo) they stay at the
    /// maximum, which ffmpeg reads as "until the end of the file".
    static func header(frames: Int64, channels: Int, sampleRate: Int) -> Data {
        let dataBytes = UInt32(clamping: frames * Int64(channels) * 4)
        var d = Data()
        func tag(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        tag("RIFF"); u32(dataBytes > UInt32.max - 36 ? UInt32.max : 36 + dataBytes); tag("WAVE")
        tag("fmt "); u32(16); u16(3) // IEEE float
        u16(UInt16(channels)); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * channels * 4))
        u16(UInt16(channels * 4)); u16(32)
        tag("data"); u32(dataBytes)
        return d
    }

    private func header() -> Data { Self.header(frames: frames, channels: channels, sampleRate: sampleRate) }

    func append(_ samples: ArraySlice<Float>) throws {
        guard !samples.isEmpty else { return }
        try handle.seekToEnd()
        try samples.withUnsafeBufferPointer { try handle.write(contentsOf: Data(buffer: $0)) }
        frames += Int64(samples.count / channels)
        if Date().timeIntervalSince(lastHeader) >= 1 { try refreshHeader() }
    }

    func appendSilence(frames n: Int) throws {
        guard n > 0 else { return }
        try append(ArraySlice([Float](repeating: 0, count: n * channels)))
    }

    private func refreshHeader() throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header())
        try? handle.synchronize()
        lastHeader = Date()
    }

    func close() {
        try? refreshHeader()
        try? handle.close()
    }
}

/// Interleaved Float32 samples out of any linear-PCM sample buffer, as `outChannels` channels.
func floatSamples(_ sb: CMSampleBuffer, outChannels: Int) -> (samples: [Float], frames: Int, rate: Double)? {
    guard let fmt = CMSampleBufferGetFormatDescription(sb),
          let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return nil }
    let asbd = asbdPtr.pointee
    guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }
    let n = CMSampleBufferGetNumSamples(sb)
    guard n > 0 else { return nil }

    var size = 0
    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &size, bufferListOut: nil,
        bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
    guard size > 0 else { return nil }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
    defer { raw.deallocate() }
    let ablPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    var block: CMBlockBuffer?
    guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: ablPtr,
        bufferListSize: size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
        flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr else { return nil }
    let abl = UnsafeMutableAudioBufferListPointer(ablPtr)

    let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
    let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    let bits = Int(asbd.mBitsPerChannel)
    let inCh = max(1, Int(asbd.mChannelsPerFrame))

    func sample(_ ch: Int, _ i: Int) -> Float {
        let c = min(ch, inCh - 1)
        let buffer = nonInterleaved ? abl[min(c, abl.count - 1)] : abl[0]
        let idx = nonInterleaved ? i : i * inCh + c
        guard let p = buffer.mData else { return 0 }
        switch (isFloat, bits) {
        case (true, 32): return p.assumingMemoryBound(to: Float.self)[idx]
        case (true, 64): return Float(p.assumingMemoryBound(to: Double.self)[idx])
        case (false, 16): return Float(p.assumingMemoryBound(to: Int16.self)[idx]) / 32768
        case (false, 32): return Float(p.assumingMemoryBound(to: Int32.self)[idx]) / 2147483648
        case (false, 24):
            let b = p.assumingMemoryBound(to: UInt8.self)
            let o = idx * 3
            let v = Int32(b[o]) | Int32(b[o + 1]) << 8 | Int32(Int8(bitPattern: b[o + 2])) << 16
            return Float(v) / 8388608
        default: return 0
        }
    }

    var out = [Float](repeating: 0, count: n * outChannels)
    for i in 0..<n {
        if outChannels == 1 && inCh > 1 {
            var s: Float = 0
            for c in 0..<inCh { s += sample(c, i) }
            out[i] = s / Float(inCh)
        } else {
            for c in 0..<outChannels { out[i * outChannels + c] = sample(c, i) }
        }
    }
    return (out, n, asbd.mSampleRate)
}

/// An audio track cut to the take: samples before T0 and after T1 are dropped, sample-exact.
/// A hole in the stream (a late first buffer, a device that hiccups) is filled with silence, so
/// the file keeps the take's clock instead of sliding earlier by the length of the hole.
/// `handle` and `close` run on the track's own queue; the counters are read from the main thread.
final class AudioTrack {
    let url: URL
    let channels: Int
    private var wav: WavWriter?
    private let t0: Double
    private var nextHost: Double?
    private let lock = NSLock()
    private var _t1: Double?
    private var _pausedAt: Double?
    private var _windowStart: Double?
    private var _offset = 0.0
    private var _frames: Int64 = 0
    private var _rate = 0
    private var _first: Double?
    private var _failure: String?
    private var _gaps = 0

    init(url: URL, channels: Int, t0: Double) {
        self.url = url
        self.channels = channels
        self.t0 = t0
    }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var frames: Int64 { locked { _frames } }
    var sampleRate: Int { locked { _rate } }
    var firstSampleHost: Double? { locked { _first } }
    var failure: String? { locked { _failure } }
    /// Holes filled with silence since the start.
    var gaps: Int { locked { _gaps } }

    func end(at t1: Double) { locked { _t1 = t1 } }
    /// A pause is cut out: nothing is kept from `pause` to `resume`, and what follows is written right after.
    func pause(at t: Double) { locked { _pausedAt = t } }
    func resume(at r: Double) { locked { if let p = _pausedAt { _offset += r - p; _windowStart = r; _pausedAt = nil } } }

    /// `ptsHost`: the buffer's first sample on the host clock, in seconds.
    func handle(_ samples: [Float], frames: Int, rate: Double, ptsHost: Double) {
        guard failure == nil else { return }
        let (t1, pausedAt, windowStart, offset) = locked { (_t1, _pausedAt, _windowStart ?? t0, _offset) }
        // The stretch being recorded now, on the host clock: from the start (or the last resume) to the pause (or the end).
        let lo = windowStart
        let hi = [t1, pausedAt].compactMap { $0 }.min()
        let end = ptsHost + Double(frames) / rate
        if end <= lo { return }
        if let hi, ptsHost >= hi { return }
        var from = 0
        if ptsHost < lo { from = min(frames, Int(((lo - ptsHost) * rate).rounded())) }
        var to = frames
        if let hi, end > hi { to = max(from, min(frames, Int(((hi - ptsHost) * rate).rounded()))) }
        guard to > from else { return }
        do {
            // On the file's timeline: host time minus the time paused.
            let start = ptsHost + Double(from) / rate - offset
            if wav == nil {
                wav = try WavWriter(url: url, sampleRate: Int(rate.rounded()), channels: channels)
                locked { _first = start + offset; _rate = Int(rate.rounded()) }
                nextHost = t0
            }
            // Only real holes (over 20 ms): the normal jitter between two buffers must not add samples.
            if let expected = nextHost, start - expected > 0.02 {
                try wav?.appendSilence(frames: Int(((start - expected) * rate).rounded()))
                locked { _gaps += 1 }
            }
            try wav?.append(samples[(from * channels)..<(to * channels)])
            nextHost = ptsHost + Double(to) / rate - offset
            let n = wav?.frames ?? 0
            locked { _frames = n }
        } catch {
            locked { _failure = error.localizedDescription }
        }
    }

    func close() { wav?.close() }
}
