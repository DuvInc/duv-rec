# Security policy

## Reporting a vulnerability

Please report privately rather than in a public issue, using GitHub's
[private vulnerability reporting](https://github.com/DuvInc/duv-rec/security/advisories/new)
on this repository.

This is a one-person project. You should get an acknowledgement within a few days; if a week passes
with no reply, feel free to nudge by opening a public issue that says only that you are waiting on a
private report, with no details.

## What the app does with what it records

It records the screen, the camera, the microphone and the Mac's sound, only between Start and Stop,
and writes them to the folder you chose (`~/Movies/Duv Rec` by default). It makes no network call,
has no analytics and no update check. Its settings live in its own user defaults.

## What is in scope

- **Recording outside a take.** Anything that makes the app capture the screen, the camera, the
  microphone or the Mac's sound before Start or after Stop, or write it anywhere other than the take
  folder.
- **Data leaving the Mac.** Any network traffic from the app.
- **The take folder.** Writing outside it, or a crafted settings value (`folder`) that makes the app
  write somewhere it should not.
- **The scripts.** `scripts/install.sh` and `scripts/setup-signing.sh` touch `/Applications` and the
  login keychain. A way for them to do more than they say is in scope.

## What is out of scope

- macOS itself, ScreenCaptureKit, AVFoundation and the device drivers. Report those to Apple or the
  device maker.
- What macOS shows in the picture: notifications, other apps' windows. The app records what is on
  screen; hiding it is up to you (Focus modes, a drawn area).
- The local signing identity being self-signed. It exists so macOS keeps the permissions across your
  own builds; it is not meant to vouch for the app to anyone else.
- A problem that needs the attacker to already run code as you or have commit access.

## If you record

- **A take holds everything that was on screen and in the room.** Check it before you share it.
- **Never attach a take to an issue.** `session.json` is enough to debug almost anything.

## If you forked this app

Replace the link above with your own repository. This file arrived with the code and points at
somebody else's advisories.
