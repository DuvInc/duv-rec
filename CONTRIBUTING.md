# Contributing

Thanks for looking. This is a one-person project maintained on a best-effort basis, so the most
useful thing you can do before writing code is open an issue. A small fix is always welcome; a large
one is worth agreeing on first.

## Getting set up

macOS 14 or newer, Swift 5.9 or newer (Xcode, or only the Command Line Tools).

```bash
scripts/test.sh                 # no device, no permission, no network
scripts/setup-signing.sh        # once: a local signing identity, so permissions survive rebuilds
scripts/install.sh              # build, sign, install in /Applications, relaunch
```

`scripts/test.sh` is `swift test`, plus the framework path the Command Line Tools need for Swift
Testing. If it does not pass on a fresh clone, that is a bug worth reporting on its own.

## Sign your commits off

Every commit needs a `Signed-off-by` line, which certifies that you wrote the patch or otherwise
have the right to submit it under the MIT licence. This is the
[Developer Certificate of Origin](https://developercertificate.org): one line, no paperwork, no
copyright assignment.

```bash
git commit -s -m "Your message"
```

## What makes a change likely to be merged

**A sync or audio fix comes with its test.** The cut to `[T0, T1]`, pauses and gap filling are
tested with made-up buffers in `Tests/DuvRecTests/`. Write the test that fails without your fix,
with a comment that says what it stops from coming back.

**A capture change is checked on a real take.** Say the devices, the length of the take, and what
`session.json` and `ffprobe` said: frames written and dropped, `gaps_filled`, and the duration of
every track. Every track must still start at T0 and end at T1.

**It still only captures.** No editor, no export, no network call. Those belong in whatever comes
after the take.

**Nothing raises an Objective-C exception.** Swift cannot catch one, and it kills the app mid-take.
Use the throwing APIs (`write(contentsOf:)`, `seekToEnd()`) and keep frame durations inside a
format's declared ranges. `docs/IMPLEMENTATION.md` lists the ones already met.

**Swift 5 language mode stays.** See `AGENTS.md`.

**No new dependency without an issue first.** **Comments explain why, not what.** **No em dashes.**

## Reporting a bug

Include the commit, the macOS version, the Mac, the camera and microphone, and the take's
`session.json`. It holds settings and counts, nothing you recorded. Never attach the `.mov` or
`.wav` files of a take.

For anything with security implications, read [SECURITY.md](./SECURITY.md) instead of opening a
public issue.
