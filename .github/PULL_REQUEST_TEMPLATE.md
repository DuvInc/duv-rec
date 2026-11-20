## What this changes

<!-- One or two sentences. If it fixes an issue, write "Fixes #123". -->

## Why

<!-- What went wrong or could not be done before. -->

## How it was checked

<!-- A capture change is checked on a real take: say the devices, the length, and what session.json and ffprobe said (frames, dropped, gaps_filled, track durations). -->

## Checklist

- [ ] `scripts/test.sh` passes locally
- [ ] Commits are signed off (`git commit -s`); see CONTRIBUTING.md
- [ ] A fix to the sync or audio logic comes with a test in `Tests/DuvRecTests/` that fails without it
- [ ] A capture change was checked on a real take, and the result is written above
- [ ] Every track still starts at T0 and ends at T1 (durations within a few ms in `ffprobe`)
- [ ] No new dependency, and still no network call
- [ ] Swift 5 language mode kept (see AGENTS.md)
- [ ] No recorded take, no personal path, no device serial number in this diff
