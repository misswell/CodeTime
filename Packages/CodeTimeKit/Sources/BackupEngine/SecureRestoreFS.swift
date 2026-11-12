import Foundation
import Darwin

/// Directory-FD based filesystem access for restore.
///
/// Restore must not re-open `staging/<relative-path>` through ordinary absolute
/// paths after the initial check: a parent directory can be swapped for a
/// symlink between `lstat` and `open`. Every operation here starts from the
/// staging root descriptor and walks components with
/// `openat(..., O_NOFOLLOW | O_DIRECTORY)`, so the checked directory is the
/// directory actually used for the write.
final class RestoreDirectoryFS: @unchecked Sendable {
    let rootURL: URL
    private let rootFD: Int32

    init(rootURL: URL) throws {
        self.rootURL = rootURL
        let fd = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw CloudRestoreError.invalidPath("无法打开安全恢复目录：\(rootURL.path)")
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            close(fd)
            throw CloudRestoreError.invalidPath("安全恢复根不是目录：\(rootURL.path)")
        }
        self.rootFD = fd
    }

    deinit { close(rootFD) }

    private func components(_ relative: String) throws -> [String] {
        guard !relative.isEmpty else { return [] }
        guard !relative.hasPrefix("/") else {
            throw CloudRestoreError.invalidPath(relative)
        }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CloudRestoreError.invalidPath(relative)
        }
        return parts
    }

    private func openComponent(_ fd: Int32, _ component: String) -> Int32 {
        component.withCString {
            openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
    }

    /// Opens (and optionally creates) the directory containing `relative`.
    private func parentFD(for relative: String, create: Bool) throws -> (fd: Int32, name: String) {
        let parts = try components(relative)
        guard let name = parts.last else {
            throw CloudRestoreError.invalidPath(relative)
        }
        var current = dup(rootFD)
        guard current >= 0 else {
            throw CloudRestoreError.invalidPath("无法复制恢复目录 FD")
        }
        for component in parts.dropLast() {
            var next = openComponent(current, component)
            if next < 0, errno == ENOENT, create {
                let made = component.withCString { mkdirat(current, $0, 0o700) }
                if made != 0, errno != EEXIST {
                    close(current)
                    throw CloudRestoreError.invalidPath("无法创建恢复子目录：\(component)")
                }
                next = openComponent(current, component)
            }
            guard next >= 0 else {
                close(current)
                throw CloudRestoreError.invalidPath("恢复子目录不安全或不可访问：\(component)")
            }
            close(current)
            current = next
        }
        return (current, name)
    }

    func ensureDirectory(_ relative: String) throws {
        let parts = try components(relative)
        guard !parts.isEmpty else { return }
        var current = dup(rootFD)
        guard current >= 0 else {
            throw CloudRestoreError.invalidPath("无法复制恢复目录 FD")
        }
        for component in parts {
            var next = openComponent(current, component)
            if next < 0, errno == ENOENT {
                let made = component.withCString { mkdirat(current, $0, 0o700) }
                if made != 0, errno != EEXIST {
                    close(current)
                    throw CloudRestoreError.invalidPath("无法创建恢复目录：\(relative)")
                }
                next = openComponent(current, component)
            }
            guard next >= 0 else {
                close(current)
                throw CloudRestoreError.invalidPath("恢复目录链不安全：\(relative)")
            }
            close(current)
            current = next
        }
        close(current)
    }

    func openFile(_ relative: String, flags: Int32, mode: mode_t = 0o600) throws -> Int32 {
        let parent = try parentFD(for: relative, create: true)
        defer { close(parent.fd) }
        let fd = parent.name.withCString {
            openat(parent.fd, $0, flags | O_NOFOLLOW | O_CLOEXEC, mode)
        }
        guard fd >= 0 else {
            throw CloudRestoreError.invalidPath("无法安全打开恢复文件：\(relative)")
        }
        return fd
    }

    func readFile(_ relative: String) throws -> Data? {
        let parts = try components(relative)
        guard let name = parts.last else { return nil }
        let parent = try parentFD(for: relative, create: false)
        defer { close(parent.fd) }
        let fd = name.withCString {
            openat(parent.fd, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw CloudRestoreError.invalidPath("无法安全读取恢复文件：\(relative)")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        return try handle.readToEnd()
    }

    func fileSize(_ relative: String) -> Int64? {
        guard let parts = try? components(relative), let name = parts.last,
              let parent = try? parentFD(for: relative, create: false) else { return nil }
        defer { close(parent.fd) }
        var info = stat()
        let result = name.withCString {
            fstatat(parent.fd, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return info.st_size
    }

    func createSymlink(target: String, at relative: String) throws {
        let parent = try parentFD(for: relative, create: true)
        defer { close(parent.fd) }
        let result = target.withCString { targetPtr in
            parent.name.withCString { namePtr in
                symlinkat(targetPtr, parent.fd, namePtr)
            }
        }
        guard result == 0 else {
            throw CloudRestoreError.invalidPath("无法创建恢复符号链接：\(relative)")
        }
    }

    func readSymlink(_ relative: String) throws -> String? {
        guard let parts = try? components(relative), let name = parts.last,
              let parent = try? parentFD(for: relative, create: false) else { return nil }
        defer { close(parent.fd) }
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = name.withCString {
            readlinkat(parent.fd, $0, &buffer, buffer.count - 1)
        }
        guard count >= 0 else {
            if errno == ENOENT { return nil }
            return nil
        }
        buffer[count] = 0
        return String(cString: buffer)
    }

    func exists(_ relative: String) -> Bool {
        guard let parts = try? components(relative), let name = parts.last,
              let parent = try? parentFD(for: relative, create: false) else { return false }
        defer { close(parent.fd) }
        var info = stat()
        return name.withCString {
            fstatat(parent.fd, $0, &info, AT_SYMLINK_NOFOLLOW)
        } == 0
    }

    func remove(_ relative: String) throws {
        let parent = try parentFD(for: relative, create: false)
        defer { close(parent.fd) }
        let result = parent.name.withCString { unlinkat(parent.fd, $0, 0) }
        if result != 0, errno != ENOENT {
            throw CloudRestoreError.invalidPath("无法删除恢复文件：\(relative)")
        }
    }

    func rename(_ from: String, to: String) throws {
        guard let fromParts = try? components(from), let fromName = fromParts.last,
              let toParts = try? components(to), let toName = toParts.last,
              Array(fromParts.dropLast()) == Array(toParts.dropLast()) else {
            throw CloudRestoreError.invalidPath("恢复临时文件与目标不在同一目录")
        }
        let parent = try parentFD(for: from, create: false)
        defer { close(parent.fd) }
        let result = fromName.withCString { fromPtr in
            toName.withCString { toPtr in
                renameat(parent.fd, fromPtr, parent.fd, toPtr)
            }
        }
        guard result == 0 else {
            throw CloudRestoreError.invalidPath("无法原子提交恢复文件：\(to)")
        }
    }

    /// Applies POSIX mode and mtime through a descriptor, never a fresh absolute
    /// path lookup.
    func applyMetadata(_ relative: String, mode: UInt16?, modifiedAt: Date?) throws {
        let target: Int32
        if relative.isEmpty {
            target = dup(rootFD)
            guard target >= 0 else {
                throw CloudRestoreError.invalidPath("无法复制恢复根目录 FD")
            }
        } else {
            let parent = try parentFD(for: relative, create: false)
            defer { close(parent.fd) }
            target = parent.name.withCString {
                openat(parent.fd, $0, O_RDONLY | O_NOFOLLOW)
            }
            guard target >= 0 else {
                throw CloudRestoreError.invalidPath("无法打开恢复元数据目标：\(relative)")
            }
        }
        defer { close(target) }
        if let mode {
            guard fchmod(target, mode_t(mode)) == 0 else {
                throw CloudRestoreError.invalidPath("无法恢复权限：\(relative)")
            }
        }
        if let modifiedAt {
            var times = [
                timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                timespec(
                    tv_sec: Int(modifiedAt.timeIntervalSince1970),
                    tv_nsec: Int((modifiedAt.timeIntervalSince1970 - floor(modifiedAt.timeIntervalSince1970)) * 1_000_000_000)
                ),
            ]
            guard futimens(target, &times) == 0 else {
                throw CloudRestoreError.invalidPath("无法恢复修改时间：\(relative)")
            }
        }
    }
}
