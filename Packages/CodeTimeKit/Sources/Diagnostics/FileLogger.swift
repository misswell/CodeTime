import Foundation
import SharedModels

public actor FileLogger {
    public let fileURL: URL
    private let maxBytes: Int64
    private let maxArchives: Int
    private let maxAge: TimeInterval
    private let fileManager = FileManager.default

    public init(
        fileURL: URL,
        maxBytes: Int64 = 5 * 1024 * 1024,
        maxArchives: Int = 5,
        maxAge: TimeInterval = 30 * 86_400
    ) {
        self.fileURL = fileURL
        self.maxBytes = max(256 * 1024, maxBytes)
        self.maxArchives = max(1, maxArchives)
        self.maxAge = maxAge
    }

    public func info(_ message: String) {
        write("INFO", message)
    }

    public func warning(_ message: String) {
        write("WARN", message)
    }

    public func error(_ message: String) {
        write("ERROR", message)
    }

    private func write(_ level: String, _ message: String) {
        let line = "[\(CodeTimeDateCoding.string(from: Date()))] [\(level)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateIfNeeded()
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func rotateIfNeeded() {
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? Int64, size > maxBytes else { return }
        let base = fileURL.deletingPathExtension()
        // Two rotations can happen within the same second; a unique archive name
        // keeps the move from failing and leaving the current file unbounded.
        var stamp = Int(Date().timeIntervalSince1970 * 1_000)
        var archive = base.appendingPathExtension("\(stamp).log")
        while fileManager.fileExists(atPath: archive.path) {
            stamp += 1
            archive = base.appendingPathExtension("\(stamp).log")
        }
        guard (try? fileManager.moveItem(at: fileURL, to: archive)) != nil else { return }
        pruneArchives()
    }

    /// Rotation is bounded by count and age; otherwise a long-running install
    /// would grow logs without limit even though each file is capped.
    private func pruneArchives() {
        let directory = fileURL.deletingLastPathComponent()
        let stem = fileURL.deletingPathExtension().lastPathComponent
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var archives = entries.filter { url in
            url.lastPathComponent.hasPrefix(stem + ".") && url.pathExtension == "log"
        }
        archives.sort { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l > r
        }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for (index, archive) in archives.enumerated() {
            let modified = (try? archive.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if index >= maxArchives || modified < cutoff {
                try? fileManager.removeItem(at: archive)
            }
        }
    }
}

public enum DiagnosticsCheck: String, CaseIterable, Sendable {
    case repository
    case database
    case cloud
    case keychain
    case diskSpace

    public var displayName: String {
        switch self {
        case .repository: return "备份仓库"
        case .database: return "任务数据库"
        case .cloud: return "云端镜像"
        case .keychain: return "密钥与恢复凭据"
        case .diskSpace: return "磁盘空间"
        }
    }
}

public struct DiagnosticsReport: Sendable {
    public var checks: [(name: String, passed: Bool, detail: String)]

    public init(checks: [(name: String, passed: Bool, detail: String)] = []) {
        self.checks = checks
    }

    public var allPassed: Bool { checks.allSatisfy(\.passed) }
}
