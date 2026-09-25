import Foundation
import Darwin

/// Shared by the UI, workers, guardian, and CLI; all state belongs to this boot.
enum RecoveryCoordinator {
    static let sessionID: String = {
        #if OUTSCREEN_TESTING
        return "isolated-test-session"
        #else
        var count = 0
        if sysctlbyname("kern.bootsessionuuid", nil, &count, nil, 0) == 0, count > 1, count < 1024 {
            var bytes = [CChar](repeating: 0, count: count)
            if sysctlbyname("kern.bootsessionuuid", &bytes, &count, nil, 0) == 0 {
                let value = String(cString: bytes)
                if !value.isEmpty && value.allSatisfy({ $0.isHexDigit || $0 == "-" }) { return value }
            }
        }
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 {
            return "\(boot.tv_sec)-\(boot.tv_usec)"
        }
        return "unavailable"
        #endif
    }()

    static let directory: URL = {
        #if OUTSCREEN_TESTING
        guard let path = ProcessInfo.processInfo.environment["OUTSCREEN_TEST_DIRECTORY"], !path.isEmpty else {
            fatalError("Test builds require an isolated OUTSCREEN_TEST_DIRECTORY.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
        #else
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("outscreen-\(getuid())-\(sessionID)", isDirectory: true)
        #endif
    }()

    private static func posixFailure(_ operation: String) -> DisplayFailure {
        DisplayFailure("Outscreen recovery coordination could not \(operation): \(String(cString: strerror(errno))).")
    }

    private static func withDirectory<T>(_ body: (Int32) throws -> T) throws -> T {
        guard sessionID != "unavailable" else {
            throw DisplayFailure("Outscreen could not identify this macOS session. Restart the app before switching displays.")
        }
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw posixFailure("create its session folder") }
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixFailure("open its session folder") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixFailure("inspect its session folder") }
        guard info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700 else {
            throw DisplayFailure("Outscreen's session folder has unexpected permissions. Display switching has been stopped.")
        }
        return try body(descriptor)
    }

    static func prepare() throws { try withDirectory { _ in } }

    static var restoreToken: String? {
        do {
            return try withDirectory { directoryFD in
                let descriptor = openat(directoryFD, "restore-request", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                if descriptor < 0 {
                    if errno == ENOENT { return nil }
                    throw posixFailure("read the restore request")
                }
                defer { close(descriptor) }
                var info = stat()
                guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
                      (info.st_mode & S_IFMT) == S_IFREG else {
                    throw DisplayFailure("Outscreen's restore marker is not a regular file owned by this user.")
                }
                var bytes = [UInt8](repeating: 0, count: 128)
                let length = read(descriptor, &bytes, bytes.count)
                guard length > 0 else { throw posixFailure("read the restore request") }
                return String(decoding: bytes.prefix(length), as: UTF8.self)
            }
        } catch {
            // An unreadable marker must never imply permission to switch off.
            return "coordination-unavailable"
        }
    }

    /// No mutation lock here: recovery must cancel even an in-flight off request.
    @discardableResult
    static func requestRestore() throws -> String {
        let token = UUID().uuidString
        try withDirectory { directoryFD in
            let staging = "restore-\(token).tmp"
            let descriptor = openat(directoryFD, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw posixFailure("save the restore request") }
            defer { close(descriptor); unlinkat(directoryFD, staging, 0) }
            let bytes = Array(token.utf8)
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw posixFailure("save the restore request") }
                    offset += written
                }
            }
            guard fsync(descriptor) == 0 else { throw posixFailure("save the restore request") }
            guard renameat(directoryFD, staging, directoryFD, "restore-request") == 0 else {
                throw posixFailure("publish the restore request")
            }
        }
        return token
    }

    /// Only explicit user intent to switch off/re-enable automatic mode clears
    /// recovery. Routine monitor callbacks must never clear this marker.
    static func allowOff() throws {
        try withDirectory { directoryFD in
            if unlinkat(directoryFD, "restore-request", 0) != 0 && errno != ENOENT {
                throw posixFailure("clear the restore request")
            }
        }
    }

    static func withMutationLock<T>(_ body: () throws -> T) throws -> T {
        try withDirectory { directoryFD in
            let descriptor = openat(directoryFD, "mutation.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw posixFailure("open the display lock") }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
                  (info.st_mode & S_IFMT) == S_IFREG, (info.st_mode & 0o077) == 0 else {
                throw DisplayFailure("Outscreen's display lock has unexpected ownership or permissions.")
            }
            let deadline = DispatchTime.now().uptimeNanoseconds + 4_000_000_000
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                    throw posixFailure("acquire the display lock")
                }
                guard DispatchTime.now().uptimeNanoseconds < deadline else {
                    throw DisplayFailure("Another display change is still running. Wait a moment, then use Restore Built-in Display.")
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            // Never unlock while body executes a private API. If killed, the
            // kernel releases this lock only when the worker actually exits.
            defer { flock(descriptor, LOCK_UN) }
            return try body()
        }
    }
}
