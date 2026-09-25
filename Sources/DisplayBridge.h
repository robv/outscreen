// SPDX-License-Identifier: MIT
#ifndef OUTSCREEN_DISPLAY_BRIDGE_H
#define OUTSCREEN_DISPLAY_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t builtin_id;
    int builtin_active;
    int builtin_online;
    int external_count;
    int lid_closed;       // -1 means that the lid state could not be read.
    int can_disable;
} OSDisplayStatus;

// Zero means success. A nonzero return includes a human-readable error when
// error/capacity are supplied. Status is read-only and may be polled freely.
int OSReadDisplayStatus(uint32_t cachedBuiltinID, OSDisplayStatus *out,
                        char *error, size_t capacity);

// Run on a background queue in a short-lived helper. May take up to ~5 seconds
// while macOS changes the display arrangement. The caller must retain the real
// builtin_id from a successful snapshot BEFORE disabling the screen.
int OSSetBuiltinEnabled(int enabled, uint32_t cachedBuiltinID,
                        char *error, size_t capacity);
const char *OSBackendVersion(void);

#ifdef __cplusplus
}
#endif
#endif
