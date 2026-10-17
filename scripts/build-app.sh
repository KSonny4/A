#!/usr/bin/env bash
# Builds Flare.app from the Swift package.
#
#   scripts/build-app.sh            build into ./build/Flare.app
#   scripts/build-app.sh --install  also copy to /Applications and launch it
#
# Set FLARE_SIGN_IDENTITY to a codesigning identity (e.g. "Apple Development: you@example.com")
# to keep macOS permissions (Accessibility) across rebuilds. Defaults to ad-hoc signing.
set -euo pipefail

cd "$(dirname "$0")/.."
INSTALL=0
[[ "${1:-}" == "--install" ]] && INSTALL=1

echo "▸ Building release binary"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/Flare.app"
echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Flare" "$APP/Contents/MacOS/Flare"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENTITY="${FLARE_SIGN_IDENTITY:--}"
echo "▸ Signing ($IDENTITY)"
codesign --force --deep --timestamp=none --sign "$IDENTITY" "$APP"

if [[ $INSTALL == 1 ]]; then
  echo "▸ Installing to /Applications"
  osascript -e 'tell application id "dev.flare.Flare" to quit' >/dev/null 2>&1 || true
  pkill -x Flare >/dev/null 2>&1 || true
  sleep 0.5
  rm -rf /Applications/Flare.app
  cp -R "$APP" /Applications/Flare.app
  xattr -dr com.apple.quarantine /Applications/Flare.app 2>/dev/null || true
  open /Applications/Flare.app
  echo "✓ Flare is running. Look for ✦ in the menu bar."
else
  echo "✓ Built $APP"
fi
