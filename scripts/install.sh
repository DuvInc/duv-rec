#!/usr/bin/env bash
# Build Duv Rec, sign it, replace /Applications/Duv Rec.app, relaunch. One command after every change.
#
#   scripts/install.sh               build, sign, install, relaunch
#   scripts/install.sh --no-install  build and sign into dist/ only
#
# Signed with a stable local identity (scripts/setup-signing.sh creates "Duv Rec Local" once; set
# DUVREC_SIGN_IDENTITY to use another one you already have). Every build then keeps the same
# identity, so macOS keeps the Screen Recording, Camera and Microphone grants across builds.
# Without it the build is signed ad hoc and macOS asks again after every build.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$DIR/dist/Duv Rec.app"
SIGN_NAME="${DUVREC_SIGN_IDENTITY:-Duv Rec Local}"

cd "$DIR"
swift build -c release --product DuvRec
BIN="$(swift build -c release --show-bin-path)/DuvRec"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DuvRec"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # from Assets/AppIcon.svg (rsvg-convert + iconutil)

if security find-identity -p codesigning | grep -q "\"$SIGN_NAME\""; then
  SIGN_ID="$SIGN_NAME"
else
  echo "No \"$SIGN_NAME\" signing identity: run scripts/setup-signing.sh once, or macOS asks for permissions again after every build." >&2
  SIGN_ID="-"
fi
codesign --force --deep --sign "$SIGN_ID" --entitlements Resources/DuvRec.entitlements "$APP"

if [[ "${1:-}" == "--no-install" ]]; then echo "Built $APP"; exit 0; fi
pkill -x DuvRec 2>/dev/null || true
sleep 1
rm -rf "/Applications/Duv Rec.app"
cp -R "$APP" "/Applications/Duv Rec.app"
open "/Applications/Duv Rec.app"
echo "Installed /Applications/Duv Rec.app (signed: $SIGN_ID)"
