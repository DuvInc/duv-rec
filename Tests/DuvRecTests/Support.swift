/* Foundation lives in this file only, and Swift Testing in the others. Importing both in one file
   loads their cross-import overlay, which the Command Line Tools do not ship ("no such module
   _Testing_Foundation"): kept apart, `scripts/test.sh` runs on a Mac without Xcode. */
import CoreGraphics
import Foundation
@testable import DuvRec

let testRate = 48_000.0
let testT0 = 1_000.0

func makeTrack(channels: Int = 1) -> AudioTrack {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("duvrec-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return AudioTrack(url: dir.appendingPathComponent("track.wav"), channels: channels, t0: testT0)
}

/// A mono buffer of `frames` samples starting at stream index `from`, stamped on the host clock.
/// Each sample's value is its index in the stream, so a read-back says exactly which ones were kept.
func feed(_ track: AudioTrack, from: Int, frames: Int) {
    let samples = (from..<from + frames).map(Float.init)
    track.handle(samples, frames: frames, rate: testRate, ptsHost: testT0 + Double(from) / testRate)
}

struct WavFile {
    let riffBytes: UInt32
    let format: UInt16
    let channels: Int
    let sampleRate: Int
    let dataBytes: UInt32
    let samples: [Float]
}

private func parse(_ d: Data) -> WavFile {
    func u32(_ o: Int) -> UInt32 { d.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
    func u16(_ o: Int) -> UInt16 { d.subdata(in: o..<o + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) } }
    let body = d.count > 44 ? d.subdata(in: 44..<d.count) : Data()
    let samples = body.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    return WavFile(riffBytes: u32(4), format: u16(20), channels: Int(u16(22)), sampleRate: Int(u32(24)), dataBytes: u32(40), samples: samples)
}

/// Closes the track and reads its file back.
func closeAndRead(_ track: AudioTrack) -> WavFile? {
    track.close()
    guard let d = try? Data(contentsOf: track.url) else { return nil }
    return parse(d)
}

func header(frames: Int64, channels: Int) -> (bytes: Int, ascii: String, file: WavFile) {
    let d = WavWriter.header(frames: frames, channels: channels, sampleRate: 48_000)
    return (d.count, String(data: d.prefix(4), encoding: .ascii) ?? "", parse(d))
}

func decodeSettings(_ json: String) -> RecSettings? {
    try? JSONDecoder().decode(RecSettings.self, from: Data(json.utf8))
}

func roundTrip(_ s: RecSettings) -> RecSettings? {
    guard let d = try? JSONEncoder().encode(s) else { return nil }
    return try? JSONDecoder().decode(RecSettings.self, from: d)
}

func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
