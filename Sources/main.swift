import AppKit
import Darwin

let arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}
let preferences = UserDefaults.standard
let savedID = preferences.string(forKey: "CachedDisplaySession") == RecoveryCoordinator.sessionID ? UInt32(clamping: preferences.integer(forKey: "CachedBuiltinDisplayID")) : 0
let cachedID = UInt32(option("--builtin-id") ?? "") ?? savedID

if arguments.contains("--version") {
    print("Outscreen 0.1.0")
    exit(0)
}
if arguments.contains("--status") {
    do {
        let status = try DisplaySnapshot.read(cachedID: cachedID)
        let values: [String: Any] = ["builtinID": status.builtinID, "builtinActive": status.builtinActive,
                                    "builtinOnline": status.builtinOnline, "externalCount": status.externalCount,
                                    "lidClosed": status.lidClosed, "canDisable": status.canDisable,
                                    "backend": String(cString: OSBackendVersion())]
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if let parent = option("--guardian"), let pid = Int32(parent) {
    exit(runGuardian(parentPID: pid, cachedID: cachedID))
}
if arguments.contains("--toggle") || arguments.contains("--quit") {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.daymoon.outscreen")
        .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    guard running else { fputs("Outscreen is not running. Open the app first.\n", stderr); exit(1) }
    let action = arguments.contains("--toggle") ? "toggle" : "quit"
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.daymoon.outscreen.\(action)"), object: nil, userInfo: nil, deliverImmediately: true)
    print("Sent \(action) to Outscreen.")
    exit(0)
}
if arguments.contains("--restore") || arguments.contains("--set") {
    let enabled = arguments.contains("--restore") || option("--set") == "on"
    guard enabled || option("--set") == "off" else { fputs("Expected --set on or off\n", stderr); exit(2) }
    do {
        if arguments.contains("--restore") {
            preferences.set(false, forKey: "AutomaticSwitching")
            _ = try RecoveryCoordinator.requestRestore()
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.daymoon.outscreen.restore"), object: nil, userInfo: nil, deliverImmediately: true)
        }
        let result = try RecoveryCoordinator.withMutationLock { () -> Int32 in
            if !enabled && (RecoveryCoordinator.restoreToken != nil || FileManager.default.fileExists(atPath: RecoveryCoordinator.directory.appendingPathComponent("sleeping").path)) {
                fputs("Display-off canceled by a restore request.\n", stderr)
                return 1
            }
            var buffer = [CChar](repeating: 0, count: 1024)
            let code = OSSetBuiltinEnabled(enabled ? 1 : 0, cachedID, &buffer, buffer.count)
            // A restore arriving during the private call wins before the lock is released.
            if !enabled && RecoveryCoordinator.restoreToken != nil {
                let restored = OSSetBuiltinEnabled(1, cachedID, &buffer, buffer.count)
                if restored != 0 { fputs("\(String(cString: buffer))\n", stderr) }
                return 1
            }
            if code == 0 { print(enabled ? "Built-in display restored." : "Built-in display turned off.") }
            else { fputs("\(String(cString: buffer))\n", stderr) }
            return code == 0 ? 0 : 1
        }
        exit(result)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if !arguments.isEmpty {
    print("Outscreen\n  --status   Read current display status\n  --restore  Restore built-in display, even if the app has crashed\n  --toggle   Toggle through the running menu app\n  --quit     Quit the running menu app and restore\n  --version  Show version")
    exit(arguments.contains("--help") ? 0 : 2)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = DisplayController()
    private var restoreObserver: NSObjectProtocol?
    private var actionObservers: [NSObjectProtocol] = []
    private var readyToTerminate = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.daymoon.outscreen").filter({ $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }).isEmpty else {
            exit(0)
        }
        restoreObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.daymoon.outscreen.restore"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.controller.emergencyRestore() }
        }
        actionObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.daymoon.outscreen.toggle"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.controller.toggle() }
        })
        actionObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.daymoon.outscreen.quit"), object: nil, queue: .main) { _ in
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        })
        controller.start()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToTerminate { return .terminateNow }
        controller.quit { [weak self] success in
            // Returning terminateCancel keeps the ordinary run loop alive for
            // worker callbacks. terminateLater can enter an AppKit nested loop
            // while already draining the main dispatch queue, starving them.
            DispatchQueue.main.async {
                guard success else { return }
                self?.readyToTerminate = true
                sender.terminate(nil)
            }
        }
        return .terminateCancel
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
