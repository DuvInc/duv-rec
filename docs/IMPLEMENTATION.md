# Duv Rec: implementation notes

How the recorder was built, what went wrong on the way, what was measured, and what it still does not do. Written for version 0.1.0 (2026-11-16), kept up to date since. User guide: [README](../README.md).

## Why it exists

Screen Studio recorded a 39-minute shoot with the microphone as AAC 64 kb/s mono and the webcam as HEVC at quality 0.6, capped to 1080p (0.65 Mb/s), whatever the hardware (a RØDE NT-USB Mini and a 4K Insta360 Link 2C Pro). Those two tracks were the quality ceiling of the film and no processing recovers them. Duv Rec only captures: no editor, no export. Each source goes to its own file at master quality, and whatever editor or pipeline comes next does the rest.

## Layout

```
.
├── README.md               user guide
├── AGENTS.md               how to work in this repository
├── docs/IMPLEMENTATION.md  this file
├── Package.swift           SwiftPM, Swift 5 language mode, macOS 14+
├── Sources/DuvRec/
│   ├── App.swift           window, source tiles, recording panel, menu bar item
│   ├── Recorder.swift      state machine, settings, devices, start and stop of a take
│   ├── Capture.swift       ScreenCapture (ScreenCaptureKit), CaptureRig (AVFoundation), device defaults
│   ├── Session.swift       RecSettings, RecordingSession (one take, its tracks, session.json)
│   ├── Writers.swift       VideoTrackWriter (HEVC .mov), WavWriter, AudioTrack
│   └── RegionPicker.swift  the area picker overlay and the red frame during a take
├── Tests/DuvRecTests/      Swift Testing, no device: WAV, cut to the take, pauses, gaps, settings, device defaults
├── Resources/              Info.plist, entitlements
├── Assets/                 AppIcon.svg and the generated .icns
└── scripts/                install.sh, setup-signing.sh, test.sh
```

## Design

**One clock.** Every track is cut to the same window of the host clock, `[T0, T1]`. `T0` is set half a second after every source is flowing. A video file opens its session at `T0` (the screen repeats the frame showing at `T0` if nothing moved), an audio track drops the samples before `T0`, and every track ends at `T1`. The files line up as they are.

**A pause is cut out of the files.** Nothing is written between pause and resume, and everything after is written earlier by the total time paused: video frames are re-timed (`CMSampleBufferCreateCopyWithNewTiming`, the picture is shared, not copied), audio samples are dropped sample-exact at the same two instants of the host clock. One continuous file per track, still aligned. At resume the screen's latest picture is written at the resume point, because a screen that changed during the pause and is still again sends no new frame. Stopping while paused ends the take at the pause.

**Camera and microphone share one `AVCaptureSession`,** so they share its synchronization clock; times are converted to the host clock with `CMSyncConvertTime`. The screen and the system audio come from one `SCStream`, already on the host clock.

**Crash safety without chunks.**
- Video: `AVAssetWriter.movieFragmentInterval = 2 s`. A file cut mid-write opens up to its last fragment. Cost: about 1 to 2 kB per fragment, 3 MB per hour.
- Audio: a hand-written 32-bit float WAV. Samples go straight to disk, the header is rewritten every second.
- `session.json` is written at the start and every 10 s with status `recording`, then `complete`.
- Rotating files every N minutes was rejected: same safety, plus seams to rejoin.

**Hardware encoding.** HEVC through VideoToolbox (the media engine), constant quality: Standard (default) 0.75 on the camera, High 0.85, Maximum 0.90; the screen stays at 0.85 (0.90 in Maximum), cheap and its text must stay crisp. The cores stay free for what is being recorded.

**The app's own windows are never recorded.** The stream's content filter excludes the application, so the floating panel, the menu bar item and the red frame around a drawn area can stay on screen.

## Measured

| What | Result |
| :--- | :--- |
| 45 min, Retina screen at 60 fps + Insta360 4K + RØDE, High | 81,011 camera frames all 32 to 35 ms apart, none dropped on camera or screen, no audio gap, mic clock 12 ppm slow (32 ms over 45 min), 27 to 29% of one core, memory 107 MB then 66 MB over the last 15 min, Mac kept awake; camera 22.1 GB (65 Mb/s in a dim room) |
| `kill -9` mid-take | 12.0 s readable on camera, screen and mic, no decode error |
| 5 min, Retina screen at 60 fps + Insta360 4K + RØDE | 9,011 camera frames all 33 ms apart, 12,751 screen frames, none dropped, no audio gap, tracks within 2 ms, mic clock −9 ppm |
| Load during that take | 19 to 25% of one core, 105 MB, flat |
| Pause of 5 s inside a 12 s take, four tracks | 9.320 s on camera, screen, mic and system audio; camera frames 33 ms apart across the pause (largest gap 37 ms) |
| Standard vs High, Insta360 4K in low light, against an uncompressed capture of the same 12 s | camera 0.75: 24 Mb/s, VMAF 94.1; 0.85: 48 Mb/s, 96.4; 0.65: 8 Mb/s, 90.3; 0.90: 82 Mb/s, 97.2. A 100% crop of the face shows no difference between 0.75 and 0.85. In the app: 18 Mb/s for the camera in Standard |
| Load against Screen Studio, same sources (screen, Insta360 4K, RØDE), 75 s each | Duv Rec ≈ 42% of one core (app 29%, system capture and codecs 13%), Screen Studio ≈ 50% (+7% on WindowServer); Screen Studio's webcam is HEVC 0.6 at 4.5 Mb/s, its voice AAC 64 kb/s |
| Quality 0.85 (High) | VMAF 97.1 on the camera at 10.5 Mb/s (1080p), 97.2 on a scrolling screen at 4 Mb/s, against a near-lossless take |
| Quality 0.90 / 0.95 | 98.0 at 23.5 Mb/s / 94 Mb/s: twice and nine times the size for under one VMAF point |
| Blind test, the same 10 s of 4K camera at 0.60 (Screen Studio), 0.75, 0.85 and 0.90, shuffled, converted to ProRes HQ | no level could be told apart in normal playback. The first reference capture (raw 4K written by ffmpeg) froze 1.5 s and dropped a frame every half second; ProRes HQ kept up (418 frames in 13.9 s, none missing). ProRes sizes ranked the levels backwards: the 0.60 file was the largest, its block edges are expensive to re-encode |
| Size per hour, High | camera 4K ≈ 20 GB in a dim room (45 Mb/s), 1080p ≈ 5 GB, screen ≈ 1 GB, voice 0.7 GB, system audio 1.4 GB |
| Webcam lag (Insta360 Link 2C Pro) | hands meet 50 to 84 ms after the clap is heard: delay the voice by about 70 ms when muxing |

## Pitfalls met, in the order they bit

Each one cost a broken take or a crash. They are the checklist for anyone touching the capture code.

1. **`AVCaptureVideoPreviewLayer` starves the data output.** Attached to the session, it let the video data output deliver one frame and then nothing: the camera track came out empty. The preview is an `AVSampleBufferDisplayLayer` fed with the frames being recorded.
2. **Reconfiguring a running session.** Adding inputs again to a running `AVCaptureSession` (it happened twice at launch) also stopped the frames. A real change stops the session, rebuilds it, starts it; an identical request does nothing.
3. **Non-16:9 formats.** The MacBook camera offers a 1552×1552 Center Stage format that delivers no frame to a capture output. Only 16:9 formats are candidates.
4. **Virtual cameras.** "Insta360 Virtual Camera" relays another camera and showed a "camera off" card. A device on the virtual transport, or with "virtual" in its name, is never the default.
5. **Format and frame rate are overridden when the session starts.** On the Insta360, the format chosen before `startRunning()` came out as 1080p or as 25 fps. Applied again on the running session it holds: 4K at 30 fps. The stream restarts for it, so the rig waits 2 s before reporting ready.
6. **Frame durations must come from the format's own ranges.** The Insta360 declares fixed rates, 30.00003 among them. Setting exactly 1/30 outside a declared range raises an Objective-C exception, which Swift cannot catch.
7. **`FileHandle.write(_:)` raises on a full or missing disk.** Same uncatchable exception. Every write uses the throwing API (`write(contentsOf:)`, `seekToEnd()`); a failed track stops the take within half a second and says so.
8. **Drawing outside `draw(_:)`.** A fill call that ended up in a layout method crashed the area picker as soon as it opened.
9. **Clicks pass through transparent pixels.** The picked area is a hole in the dimming overlay, and macOS sends clicks on fully transparent pixels to the window below. The overlay sets `ignoresMouseEvents = false` and fills the hole at 1% opacity.
10. **Keys only reach the key window.** With one overlay per display, Escape worked on one screen only. A local event monitor handles Escape and Return and swallows the rest while picking.
11. **Screen colours.** Left to its default, `SCStreamConfiguration` delivers the display's colour space (P3 on a MacBook) while the file is tagged Rec. 709. `colorSpaceName = sRGB` makes pixels and tags agree.
12. **Sleep and App Nap.** Nothing kept the Mac awake during a take. `ProcessInfo.beginActivity` with the idle-sleep options is held from start to stop (visible in `pmset -g assertions`).
13. **A source that is on but not delivering.** A camera still starting, or a microphone unplugged, was left out of the take without a word. The take now refuses to start and says which source is missing.
14. **A device preference that did not survive an unplug.** Falling back to the built-in camera overwrote the choice, so the Insta360 was not taken back when it returned. The hand-picked device is stored apart (`cameraWanted`, `micWanted`) from the one in use.
15. **Device types do not tell microphones apart.** A USB microphone, a webcam's microphone and the built-in one are all `.microphone`. The default comes from the transport (`usb `, `thun`, `bltn`, `virt`), and a microphone named like a connected camera is the webcam's own and is skipped.
16. **Holes in an audio stream.** Appending buffers end to end slides the voice earlier by the length of any hole. Holes over 20 ms are filled with silence and counted (`gaps_filled`); the 20 ms threshold keeps normal jitter from adding samples.
17. **An interrupted take at import.** Its sample count in `session.json` is up to 10 s old; an importer that computes a microphone drift from it would resample the voice by several percent. For a take whose status is not `complete`, use the shortest track as the duration and correct no drift.
18. **Screen recording permission.** The stream fails with `SCStreamError.userDeclined` until the user enables the app in System Settings and relaunches it. The window says so, opens the right pane and can relaunch itself.
19. **Swift 6 language mode.** Its dynamic actor isolation checks crashed at AppKit callback boundaries in a sibling app built the same way. The package stays in Swift 5 mode; capture callbacks run on their own serial queues.
20. **Hiding the window quits the app.** With "quit when the last window closes" on, `orderOut` on the only window counts as closed: the take ended as it began (duration −0.47 s). The delegate answers no while a take is running or restarting.
21. **A re-timed frame needs its duration.** Copied with an invalid duration, the last frame of a still screen was not held to the end of the take and the track came out half a second short.
22. **SwiftPM after moving the folder.** The module cache holds absolute paths: `swift package clean` once.

## Known limits

- **WAV over 4 GB.** Sizes are 32-bit: past about 6 h of mono voice (3 h of stereo system audio) the header stays at its maximum. The samples are on disk and ffmpeg reads to the end of the file; other software may not. RF64 would fix it.
- **Webcam lag is not compensated.** A webcam delivers its picture late: 50 to 84 ms on an Insta360 Link 2C Pro (clap test), so delay the voice by about 70 ms against the camera when you mux them. A sync mark at the start of a take (a flash and a beep) would measure it per take.
- **No window capture.** A display or a drawn area.
- **Camera exposure and white balance** are left to the camera's own software.
- **No recovery pass.** After a crash the files are readable but `session.json` still says `recording` and holds stale counts.
- **Thread safety is by convention.** Each writer is touched from its own queue; the counters read from the main thread are lock-protected for audio and plain reads for video.
- **Not tested:** unplugging a device mid-take, a disk that really fills up, two displays, a second user account, an Intel Mac.
- **Not notarized.** You build it yourself and sign it with a local identity (`scripts/setup-signing.sh`). A downloadable build would need a Developer ID, the hardened runtime and notarization.
