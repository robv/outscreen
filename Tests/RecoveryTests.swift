import Foundation
import Darwin

/// Runs with OUTSCREEN_TESTING and a separate temporary coordination folder.
/// The test binary links an aborting C snapshot stub, never the display backend.
@main
struct RecoveryTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw DisplayFailure(message) }
    }

    static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    static func run() throws {
        if CommandLine.arguments.contains("--hold-lock") {
            try RecoveryCoordinator.withMutationLock {
                try Data("ready".utf8).write(to: RecoveryCoordinator.directory.appendingPathComponent("held"))
                Thread.sleep(forTimeInterval: 5.5)
            }
            return
        }

        try RecoveryCoordinator.prepare()
        var info = stat()
        try expect(lstat(RecoveryCoordinator.directory.path, &info) == 0 && (info.st_mode & 0o777) == 0o700,
                   "Coordination folder must be private to its user.")
        try expect(RecoveryCoordinator.restoreToken == nil, "A new session must not contain a restore marker.")
        let first = try RecoveryCoordinator.requestRestore()
        try expect(RecoveryCoordinator.restoreToken == first, "Restore token was not published.")
        let second = try RecoveryCoordinator.requestRestore()
        try expect(first != second && RecoveryCoordinator.restoreToken == second, "Each restore must publish a unique token.")
        try RecoveryCoordinator.allowOff()
        try expect(RecoveryCoordinator.restoreToken == nil, "Explicit off permission must clear recovery.")
        let marker = RecoveryCoordinator.directory.appendingPathComponent("restore-request")
        try expect(mkfifo(marker.path, 0o600) == 0, "Could not create malformed-marker fixture.")
        let markerStart = Date()
        try expect(RecoveryCoordinator.restoreToken != nil, "Nonregular markers must fail closed.")
        try expect(Date().timeIntervalSince(markerStart) < 1, "A FIFO marker must not block a reader.")
        try RecoveryCoordinator.allowOff()
        print("PASS: unique restore markers, explicit clear, private permissions, nonblocking malformed marker")

        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        holder.arguments = ["--hold-lock"]
        let finished = DispatchSemaphore(value: 0)
        holder.terminationHandler = { _ in finished.signal() }
        try holder.run()
        defer { if holder.isRunning { kill(holder.processIdentifier, SIGKILL) } }
        let ready = RecoveryCoordinator.directory.appendingPathComponent("held").path
        let readyDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: ready) && Date() < readyDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        try expect(FileManager.default.fileExists(atPath: ready), "Lock holder did not start.")
        let lockStart = Date()
        var acquiredCompetingLock = false
        var acquisitionFailed = false
        do { try RecoveryCoordinator.withMutationLock { acquiredCompetingLock = true } }
        catch { acquisitionFailed = true }
        try expect(!acquiredCompetingLock && acquisitionFailed, "Concurrent processes entered the mutation lock.")
        try expect(Date().timeIntervalSince(lockStart) < 4.7, "Lock acquisition exceeded its bounded timeout.")
        try expect(finished.wait(timeout: .now() + 3) == .success, "Lock holder did not exit.")
        try expect(holder.terminationStatus == 0, "Lock holder failed.")
        try RecoveryCoordinator.withMutationLock { }
        print("PASS: cross-process exclusion, bounded acquisition timeout, lock release after exit")

        switch performDisplayChange(executable: URL(fileURLWithPath: "/bin/echo"), enabled: true, cachedID: 0) {
        case .success: break
        case .failure(let error): throw error
        }
        switch performDisplayChange(executable: URL(fileURLWithPath: "/usr/bin/false"), enabled: true, cachedID: 0) {
        case .success: throw DisplayFailure("A failed helper was reported as successful.")
        case .failure: break
        }
        print("PASS: helper success and nonzero exit reporting")

        let sleeper = RecoveryCoordinator.directory.appendingPathComponent("fake-worker.sh")
        try Data("#!/bin/sh\necho $$ > \"$OUTSCREEN_TEST_DIRECTORY/fake-worker-pid\"\nexec /bin/sleep 25\n".utf8).write(to: sleeper)
        try expect(chmod(sleeper.path, 0o700) == 0, "Could not make the fake worker executable.")
        let timeoutStart = Date()
        switch performDisplayChange(executable: sleeper, enabled: true, cachedID: 0) {
        case .success: throw DisplayFailure("A stalled helper was reported as successful.")
        case .failure(let error):
            try expect(error.localizedDescription.contains("timed out"), "The helper failure did not identify its timeout.")
        }
        try expect(Date().timeIntervalSince(timeoutStart) < 16, "A stalled helper exceeded its bounded termination period.")
        let pidText = try String(contentsOf: RecoveryCoordinator.directory.appendingPathComponent("fake-worker-pid"), encoding: .utf8)
        guard let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw DisplayFailure("The fake worker did not record its PID.")
        }
        try expect(kill(pid, 0) == -1 && errno == ESRCH, "The timed-out helper is still running.")
        print("PASS: stalled helper terminated within its timeout; no display APIs invoked")
    }
}
