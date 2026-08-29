#!/bin/bash
# Install the app beside the user account and add a Desktop shortcut.
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="$SOURCE_DIR/MacEQ.app"
DESTINATION="$HOME/Applications/MacEQ.app"
SHORTCUT="$HOME/Desktop/MacEQ.app"

[ -d "$SOURCE_APP" ] || { echo "MacEQ.app must be next to this installer." >&2; exit 1; }
mkdir -p "$HOME/Applications"
rm -rf "$DESTINATION"
ditto "$SOURCE_APP" "$DESTINATION"

if [ -e "$SHORTCUT" ] && [ ! -L "$SHORTCUT" ]; then
  echo "Desktop shortcut already exists: $SHORTCUT" >&2
  exit 1
fi
rm -f "$SHORTCUT"
ln -s "$DESTINATION" "$SHORTCUT"
open "$DESTINATION"
