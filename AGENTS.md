# AGENTS.md

How to work in this repository. Claude Code, Codex, Cursor and the others all read this one file.

Duv Rec is a macOS app (SwiftUI + AppKit, SwiftPM, no Xcode project) that records the screen, the webcam, the microphone and the Mac's sound into separate files cut to the same instant. User guide: [README.md](README.md). Design, measurements and pitfalls: [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md).

## Layout

| Path | What |
| :--- | :--- |
| `Sources/DuvRec/App.swift` | the window, source tiles, footer, menu bar item during a take |
| `Sources/DuvRec/Recorder.swift` | state machine (idle, starting, recording, stopping), devices, start, pause, stop, restart, the `--test-*` flags |
| `Sources/DuvRec/Capture.swift` | `ScreenCapture` (ScreenCaptureKit: screen and the Mac's sound), `CaptureRig` (AVFoundation: camera and microphone in one session), device defaults |
| `Sources/DuvRec/Session.swift` | `RecSettings` (persisted in user defaults), `Quality`, `RecordingSession` (one take: the `[T0, T1]` window, pauses, `session.json`) |
| `Sources/DuvRec/Writers.swift` | `VideoTrackWriter` (HEVC `.mov`, fragmented), `WavWriter` (float32 WAV), `AudioTrack` (cut to the take, pauses, gap filling) |
| `Sources/DuvRec/RegionPicker.swift` | the area picker overlay and the red frame shown around the area during a take |
| `Tests/DuvRecTests/` | Swift Testing. `Support.swift` is the only test file that imports Foundation (see rule 6) |
| `scripts/` | `install.sh` (build, sign, install, relaunch), `setup-signing.sh` (local identity, once), `test.sh` |
| `skills/duv-rec/SKILL.md` | the procedure for an agent recording or importing a take |

## Commands

```bash
scripts/test.sh                                  # unit tests, no device, no permission
swift build                                      # debug build, fast compile check
scripts/install.sh --no-install                  # release build signed into dist/, nothing replaced
scripts/install.sh                               # replaces /Applications/Duv Rec.app and relaunches it
open -a "Duv Rec" --args --test-take 20          # a real 20 s take with the saved settings
open -a "Duv Rec" --args --test-take 12 --test-pause 5   # pause a third of the way in, for 5 s
open -a "Duv Rec" --args --test-take 12 --test-stop-paused
open -a "Duv Rec" --args --test-take 12 --test-restart
open -a "Duv Rec" --args --pick-region           # opens the area picker at launch
```

Check a take with `ffprobe` (duration of every track, frame count) and its `session.json` (`dropped`, `gaps_filled`, `status`).

## Rules

1. **It only captures.** No editor, no export, no network call, no analytics. A feature that needs one of these belongs in another tool.
2. **Every track is cut to `[T0, T1]` of the host clock.** Camera and microphone times come from the capture session's clock and go through `CMSyncConvertTime`. A change that lets one track start or end elsewhere breaks every editor timeline downstream.
3. **No Objective-C exception, ever.** Swift cannot catch one and it kills the app mid-take. Throwing file APIs only (`write(contentsOf:)`, `seekToEnd()`), frame durations from the format's declared ranges, no drawing outside `draw(_:)`.
4. **A source that is on must deliver, or the take does not start.** Never leave a track out without saying so.
5. **Swift 5 language mode.** Swift 6's dynamic actor-isolation checks crashed at AppKit callback boundaries, and the capture callbacks run on their own serial queues. Each writer is touched from its own queue only.
6. **Tests need no device and no Xcode.** Keep `import Foundation` and `import Testing` in separate test files: together they load a cross-import overlay the Command Line Tools do not ship.
7. **A fix to the sync or audio logic comes with a test** in `Tests/DuvRecTests/` that fails without it.
8. **No dependency.** Apple frameworks only.
9. **English everywhere, no em dashes.** Comments say why, and keep what broke before.

## Things that bite

- `AVCaptureVideoPreviewLayer` on the session stops the video data output after one frame. The preview is an `AVSampleBufferDisplayLayer` fed with the recorded frames.
- Re-adding inputs to a running `AVCaptureSession` stops the frames: stop, rebuild, start.
- Some cameras override the format chosen before `startRunning()`; it is applied again once the session runs.
- Device types do not tell a USB microphone from the built-in one; the transport type does.
- Screen recording permission only applies to a fresh process: the app relaunches itself.
- An ad-hoc signature is a new app to macOS each build: every permission is asked again. `scripts/setup-signing.sh` once.
- After moving the folder, SwiftPM's module cache holds absolute paths: `swift package clean`.
- `scripts/install.sh` kills the running app. Never run it while a take is recording.

The full list, with how each one was found: [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md), "Pitfalls met".
