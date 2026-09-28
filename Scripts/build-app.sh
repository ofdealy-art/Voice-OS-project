#!/bin/bash
#
# Builds ScreenMate.app from the Swift package.
#
# SwiftPM produces a bare executable, but macOS will not grant Screen Recording,
# Microphone or Speech Recognition permission to one: TCC keys its decisions on a
# bundle identifier and a code signature. So this assembles a proper .app around
# the binary and signs it.
#
#   ./Scripts/build-app.sh            # debug build into ./dist
#   ./Scripts/build-app.sh release    # optimised build
#
set -euo pipefail

CONFIGURATION="${1:-debug}"
APP_NAME="ScreenMate"
BUNDLE_ID="com.screenmate.ScreenMate"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: ScreenMate is a macOS app and can only be built on macOS." >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "error: the Swift toolchain was not found. Install Xcode or the Swift toolchain, then retry." >&2
  exit 1
fi

echo "==> Building ($CONFIGURATION)"
swift build --configuration "$CONFIGURATION" --product "$APP_NAME"

BIN_PATH="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
EXECUTABLE="$BIN_PATH/$APP_NAME"

if [[ ! -x "$EXECUTABLE" ]]; then
  echo "error: the built executable was not found at $EXECUTABLE" >&2
  exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$EXECUTABLE" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Copy any SwiftPM resource bundles the build produced (none today, but this
# keeps the script correct if a target gains resources).
shopt -s nullglob
for bundle in "$BIN_PATH"/*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

echo "==> Signing"
# An ad-hoc signature is enough for TCC to remember its decisions on the machine
# that built the app. Set SCREENMATE_SIGN_IDENTITY to a Developer ID to produce a
# build that runs elsewhere.
IDENTITY="${SCREENMATE_SIGN_IDENTITY:--}"
codesign --force --deep \
  --sign "$IDENTITY" \
  --options runtime \
  --entitlements "$ROOT/Resources/ScreenMate.entitlements" \
  --identifier "$BUNDLE_ID" \
  "$APP"

codesign --verify --verbose=2 "$APP"

cat <<EOM

Built: $APP

Run it with:
  open "$APP"

First launch:
  • macOS will ask for Microphone and Speech Recognition the first time you use voice.
  • Screen Recording must be granted in System Settings › Privacy & Security, and
    macOS requires the app to be quit and reopened before it takes effect.
  • Add an API key in Settings › Provider. Until then ScreenMate runs against its
    offline demo provider.

If macOS refuses to capture the screen after you granted permission, remove the
stale entry:  tccutil reset ScreenCapture $BUNDLE_ID   then reopen the app.
EOM
