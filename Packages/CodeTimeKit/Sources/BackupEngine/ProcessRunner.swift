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

    public var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
    public var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }
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

private final class PIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = -1
    private var cancelled = false

    func set(_ value: pid_t) {
        lock.lock()
        pid = value
        let shouldKill = cancelled
        lock.unlock()
        if shouldKill { Darwin.kill(value, SIGKILL) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let target = pid
        lock.unlock()
        if target > 0 { Darwin.kill(target, SIGKILL) }
    }
}

/// POSIX-based subprocess runner. Foundation's `Process.waitUntilExit()` has been
/// observed to hang on macOS when many short-lived children are spawned, so the
/// engine uses posix_spawn + poll + waitpid directly.
public final class ProcessRunner: @unchecked Sendable {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        environment overrides: [String: String] = [:],
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 300
    ) async throws -> CommandResult {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        environment["KOPIA_CHECK_FOR_UPDATES"] = "false"
        for (key, value) in overrides {
            environment[key] = value
        }

        let box = PIDBox()
        let result = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try Self.runSync(
                    executable: executable,
                    arguments: arguments,
                    environment: environment,
                    currentDirectory: currentDirectory,
                    timeout: timeout,
                    box: box
                )
            }.value
        } onCancel: {
            box.cancel()
        }
        if Task.isCancelled { throw CodeTimeError.cancelled }
        return result
    }

    private static func decodeExitStatus(_ waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7F
        if signal == 0 {
            return (waitStatus >> 8) & 0xFF
        }
        return 128 + signal
    }

    private static func runSync(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        timeout: TimeInterval,
        box: PIDBox
    ) throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CodeTimeError.kopiaNotFound
        }

        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            throw CodeTimeError.repositoryUnavailable("无法创建命令输出管道")
        }
        defer {
            for fd in stdoutPipe + stderrPipe where fd >= 0 { close(fd) }
        }

        let devNull = open("/dev/null", O_RDONLY)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)
        if devNull >= 0 {
            posix_spawn_file_actions_adddup2(&actions, devNull, STDIN_FILENO)
            if devNull > 2 { posix_spawn_file_actions_addclose(&actions, devNull) }
        }
        posix_spawn_file_actions_addclose(&actions, stdoutPipe[0])
        posix_spawn_file_actions_addclose(&actions, stderrPipe[0])
        if let currentDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, currentDirectory.path)
        }

        var argumentPointers: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) }
        argumentPointers.append(nil)
        defer { for pointer in argumentPointers where pointer != nil { free(pointer) } }

        var environmentPointers: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        environmentPointers.append(nil)
        defer { for pointer in environmentPointers where pointer != nil { free(pointer) } }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, executable.path, &actions, nil, argumentPointers, environmentPointers)
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
        var stdoutOpen = true
        var stderrOpen = true
        var childExited = false
        var status: Int32 = 0
        var exitSeenAt: Date?

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let maxCapture = 32 * 1024 * 1024

        while true {
            if Date() >= deadline {
                Darwin.kill(pid, SIGKILL)
                var waitStatus: Int32 = 0
                waitpid(pid, &waitStatus, 0)
                throw CommandTimeoutError(seconds: timeout)
            }

            var descriptors = [
                pollfd(fd: stdoutOpen ? stdoutPipe[0] : -1, events: Int16(POLLIN | POLLHUP), revents: 0),
                pollfd(fd: stderrOpen ? stderrPipe[0] : -1, events: Int16(POLLIN | POLLHUP), revents: 0),
            ]
            let ready = poll(&descriptors, 2, 40)

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
                            if stdout.count < maxCapture { stdout.append(chunk) }
                        } else {
                            if stderr.count < maxCapture { stderr.append(chunk) }
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

            if !childExited {
                var waitStatus: Int32 = 0
                let waitResult = waitpid(pid, &waitStatus, WNOHANG)
                if waitResult == pid {
                    childExited = true
                    exitSeenAt = Date()
                    status = Self.decodeExitStatus(waitStatus)
                } else if waitResult < 0 {
                    childExited = true
                    status = -1
                    exitSeenAt = Date()
                }
            }

            if childExited {
                if !stdoutOpen && !stderrOpen { break }
                if let exitSeenAt, Date().timeIntervalSince(exitSeenAt) > 2 {
                    if stdoutOpen { close(stdoutPipe[0]); stdoutOpen = false }
                    if stderrOpen { close(stderrPipe[0]); stderrOpen = false }
                    break
                }
            }
        }

        if !childExited {
            var waitStatus: Int32 = 0
            waitpid(pid, &waitStatus, 0)
            status = Self.decodeExitStatus(waitStatus)
        }

        return CommandResult(
            status: status,
            stdout: stdout,
            stderr: stderr,
            duration: Date().timeIntervalSince(startedAt)
        )
    }
}

public final class RepositoryLock: @unchecked Sendable {
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
                throw CodeTimeError.repositoryUnavailable("仓库正在被另一个备份任务使用")
            }
            usleep(200_000)
        }
    }

    @discardableResult
    public func tryAcquire() -> Bool {
        let fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard fd >= 0 else { return false }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            descriptor = fd
            let pid = "\(getpid())\n"
            _ = ftruncate(fd, 0)
            _ = pid.withCString { pointer in
                write(fd, pointer, strlen(pointer))
            }
            return true
        }
        close(fd)
        return false
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
