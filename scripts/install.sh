#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
OUTSCREEN_DEST="${1:-/Applications/Outscreen.app}"
if pgrep -x Outscreen >/dev/null; then
  printf 'Quit Outscreen from its menu before installing an update (this restores your display).\n' >&2
  exit 1
fi
if [[ -e "$OUTSCREEN_DEST" ]]; then
  OUTSCREEN_EXISTING_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$OUTSCREEN_DEST/Contents/Info.plist" 2>/dev/null || true)
  if [[ "$OUTSCREEN_EXISTING_ID" != 'com.daymoon.outscreen' ]]; then
    printf 'Refusing to overwrite a different app at %s\n' "$OUTSCREEN_DEST" >&2
    exit 1
  fi
fi
mkdir -p "$(dirname "$OUTSCREEN_DEST")"
ditto .build/Outscreen.app "$OUTSCREEN_DEST"
codesign --verify --strict "$OUTSCREEN_DEST"
printf 'Installed %s\n' "$OUTSCREEN_DEST"
open "$OUTSCREEN_DEST"
