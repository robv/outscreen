// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Robert Velasquez
// Original Outscreen implementation. DisplayServices ABI declarations researched
// in https://github.com/nriley/brightness/blob/master/brightness.c and
// https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/screen/libscreen.m
// No topology, panel power, DDC, gamma, or software dimming changes occur here.

#include "BrightnessBridge.h"
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdio.h>

enum { OSBrightnessMaxDisplays = 64 };
typedef bool (*OSCanChangeBrightnessFn)(CGDirectDisplayID);
typedef int (*OSGetBrightnessFn)(CGDirectDisplayID, float *);
typedef int (*OSSetBrightnessFn)(CGDirectDisplayID, float);

static struct {
    OSCanChangeBrightnessFn canChange;
    OSGetBrightnessFn get;
    OSSetBrightnessFn set;
} brightnessAPI;
static pthread_once_t brightnessOnce = PTHREAD_ONCE_INIT;

static void loadBrightnessAPI(void) {
    // Retain this framework for the process lifetime so cached pointers remain
    // valid when a background queue handles a later key event.
    void *framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                             RTLD_LAZY | RTLD_LOCAL);
    if (!framework) return;
    brightnessAPI.canChange = (OSCanChangeBrightnessFn)dlsym(framework, "DisplayServicesCanChangeBrightness");
    brightnessAPI.get = (OSGetBrightnessFn)dlsym(framework, "DisplayServicesGetBrightness");
    brightnessAPI.set = (OSSetBrightnessFn)dlsym(framework, "DisplayServicesSetBrightness");
}

static void clearBrightnessError(char *error, size_t capacity) {
    if (error && capacity) error[0] = '\0';
}

static int brightnessFailure(char *error, size_t capacity, const char *format, ...) {
    if (error && capacity) {
        va_list args;
        va_start(args, format);
        vsnprintf(error, capacity, format, args);
        va_end(args);
    }
    return 1;
}

static bool brightnessNumber(CFDictionaryRef dictionary, CFStringRef key, int64_t *result) {
    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    return value && CFGetTypeID(value) == CFNumberGetTypeID() &&
           CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, result);
}

// A real framebuffer identity prevents a virtual display, AirPlay, or Sidecar
// target from qualifying merely because it advertises a brightness API. This
// first version intentionally follows Outscreen's Apple Silicon hardware scope.
static bool physicalExternal(CGDirectDisplayID display) {
    const uint32_t vendor = CGDisplayVendorNumber(display);
    const uint32_t model = CGDisplayModelNumber(display);
    const uint32_t serial = CGDisplaySerialNumber(display);
    if (!vendor || !model) return false;
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching("IOMobileFramebuffer"), &iterator) != KERN_SUCCESS) return false;
    bool matched = false;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        CFTypeRef name = IORegistryEntryCreateCFProperty(service, CFSTR("IONameMatched"), kCFAllocatorDefault, 0);
        bool external = name && CFGetTypeID(name) == CFStringGetTypeID() &&
                        CFStringHasPrefix((CFStringRef)name, CFSTR("dispext"));
        if (name) CFRelease(name);
        if (external) {
            CFTypeRef attributes = IORegistryEntryCreateCFProperty(service, CFSTR("DisplayAttributes"), kCFAllocatorDefault, 0);
            if (attributes && CFGetTypeID(attributes) == CFDictionaryGetTypeID()) {
                CFTypeRef product = CFDictionaryGetValue((CFDictionaryRef)attributes, CFSTR("ProductAttributes"));
                if (product && CFGetTypeID(product) == CFDictionaryGetTypeID()) {
                    CFDictionaryRef dictionary = (CFDictionaryRef)product;
                    int64_t hardwareVendor = 0, hardwareModel = 0, hardwareSerial = 0;
                    bool identified = brightnessNumber(dictionary, CFSTR("LegacyManufacturerID"), &hardwareVendor) &&
                                      brightnessNumber(dictionary, CFSTR("ProductID"), &hardwareModel);
                    brightnessNumber(dictionary, CFSTR("SerialNumber"), &hardwareSerial);
                    matched |= identified && hardwareVendor == vendor && hardwareModel == model &&
                               (!hardwareSerial || hardwareSerial == serial);
                }
            }
            if (attributes) CFRelease(attributes);
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return matched;
}

static bool activeExternal(CGDirectDisplayID display) {
    if (!display || CGDisplayIsBuiltin(display) || !CGDisplayIsOnline(display)) return false;
    CGDirectDisplayID active[OSBrightnessMaxDisplays];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(OSBrightnessMaxDisplays, active, &count) != kCGErrorSuccess) return false;
    for (uint32_t i = 0; i < count; ++i) if (active[i] == display) return true;
    return false;
}

static int validateBrightnessTarget(CGDirectDisplayID display, char *error, size_t capacity) {
    if (!activeExternal(display))
        return brightnessFailure(error, capacity, "Brightness control requires an active external monitor.");
    pthread_once(&brightnessOnce, loadBrightnessAPI);
    if (!brightnessAPI.canChange || !brightnessAPI.get || !brightnessAPI.set)
        return brightnessFailure(error, capacity, "Native monitor brightness controls are unavailable on this macOS version.");
    if (!physicalExternal(display))
        return brightnessFailure(error, capacity, "Outscreen could not identify this monitor as a physical external display.");
    if (!brightnessAPI.canChange(display))
        return brightnessFailure(error, capacity, "This monitor does not support native macOS brightness controls.");
    return 0;
}

int OSReadExternalBrightness(uint32_t displayID, float *brightness, char *error, size_t capacity) {
    clearBrightnessError(error, capacity);
    if (!brightness) return brightnessFailure(error, capacity, "No destination was supplied for monitor brightness.");
    if (validateBrightnessTarget(displayID, error, capacity)) return 1;
    float value = NAN;
    int result = brightnessAPI.get(displayID, &value);
    if (result != 0) return brightnessFailure(error, capacity, "macOS could not read this monitor's brightness (error %d).", result);
    if (!isfinite(value) || value < 0.0f || value > 1.0f)
        return brightnessFailure(error, capacity, "The monitor returned an invalid brightness value.");
    *brightness = value;
    return 0;
}

int OSSetExternalBrightness(uint32_t displayID, float brightness, char *error, size_t capacity) {
    clearBrightnessError(error, capacity);
    if (!isfinite(brightness) || brightness < 0.0f || brightness > 1.0f)
        return brightnessFailure(error, capacity, "Monitor brightness must be a finite value between 0 and 1.");
    if (validateBrightnessTarget(displayID, error, capacity)) return 1;
    // Recheck connectivity after the hardware/capability queries in case the
    // cable was removed during them. Never substitute a different display ID.
    if (!activeExternal(displayID))
        return brightnessFailure(error, capacity, "The external monitor disconnected before brightness could change.");
    int result = brightnessAPI.set(displayID, brightness);
    if (result != 0) return brightnessFailure(error, capacity, "macOS could not set this monitor's brightness (error %d).", result);
    return 0;
}

static bool builtinRemainsInactive(void) {
    CGDirectDisplayID active[OSBrightnessMaxDisplays];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(OSBrightnessMaxDisplays, active, &count) != kCGErrorSuccess) return false;
    for (uint32_t i = 0; i < count; ++i) if (CGDisplayIsBuiltin(active[i])) return false;
    return true;
}

uint32_t OSPreferredBrightnessDisplay(void) {
    CGDirectDisplayID active[OSBrightnessMaxDisplays];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(OSBrightnessMaxDisplays, active, &count) != kCGErrorSuccess) return 0;
    for (uint32_t i = 0; i < count; ++i) if (CGDisplayIsBuiltin(active[i])) return 0;
    CGDirectDisplayID main = CGMainDisplayID();
    if (validateBrightnessTarget(main, NULL, 0) == 0) return builtinRemainsInactive() ? main : 0;
    for (uint32_t i = 0; i < count; ++i) {
        if (active[i] != main && validateBrightnessTarget(active[i], NULL, 0) == 0)
            return builtinRemainsInactive() ? active[i] : 0;
    }
    return 0;
}
