import AppKit
import ApplicationServices
import CoreGraphics

struct BrightnessKeyState {
    var enabled: Bool
    var needsPermission: Bool
    var available: Bool
    var message: String?
}

/// Owns a media-only event tap. Display calls stay off the input callback.
@MainActor
final class BrightnessKeys {
    private let preferences = UserDefaults.standard
    private let queue = DispatchQueue(label: "com.daymoon.outscreen.brightness", qos: .userInitiated)
    private let hud = BrightnessHUD()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var target: UInt32 = 0
    private var generation = 0
    private var targetQueryPending = false
    private var queuedSteps: [BrightnessKeyInput] = []
    private var changing = false
    private var needsPermission = false
    private var errorMessage: String?
    private var enabled: Bool
    private var onState: ((BrightnessKeyState) -> Void)?
    private var pressRouting = BrightnessPressRouting()

    init() {
        preferences.register(defaults: ["ExternalBrightnessKeys": true])
        enabled = preferences.bool(forKey: "ExternalBrightnessKeys")
    }

    func start(onState: @escaping (BrightnessKeyState) -> Void) {
        self.onState = onState
        updateTap()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.enabled else { return }
                if self.tap == nil && (!self.needsPermission || AXIsProcessTrusted()) { self.updateTap() }
            }
        }
        if let permissionTimer { RunLoop.main.add(permissionTimer, forMode: .common) }
        refreshTarget()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        preferences.set(value, forKey: "ExternalBrightnessKeys")
        errorMessage = nil
        if !value { stopTap() }
        else { updateTap(); refreshTarget() }
        publish()
    }

    func requestPermission() {
        // This is only called by the user's menu click, never on launch.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        updateTap()
        if !AXIsProcessTrusted(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func invalidateTarget() {
        generation += 1
        target = 0
        queuedSteps.removeAll()
        publish()
    }

    func refreshTarget() {
        guard enabled, !targetQueryPending else { publish(); return }
        targetQueryPending = true
        let currentGeneration = generation
        queue.async {
            let found = OSPreferredBrightnessDisplay()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.targetQueryPending = false
                guard self.generation == currentGeneration else { self.refreshTarget(); return }
                self.target = found
                self.publish()
            }
        }
    }

    private func updateTap() {
        guard enabled, tap == nil else { return }
        // A system-defined-only tap may be permitted without Accessibility on
        // some macOS versions. Try it first; request no extra input classes.
        let mask = CGEventMask(1) << CGEventType.systemDefinedRawValue
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<BrightnessKeys>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated { owner.handle(type: type, event: event) }
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            needsPermission = !AXIsProcessTrusted()
            errorMessage = needsPermission ? nil : "Brightness key capture could not start. Quit and reopen Outscreen."
            publish()
            return
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            errorMessage = "Brightness key capture could not start."
            publish()
            return
        }
        tap = port
        source = runLoopSource
        needsPermission = false
        errorMessage = nil
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        publish()
    }

    private func stopTap() {
        generation += 1
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        needsPermission = false
        target = 0
        pressRouting = BrightnessPressRouting()
        queuedSteps.removeAll()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if enabled, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == CGEventType.systemDefinedRawValue, let native = NSEvent(cgEvent: event), native.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let key = (native.data1 >> 16) & 0xffff
        let state = (native.data1 >> 8) & 0xff
        guard (key == 2 || key == 3), state == 0x0a || state == 0x0b else {
            return Unmanaged.passUnretained(event)
        }
        let flags = native.modifierFlags
        let input = BrightnessKeyInput.decode(data1: native.data1, subtype: Int(native.subtype.rawValue),
                                             shift: flags.contains(.shift), option: flags.contains(.option),
                                             control: flags.contains(.control), command: flags.contains(.command))
        let eligible = enabled && target != 0 && input != nil
        let consume = pressRouting.consumes(key: key, isDown: state == 0x0a,
                                             isRepeat: (native.data1 & 1) != 0, eligible: eligible)
        guard consume else { return Unmanaged.passUnretained(event) }
        guard eligible, let input, input.isDown else { return nil }
        // Bound pending work during a held key; display I/O never blocks typing.
        if queuedSteps.count < 32 { queuedSteps.append(input) }
        drain()
        return nil
    }

    private func drain() {
        guard !changing, enabled, target != 0, !queuedSteps.isEmpty else { return }
        changing = true
        let inputs = queuedSteps
        queuedSteps.removeAll()
        let displayID = target
        let currentGeneration = generation
        queue.async {
            let result: Result<Float, Error>
            var value: Float = 0
            var error = [CChar](repeating: 0, count: 512)
            if OSPreferredBrightnessDisplay() != displayID {
                result = .failure(DisplayFailure("The active brightness display changed."))
            } else if OSReadExternalBrightness(displayID, &value, &error, error.count) != 0 {
                result = .failure(DisplayFailure(String(cString: error)))
            } else {
                for input in inputs { value = input.applying(to: value) }
                if OSSetExternalBrightness(displayID, value, &error, error.count) == 0 { result = .success(value) }
                else { result = .failure(DisplayFailure(String(cString: error))) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.changing = false
                guard self.generation == currentGeneration else { self.drain(); return }
                switch result {
                case .success(let value):
                    self.errorMessage = nil
                    self.hud.show(value: value, displayID: displayID)
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                    self.target = 0
                    self.queuedSteps.removeAll()
                }
                self.publish()
                self.drain()
            }
        }
    }

    private func publish() {
        // Small, local diagnostics contain capability/state only, never key data.
        let diagnostics: [String: Any] = [
            "processID": ProcessInfo.processInfo.processIdentifier,
            "enabled": enabled, "displayID": target,
            "eventTapActive": tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
            "needsAccessibility": needsPermission
        ]
        if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.sortedKeys]) {
            try? RecoveryCoordinator.prepare()
            try? data.write(to: RecoveryCoordinator.directory.appendingPathComponent("brightness-state.json"), options: .atomic)
        }
        onState?(BrightnessKeyState(enabled: enabled, needsPermission: needsPermission,
                                    available: target != 0 && tap != nil, message: errorMessage))
    }
}

private extension CGEventType {
    // NX_SYSDEFINED, deliberately excluding keyDown/keyUp/text events.
    static let systemDefinedRawValue: UInt32 = 14
}
