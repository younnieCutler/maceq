#!/bin/bash
# Assemble MacEQ.app from the SwiftPM build product and code-sign it.
# Signing identity must stay stable: TCC ties the audio-capture grant to
# (bundle id, designated requirement). Changing either re-prompts the user.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-debug}"
BUILD_DIR="$ROOT/.build/$([ "$CONFIG" = release ] && echo release || echo "arm64-apple-macosx/debug")"
BIN="$ROOT/.build/$CONFIG/maceq"
RESOURCE_BUNDLE="$BUILD_DIR/MacEQ_maceq.bundle"
APP="$ROOT/MacEQ.app"
IDENTITY="${MACEQ_IDENTITY:-Apple Development: ehrktm090@gmail.com (7TFR357KWQ)}"

[ -x "$BIN" ] || { echo "build product missing: $BIN" >&2; exit 1; }
[ -d "$RESOURCE_BUNDLE" ] || { echo "resource bundle missing: $RESOURCE_BUNDLE" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/maceq"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/MacEQ_maceq.bundle"
for locale in ko en ja; do
  mkdir -p "$APP/Contents/Resources/$locale.lproj"
  cp "$ROOT/Resources/$locale.lproj/InfoPlist.strings" "$APP/Contents/Resources/$locale.lproj/InfoPlist.strings"
done

codesign --force --options runtime \
         --sign "$IDENTITY" \
         --entitlements "$ROOT/Resources/MacEQ.entitlements" \
         "$APP"
codesign --verify --verbose=2 "$APP"
echo "built $APP"
