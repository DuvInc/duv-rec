import Testing
@testable import DuvRec

@Test func settingsFromAnOlderVersionKeepTheirValues() throws {
    // A setting added in a later version must take its default, not reset everything else.
    let s = try #require(decodeSettings(#"{"fps": 60, "cameraOn": false, "quality": "high"}"#))
    #expect(s.fps == 60)
    #expect(s.cameraOn == false)
    #expect(s.quality == .high)
    #expect(s.micOn == RecSettings().micOn)
    #expect(s.systemAudio == RecSettings().systemAudio)
}

@Test func anUnknownValueFallsBackToItsDefault() throws {
    let s = try #require(decodeSettings(#"{"quality": "ultra", "screenMode": "window", "fps": 30}"#))
    #expect(s.quality == .standard)
    #expect(s.screenMode == .display)
    #expect(s.fps == 30)
}

@Test func settingsRoundTrip() throws {
    var s = RecSettings()
    s.screenMode = .region
    s.region = rect(10, 20, 640, 360)
    s.cameraWanted = "cam-1"
    let back = try #require(roundTrip(s))
    #expect(back == s)
    #expect(back.activeRegion == rect(10, 20, 640, 360))
}

@Test func theCameraKeepsHalfTheBitrateOfHighByDefault() {
    #expect(RecSettings().quality == .standard)
    #expect(Quality.standard.camera < Quality.high.camera)
    // The screen does not follow the camera down: its text must stay crisp, and it is cheap.
    #expect(Quality.standard.screen == Quality.high.screen)
}

// MARK: Device defaults

private let cameras = [
    DeviceChoice(id: "webcam", name: "Acme 4K Webcam", wired: true),
    DeviceChoice(id: "virtual", name: "Acme Virtual Camera", wired: false, virtual: true),
    DeviceChoice(id: "builtin", name: "MacBook Pro Camera"),
]

@Test func aPluggedInCameraWinsOverTheBuiltInOne() {
    #expect(CaptureRig.defaultCamera(cameras)?.id == "webcam")
    #expect(CaptureRig.defaultCamera(Array(cameras.dropFirst()))?.id == "builtin")
}

@Test func aVirtualCameraIsNeverTheDefault() {
    // It relays another camera and showed a "camera off" card instead of a picture.
    #expect(CaptureRig.defaultCamera([cameras[1], cameras[2]])?.id == "builtin")
    #expect(DeviceChoice(id: "x", name: "OBS Virtual Camera").virtual)
}

@Test func aUSBMicrophoneWinsButNotTheWebcamsOwn() {
    // A webcam carries its own microphone, also on USB, and listed first: usually the worst one in the room.
    let mics = [
        DeviceChoice(id: "webcam-mic", name: "Acme 4K Webcam", wired: true),
        DeviceChoice(id: "usb-mic", name: "Studio USB Mic", wired: true),
        DeviceChoice(id: "builtin-mic", name: "MacBook Pro Microphone"),
    ]
    #expect(CaptureRig.defaultMic(mics, cameras: cameras, systemDefault: "builtin-mic")?.id == "usb-mic")
    #expect(CaptureRig.defaultMic([mics[0], mics[2]], cameras: cameras, systemDefault: "builtin-mic")?.id == "builtin-mic")
}
