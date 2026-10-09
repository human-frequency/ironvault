#!/bin/zsh -f
# Builds IronVault.app and the ironvault command into ./build. Installs nothing.
# Needs Apple's Command Line Tools (xcode-select --install).
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$ROOT/build"
APP="$OUT/IronVault.app"

cd "$ROOT/app"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/IronVault" "$APP/Contents/MacOS/IronVault"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN_DIR/ironvault-cli" "$OUT/ironvault"
# Local ad-hoc signatures. Nothing leaves your Mac, so no Apple developer account is needed.
codesign --force --sign - "$OUT/ironvault"
codesign --force --sign - "$APP"

echo "Built $APP and $OUT/ironvault"
