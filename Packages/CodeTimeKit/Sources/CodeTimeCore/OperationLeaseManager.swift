import Foundation
import SharedModels

/// Cross-process runtime coordination between backups/restores and destructive
/// maintenance (GC/migration).
///
/// A single flock file provides advisory mutual exclusion for CodeTime processes
/// on this Mac. It is deliberately NOT treated as a distributed lock: iCloud is
/// only used for the GC Epoch/device-ack protocol, never as a CAS service.
///
/// Lock order is fixed: runtime lease first, then SQLite transactions. No code may
/// acquire the runtime lease while holding a SQLite write transaction.
public final class OperationLeaseManager: @unchecked Sendable {
    public enum Mode: String, Sendable {
        /// Backup, restore, verification: any number may run concurrently.
        case shared
        /// GC, migration, destructive maintenance: exclusive.
        case exclusive
    }

    private let path: String
    private let lock = NSLock()

    public init(path: String) {
        self.path = path
    }

    /// Blocks until the requested mode is available or the timeout elapses.
    /// `timeout == 0` performs a single non-blocking attempt.
    public func acquire(_ mode: Mode, timeout: TimeInterval = 0) throws -> OperationLease {
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw CodeTimeError.repositoryUnavailable("无法打开运行时锁：\(path)")
        }
        let operation = mode == .shared ? LOCK_SH : LOCK_EX
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            if flock(fd, operation | LOCK_NB) == 0 {
                return OperationLease(fd: fd, path: path)
            }
            let code = errno
            guard code == EWOULDBLOCK || code == EAGAIN else {
                close(fd)
                throw CodeTimeError.repositoryBusy("运行时锁失败（errno \(code)）")
            }
            if Date() >= deadline {
                close(fd)
                throw CodeTimeError.repositoryBusy(
                    mode == .exclusive ? "备份/恢复任务正在运行，维护操作稍后重试" : "维护任务正在运行"
                )
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}

public final class OperationLease: @unchecked Sendable {
    private var fd: Int32?
    private let path: String
    private let lock = NSLock()

    init(fd: Int32, path: String) {
        self.fd = fd
        self.path = path
    }

    deinit { release() }

    public func release() {
        lock.lock(); defer { lock.unlock() }
        guard let descriptor = fd else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        fd = nil
    }

    public var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return fd != nil
    }
}
