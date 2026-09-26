import AppKit
import ServiceManagement

struct MenuState {
    var builtinOff: Bool
    var externalCount: Int
    var busy: Bool
    var automatic: Bool
    var paused: Bool
    var canDisable: Bool
    var message: String?
}

/// The menu is the entire app UI. Display changes remain in the app controller.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let displayStatus = NSMenuItem()
    private let monitorStatus = NSMenuItem()
    private let toggleItem = NSMenuItem()
    private let automaticItem = NSMenuItem()
    private let pausedItem = NSMenuItem()
    private let messageItem = NSMenuItem()
    private let brightnessItem = NSMenuItem()
    private let brightnessPermissionItem = NSMenuItem()
    private let brightnessMessageItem = NSMenuItem()
    private var brightnessEnabled = true
    private let onBrightnessToggle: (Bool) -> Void
    private let onBrightnessPermission: () -> Void
    private let loginItem = NSMenuItem()
    private let loginSettingsItem = NSMenuItem()
    private let loginMessageItem = NSMenuItem()
    private let onToggle: () -> Void
    private let onAutomatic: (Bool) -> Void
    private let onRestore: () -> Void
    private let onQuit: () -> Void
    private var automatic = false
    private var changingLogin = false

    init(
        onToggle: @escaping () -> Void,
        onAutomatic: @escaping (Bool) -> Void,
        onRestore: @escaping () -> Void,
        onBrightnessToggle: @escaping (Bool) -> Void,
        onBrightnessPermission: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        self.onAutomatic = onAutomatic
        self.onRestore = onRestore
        self.onBrightnessToggle = onBrightnessToggle
        self.onBrightnessPermission = onBrightnessPermission
        self.onQuit = onQuit
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        let heading = NSMenuItem(title: "Outscreen", action: nil, keyEquivalent: "")
        heading.attributedTitle = NSAttributedString(
            string: "Outscreen",
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
        )
        heading.isEnabled = false
        menu.addItem(heading)
        addInformation(displayStatus)
        addInformation(monitorStatus)
        menu.addItem(.separator())

        addAction(toggleItem, title: "Turn Off Built-in Display", action: #selector(toggleDisplay))
        addAction(automaticItem, title: "Automatically Switch on Monitor Connection", action: #selector(toggleAutomatic))
        pausedItem.title = "Automatic switching paused until monitor reconnects"
        addInformation(pausedItem)
        addInformation(messageItem)
        pausedItem.isHidden = true
        messageItem.isHidden = true
        menu.addItem(.separator())

        let restoreItem = NSMenuItem()
        addAction(restoreItem, title: "Restore Built-in Display", action: #selector(restoreDisplay))
        restoreItem.keyEquivalent = "r"
        restoreItem.keyEquivalentModifierMask = [.control, .option, .command]
        restoreItem.toolTip = "Emergency restore works across apps: Control–Option–Command–R."
        menu.addItem(.separator())

        addAction(brightnessItem, title: "Use Brightness Keys for External Display", action: #selector(toggleBrightnessKeys))
        brightnessItem.state = .on
        brightnessItem.toolTip = "Redirect brightness keys to a supported external display while the built-in screen is off. Shift–Option makes smaller changes."
        addAction(brightnessPermissionItem, title: "Allow Brightness Keys…", action: #selector(allowBrightnessKeys))
        brightnessPermissionItem.isHidden = true
        addInformation(brightnessMessageItem)
        brightnessMessageItem.isHidden = true
        menu.addItem(.separator())

        addAction(loginItem, title: "Launch at Login", action: #selector(toggleLaunchAtLogin))
        addAction(loginSettingsItem, title: "Allow Outscreen in Login Items…", action: #selector(openLoginSettings))
        addInformation(loginMessageItem)
        loginMessageItem.isHidden = true
        menu.addItem(.separator())
        let aboutItem = NSMenuItem()
        addAction(aboutItem, title: "About Outscreen", action: #selector(showAbout))
        let quitItem = NSMenuItem()
        addAction(quitItem, title: "Quit Outscreen", action: #selector(quit))
        quitItem.keyEquivalent = "q"
        quitItem.keyEquivalentModifierMask = [.command]
        statusItem.menu = menu
        statusItem.button?.setAccessibilityLabel("Outscreen")
        statusItem.button?.setAccessibilityIdentifier("outscreen.status")
        update(MenuState(builtinOff: false, externalCount: 0, busy: false,
                         automatic: false, paused: false, canDisable: false, message: nil))
        refreshLoginStatus()
    }

    func update(_ state: MenuState) {
        automatic = state.automatic
        displayStatus.title = state.busy ? "Updating displays…" : "Built-in display is \(state.builtinOff ? "off" : "on")"
        monitorStatus.title = state.externalCount == 0
            ? "Connect an external monitor to turn it off"
            : "\(state.externalCount) external \(state.externalCount == 1 ? "monitor" : "monitors") connected"
        toggleItem.title = state.builtinOff ? "Turn On Built-in Display" : "Turn Off Built-in Display"
        toggleItem.isEnabled = !state.busy && (state.builtinOff || state.canDisable)
        automaticItem.state = state.automatic ? .on : .off
        pausedItem.isHidden = !(state.automatic && state.paused)
        messageItem.isHidden = state.message?.isEmpty != false
        messageItem.title = shortMessage(state.message ?? "")
        messageItem.toolTip = state.message

        let symbol = state.builtinOff ? "display" : "laptopcomputer"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Outscreen")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.title = image == nil ? "Outscreen" : ""
        statusItem.button?.toolTip = "Outscreen — \(displayStatus.title.lowercased())"
        statusItem.button?.setAccessibilityValue(displayStatus.title)
    }

    func updateBrightness(_ state: BrightnessKeyState) {
        brightnessEnabled = state.enabled
        brightnessItem.state = state.enabled ? .on : .off
        brightnessPermissionItem.isHidden = !state.enabled || !state.needsPermission
        brightnessMessageItem.isHidden = state.message?.isEmpty != false
        brightnessMessageItem.title = shortMessage(state.message ?? "")
        brightnessMessageItem.toolTip = state.message
    }

    @objc private func toggleBrightnessKeys() { onBrightnessToggle(!brightnessEnabled) }
    @objc private func allowBrightnessKeys() { onBrightnessPermission() }

    func menuWillOpen(_ menu: NSMenu) {
        // System Settings may have changed the registration while we were idle.
        refreshLoginStatus()
    }

    private func addInformation(_ item: NSMenuItem) {
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addAction(_ item: NSMenuItem, title: String, action: Selector) {
        item.title = title
        item.target = self
        item.action = action
        menu.addItem(item)
    }

    private func shortMessage(_ message: String) -> String {
        let singleLine = message.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count > 100 ? String(singleLine.prefix(99)) + "…" : singleLine
    }

    private func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        loginItem.isEnabled = !changingLogin
        loginSettingsItem.isHidden = status != .requiresApproval
        switch status {
        case .enabled:
            loginItem.state = .on
            loginItem.title = "Launch at Login"
        case .requiresApproval:
            loginItem.state = .mixed
            loginItem.title = "Launch at Login — Approval Needed"
        default:
            loginItem.state = .off
            loginItem.title = "Launch at Login"
        }
    }

    @objc private func toggleDisplay() { onToggle() }
    @objc private func toggleAutomatic() { onAutomatic(!automatic) }
    @objc private func restoreDisplay() { onRestore() }
    @objc private func quit() { onQuit() }
    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    @objc private func toggleLaunchAtLogin() {
        guard !changingLogin else { return }
        changingLogin = true
        loginMessageItem.isHidden = true
        refreshLoginStatus()
        Task { @MainActor in
            defer {
                changingLogin = false
                refreshLoginStatus()
            }
            do {
                switch SMAppService.mainApp.status {
                case .enabled, .requiresApproval:
                    try await SMAppService.mainApp.unregister()
                default:
                    try SMAppService.mainApp.register()
                }
            } catch {
                let message = "Login setting failed: \(error.localizedDescription)"
                loginMessageItem.title = shortMessage(message)
                loginMessageItem.toolTip = message
                loginMessageItem.isHidden = false
            }
        }
    }

    @objc private func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let credits = NSAttributedString(
            string: "Use your external monitor with your laptop open.\n\nEmergency restore: Control–Option–Command–R\nYour built-in display restores when you quit.\n\nOpen source under the MIT License.",
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Outscreen",
            .applicationVersion: version,
            .version: "",
            .credits: credits
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}
