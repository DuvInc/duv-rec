---
name: duv-rec
description: Record a take with Duv Rec (screen, webcam, microphone and Mac sound as separate, aligned master-quality files on macOS), check it, and bring it into an editing pipeline. Use when a person asks to record a screen or camera take with this app, to verify a take, or to mux or import its files. Not for editing the video itself.
---

# Recording and importing a Duv Rec take

## Before a take

- The app is built and installed from this repository (`scripts/setup-signing.sh` once, then `scripts/install.sh`). Never run `install.sh` while a take is recording: it kills the app.
- Screen, Camera and Microphone permissions are granted (System Settings > Privacy & Security). Screen recording applies after a relaunch.
- At least 5 GB free on the take folder's volume, or the take does not start.

## Recording without clicking

```bash
open -a "Duv Rec" --args --test-take <seconds>
```

It uses the settings saved in the app (sources, devices, area, quality). The take lands in a new dated folder under the take folder (`~/Movies/Duv Rec` by default). Wait `seconds + 5` before reading it.

## Checking a take

1. `session.json`: `status` is `complete`; `dropped` is 0 or close on each video track; `gaps_filled` is 0 or small on each audio track.
2. Every track has the same duration within a few milliseconds:
   `for f in *.mov *.wav; do ffprobe -v error -show_entries format=duration -of csv=p=0 "$f"; done`
3. If `status` is `recording`, the app did not stop cleanly: the files are readable to their last fragment, but the counts in `session.json` are stale.

## Importing

- Lay the tracks at zero: no sync step.
- Delay the voice against the webcam by the camera's lag (about 70 ms measured on an Insta360 Link 2C Pro; measure yours with a clap). No delay against the screen.
- Microphone drift: `samples / (duration × sample_rate)`. Resample only for a `complete` take; for an interrupted one, use the shortest track as the duration and correct nothing.
- Copy the video streams (`-c:v copy`); keep the voice lossless (ALAC or WAV).

```bash
ffmpeg -i camera.mov -i mic.wav -map 0:v -map 1:a -c:v copy -af "adelay=70:all=1" -c:a alac -shortest rush.mov
```

## Never

- Attach a take's `.mov` or `.wav` to an issue or a message: it holds everything that was on screen and in the room. `session.json` is enough to debug.
