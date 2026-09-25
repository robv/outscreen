#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUTSCREEN_TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/outscreen-recovery.XXXXXX")"
trap 'rm -rf "$OUTSCREEN_TEST_BUILD"' EXIT
export OUTSCREEN_TEST_DIRECTORY="$OUTSCREEN_TEST_BUILD/session"
mkdir -p .build/module-cache

# Deliberately do not link DisplayBridge.c: even an accidental snapshot request
# must fail the test rather than read or modify a real display.
cat > "$OUTSCREEN_TEST_BUILD/status-stub.c" <<'STUB'
#include "DisplayBridge.h"
#include <stdlib.h>
int OSReadDisplayStatus(uint32_t cached, OSDisplayStatus *out, char *error, size_t capacity) {
    (void)cached; (void)out; (void)error; (void)capacity;
    abort();
}
STUB
xcrun clang -std=c11 -Wall -Wextra -Werror -I Sources \
  -c "$OUTSCREEN_TEST_BUILD/status-stub.c" -o "$OUTSCREEN_TEST_BUILD/status-stub.o"
xcrun swiftc -swift-version 5 -D OUTSCREEN_TESTING \
  -module-cache-path "$PWD/.build/module-cache" \
  -import-objc-header Sources/DisplayBridge.h \
  Sources/RecoveryCoordinator.swift Sources/DisplayWorker.swift Tests/RecoveryTests.swift \
  "$OUTSCREEN_TEST_BUILD/status-stub.o" -o "$OUTSCREEN_TEST_BUILD/recovery-tests"
"$OUTSCREEN_TEST_BUILD/recovery-tests"
