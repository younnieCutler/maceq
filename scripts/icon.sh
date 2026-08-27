#!/bin/bash
# Regenerates Resources/AppIcon.icns from scripts/generate-icon.swift.
# Run this after editing the icon artwork.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc -O -o "$WORK/gen" "$ROOT/scripts/generate-icon.swift"
"$WORK/gen" "$WORK/icon-1024.png"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
            "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
  sz="${spec%% *}"; name="${spec#* }"
  sips -z "$sz" "$sz" "$WORK/icon-1024.png" --out "$ICONSET/${name}.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
echo "wrote Resources/AppIcon.icns"
