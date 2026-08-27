#!/bin/bash
# Builds the release .app and packages it into a distributable DMG.
# Usage: scripts/dmg.sh [version]   (defaults to CFBundleShortVersionString)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
DMG_NAME="MacEQ-${VERSION}.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

CONFIG=release "$ROOT/scripts/bundle.sh"

cp -R "$ROOT/MacEQ.app" "$STAGING/MacEQ.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$ROOT/$DMG_NAME"
hdiutil create -volname "MacEQ $VERSION" \
                -srcfolder "$STAGING" \
                -ov -format UDZO \
                "$ROOT/$DMG_NAME"

echo "built $DMG_NAME"
