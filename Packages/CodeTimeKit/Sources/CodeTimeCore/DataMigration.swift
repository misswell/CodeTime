import Foundation
import SharedModels
import CodeTimeSecurity

/// One-time import of a v1.0.0-beta.1 data directory (database, local Kopia
/// repository, recovery copies) into the current App Support location.
///
/// The migration never deletes or rewrites the source directory. Everything is
/// copied into a staging directory, verified byte-for-byte, and only then moved
/// into place, so an interrupted migration leaves both the source and the target
/// usable and can be retried.
public struct MigrationPlan: Sendable, Equatable {
    public var sourceRoot: URL
    public var targetRoot: URL
    public var hasDatabase: Bool
    public var repositoryCount: Int
    public var fileCount: Int
    public var totalBytes: Int64
    public var conflicts: [String]

    public init(
        sourceRoot: URL,
        targetRoot: URL,
        hasDatabase: Bool,
        repositoryCount: Int,
        fileCount: Int,
        totalBytes: Int64,
        conflicts: [String]
    ) {
        self.sourceRoot = sourceRoot
        self.targetRoot = targetRoot
        self.hasDatabase = hasDatabase
        self.repositoryCount = repositoryCount
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.conflicts = conflicts
    }

    public var isSafeToProceed: Bool { conflicts.isEmpty && fileCount > 0 }
}

public struct MigrationResult: Sendable, Equatable {
    public var jobID: UUID
    public var fileCount: Int
    public var totalBytes: Int64
    public var migratedAt: Date
    public var sourceRoot: URL
}

public enum MigrationError: LocalizedError {
    case sourceUnreadable(String)
    case nothingToMigrate
    case targetNotEmpty(String)
    case verificationFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .sourceUnreadable(let detail): return "无法读取旧版数据目录：\(detail)"
        case .nothingToMigrate: return "所选目录不是 CodeTime 数据目录（缺少数据库与仓库）"
        case .targetNotEmpty(let detail): return "当前数据目录已有内容，拒绝合并：\(detail)"
        case .verificationFailed(let detail): return "迁移校验失败，已保留旧数据：\(detail)"
        case .cancelled: return "迁移已取消"
        }
    }
}

public enum DataMigrator {
    public static let journalName = "migration-journal.json"
    public static let completionName = "migration-complete.json"
    public static let requestName = "migration-request.json"

    private struct Request: Codable {
        var sourcePath: String
        var sourceBookmark: Data
        var createdAt: Date
    }

    private struct Journal: Codable {
        var jobID: UUID
        var state: String
        var sourceRoot: String
        var stagingPath: String
        var startedAt: Date
        var updatedAt: Date
        var message: String?
    }

    private struct Completion: Codable {
        var jobID: UUID
        var sourceRoot: String
        var migratedAt: Date
        var fileCount: Int
        var totalBytes: Int64
    }

    public static func inspect(source: URL, target: URL) throws -> MigrationPlan {
        let fileManager = FileManager.default
        let source = source.standardizedFileURL
        let target = target.standardizedFileURL
        guard fileManager.fileExists(atPath: source.path) else {
            throw MigrationError.sourceUnreadable("目录不存在")
        }
        let database = source.appendingPathComponent("database/codetime.sqlite")
        let repositories = source.appendingPathComponent("repositories", isDirectory: true)
        let hasDatabase = fileManager.fileExists(atPath: database.path)
        let repositoryCount: Int
        if fileManager.fileExists(atPath: repositories.path) {
            do {
                let entries = try fileManager.contentsOfDirectory(atPath: repositories.path)
                repositoryCount = entries.filter { !$0.hasPrefix(".") }.count
            } catch {
                throw MigrationError.sourceUnreadable("无法读取备份仓库目录：\(error.localizedDescription)")
            }
        } else {
            repositoryCount = 0
        }
        guard hasDatabase || repositoryCount > 0 else {
            throw MigrationError.nothingToMigrate
        }

        var conflicts: [String] = []
        let targetDatabase = target.appendingPathComponent("database/codetime.sqlite")
        if fileManager.fileExists(atPath: targetDatabase.path) {
            conflicts.append("当前目录已有数据库")
        }
        let targetRepositories = target.appendingPathComponent("repositories")
        if fileManager.fileExists(atPath: targetRepositories.path) {
            do {
                let targetRepos = try fileManager.contentsOfDirectory(atPath: targetRepositories.path)
                if targetRepos.contains(where: { !$0.hasPrefix(".") }) {
                    conflicts.append("当前目录已有备份仓库")
                }
            } catch {
                throw MigrationError.targetNotEmpty("无法读取当前备份仓库目录：\(error.localizedDescription)")
            }
        }

        var fileCount = 0
        var totalBytes: Int64 = 0
        if let enumerator = fileManager.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            while let url = enumerator.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }
                fileCount += 1
                totalBytes += Int64(values?.fileSize ?? 0)
            }
        }

        return MigrationPlan(
            sourceRoot: source,
            targetRoot: target,
            hasDatabase: hasDatabase,
            repositoryCount: repositoryCount,
            fileCount: fileCount,
            totalBytes: totalBytes,
            conflicts: conflicts
        )
    }

    /// Copies `source` into `target` through a staging directory. Returns only
    /// after every file has been re-read from staging and hashed successfully.
    @discardableResult
    public static func migrate(
        source: URL,
        target: URL,
        jobID: UUID = UUID(),
        isCancelled: () -> Bool = { false },
        progress: (Double) -> Void = { _ in }
    ) throws -> MigrationResult {
        let plan = try inspect(source: source, target: target)
        guard plan.conflicts.isEmpty else {
            throw MigrationError.targetNotEmpty(plan.conflicts.joined(separator: "；"))
        }
        guard plan.isSafeToProceed else {
            throw MigrationError.nothingToMigrate
        }

        let fileManager = FileManager.default
        let target = plan.targetRoot
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".codetime-migration-\(jobID.uuidString.prefix(8))", isDirectory: true)
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        var journal = Journal(
            jobID: jobID,
            state: "copying",
            sourceRoot: plan.sourceRoot.path,
            stagingPath: staging.path,
            startedAt: Date(),
            updatedAt: Date(),
            message: nil
        )
        try write(journal, to: target.appendingPathComponent(journalName))

        do {
            let files = try regularFiles(under: plan.sourceRoot)
            var copied: [String: Int64] = [:]
            for (index, file) in files.enumerated() {
                if isCancelled() { throw MigrationError.cancelled }
                let relative = relativePath(file, root: plan.sourceRoot)
                let destination = staging.appendingPathComponent(relative)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: file, to: destination)
                let values = try destination.resourceValues(forKeys: [.fileSizeKey])
                copied[relative] = Int64(values.fileSize ?? 0)
                progress(Double(index + 1) / Double(max(1, files.count)) * 0.9)
            }

            journal.state = "verifying"
            journal.updatedAt = Date()
            try write(journal, to: target.appendingPathComponent(journalName))

            for (index, file) in files.enumerated() {
                if isCancelled() { throw MigrationError.cancelled }
                let relative = relativePath(file, root: plan.sourceRoot)
                guard let expectedSize = copied[relative] else {
                    throw MigrationError.verificationFailed("缺少文件 \(relative)")
                }
                let staged = staging.appendingPathComponent(relative)
                let size = (try? staged.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                guard Int64(size) == expectedSize else {
                    throw MigrationError.verificationFailed("大小不一致：\(relative)")
                }
                let sourceHash = try Hashing.sha256Hex(fileURL: file)
                let stagedHash = try Hashing.sha256Hex(fileURL: staged)
                guard sourceHash == stagedHash else {
                    throw MigrationError.verificationFailed("内容不一致：\(relative)")
                }
                progress(0.9 + Double(index + 1) / Double(max(1, files.count)) * 0.1)
            }

            journal.state = "installing"
            journal.updatedAt = Date()
            try write(journal, to: target.appendingPathComponent(journalName))

            // Move children rather than the directory itself: the target already
            // holds the journal file and may hold unrelated user files.
            for child in try fileManager.contentsOfDirectory(atPath: staging.path) {
                let from = staging.appendingPathComponent(child)
                let to = target.appendingPathComponent(child)
                guard !fileManager.fileExists(atPath: to.path) else {
                    throw MigrationError.targetNotEmpty("安装阶段发现冲突：\(child)")
                }
                try fileManager.moveItem(at: from, to: to)
            }
            try? fileManager.removeItem(at: staging)

            let completion = Completion(
                jobID: jobID,
                sourceRoot: plan.sourceRoot.path,
                migratedAt: Date(),
                fileCount: plan.fileCount,
                totalBytes: plan.totalBytes
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(completion).write(to: target.appendingPathComponent(completionName), options: .atomic)
            try? fileManager.removeItem(at: target.appendingPathComponent(journalName))
            progress(1)

            return MigrationResult(
                jobID: jobID,
                fileCount: plan.fileCount,
                totalBytes: plan.totalBytes,
                migratedAt: completion.migratedAt,
                sourceRoot: plan.sourceRoot
            )
        } catch {
            journal.state = "failed"
            journal.updatedAt = Date()
            journal.message = error.localizedDescription
            try? write(journal, to: target.appendingPathComponent(journalName))
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    /// A previous run left staging data behind; remove it so a retry starts clean.
    public static func clearInterruptedStaging(target: URL) {
        let fileName = target.appendingPathComponent(journalName)
        guard let data = try? Data(contentsOf: fileName),
              let journal = try? JSONDecoder().decode(Journal.self, from: data) else { return }
        if journal.state != "installing" {
            try? FileManager.default.removeItem(atPath: journal.stagingPath)
        }
    }

    // MARK: - Deferred migration (runs before the database is opened)

    /// Records a migration request. The actual copy happens on the next launch,
    /// before `CodeTimeService` opens SQLite, because replacing a database under
    /// an open connection is never safe.
    public static func requestMigration(source: URL, target: URL) throws {
        let bookmark = try SecurityScopedBookmarks.makeBookmark(for: source)
        let request = Request(sourcePath: source.path, sourceBookmark: bookmark, createdAt: Date())
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(request).write(
            to: target.appendingPathComponent(requestName),
            options: .atomic
        )
    }

    public static func hasPendingRequest(target: URL) -> Bool {
        FileManager.default.fileExists(atPath: target.appendingPathComponent(requestName).path)
    }

    /// Executes a pending request. A non-empty target database is moved aside to a
    /// timestamped directory rather than deleted; the migration then installs the
    /// old data and removes the request only after full verification.
    public static func performPending(target: URL) throws -> MigrationResult? {
        let requestURL = target.appendingPathComponent(requestName)
        guard FileManager.default.fileExists(atPath: requestURL.path) else { return nil }
        guard let data = try? Data(contentsOf: requestURL),
              let request = try? JSONDecoder().decode(Request.self, from: data) else {
            throw MigrationError.sourceUnreadable("迁移请求文件损坏")
        }
        let resolved = try SecurityScopedBookmarks.resolve(request.sourceBookmark)
        let access = SecurityScopedAccess(url: resolved.url)
        defer { access.stop() }

        clearInterruptedStaging(target: target)

        let databaseDirectory = target.appendingPathComponent("database", isDirectory: true)
        if FileManager.default.fileExists(atPath: databaseDirectory.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = target.appendingPathComponent("database.pre-migration-\(stamp)", isDirectory: true)
            try FileManager.default.moveItem(at: databaseDirectory, to: backup)
        }

        let result = try migrate(source: resolved.url, target: target)
        try? FileManager.default.removeItem(at: requestURL)
        return result
    }

    private static func regularFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw MigrationError.sourceUnreadable(root.path)
        }
        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true, values.isSymbolicLink != true {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func write(_ journal: Journal, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: url, options: .atomic)
    }
}
