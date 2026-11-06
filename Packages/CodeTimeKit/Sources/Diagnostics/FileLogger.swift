import Foundation
import SharedModels

public actor FileLogger {
    public let fileURL: URL
    private let maxBytes: Int64
    private let fileManager = FileManager.default

    public init(fileURL: URL, maxBytes: Int64 = 5 * 1024 * 1024) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
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
        let archive = fileURL.deletingPathExtension()
            .appendingPathExtension("\(Int(Date().timeIntervalSince1970)).log")
        try? fileManager.moveItem(at: fileURL, to: archive)
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
