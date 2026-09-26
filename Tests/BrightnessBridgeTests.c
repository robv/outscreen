#include "BrightnessBridge.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

int main(void) {
    char error[256];
    float value = 42;
    // Every call is rejected before reaching any display write API.
    assert(OSSetExternalBrightness(0, NAN, error, sizeof(error)) != 0);
    assert(OSSetExternalBrightness(0, INFINITY, error, sizeof(error)) != 0);
    assert(OSSetExternalBrightness(0, -0.1f, error, sizeof(error)) != 0);
    assert(OSSetExternalBrightness(0, 1.1f, error, sizeof(error)) != 0);
    assert(OSSetExternalBrightness(0, 0.5f, error, sizeof(error)) != 0);
    assert(OSReadExternalBrightness(0, &value, error, sizeof(error)) != 0 && value == 42);
    assert(OSReadExternalBrightness(0, NULL, error, sizeof(error)) != 0);
    puts("PASS: native brightness invalid-value/target guards; no display writes");
    return 0;
}
