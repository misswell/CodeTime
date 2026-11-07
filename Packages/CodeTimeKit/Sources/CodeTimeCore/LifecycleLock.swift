import Foundation
import Darwin
import SharedModels

/// CT-072: A shared/exclusive lifecycle coordination lock that lives OUTSIDE the
/// replaceable data root. Multiple processes (UI, Agent, Scheduler) hold shared
/// locks during normal operation. Migration acquires an exclusive lock, which
/// blocks new shared acquisitions until the migration completes.
///
/// Uses POSIX flock(2) semantics:
/// - `LOCK_SH` (shared): multiple holders allowed; blocks exclusive acquisition.
/// - `LOCK_EX` (exclusive): sole holder; blocks both shared and exclusive.
///
/// The lock file is never deleted during the process lifetime, so the fd always
/// refers to the same inode regardless of directory replacement.
public final class LifecycleLock: @unchecked Sendable {
    public enum Mode: Sendable {
        case shared
        case exclusive
    }

    private let path: String
    private var fd: Int32 = -1
    private var mode: Mode?
    private let lock = NSLock()

    public init(path: String) {
        self.path = path
    }

    deinit { release() }

    /// Acquire a shared lock. Multiple processes may hold shared locks
    /// simultaneously. Blocks if an exclusive lock is held by another process.
    public func acquireShared(timeout: TimeInterval = 120) throws {
        try acquire(.shared, timeout: timeout)
    }

    /// Acquire an exclusive lock. No other process may hold any lock on this
    /// file. Blocks until all shared and exclusive locks are released.
    public func acquireExclusive(timeout: TimeInterval = 120) throws {
        try acquire(.exclusive, timeout: timeout)
    }

    /// Non-blocking attempt. Returns false if the lock cannot be acquired
    /// immediately (an incompatible lock is held by another process).
    @discardableResult
    public func tryAcquire(_ mode: Mode) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard fd < 0 else { return false }
        guard openLockFile() else { return false }
        let operation: Int32 = mode == .shared ? LOCK_SH : LOCK_EX
        guard flock(fd, operation | LOCK_NB) == 0 else {
            close(fd); fd = -1
            return false
        }
        self.mode = mode
        return true
    }

    /// Release the lock and close the fd. Safe to call multiple times.
    public func release() {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
        mode = nil
    }

    public var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fd >= 0
    }

    public var heldMode: Mode? {
        lock.lock()
        defer { lock.unlock() }
        return mode
    }

    private func acquire(_ mode: Mode, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if tryAcquire(mode) { return }
            if Date() >= deadline {
                throw CodeTimeError.repositoryUnavailable(
                    "生命周期锁（\(mode == .shared ? "共享" : "独占")）等待超时：\(path)"
                )
            }
            usleep(100_000)
        }
    }

    private func openLockFile() -> Bool {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        return fd >= 0
    }
}
