import Foundation
import Darwin

struct DisplaySnapshot {
    let builtinID: UInt32
    let builtinActive: Bool
    let builtinOnline: Bool
    let externalCount: Int
    let lidClosed: Bool
    let canDisable: Bool

    static func read(cachedID: UInt32 = 0) throws -> DisplaySnapshot {
        var value = OSDisplayStatus()
        var buffer = [CChar](repeating: 0, count: 1024)
        guard OSReadDisplayStatus(cachedID, &value, &buffer, buffer.count) == 0 else {
            throw DisplayFailure(String(cString: buffer))
        }
        return DisplaySnapshot(builtinID: value.builtin_id, builtinActive: value.builtin_active != 0,
                               builtinOnline: value.builtin_online != 0, externalCount: Int(value.external_count),
                               lidClosed: value.lid_closed == 1, canDisable: value.can_disable != 0)
    }
}

struct DisplayFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The disposable helper owns the shared mutation lock and every private API.
func performDisplayChange(executable: URL, enabled: Bool, cachedID: UInt32) -> Result<Void, Error> {
    do {
        try RecoveryCoordinator.prepare()
        let outputURL = RecoveryCoordinator.directory.appendingPathComponent("worker-\(UUID().uuidString).log")
        let descriptor = open(outputURL.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw DisplayFailure("Could not create the display helper's output file.") }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { close(descriptor); unlink(outputURL.path) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--set", enabled ? "on" : "off", "--builtin-id", String(cachedID)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 12) == .timedOut {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 1) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                if finished.wait(timeout: .now() + 2) == .timedOut && process.isRunning {
                    return .failure(DisplayFailure("The display helper has not exited after termination. Its safety lock remains held; no competing display change will run. Try Restore Built-in Display again in a moment."))
                }
            }
            return .failure(DisplayFailure("Display change timed out and its helper was stopped. Use Restore Built-in Display to recover."))
        }
        // A regular file avoids pipe-buffer deadlocks and unbounded EOF waits.
        var bytes = [UInt8](repeating: 0, count: 8192)
        let length = pread(descriptor, &bytes, bytes.count, 0)
        let message = length > 0 ? String(decoding: bytes.prefix(length), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) : "Display change failed."
        return process.terminationStatus == 0 ? .success(()) : .failure(DisplayFailure(message))
    } catch { return .failure(error) }
}

/// A disposable process keeps a stalled private API away from the menu and recovery path.
final class DisplayWorker {
    private let queue = DispatchQueue(label: "com.daymoon.outscreen.worker", qos: .userInitiated)
    let executable: URL

    init(executable: URL) { self.executable = executable }

    func setEnabled(_ enabled: Bool, cachedID: UInt32, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            let result = performDisplayChange(executable: self.executable, enabled: enabled, cachedID: cachedID)
            DispatchQueue.main.async { completion(result) }
        }
    }
}
