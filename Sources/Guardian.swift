import Foundation
import Darwin
import IOKit

private func guardianLidClosed() -> Bool {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != IO_OBJECT_NULL else { return false }
    defer { IOObjectRelease(service) }
    guard let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                                       kCFAllocatorDefault, 0)?.takeRetainedValue(),
          CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
    return CFBooleanGetValue((value as! CFBoolean))
}

/// Separate from the UI process: restores after a crash or loss of every external.
/// Mutations run in a bounded helper using the shared display lock.
func runGuardian(parentPID: pid_t, cachedID: UInt32) -> Int32 {
    guard parentPID > 1, let executable = Bundle.main.executableURL else { return 2 }
    do { try RecoveryCoordinator.prepare() }
    catch { fputs("Outscreen guardian coordination: \(error.localizedDescription)\n", stderr); return 2 }
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--ready-file"), arguments.indices.contains(index + 1) {
        do {
            try Data("ready".utf8).write(to: URL(fileURLWithPath: arguments[index + 1]), options: .atomic)
        } catch {
            fputs("Outscreen guardian could not signal readiness: \(error.localizedDescription)\n", stderr)
            return 2
        }
    }
    var failures = 0
    var absentSamples = 0
    var rescueStarted = false
    var parentDeathRecorded = false
    while true {
        let parentAlive = kill(parentPID, 0) == 0 || errno == EPERM
        if parentAlive && FileManager.default.fileExists(atPath: RecoveryCoordinator.directory.appendingPathComponent("sleeping").path) {
            absentSamples = 0
            Thread.sleep(forTimeInterval: 1)
            continue
        }
        let snapshot = try? DisplaySnapshot.read(cachedID: cachedID)
        if snapshot?.lidClosed == true || guardianLidClosed() {
            // Stay alive after UI quit until reopening allows safe restoration.
            absentSamples = 0
            Thread.sleep(forTimeInterval: 1)
            continue
        }
        if snapshot?.externalCount == 0 { absentSamples += 1 }
        else { absentSamples = 0 }
        rescueStarted = rescueStarted || !parentAlive || absentSamples >= 2
        if rescueStarted {
            if !parentAlive && !parentDeathRecorded {
                do { try RecoveryCoordinator.requestRestore(); parentDeathRecorded = true }
                catch { fputs("Outscreen recovery coordination: \(error.localizedDescription)\n", stderr) }
            }
            switch performDisplayChange(executable: executable, enabled: true, cachedID: cachedID) {
            case .success: return 0
            case .failure(let error):
                failures += 1
                fputs("Outscreen recovery: \(error.localizedDescription)\n", stderr)
                if failures >= 5 { return 1 }
            }
        }
        Thread.sleep(forTimeInterval: 1)
    }
}
