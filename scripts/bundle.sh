#!/bin/bash
# Assemble MacEQ.app from the SwiftPM build product and code-sign it.
# Signing identity must stay stable: TCC ties the audio-capture grant to
# (bundle id, designated requirement). Changing either re-prompts the user.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-debug}"
BIN="$ROOT/.build/$CONFIG/maceq"
APP="$ROOT/MacEQ.app"
IDENTITY="${MACEQ_IDENTITY:-Apple Development: ehrktm090@gmail.com (7TFR357KWQ)}"

[ -x "$BIN" ] || { echo "build product missing: $BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/maceq"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

codesign --force --options runtime \
         --sign "$IDENTITY" \
         --entitlements "$ROOT/Resources/MacEQ.entitlements" \
         "$APP"
codesign --verify --verbose=2 "$APP"
echo "built $APP"
