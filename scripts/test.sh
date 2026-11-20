#!/usr/bin/env bash
# `swift test`, also on a Mac with only the Command Line Tools: they ship Swift Testing, but outside
# the default search path. With Xcode installed this is plain `swift test`.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [[ "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools* && -d "$F/Testing.framework" ]]; then
  exec swift test -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" "$@"
fi
exec swift test "$@"
