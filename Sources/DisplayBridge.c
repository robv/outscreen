// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Robert Velasquez
// Original implementation for Outscreen. Private API signatures, panel power
// values, and Apple Silicon service naming were researched in Clamless (MIT):
// https://github.com/TCXM/clamless/blob/main/src/helper/clamless-display.c
// This backend never changes permanent display preferences or brightness.

#include "DisplayBridge.h"
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

enum { OSMaxDisplays = 64 };
typedef struct __IOMobileFramebuffer *OSFramebuffer;
typedef CGError (*OSConfigureFn)(CGDisplayConfigRef, CGDirectDisplayID, bool);
typedef kern_return_t (*OSOpenFramebufferFn)(io_service_t, task_port_t,
                                            unsigned int, OSFramebuffer *);
typedef kern_return_t (*OSPowerFn)(OSFramebuffer, uint32_t);
typedef kern_return_t (*OSFramebufferIDFn)(OSFramebuffer, uint32_t *);

static struct {
    OSConfigureFn configure;
    OSOpenFramebufferFn open;
    OSPowerFn power;
    OSFramebufferIDFn getID;
    bool appleSilicon;
} api;
static pthread_once_t apiOnce = PTHREAD_ONCE_INIT;

static void loadAPI(void) {
    int arm = 0;
    size_t size = sizeof(arm);
    api.appleSilicon = sysctlbyname("hw.optional.arm64", &arm, &size, NULL, 0) == 0 && arm == 1;
    // Keep these system frameworks loaded for the process lifetime. Function
    // pointers remain valid when a caller polls from a different thread.
    void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                       RTLD_LAZY | RTLD_LOCAL);
    void *fb = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",
                      RTLD_LAZY | RTLD_LOCAL);
    if (sky) api.configure = (OSConfigureFn)dlsym(sky, "SLSConfigureDisplayEnabled");
    if (fb) {
        api.open = (OSOpenFramebufferFn)dlsym(fb, "IOMobileFramebufferOpen");
        api.power = (OSPowerFn)dlsym(fb, "IOMobileFramebufferRequestPowerChange");
        api.getID = (OSFramebufferIDFn)dlsym(fb, "IOMobileFramebufferGetID");
    }
}

static int fail(char *error, size_t capacity, const char *format, ...) {
    if (error && capacity) {
        va_list args;
        va_start(args, format);
        vsnprintf(error, capacity, format, args);
        va_end(args);
    }
    return 1;
}

static void clearError(char *error, size_t capacity) {
    if (error && capacity) error[0] = '\0';
}

static bool number(CFTypeRef value, int64_t *result) {
    return value && CFGetTypeID(value) == CFNumberGetTypeID() &&
           CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, result);
}

static CFDictionaryRef copyProduct(io_service_t service) {
    CFTypeRef attributes = IORegistryEntryCreateCFProperty(service, CFSTR("DisplayAttributes"),
                                                          kCFAllocatorDefault, 0);
    CFDictionaryRef result = NULL;
    if (attributes && CFGetTypeID(attributes) == CFDictionaryGetTypeID()) {
        CFTypeRef product = CFDictionaryGetValue((CFDictionaryRef)attributes, CFSTR("ProductAttributes"));
        if (product && CFGetTypeID(product) == CFDictionaryGetTypeID())
            result = (CFDictionaryRef)CFRetain(product);
    }
    if (attributes) CFRelease(attributes);
    return result;
}

static bool isBuiltinService(io_service_t service) {
    CFTypeRef name = IORegistryEntryCreateCFProperty(service, CFSTR("IONameMatched"),
                                                    kCFAllocatorDefault, 0);
    bool result = name && CFGetTypeID(name) == CFStringGetTypeID() &&
        CFStringHasPrefix((CFStringRef)name, CFSTR("disp0,"));
    if (name) CFRelease(name);
    // Deliberately do not infer built-in from Apple as manufacturer: Studio
    // Displays are external and also made by Apple.
    return result;
}

// Returns a retained service; caller releases it. Reenumeration is intentional:
// service handles and connection state may change during sleep or hot plugging.
static io_service_t copyBuiltinService(void) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching("IOMobileFramebuffer"), &iterator) != KERN_SUCCESS) return IO_OBJECT_NULL;
    io_service_t found = IO_OBJECT_NULL;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        if (!found && isBuiltinService(service)) found = service;
        else IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return found;
}

static int lidClosed(void) {
    io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault,
                                                   IOServiceMatching("IOPMrootDomain"));
    if (!root) return -1;
    CFTypeRef value = IORegistryEntryCreateCFProperty(root, CFSTR("AppleClamshellState"),
                                                      kCFAllocatorDefault, 0);
    IOObjectRelease(root);
    int result = -1;
    if (value) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) result = CFBooleanGetValue(value) ? 1 : 0;
        else {
            int64_t integer;
            if (number(value, &integer)) result = integer ? 1 : 0;
        }
        CFRelease(value);
    }
    return result;
}

static int panelPower(void) {
    io_service_t service = copyBuiltinService();
    if (!service) return -1;
    CFTypeRef management = IORegistryEntryCreateCFProperty(service, CFSTR("IOPowerManagement"),
                                                          kCFAllocatorDefault, 0);
    IOObjectRelease(service);
    int result = -1;
    if (management) {
        if (CFGetTypeID(management) == CFDictionaryGetTypeID()) {
            int64_t state = -1;
            if (number(CFDictionaryGetValue((CFDictionaryRef)management,
                                           CFSTR("CurrentPowerState")), &state))
                result = (int)state;
        }
        CFRelease(management);
    }
    return result;
}

static bool includes(const CGDirectDisplayID *list, uint32_t count, CGDirectDisplayID id) {
    for (uint32_t i = 0; i < count; ++i) if (list[i] == id) return true;
    return false;
}

static CGDirectDisplayID builtinInList(const CGDirectDisplayID *list, uint32_t count) {
    for (uint32_t i = 0; i < count; ++i) if (CGDisplayIsBuiltin(list[i])) return list[i];
    return kCGNullDirectDisplay;
}

static bool hasMirror(CGDirectDisplayID id) {
    return CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay ||
           CGDisplayIsInMirrorSet(id) || CGDisplayIsInHWMirrorSet(id);
}

// Only a physical Apple Silicon framebuffer counts as a usable fallback screen.
// This intentionally excludes Sidecar, AirPlay, virtual displays, and DisplayLink
// adapters until an explicit reliable physical-presence implementation is added.
static int countPhysicalExternals(const CGDirectDisplayID *active, uint32_t count) {
    bool matched[OSMaxDisplays] = {false};
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching("IOMobileFramebuffer"), &iterator) != KERN_SUCCESS) return 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        if (!isBuiltinService(service)) {
            CFDictionaryRef product = copyProduct(service);
            if (product) {
                int64_t vendor = 0, model = 0, serial = 0;
                bool identified = number(CFDictionaryGetValue(product, CFSTR("LegacyManufacturerID")), &vendor) &&
                                  number(CFDictionaryGetValue(product, CFSTR("ProductID")), &model);
                number(CFDictionaryGetValue(product, CFSTR("SerialNumber")), &serial);
                if (identified && vendor != 0 && model != 0) {
                    for (uint32_t i = 0; i < count; ++i) {
                        CGDirectDisplayID id = active[i];
                        if (!CGDisplayIsBuiltin(id) && CGDisplayIsOnline(id) &&
                            CGDisplayVendorNumber(id) == (uint32_t)vendor &&
                            CGDisplayModelNumber(id) == (uint32_t)model &&
                            (!serial || CGDisplaySerialNumber(id) == (uint32_t)serial)) matched[i] = true;
                    }
                }
                CFRelease(product);
            }
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    int result = 0;
    for (uint32_t i = 0; i < count; ++i) if (matched[i]) ++result;
    return result;
}

int OSReadDisplayStatus(uint32_t cachedBuiltinID, OSDisplayStatus *out,
                        char *error, size_t capacity) {
    clearError(error, capacity);
    if (!out) return fail(error, capacity, "No destination was supplied for display status.");
    memset(out, 0, sizeof(*out));
    out->lid_closed = -1;
    pthread_once(&apiOnce, loadAPI);
    CGDirectDisplayID active[OSMaxDisplays], online[OSMaxDisplays];
    uint32_t activeCount = 0, onlineCount = 0;
    CGError rc = CGGetActiveDisplayList(OSMaxDisplays, active, &activeCount);
    if (rc != kCGErrorSuccess) return fail(error, capacity, "Cannot read active displays (macOS error %d).", rc);
    rc = CGGetOnlineDisplayList(OSMaxDisplays, online, &onlineCount);
    if (rc != kCGErrorSuccess) return fail(error, capacity, "Cannot read connected displays (macOS error %d).", rc);
    out->builtin_id = builtinInList(online, onlineCount);
    if (!out->builtin_id) out->builtin_id = builtinInList(active, activeCount);
    // Never use a cached ID if macOS now identifies it as an external display.
    if (!out->builtin_id && cachedBuiltinID &&
        (!includes(online, onlineCount, cachedBuiltinID) || CGDisplayIsBuiltin(cachedBuiltinID)))
        out->builtin_id = cachedBuiltinID;
    out->builtin_active = includes(active, activeCount, out->builtin_id);
    out->builtin_online = includes(online, onlineCount, out->builtin_id);
    out->external_count = countPhysicalExternals(active, activeCount);
    out->lid_closed = lidClosed();
    io_service_t builtin = copyBuiltinService();
    bool mirrored = false;
    for (uint32_t i = 0; i < onlineCount; ++i) mirrored |= hasMirror(online[i]);
    out->can_disable = api.appleSilicon && api.configure && api.open && api.power &&
        builtin && out->builtin_active && out->external_count > 0 && out->lid_closed == 0 && !mirrored;
    if (builtin) IOObjectRelease(builtin);
    if (!api.appleSilicon) return fail(error, capacity, "Outscreen currently supports Apple Silicon MacBooks.");
    if (!api.configure || !api.open || !api.power)
        return fail(error, capacity, "This macOS version does not provide the display controls Outscreen needs.");
    if (mirrored) return fail(error, capacity, "Set your monitor to an extended display in System Settings before turning the built-in screen off.");
    return 0;
}

static CGError configureTopology(CGDirectDisplayID id, bool enabled) {
    if (!api.configure || !id) return kCGErrorIllegalArgument;
    CGDisplayConfigRef configuration = NULL;
    CGError rc = CGBeginDisplayConfiguration(&configuration);
    if (rc != kCGErrorSuccess) return rc;
    if (!configuration) return kCGErrorFailure;
    rc = api.configure(configuration, id, enabled);
    if (rc != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(configuration);
        return rc;
    }
    // There is deliberately no permanent fallback: failure leaves the app in a
    // recoverable session state and can never persist a disconnected panel.
    return CGCompleteDisplayConfiguration(configuration, kCGConfigureForSession);
}

static kern_return_t requestPower(bool enabled, uint32_t *fallbackID) {
    if (fallbackID) *fallbackID = 0;
    if (!api.open || !api.power) return kIOReturnUnsupported;
    io_service_t service = copyBuiltinService();
    if (!service) return kIOReturnNotFound;
    OSFramebuffer framebuffer = NULL;
    kern_return_t rc = api.open(service, mach_task_self(), 0, &framebuffer);
    IOObjectRelease(service);
    if (rc != KERN_SUCCESS) return rc;
    if (!framebuffer) return kIOReturnError;
    if (fallbackID && api.getID) api.getID(framebuffer, fallbackID);
    rc = api.power(framebuffer, enabled ? 1 : 0);
    // The private framework exposes no documented ownership/close contract.
    // Mutation runs in a short-lived helper, so process exit reclaims this
    // connection; never CFRelease an opaque pointer based on an assumption.
    return rc;
}

static bool verifyActive(CGDirectDisplayID id, bool enabled) {
    CGDirectDisplayID displays[OSMaxDisplays];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(OSMaxDisplays, displays, &count) != kCGErrorSuccess) return false;
    if (enabled) {
        // A wake may create a new ID, so accept a newly enumerated built-in.
        return builtinInList(displays, count) != 0;
    }
    return !includes(displays, count, id) && builtinInList(displays, count) == 0 &&
           countPhysicalExternals(displays, count) > 0;
}

static int restore(uint32_t cached, char *error, size_t capacity) {
    // macOS owns closed-lid behavior. In particular, quitting Outscreen while
    // clamshelled must not force the enclosed panel on or fight system sleep.
    if (lidClosed() == 1) return 0;
    uint32_t framebufferID = 0;
    kern_return_t powerRC = requestPower(true, &framebufferID);
    CGError layoutRC = kCGErrorFailure;
    // Wake the panel before enabling topology, including when the ID is lost.
    usleep(300000);
    for (int attempt = 0; attempt < 7; ++attempt) {
        CGDirectDisplayID online[OSMaxDisplays];
        uint32_t count = 0;
        CGDirectDisplayID id = cached;
        if (CGGetOnlineDisplayList(OSMaxDisplays, online, &count) == kCGErrorSuccess) {
            id = builtinInList(online, count);
            if (!id && cached && (!includes(online, count, cached) || CGDisplayIsBuiltin(cached))) id = cached;
        }
        // IOMFBGetID is NOT guaranteed to return a CG ID. Only use it when
        // CoreGraphics positively identifies that ID as the built-in screen.
        if (!id && framebufferID && CGDisplayIsBuiltin(framebufferID)) id = framebufferID;
        if (id) layoutRC = configureTopology(id, true);
        if (verifyActive(id, true) && powerRC == KERN_SUCCESS) return 0;
        if (attempt == 2 || attempt == 4) powerRC = requestPower(true, &framebufferID);
        usleep(400000);
    }
    return fail(error, capacity,
        "macOS has not confirmed that the built-in screen is restored (panel 0x%x, layout %d). "
        "Try the restore shortcut again or close and reopen the lid.", powerRC, layoutRC);
}

int OSSetBuiltinEnabled(int enabled, uint32_t cachedBuiltinID,
                        char *error, size_t capacity) {
    clearError(error, capacity);
    pthread_once(&apiOnce, loadAPI);
    if (enabled) return restore(cachedBuiltinID, error, capacity);

    OSDisplayStatus status;
    if (OSReadDisplayStatus(cachedBuiltinID, &status, error, capacity)) return 1;
    if (!status.external_count) return fail(error, capacity, "Connect an active physical monitor before turning the built-in screen off.");
    if (status.lid_closed != 0) return fail(error, capacity, "Open your MacBook lid before using Outscreen.");
    if (!status.builtin_active) return fail(error, capacity, "The built-in screen is already disconnected. Restore it before switching again.");
    if (!status.can_disable) return fail(error, capacity, "Outscreen could not safely identify the built-in screen controls.");

    CGError layoutRC = configureTopology(status.builtin_id, false);
    kern_return_t powerRC = kIOReturnNotReady;
    bool topologyOff = false;
    if (layoutRC == kCGErrorSuccess) {
        // Require another usable display throughout the transition, not just
        // when the user initially clicked. Power-off follows topology-off.
        for (int attempt = 0; attempt < 8; ++attempt) {
            usleep(100000);
            if (verifyActive(status.builtin_id, false)) { topologyOff = true; break; }
        }
        if (topologyOff) powerRC = requestPower(false, NULL);
    }
    // IORegistry CurrentPowerState is a driver power-domain state, not panel
    // illumination: it remains 1 on this Mac after a successful panel-off.
    // Confirm topology and require the panel request to have been accepted.
    if (layoutRC == kCGErrorSuccess && topologyOff && powerRC == KERN_SUCCESS) {
        for (int attempt = 0; attempt < 6; ++attempt) {
            usleep(100000);
            if (verifyActive(status.builtin_id, false)) return 0;
        }
    }

    int observedPower = panelPower();
    bool observedTopologyOff = verifyActive(status.builtin_id, false);
    // Any partial failure immediately attempts the full restore sequence.
    char restoreError[512];
    int restoreRC = restore(status.builtin_id, restoreError, sizeof(restoreError));
    if (restoreRC) return fail(error, capacity,
        "Could not turn the built-in screen off (panel 0x%x, layout %d). %s", powerRC, layoutRC, restoreError);
    return fail(error, capacity,
        "macOS did not confirm the screen-off change (panel call 0x%x, layout %d, IO power state %d, topology off %d). The built-in screen was restored.",
        powerRC, layoutRC, observedPower, observedTopologyOff);
}

const char *OSBackendVersion(void) { return "Outscreen Apple Silicon display backend 1"; }
