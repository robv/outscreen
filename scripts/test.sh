#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" \
  Sources/DisplayPolicy.swift Tests/PolicyTests.swift -o .build/policy-tests
.build/policy-tests
xcrun clang -std=c11 -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
  -fsyntax-only Sources/DisplayBridge.c
plutil -lint Resources/Info.plist
printf 'PASS: backend strict compile and app metadata\n'

./scripts/test-recovery.sh

xcrun swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" \
  Sources/BrightnessKeyPolicy.swift Tests/BrightnessKeyTests.swift -o .build/brightness-key-tests
.build/brightness-key-tests
xcrun clang -std=c11 -Wall -Wextra -Werror -I Sources \
  Sources/BrightnessBridge.c Tests/BrightnessBridgeTests.c \
  -framework CoreGraphics -framework CoreFoundation -framework IOKit -o .build/brightness-bridge-tests
.build/brightness-bridge-tests
