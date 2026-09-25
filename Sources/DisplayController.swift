import AppKit
import CoreGraphics

private func displayChanged(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ context: UnsafeMutableRawPointer?) {
    guard !flags.contains(.beginConfigurationFlag), let context else { return }
    let controller = Unmanaged<DisplayController>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { controller.screenEvent() }
}

@MainActor
final class DisplayController {
    private let preferences = UserDefaults.standard
    private var policy = DisplayPolicy()
    private var snapshot: DisplaySnapshot?
    private var cachedID: UInt32 = 0
    private var busy = false
    private var pendingDisable = false
    private var stateGeneration = 0
    private var readingStatus = false
    private var ownsOff = false
    private var sleeping = false
    private var blockedAfterFailure = false
    private var forceRestore = false
    private var lastRestoreToken: String?
    private var message: String?
    private var timer: Timer?
    private var debounce: DispatchWorkItem?
    private var observations: [NSObjectProtocol] = []
    private var guardian: Process?
    private var hotkey: GlobalHotKey?
    private var quitCompletion: ((Bool) -> Void)?
    private let executable = Bundle.main.executableURL!
    private let statusQueue = DispatchQueue(label: "com.daymoon.outscreen.status", qos: .userInitiated)
    private lazy var worker = DisplayWorker(executable: executable)
    private lazy var menu = MenuBarController(
        onToggle: { [weak self] in self?.toggle() },
        onAutomatic: { [weak self] in self?.setAutomatic($0) },
        onRestore: { [weak self] in self?.emergencyRestore() },
        onQuit: { NSApplication.shared.terminate(nil) })

    func start() {
        if preferences.string(forKey: "CachedDisplaySession") == RecoveryCoordinator.sessionID {
            cachedID = UInt32(clamping: preferences.integer(forKey: "CachedBuiltinDisplayID"))
        }
        policy.automatic = preferences.bool(forKey: "AutomaticSwitching")
        try? FileManager.default.removeItem(at: RecoveryCoordinator.directory.appendingPathComponent("sleeping"))
        _ = menu
        do { hotkey = try GlobalHotKey { [weak self] in self?.emergencyRestore() } }
        catch { message = "Emergency shortcut unavailable: \(error.localizedDescription)" }
        CGDisplayRegisterReconfigurationCallback(displayChanged, Unmanaged.passUnretained(self).toOpaque())
        let center = NSWorkspace.shared.notificationCenter
        observations.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                self?.sleeping = true
                self?.stateGeneration += 1
                try? Data().write(to: RecoveryCoordinator.directory.appendingPathComponent("sleeping"), options: .atomic)
            }
        })
        observations.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                self?.sleeping = false
                self?.stateGeneration += 1
                try? FileManager.default.removeItem(at: RecoveryCoordinator.directory.appendingPathComponent("sleeping"))
                self?.screenEvent(delay: 2)
            }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.ownsOff || self.forceRestore || self.snapshot?.builtinActive == false else { return }
                self.refresh()
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        refresh()
    }

    func screenEvent(delay: TimeInterval = 0.4) {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refresh()
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func observeEmergency() {
        if let token = RecoveryCoordinator.restoreToken, token != lastRestoreToken {
            lastRestoreToken = token
            policy.emergencyRestore()
            preferences.set(false, forKey: "AutomaticSwitching")
            forceRestore = true
        }
    }

    private func refresh() {
        observeEmergency()
        guard !busy else { render(); return }
        if sleeping {
            // Existing guardian survives parent exit and restores on wake/lid-open.
            if quitCompletion != nil { finishQuit(true, leaveGuardian: ownsOff) }
            render()
            return
        }
        // Emergency restoration must not wait for an enumeration call to finish.
        if forceRestore { change(enabled: true); return }
        guard !readingStatus else { return }
        readingStatus = true
        let id = cachedID
        let generation = stateGeneration
        statusQueue.async {
            let result = Result { try DisplaySnapshot.read(cachedID: id) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.readingStatus = false
                guard !self.busy, !self.sleeping else { return }
                guard generation == self.stateGeneration else { self.refresh(); return }
                switch result {
                case .success(let current): self.accept(current)
                case .failure(let error): self.message = error.localizedDescription; self.render()
                }
            }
        }
    }

    private func accept(_ current: DisplaySnapshot) {
        let topologyChanged = snapshot.map { $0.externalCount != current.externalCount || $0.lidClosed != current.lidClosed } ?? false
        if topologyChanged { blockedAfterFailure = false }
        if current.builtinID != 0 {
            cachedID = current.builtinID
            preferences.set(Int(cachedID), forKey: "CachedBuiltinDisplayID")
            preferences.set(RecoveryCoordinator.sessionID, forKey: "CachedDisplaySession")
        }
        snapshot = current
        policy.observe(externalCount: current.externalCount)
        observeEmergency()
        render()
        guard !current.lidClosed else {
            if quitCompletion != nil { finishQuit(true, leaveGuardian: ownsOff) }
            return
        }
        if forceRestore || (current.externalCount == 0 && !current.builtinActive && !blockedAfterFailure) {
            change(enabled: true)
        } else if !blockedAfterFailure {
            let off = policy.wantsOff(externalCount: current.externalCount)
            if off && current.builtinActive && current.canDisable { change(enabled: false) }
            else if !off && !current.builtinActive && ownsOff { change(enabled: true) }
        }
    }

    func toggle() {
        blockedAfterFailure = false
        message = nil
        if snapshot?.builtinActive == true {
            do { try RecoveryCoordinator.allowOff(); lastRestoreToken = nil }
            catch { message = error.localizedDescription; render(); return }
            policy.requestOff(true)
            refresh()
        } else {
            policy.requestOff(false)
            forceRestore = true
            refresh()
        }
    }

    private func setAutomatic(_ enabled: Bool) {
        if enabled {
            do { try RecoveryCoordinator.allowOff(); lastRestoreToken = nil }
            catch { message = error.localizedDescription; render(); return }
        }
        policy.setAutomatic(enabled)
        preferences.set(enabled, forKey: "AutomaticSwitching")
        blockedAfterFailure = false
        message = nil
        if !enabled && ownsOff { forceRestore = true }
        refresh()
    }

    func emergencyRestore() {
        policy.emergencyRestore()
        preferences.set(false, forKey: "AutomaticSwitching")
        do { lastRestoreToken = try RecoveryCoordinator.requestRestore() }
        catch { message = error.localizedDescription }
        blockedAfterFailure = false
        forceRestore = true
        refresh()
    }

    func quit(completion: @escaping (Bool) -> Void) {
        guard quitCompletion == nil else { completion(false); return }
        quitCompletion = completion
        // The worker queue drains any in-flight disable before this restoration.
        // Keep the saved automatic preference for the next login.
        policy.requestOff(false)
        forceRestore = true
        if snapshot?.lidClosed == true && !busy { finishQuit(true, leaveGuardian: ownsOff); return }
        refresh()
    }

    private func change(enabled: Bool) {
        guard !busy else { return }
        busy = true
        stateGeneration += 1
        pendingDisable = !enabled
        render()
        if enabled { executeChange(enabled: true) }
        else {
            startGuardian { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    // User intent and sleep may change during guardian startup.
                    if self.sleeping || (!self.forceRestore && !self.policy.wantsOff(externalCount: self.snapshot?.externalCount ?? 0)) {
                        self.busy = false
                        self.pendingDisable = false
                        self.stopGuardian()
                        self.refresh()
                    } else {
                        self.executeChange(enabled: self.forceRestore)
                    }
                case .failure(let error):
                    self.busy = false
                    self.pendingDisable = false
                    self.blockedAfterFailure = true
                    self.message = "Could not start recovery protection: \(error.localizedDescription)"
                    self.render()
                    if self.forceRestore { self.refresh() }
                }
            }
        }
    }

    private func executeChange(enabled: Bool) {
        worker.setEnabled(enabled, cachedID: cachedID) { [weak self] result in
            guard let self else { return }
            self.busy = false
            self.pendingDisable = false
            switch result {
            case .success:
                self.message = nil
                if enabled {
                    let deferRecovery = self.snapshot?.lidClosed == true || self.sleeping
                    if !deferRecovery { self.ownsOff = false; self.stopGuardian() }
                    self.forceRestore = false
                    if self.quitCompletion != nil { self.finishQuit(true, leaveGuardian: deferRecovery); return }
                } else {
                    self.ownsOff = true
                    if self.guardian?.isRunning != true {
                        self.policy.requestOff(false)
                        self.forceRestore = true
                    }
                }
            case .failure(let error):
                self.blockedAfterFailure = true
                self.message = error.localizedDescription
                if enabled {
                    self.forceRestore = false
                    if self.quitCompletion != nil {
                        self.message = "Quit canceled because screen restoration failed. Use Restore Built-in Display to retry."
                        self.finishQuit(false)
                    }
                } else {
                    self.policy.requestOff(false)
                    self.forceRestore = true
                }
            }
            self.refresh()
        }
    }

    private func startGuardian(completion: @escaping (Result<Void, Error>) -> Void) {
        if guardian?.isRunning == true { completion(.success(())); return }
        let process = Process()
        let readyFile = RecoveryCoordinator.directory.appendingPathComponent("ready-\(UUID().uuidString)")
        process.executableURL = executable
        process.arguments = ["--guardian", String(ProcessInfo.processInfo.processIdentifier), "--builtin-id", String(cachedID), "--ready-file", readyFile.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self, weak process] _ in
            DispatchQueue.main.async {
                guard let self, let process, self.guardian === process else { return }
                self.guardian = nil
                if self.ownsOff || self.pendingDisable {
                    self.forceRestore = true
                    self.policy.requestOff(false)
                    do { self.lastRestoreToken = try RecoveryCoordinator.requestRestore() }
                    catch { self.message = error.localizedDescription }
                    self.refresh()
                }
            }
        }
        do { try process.run(); guardian = process }
        catch { completion(.failure(error)); return }
        waitForGuardian(process, readyFile: readyFile, deadline: Date().addingTimeInterval(3), completion: completion)
    }

    private func waitForGuardian(_ process: Process, readyFile: URL, deadline: Date, completion: @escaping (Result<Void, Error>) -> Void) {
        if FileManager.default.fileExists(atPath: readyFile.path) && process.isRunning {
            try? FileManager.default.removeItem(at: readyFile)
            completion(.success(())); return
        }
        guard process.isRunning, Date() < deadline else {
            stopGuardian()
            try? FileManager.default.removeItem(at: readyFile)
            completion(.failure(DisplayFailure("Recovery process did not become ready.")))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForGuardian(process, readyFile: readyFile, deadline: deadline, completion: completion)
        }
    }

    private func stopGuardian() {
        let previous = guardian
        guardian = nil
        if previous?.isRunning == true { previous?.terminate() }
    }

    private func finishQuit(_ success: Bool, leaveGuardian: Bool = false) {
        let completion = quitCompletion
        quitCompletion = nil
        if success && !leaveGuardian { stopGuardian() }
        completion?(success)
    }

    private func render() {
        menu.update(MenuState(builtinOff: snapshot?.builtinActive == false,
                              externalCount: snapshot?.externalCount ?? 0,
                              busy: busy, automatic: policy.automatic, paused: policy.isPaused,
                              canDisable: snapshot?.canDisable == true && snapshot?.lidClosed != true,
                              message: message))
    }
}
