// swift-tools-version: 5.9
// Swift 5 language mode on purpose: the Swift 6 runtime's dynamic actor-isolation checks crashed
// at AppKit/SwiftUI callback boundaries, and capture callbacks run on their own serial queues,
// which is exactly that boundary.

import PackageDescription

let package = Package(
    name: "DuvRec",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DuvRec", targets: ["DuvRec"])],
    targets: [
        .executableTarget(name: "DuvRec", path: "Sources/DuvRec"),
        // The parts that carry judgment and need no device: the WAV file, the cut of an audio
        // stream to the take, pauses, gap filling, settings decoding, device defaults.
        .testTarget(name: "DuvRecTests", dependencies: ["DuvRec"], path: "Tests/DuvRecTests"),
    ]
)
