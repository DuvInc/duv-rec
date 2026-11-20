import Testing
@testable import DuvRec

/* The audio tracks carry most of the sync logic of a take: they cut a live stream to [T0, T1]
   sample-exact, cut pauses out, and fill holes with silence so the file keeps the take's clock.
   Each test here stands for a way a take came out wrong once, or could. No device needed: the
   buffers are made up, their sample values are their index in the stream, so a read-back says
   exactly which samples were kept. */

@Test func wavHeaderDescribesFloat32() {
    let h = header(frames: 48_000, channels: 2)
    #expect(h.bytes == 44)
    #expect(h.ascii == "RIFF")
    #expect(h.file.format == 3) // IEEE float, not PCM: the voice stays as the microphone delivered it
    #expect(h.file.channels == 2)
    #expect(h.file.sampleRate == 48_000)
    #expect(h.file.dataBytes == 48_000 * 2 * 4)
}

@Test func wavHeaderPastFourGigabytesStaysAtTheMaximum() {
    // Past 4 GB the 32-bit sizes would wrap around and announce a tiny file. They stay at the
    // maximum instead, which ffmpeg reads as "until the end of the file".
    let h = header(frames: 600_000_000, channels: 2)
    #expect(h.file.riffBytes == UInt32.max)
    #expect(h.file.dataBytes == UInt32.max)
}

@Test func samplesBeforeT0AreDroppedSampleExact() throws {
    let track = makeTrack(channels: 1)
    feed(track, from: -2_400, frames: 4_800) // straddles T0: half before, half after
    let wav = try #require(closeAndRead(track))
    #expect(wav.samples.count == 2_400)
    #expect(wav.samples.first == 0) // the sample at T0 exactly
    #expect(wav.dataBytes == 2_400 * 4) // the header was rewritten at close
    #expect(track.gaps == 0)
}

@Test func aLateFirstBufferIsPaddedSoTheTrackStillStartsAtT0() throws {
    // The microphone's first buffer arrived 50 ms after T0. Written as is, the whole voice would
    // play 50 ms early against the picture.
    let track = makeTrack(channels: 1)
    feed(track, from: 2_400, frames: 480)
    let wav = try #require(closeAndRead(track))
    #expect(wav.samples.count == 2_880)
    #expect(wav.samples[2_399] == 0)
    #expect(wav.samples[2_400] == 2_400)
    #expect(track.gaps == 1)
}

@Test func normalJitterAddsNoSamples() throws {
    // Buffers rarely land back to back to the sample. Below 20 ms a hole is jitter, not a hole:
    // filling it would add samples the stream never lost and slide the voice later over time.
    let track = makeTrack(channels: 1)
    feed(track, from: 0, frames: 480)
    feed(track, from: 960, frames: 480) // 10 ms after the end of the first
    #expect(try #require(closeAndRead(track)).samples.count == 960)
    #expect(track.gaps == 0)
}

@Test func aRealHoleIsFilledWithSilence() throws {
    // A device that hiccups for 30 ms: the samples after the hole must stay at their own time.
    let track = makeTrack(channels: 1)
    feed(track, from: 0, frames: 480)
    feed(track, from: 480 + 1_440, frames: 480)
    let wav = try #require(closeAndRead(track))
    #expect(wav.samples.count == 480 + 1_440 + 480)
    #expect(wav.samples[1_920] == 1_920)
    #expect(track.gaps == 1)
}

@Test func theTrackEndsAtT1() throws {
    let track = makeTrack(channels: 1)
    track.end(at: testT0 + 0.1)
    feed(track, from: 0, frames: 9_600)     // 0.2 s: only the first 0.1 s is kept
    feed(track, from: 9_600, frames: 480)   // entirely after T1
    #expect(try #require(closeAndRead(track)).samples.count == 4_800)
}

@Test func aPauseIsCutOutAndTheTrackStaysContinuous() throws {
    // One second of stream, paused from 0.3 s to 0.6 s: 0.7 s in the file, with no hole and no
    // silence, and the sample right after the pause is the one recorded at 0.6 s.
    let track = makeTrack(channels: 1)
    var i = 0
    while i < 48_000 {
        if i == 14_400 { track.pause(at: testT0 + 0.3) }
        if i == 28_800 { track.resume(at: testT0 + 0.6) }
        feed(track, from: i, frames: 480)
        i += 480
    }
    let wav = try #require(closeAndRead(track))
    #expect(wav.samples.count == 33_600)
    #expect(wav.samples[14_399] == 14_399)
    #expect(wav.samples[14_400] == 28_800)
    #expect(track.gaps == 0)
}

@Test func stereoKeepsItsChannelsInterleaved() throws {
    let track = makeTrack(channels: 2)
    track.handle([1, -1, 2, -2, 3, -3], frames: 3, rate: testRate, ptsHost: testT0)
    let wav = try #require(closeAndRead(track))
    #expect(wav.channels == 2)
    #expect(wav.samples == [1, -1, 2, -2, 3, -3])
    #expect(track.frames == 3)
}
