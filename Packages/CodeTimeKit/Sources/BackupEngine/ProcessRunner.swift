import Foundation
import Darwin
import SharedModels

public struct CommandTimeoutError: LocalizedError, Sendable {
    public var seconds: TimeInterval
    public var errorDescription: String? { "命令执行超时（\(Int(seconds)) 秒）" }
}

public struct CommandResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var duration: TimeInterval
    /// True when the capture buffer hit its cap; callers must not treat partial
    /// output as a complete JSON document.
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool
    public var terminationSignal: Int32?

    public var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
    public var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }

    public init(
        status: Int32,
        stdout: Data,
        stderr: Data,
        duration: TimeInterval,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false,
        terminationSignal: Int32? = nil
    ) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.duration = duration
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
        self.terminationSignal = terminationSignal
    }
}

public enum KopiaBinary {
    public static func locate(explicit: URL? = nil) -> URL? {
        var candidates: [URL] = []
        if let explicit { candidates.append(explicit) }
        if let env = ProcessInfo.processInfo.environment["KOPIA_PATH"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let resource = Bundle.main.url(forResource: "kopia", withExtension: nil, subdirectory: "Kopia") {
            candidates.append(resource)
        }
        if let resource = Bundle.main.url(forResource: "kopia", withExtension: nil) {
            candidates.append(resource)
        }
        if let executable = Bundle.main.executableURL {
            let macos = executable.deletingLastPathComponent()
            let contents = macos.deletingLastPathComponent()
            candidates.append(contents.appendingPathComponent("Resources/Kopia/kopia"))
            candidates.append(macos.appendingPathComponent("kopia"))
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/kopia"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/kopia"))

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    public static func version(at url: URL) async -> String? {
        guard let result = try? await ProcessRunner().run(
            executable: url,
            arguments: ["--version"],
            timeout: 20
        ), result.status == 0 else { return nil }
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Tracks the spawned process group so cancellation can never target a recycled
/// PID: the start time is captured at spawn and re-checked before any kill.
private final class PIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = -1
    private var startTime: Double = 0
    private var cancelled = false

    func set(_ value: pid_t) {
        lock.lock()
        pid = value
        startTime = ProcessIdentity.processStartTime(value)
        let shouldKill = cancelled
        lock.unlock()
        if shouldKill { Self.signalGroup(value, startTime: startTime, sig: SIGTERM) }
    }

    /// Called only after `waitpid` has reaped the child. Any later cancel is a no-op,
    /// which removes the "kill a reused PID" window.
    func clear(_ value: pid_t) {
        lock.lock()
        if pid == value {
            pid = -1
            startTime = 0
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let target = pid
        let start = startTime
        lock.unlock()
        guard target > 0, Self.isSameProcess(target, start: start) else { return }
        Self.signalGroup(target, startTime: start, sig: SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            guard Self.isSameProcess(target, start: start) else { return }
            Self.signalGroup(target, startTime: start, sig: SIGKILL)
        }
    }

    private static func isSameProcess(_ pid: pid_t, start: Double) -> Bool {
        guard start > 0 else { return false }
        return ProcessIdentity.isAlive(pid, startTime: start)
    }

    private static func signalGroup(_ pid: pid_t, startTime: Double, sig: Int32) {
        guard isSameProcess(pid, start: startTime) else { return }
        // The child is a process-group leader; negative PID signals the whole tree,
        // including helpers spawned by kopia.
        if kill(-pid, sig) != 0 {
            _ = kill(pid, sig)
        }
    }
}

/// POSIX-based subprocess runner. Foundation's `Process.waitUntilExit()` has been
/// observed to hang on macOS when many short-lived children are spawned, so the
/// engine uses posix_spawn + poll + waitpid directly.
public final class ProcessRunner: @unchecked Sendable {
    public var captureLimitPerStream: Int

    public init(captureLimitPerStream: Int = 16 * 1024 * 1024) {
        self.captureLimitPerStream = max(64 * 1024, captureLimitPerStream)
    }

    public func run(
        executable: URL,
        arguments: [String],
        environment overrides: [String: String] = [:],
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 300
    ) async throws -> CommandResult {
        guard timeout > 0 else { throw CodeTimeError.commandFailed(command: executable.lastPathComponent, status: -1, message: "超时必须大于 0") }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        environment["KOPIA_CHECK_FOR_UPDATES"] = "false"
        for (key, value) in overrides {
            environment[key] = value
        }

        let box = PIDBox()
        let limit = captureLimitPerStream
        let result = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try Self.runSync(
                    executable: executable,
                    arguments: arguments,
                    environment: environment,
                    currentDirectory: currentDirectory,
                    timeout: timeout,
                    captureLimit: limit,
                    box: box
                )
            }.value
        } onCancel: {
            box.cancel()
        }
        if Task.isCancelled { throw CodeTimeError.cancelled }
        return result
    }

    /// Darwin's WIFEXITED/WTERMSIG are function-like C macros and are not exposed to
    /// Swift, so the wait status is decoded with the stable POSIX bit layout.
    private static func decodeExitStatus(_ waitStatus: Int32) -> (status: Int32, signal: Int32?) {
        let signal = waitStatus & 0x7F
        if signal == 0 {
            return ((waitStatus >> 8) & 0xFF, nil)
        }
        if signal == 0x7F {
            // Stopped child (only possible without WUNTRACED on some platforms).
            return (-1, nil)
        }
        return (128 + signal, signal)
    }

    /// EINTR-safe blocking wait. A signal delivered while waiting must never be
    /// mistaken for a missing child.
    private static func waitForExit(_ pid: pid_t, blocking: Bool) -> Int32? {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, blocking ? 0 : WNOHANG)
            if result == pid { return status }
            if result == 0 && !blocking { return nil }
            if result < 0 {
                if errno == EINTR { continue }
                return nil
            }
        }
    }

    private static func runSync(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        timeout: TimeInterval,
        captureLimit: Int,
        box: PIDBox
    ) throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CodeTimeError.kopiaNotFound
        }

        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdoutPipe) == 0 else {
            throw CodeTimeError.repositoryUnavailable("无法创建命令输出管道")
        }
        guard pipe(&stderrPipe) == 0 else {
            close(stdoutPipe[0]); close(stdoutPipe[1])
            throw CodeTimeError.repositoryUnavailable("无法创建命令错误管道")
        }
        defer {
            for fd in stdoutPipe + stderrPipe where fd >= 0 { close(fd) }
        }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw CodeTimeError.repositoryUnavailable("无法初始化进程文件操作")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        // Every file action is checked: an unchecked failure would leave the child
        // writing to the parent's terminal or inheriting unrelated descriptors.
        func addAction(_ result: Int32) throws {
            guard result == 0 else {
                throw CodeTimeError.repositoryUnavailable("无法配置子进程文件描述符（\(result)）")
            }
        }
        try addAction(posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO))
        try addAction(posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO))
        try addAction(posix_spawn_file_actions_addclose(&actions, stdoutPipe[0]))
        try addAction(posix_spawn_file_actions_addclose(&actions, stderrPipe[0]))
        try addAction(posix_spawn_file_actions_addclose(&actions, stdoutPipe[1]))
        try addAction(posix_spawn_file_actions_addclose(&actions, stderrPipe[1]))

        let devNull = open("/dev/null", O_RDONLY)
        if devNull >= 0 {
            try addAction(posix_spawn_file_actions_adddup2(&actions, devNull, STDIN_FILENO))
            if devNull > 2 {
                try addAction(posix_spawn_file_actions_addclose(&actions, devNull))
            }
        }
        if let currentDirectory {
            try addAction(posix_spawn_file_actions_addchdir_np(&actions, currentDirectory.path))
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            if devNull >= 0 { close(devNull) }
            throw CodeTimeError.repositoryUnavailable("无法初始化进程属性")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        // Own process group: timeout/cancel can terminate helpers too, and the
        // parent's group is never signalled.
        var flags = Int16(POSIX_SPAWN_SETPGROUP)
        if POSIX_SPAWN_CLOEXEC_DEFAULT > 0 {
            flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        }
        posix_spawnattr_setflags(&attributes, flags)
        posix_spawnattr_setpgroup(&attributes, 0)

        var argumentPointers: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) }
        argumentPointers.append(nil)
        defer { for pointer in argumentPointers where pointer != nil { free(pointer) } }

        var environmentPointers: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        environmentPointers.append(nil)
        defer { for pointer in environmentPointers where pointer != nil { free(pointer) } }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, executable.path, &actions, &attributes, argumentPointers, environmentPointers)
        if devNull >= 0 { close(devNull) }
        guard spawnResult == 0 else {
            throw CodeTimeError.commandFailed(
                command: executable.lastPathComponent,
                status: spawnResult,
                message: String(cString: strerror(spawnResult))
            )
        }
        box.set(pid)

        close(stdoutPipe[1]); stdoutPipe[1] = -1
        close(stderrPipe[1]); stderrPipe[1] = -1
        _ = fcntl(stdoutPipe[0], F_SETFL, O_NONBLOCK)
        _ = fcntl(stderrPipe[0], F_SETFL, O_NONBLOCK)

        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(timeout)
        var stdout = Data()
        var stderr = Data()
        var stdoutTruncated = false
        var stderrTruncated = false
        var stdoutOpen = true
        var stderrOpen = true
        var exitStatus: Int32?
        var terminationSignal: Int32?
        var exitSeenAt: Date?

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            if Date() >= deadline, exitStatus == nil {
                if kill(-pid, SIGKILL) != 0 { _ = kill(pid, SIGKILL) }
                if let status = waitForExit(pid, blocking: true) {
                    let decoded = decodeExitStatus(status)
                    exitStatus = decoded.status
                    terminationSignal = decoded.signal
                    box.clear(pid)
                }
                throw CommandTimeoutError(seconds: timeout)
            }

            var descriptors = [
                pollfd(fd: stdoutOpen ? stdoutPipe[0] : -1, events: Int16(POLLIN | POLLHUP), revents: 0),
                pollfd(fd: stderrOpen ? stderrPipe[0] : -1, events: Int16(POLLIN | POLLHUP), revents: 0),
            ]
            let ready = poll(&descriptors, 2, 40)
            if ready < 0 && errno != EINTR {
                let message = String(cString: strerror(errno))
                if kill(-pid, SIGKILL) != 0 { _ = kill(pid, SIGKILL) }
                _ = waitForExit(pid, blocking: true)
                box.clear(pid)
                throw CodeTimeError.commandFailed(
                    command: executable.lastPathComponent,
                    status: -1,
                    message: "poll 失败：\(message)"
                )
            }

            if ready > 0 {
                for (index, descriptor) in descriptors.enumerated() where descriptor.fd >= 0 {
                    guard descriptor.revents & Int16(POLLIN | POLLHUP) != 0 else { continue }
                    let fd = descriptor.fd
                    let count = buffer.withUnsafeMutableBytes { raw in
                        read(fd, raw.baseAddress, raw.count)
                    }
                    if count > 0 {
                        let chunk = Data(buffer[0..<count])
                        if index == 0 {
                            if stdout.count < captureLimit {
                                let room = captureLimit - stdout.count
                                stdout.append(chunk.prefix(room))
                                if chunk.count > room { stdoutTruncated = true }
                            } else {
                                stdoutTruncated = true
                            }
                        } else {
                            if stderr.count < captureLimit {
                                let room = captureLimit - stderr.count
                                stderr.append(chunk.prefix(room))
                                if chunk.count > room { stderrTruncated = true }
                            } else {
                                stderrTruncated = true
                            }
                        }
                    } else if count == 0 {
                        close(fd)
                        if index == 0 { stdoutPipe[0] = -1; stdoutOpen = false }
                        else { stderrPipe[0] = -1; stderrOpen = false }
                    } else if errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                        close(fd)
                        if index == 0 { stdoutPipe[0] = -1; stdoutOpen = false }
                        else { stderrPipe[0] = -1; stderrOpen = false }
                    }
                }
            }

            if exitStatus == nil {
                if let status = waitForExit(pid, blocking: false) {
                    let decoded = decodeExitStatus(status)
                    exitStatus = decoded.status
                    terminationSignal = decoded.signal
                    exitSeenAt = Date()
                    box.clear(pid)
                }
            }

            if exitStatus != nil {
                if !stdoutOpen && !stderrOpen { break }
                if let exitSeenAt, Date().timeIntervalSince(exitSeenAt) > 2 {
                    // A grandchild may hold the pipe open; the group was already
                    // signalled, so stop waiting for EOF.
                    if stdoutOpen { kill(-pid, SIGKILL); close(stdoutPipe[0]); stdoutOpen = false }
                    if stderrOpen { kill(-pid, SIGKILL); close(stderrPipe[0]); stderrOpen = false }
                    break
                }
            }
        }

        if exitStatus == nil, let status = waitForExit(pid, blocking: true) {
            let decoded = decodeExitStatus(status)
            exitStatus = decoded.status
            terminationSignal = decoded.signal
            box.clear(pid)
        }

        return CommandResult(
            status: exitStatus ?? -1,
            stdout: stdout,
            stderr: stderr,
            duration: Date().timeIntervalSince(startedAt),
            stdoutTruncated: stdoutTruncated,
            stderrTruncated: stderrTruncated,
            terminationSignal: terminationSignal
        )
    }
}

/// Cross-process advisory lock backed by `flock(2)`. The kernel releases the lock
/// when the owning process exits, so a crashed writer cannot wedge the repository.
public final class RepositoryLock: @unchecked Sendable {
    public struct OwnerInfo: Sendable, Equatable {
        public var pid: Int32
        public var startTime: Double
        public var acquiredAt: Date
    }

    private let path: String
    private var descriptor: Int32 = -1

    public init(path: String) {
        self.path = path
    }

    public func acquire(timeout: TimeInterval = 120) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if tryAcquire() { return }
            if Date() >= deadline {
                let owner = currentOwner().map { " (持有者 PID \($0.pid))" } ?? ""
                throw CodeTimeError.repositoryUnavailable("仓库正在被另一个备份任务使用\(owner)")
            }
            if Task.isCancelled { throw CodeTimeError.cancelled }
            usleep(200_000)
        }
    }

    /// Acquire only when the lock file already exists. Absent means no process
    /// has ever used that subsystem, so there is nothing to coordinate.
    @discardableResult
    public func tryAcquireIfPresent() -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return true }
        return tryAcquire()
    }

    @discardableResult
    public func tryAcquire() -> Bool {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard fd >= 0 else { return false }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            descriptor = fd
            let start = ProcessIdentity.processStartTime(getpid())
            let line = "\(getpid()) \(start) \(Int(Date().timeIntervalSince1970))\n"
            _ = ftruncate(fd, 0)
            _ = line.withCString { pointer in
                write(fd, pointer, strlen(pointer))
            }
            _ = fsync(fd)
            return true
        }
        close(fd)
        return false
    }

    public func currentOwner() -> OwnerInfo? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let parts = text.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        guard parts.count >= 3 else { return nil }
        return OwnerInfo(
            pid: Int32(parts[0]),
            startTime: parts[1],
            acquiredAt: Date(timeIntervalSince1970: parts[2])
        )
    }

    public func release() {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }

    deinit {
        release()
    }
}
