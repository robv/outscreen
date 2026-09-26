// SPDX-License-Identifier: MIT
#ifndef OUTSCREEN_BRIGHTNESS_BRIDGE_H
#define OUTSCREEN_BRIGHTNESS_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Zero means success. Brightness uses the native macOS range [0, 1]. Neither
// operation can target the built-in display, an inactive display, or a virtual
// display. Read leaves *brightness unchanged on failure; errors are optional.
int OSReadExternalBrightness(uint32_t displayID, float *brightness,
                             char *error, size_t capacity);
int OSSetExternalBrightness(uint32_t displayID, float brightness,
                            char *error, size_t capacity);

// Read-only. Returns an eligible physical external display (main, then first),
// or zero when the built-in display is active or no native target is available.
// This is the selection policy for forwarding the MacBook's brightness keys.
uint32_t OSPreferredBrightnessDisplay(void);

#ifdef __cplusplus
}
#endif
#endif
