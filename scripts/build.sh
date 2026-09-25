#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUTSCREEN_ROOT="$PWD"
OUTSCREEN_ARCH="$(uname -m)"
OUTSCREEN_BUILD="$OUTSCREEN_ROOT/.build"
OUTSCREEN_APP="$OUTSCREEN_BUILD/Outscreen.app"
mkdir -p "$OUTSCREEN_BUILD/module-cache" "$OUTSCREEN_APP/Contents/MacOS" "$OUTSCREEN_APP/Contents/Resources"
export CLANG_MODULE_CACHE_PATH="$OUTSCREEN_BUILD/module-cache"
export SWIFT_MODULECACHE_PATH="$OUTSCREEN_BUILD/module-cache"
xcrun clang -std=c11 -Wall -Wextra -Werror -O2 -mmacosx-version-min=13.0 \
  -c Sources/DisplayBridge.c -o "$OUTSCREEN_BUILD/DisplayBridge.o"
xcrun swiftc -swift-version 5 -O -target "$OUTSCREEN_ARCH-apple-macos13.0" \
  -module-cache-path "$OUTSCREEN_BUILD/module-cache" \
  -import-objc-header Sources/DisplayBridge.h Sources/*.swift "$OUTSCREEN_BUILD/DisplayBridge.o" \
  -framework AppKit -framework CoreGraphics -framework CoreFoundation -framework IOKit \
  -framework Carbon -framework ServiceManagement -o "$OUTSCREEN_APP/Contents/MacOS/Outscreen"
cp Resources/Info.plist "$OUTSCREEN_APP/Contents/Info.plist"
cp LICENSE "$OUTSCREEN_APP/Contents/Resources/LICENSE"
if [[ -f scripts/make-icon.swift ]]; then
  xcrun swift -module-cache-path "$OUTSCREEN_BUILD/module-cache" scripts/make-icon.swift "$OUTSCREEN_BUILD/icon.png"
  OUTSCREEN_ICONSET="$OUTSCREEN_BUILD/Outscreen.iconset"
  mkdir -p "$OUTSCREEN_ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$OUTSCREEN_BUILD/icon.png" --out "$OUTSCREEN_ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$OUTSCREEN_BUILD/icon.png" --out "$OUTSCREEN_ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$OUTSCREEN_ICONSET" -o "$OUTSCREEN_APP/Contents/Resources/Outscreen.icns"
fi
codesign --force --sign "${OUTSCREEN_SIGN_IDENTITY:--}" "$OUTSCREEN_APP"
codesign --verify --strict "$OUTSCREEN_APP"
printf 'Built %s\n' "$OUTSCREEN_APP"
