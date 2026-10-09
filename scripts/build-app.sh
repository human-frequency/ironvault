#!/bin/zsh -f
# Builds IronVault.app and the ironvault command into ./build. Installs nothing.
# Needs Apple's Command Line Tools (xcode-select --install). Xcode isn't needed.
#
# This calls the Swift compiler directly instead of Swift's package manager, because the
# package manager in some Command Line Tools installs is broken ("Invalid manifest",
# "Undefined symbols ... PackageDescription"). app/Package.swift is kept for anyone who
# prefers Xcode or `swift build`.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
ROOT="${0:A:h:h}"
SRC="$ROOT/app/Sources"
OUT="$ROOT/build"
APP="$OUT/IronVault.app"

SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)" \
  || { print -u2 "Can't find the macOS SDK. Reinstall the Command Line Tools (see the README)."; exit 1; }
TARGET="$(uname -m)-apple-macos12.0"
FLAGS=(-O -swift-version 5 -target "$TARGET" -sdk "$SDK")

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

print "  compiling the app…"
xcrun swiftc "${FLAGS[@]}" -parse-as-library -module-name IronVault \
  "$SRC"/IronVaultCore/*.swift "$SRC"/IronVault/*.swift \
  -o "$APP/Contents/MacOS/IronVault"

print "  compiling the ironvault command…"
xcrun swiftc "${FLAGS[@]}" -module-name ironvault \
  "$SRC"/IronVaultCore/*.swift "$SRC"/ironvault-cli/main.swift \
  -o "$OUT/ironvault"

cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
# Local ad-hoc signatures. Nothing leaves your Mac, so no Apple developer account is needed.
codesign --force --sign - "$OUT/ironvault"
codesign --force --sign - "$APP"

print "  built $APP and $OUT/ironvault"
