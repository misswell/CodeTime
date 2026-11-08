import Foundation
import Darwin
import CSQLite
import SharedModels
import CodeTimeSecurity
import BackupEngine

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

    /// CT-098 test hook: when set to a phase name, the process SIGKILLs itself
    /// at that migration phase — a real process death, not an in-process
    /// simulation. Production always leaves it nil.
    /// Phases: before-copy, during-copy, after-verify, before-replace,
    /// after-replace, after-complete.
    public nonisolated(unsafe) static var crashPointForTesting: String?

    static func maybeCrash(at point: String) {
        guard crashPointForTesting == point else { return }
        kill(ProcessInfo.processInfo.processIdentifier, SIGKILL)
    }

    private struct Request: Codable {
        /// CT-109: unique per user-initiated migration. A completed request never
        /// blocks a NEW request from the same source directory.
        var id: UUID?
        var sourcePath: String
        var sourceBookmark: Data
        var createdAt: Date
        /// New requests explicitly allow replacing the freshly initialized Release
        /// data root. Old requests default to false and never overwrite it.
        var allowReplaceRoot: Bool?
    }

    private struct Journal: Codable {
        var jobID: UUID
        var state: String
        var sourceRoot: String
        var stagingPath: String
        var startedAt: Date
        var updatedAt: Date
        var message: String?
        var targetPath: String?
        var backupPath: String?
    }

    private struct Completion: Codable {
        var jobID: UUID
        /// CT-109: the request this completion answers.
        var requestID: UUID?
        var sourceRoot: String
        var targetRoot: String?
        var migratedAt: Date
        var fileCount: Int
        var totalBytes: Int64
    }

    public static func inspect(
        source: URL,
        target: URL,
        ignoreTargetConflicts: Bool = false
    ) throws -> MigrationPlan {
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
        if !ignoreTargetConflicts {
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
        }

        // Use the same enumerator as the copy phase so hidden files are counted
        // consistently and symlinks are not reported as copied bytes.
        let files = try regularFiles(under: source).filter {
            let relative = relativePath($0, root: source)
            return relative != "database/codetime.sqlite-wal"
                && relative != "database/codetime.sqlite-shm"
        }
        var totalBytes: Int64 = 0
        for file in files {
            let values = try file.resourceValues(forKeys: [.fileSizeKey])
            totalBytes += Int64(values.fileSize ?? 0)
        }
        let fileCount = files.count

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
        requestID: UUID? = nil,
        replaceRoot: Bool = false,
        isCancelled: () -> Bool = { false },
        progress: (Double) -> Void = { _ in }
    ) throws -> MigrationResult {
        let plan = try inspect(source: source, target: target, ignoreTargetConflicts: replaceRoot)
        guard plan.conflicts.isEmpty else {
            throw MigrationError.targetNotEmpty(plan.conflicts.joined(separator: "；"))
        }
        guard plan.isSafeToProceed else {
            throw MigrationError.nothingToMigrate
        }

        let fileManager = FileManager.default
        let target = plan.targetRoot
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        let lifecycleDir = target.deletingLastPathComponent()
            .appendingPathComponent(".codetime-lifecycle", isDirectory: true)
        try fileManager.createDirectory(at: lifecycleDir, withIntermediateDirectories: true)
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
try write(journal, to: lifecycleDir.appendingPathComponent(journalName))
        maybeCrash(at: "before-copy")

        do {
            let files = try regularFiles(under: plan.sourceRoot)
            var copied: [String: Int64] = [:]
            var copiedCount = 0
            for (index, file) in files.enumerated() {
                if isCancelled() { throw MigrationError.cancelled }
                let relative = relativePath(file, root: plan.sourceRoot)
                if relative == "database/codetime.sqlite-wal"
                    || relative == "database/codetime.sqlite-shm" {
                    // SQLite backup below captures a consistent snapshot including
                    // the WAL. Copying sidecars separately would corrupt it.
                    continue
                }
                let destination = staging.appendingPathComponent(relative)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if relative == "database/codetime.sqlite" {
                    try copySQLiteDatabase(from: file, to: destination)
                } else {
                    try fileManager.copyItem(at: file, to: destination)
                }
                maybeCrash(at: "during-copy")
                let values = try destination.resourceValues(forKeys: [.fileSizeKey])
                copied[relative] = Int64(values.fileSize ?? 0)
                copiedCount += 1
                progress(Double(index + 1) / Double(max(1, files.count)) * 0.9)
            }

            journal.state = "verifying"
            journal.updatedAt = Date()
    try write(journal, to: lifecycleDir.appendingPathComponent(journalName))

            for (index, file) in files.enumerated() {
                if isCancelled() { throw MigrationError.cancelled }
                let relative = relativePath(file, root: plan.sourceRoot)
                if relative == "database/codetime.sqlite-wal"
                    || relative == "database/codetime.sqlite-shm" {
                    continue
                }
                guard let expectedSize = copied[relative] else {
                    throw MigrationError.verificationFailed("缺少文件 \(relative)")
                }
                let staged = staging.appendingPathComponent(relative)
                let size = (try? staged.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                guard Int64(size) == expectedSize else {
                    throw MigrationError.verificationFailed("大小不一致：\(relative)")
                }
                if relative == "database/codetime.sqlite" {
                    try verifySQLiteDatabase(at: staged)
                } else {
                    let sourceHash = try Hashing.sha256Hex(fileURL: file)
                    let stagedHash = try Hashing.sha256Hex(fileURL: staged)
                    guard sourceHash == stagedHash else {
                        throw MigrationError.verificationFailed("内容不一致：\(relative)")
                    }
                }
                progress(0.9 + Double(index + 1) / Double(max(1, files.count)) * 0.1)
            }
            maybeCrash(at: "after-verify")

            journal.state = "installing"
            journal.updatedAt = Date()
            journal.targetPath = target.path
    try write(journal, to: lifecycleDir.appendingPathComponent(journalName))
            progress(0.95)
            maybeCrash(at: "before-replace")

            if replaceRoot {
                let targetExists = fileManager.fileExists(atPath: target.path)
                if targetExists {
                    let backupName = "CodeTime.pre-migration-\(Int(Date().timeIntervalSince1970))"
                    // A single filesystem replace keeps the target either wholly old
                    // or wholly new; the previous target is retained as a backup.
                    _ = try fileManager.replaceItemAt(
                        target,
                        withItemAt: staging,
                        backupItemName: backupName,
                        options: []
                    )
                } else {
                    try fileManager.moveItem(at: staging, to: target)
                }
            } else {
                // Legacy merge mode: only used for an empty target. Move children
                // rather than deleting the target directory.
                for child in try fileManager.contentsOfDirectory(atPath: staging.path) {
                    let from = staging.appendingPathComponent(child)
                    let to = target.appendingPathComponent(child)
                    guard !fileManager.fileExists(atPath: to.path) else {
                        throw MigrationError.targetNotEmpty("安装阶段发现冲突：\(child)")
                    }
                    try fileManager.moveItem(at: from, to: to)
                }
                try? fileManager.removeItem(at: staging)
            }
            maybeCrash(at: "after-replace")

            let completion = Completion(
                jobID: jobID,
                requestID: requestID,
                sourceRoot: plan.sourceRoot.path,
                targetRoot: target.path,
                migratedAt: Date(),
                fileCount: copiedCount,
                totalBytes: plan.totalBytes
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(completion).write(to: target.appendingPathComponent(completionName), options: .atomic)
            // CT-090: the authoritative completion record lives in the lifecycle
            // directory, OUTSIDE the replaceable data root, so a later root swap
            // cannot erase the idempotency guard.
            try encoder.encode(completion).write(
                to: lifecycleDir.appendingPathComponent(completionName), options: .atomic
            )
            journal.state = "completed"
            journal.updatedAt = Date()
            try write(journal, to: lifecycleDir.appendingPathComponent(journalName))
            try? fileManager.removeItem(at: target.appendingPathComponent(journalName))
            progress(1)

            return MigrationResult(
                jobID: jobID,
                fileCount: copiedCount,
                totalBytes: plan.totalBytes,
                migratedAt: completion.migratedAt,
                sourceRoot: plan.sourceRoot
            )
        } catch {
            journal.state = "failed"
            journal.updatedAt = Date()
            journal.message = error.localizedDescription
            // Both locations: the lifecycle copy survives a whole-root swap that
            // may already have happened, the in-target copy keeps diagnostics
            // next to the data.
            try? write(journal, to: lifecycleDir.appendingPathComponent(journalName))
            try? write(journal, to: target.appendingPathComponent(journalName))
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    /// A previous run left staging data behind; remove it so a retry starts clean.
    /// Expected staging directory for a migration job. The name is derived ONLY
    /// from the job ID; a persisted path is never trusted on its own.
    public static func expectedStagingURL(target: URL, jobID: UUID) -> URL {
        target.deletingLastPathComponent()
            .appendingPathComponent(".codetime-migration-\(jobID.uuidString.prefix(8))", isDirectory: true)
    }

    /// CT-106: a journal's `stagingPath` is untrusted input. Only the exact
    /// derived directory — direct child of the target's parent, matching
    /// `.codetime-migration-<jobID8>`, not a symlink — may ever be deleted.
    /// Anything else is preserved for manual inspection (and reported).
    private static func validatedStagingURL(journal: Journal, target: URL) -> URL? {
        let expected = expectedStagingURL(target: target, jobID: journal.jobID).path
        let persisted = URL(fileURLWithPath: journal.stagingPath).standardizedFileURL.path
        guard persisted == URL(fileURLWithPath: expected).standardizedFileURL.path else {
            return nil
        }
        do {
            try SafePath.assertRealDirectoryNotSymlink(expected)
        } catch {
            return nil
        }
        return URL(fileURLWithPath: expected, isDirectory: true)
    }

    public static func clearInterruptedStaging(target: URL) {
        // The journal may be in the target or the lifecycle dir (which survives
        // whole-root replacement). Check both locations.
        var fileName = target.appendingPathComponent(journalName)
        let lifecycleDir = target.deletingLastPathComponent()
            .appendingPathComponent(".codetime-lifecycle", isDirectory: true)
        let lifecycleJournal = lifecycleDir.appendingPathComponent(journalName)
        if !FileManager.default.fileExists(atPath: fileName.path),
           FileManager.default.fileExists(atPath: lifecycleJournal.path) {
            fileName = lifecycleJournal
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileName),
              let journal = try? decoder.decode(Journal.self, from: data) else { return }
        // CT-106: never delete an unvalidated path. A tampered/corrupt journal
        // keeps the directory for manual handling.
        guard let staging = validatedStagingURL(journal: journal, target: target) else {
            return
        }
        if journal.state == "installing" {
            // Whole-root replacement is a single rename. If the target still
            // exists, the prepared staging directory is safe to reclaim; if the
            // target is gone, keep it for manual recovery instead of deleting
            // the only prepared copy.
            guard FileManager.default.fileExists(atPath: target.path) else { return }
            try? FileManager.default.removeItem(at: staging)
            return
        }
        try? FileManager.default.removeItem(at: staging)
    }

    // MARK: - Deferred migration (runs before the database is opened)

    /// Records a migration request. The actual copy happens on the next launch,
    /// before `CodeTimeService` opens SQLite, because replacing a database under
    /// an open connection is never safe.
    public static func requestMigration(
        source: URL,
        target: URL,
        allowReplaceRoot: Bool = false
    ) throws {
        let bookmark = try SecurityScopedBookmarks.makeBookmark(for: source)
        let request = Request(
            id: UUID(),
            sourcePath: source.path,
            sourceBookmark: bookmark,
            createdAt: Date(),
            allowReplaceRoot: allowReplaceRoot
        )
        // The request file lives in the lifecycle directory, NOT inside the
        // replaceable target, so it survives a whole-root swap.
        let lifecycleDir = target.deletingLastPathComponent()
            .appendingPathComponent(".codetime-lifecycle", isDirectory: true)
        try FileManager.default.createDirectory(at: lifecycleDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(request).write(
            to: lifecycleDir.appendingPathComponent(requestName),
            options: .atomic
        )
    }

    public static func hasPendingRequest(target: URL) -> Bool {
        FileManager.default.fileExists(atPath: target.deletingLastPathComponent()
            .appendingPathComponent(".codetime-lifecycle", isDirectory: true)
            .appendingPathComponent(requestName).path)
    }

    /// CT-109: a completion answers THIS request only when the request IDs match
    /// (new format) or, for legacy records without an ID, when source and target
    /// both match. A new request from the same source therefore runs again.
    private static func completionAlreadyAnswers(
        completion: Completion, request: Request, source: URL, target: URL
    ) -> Bool {
        guard let completionTarget = completion.targetRoot else {
            // Legacy completion: no target recorded.
            return false
        }
        guard URL(fileURLWithPath: completionTarget).standardizedFileURL == target.standardizedFileURL else {
            return false
        }
        if let completionID = completion.requestID, let requestID = request.id {
            return completionID == requestID
        }
        // Legacy: same source directory counts as "answered" only when the
        // completion has no request ID (pre-CT-109 records).
        return completion.requestID == nil
            && URL(fileURLWithPath: completion.sourceRoot).standardizedFileURL
                == source.standardizedFileURL
    }

    /// CT-085: how long the migration waits for a live source agent to exit after
    /// seeing the stop request (a current-version agent polls every 30s). Tests
    /// may lower this; production keeps one full poll window.
    public nonisolated(unsafe) static var sourceAgentExitTimeout: TimeInterval = 45

    /// CT-085: acquires every source agent lock, waiting out the stop-request
    /// window while a LIVE agent still holds the flock. Lock state is the ground
    /// truth — a lock file's content outlives its process, so file contents are
    /// never used to decide. Acquired locks are appended to `into` and held for
    /// the whole migration. Different Beta versions kept the agent lock at the
    /// data root or in the lifecycle directory; both are checked.
    private static func acquireSourceAgentLocks(
        sourceRoot: URL, into sourceLocks: inout [RepositoryLock]
    ) throws {
        let fm = FileManager.default
        let candidates = [
            sourceRoot.appendingPathComponent("agent.lock"),
            sourceRoot.deletingLastPathComponent()
                .appendingPathComponent(".codetime-lifecycle/agent.lock"),
        ]
        for candidate in candidates {
            guard fm.fileExists(atPath: candidate.path) else { continue }
            let lock = RepositoryLock(path: candidate.path)
            if lock.tryAcquireIfPresent() {
                sourceLocks.append(lock)
                continue
            }
            // A live agent holds the flock. It received the stop request (the
            // persisted migration request file) and a current-version agent exits
            // within one 30s poll — wait for it, never a fixed assumption.
            let timeout = sourceAgentExitTimeout
            let deadline = Date().addingTimeInterval(timeout)
            var acquired = false
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 1)
                if lock.tryAcquireIfPresent() {
                    sourceLocks.append(lock)
                    acquired = true
                    break
                }
            }
            guard acquired else {
                throw MigrationError.targetNotEmpty(
                    "Beta Agent 正在被旧版 CodeTime 使用：等待 \(Int(timeout)) 秒后仍未退出，"
                        + "已取消迁移以保护数据。请退出旧版 CodeTime 后重试"
                )
            }
        }
    }

    /// Executes a pending request. A non-empty target database is moved aside to a
    /// timestamped directory rather than deleted; the migration then installs the
    /// old data and removes the request only after full verification.
    public static func performPending(target: URL) throws -> MigrationResult? {
        let lifecycleDir = target.deletingLastPathComponent()
            .appendingPathComponent(".codetime-lifecycle", isDirectory: true)
        let requestURL = lifecycleDir.appendingPathComponent(requestName)
        guard FileManager.default.fileExists(atPath: requestURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: requestURL),
              let request = try? decoder.decode(Request.self, from: data) else {
            throw MigrationError.sourceUnreadable("迁移请求文件损坏")
        }
        let resolved = try SecurityScopedBookmarks.resolve(request.sourceBookmark)
        let access = SecurityScopedAccess(url: resolved.url)
        defer { access.stop() }

        // CT-090: A completion record for the SAME source means this request has
        // already run to completion. The residual request file (e.g. deletion
        // failed after a successful migration) must never trigger a second data
        // replacement that would overwrite newer Release data.
        let completionURL = lifecycleDir.appendingPathComponent(completionName)
        if let completionData = try? Data(contentsOf: completionURL),
           let completion = try? decoder.decode(Completion.self, from: completionData),
           completionAlreadyAnswers(
               completion: completion, request: request, source: resolved.url, target: target
           ) {
            do {
                try FileManager.default.removeItem(at: requestURL)
            } catch {
                throw MigrationError.verificationFailed(
                    "该迁移已完成，但残留请求删除失败（\(error.localizedDescription)）。"
                    + "请手动删除 \(requestURL.path) 以避免重复判断。"
                )
            }
            return nil
        }

        // The source Beta app may still have an Agent, scheduler or Kopia task.
        // Acquire every existing source lock for the whole copy/switch window.
        // Declared before the exclusive lifecycle lock so the CT-085 agent
        // stop-protocol window can already hold the agent locks it wins.
        var sourceLocks: [RepositoryLock] = []
        defer { sourceLocks.forEach { $0.release() } }
        let sourceRoot = resolved.url
        guard sourceRoot.standardizedFileURL != target.standardizedFileURL else {
            throw MigrationError.targetNotEmpty("源目录与目标目录相同，无法迁移")
        }

        // CT-085 (§4.1 stop protocol): the request file doubles as the agent stop
        // signal — a current-version agent polls it and exits on its own. Here we
        // take over the agent locks; while a live agent still holds the flock we
        // wait one stop-request window. If it cannot exit, fail safe: no data is
        // ever replaced underneath a live writer.
        try acquireSourceAgentLocks(sourceRoot: sourceRoot, into: &sourceLocks)

        // CT-072: Exclusive lifecycle lock — blocks all shared holders (UI/Agent)
        // from opening the database while the migration is in progress. The lock
        // file lives outside the replaceable target directory.
        let lifecycleLock = LifecycleLock(path: lifecycleDir.appendingPathComponent("lifecycle.lock").path)
        guard lifecycleLock.tryAcquire(.exclusive) else {
            throw MigrationError.targetNotEmpty("另一个数据迁移正在进行，或 UI/Agent 仍在运行")
        }
        defer { lifecycleLock.release() }

        func lockSource(_ url: URL, label: String) throws {
            let lock = RepositoryLock(path: url.path)
            guard lock.tryAcquireIfPresent() else {
                throw MigrationError.targetNotEmpty("\(label) 正在被旧版 CodeTime 使用，请先退出旧版并重试")
            }
            sourceLocks.append(lock)
        }
        // Agent locks were already taken above (CT-085 stop-protocol window).
        try lockSource(sourceRoot.appendingPathComponent("scheduler.lock"), label: "Beta Scheduler")
        let sourceRepositories = sourceRoot.appendingPathComponent("repositories", isDirectory: true)
        if FileManager.default.fileExists(atPath: sourceRepositories.path) {
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: sourceRepositories,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: []
                )
            } catch {
                throw MigrationError.sourceUnreadable("无法读取 Beta 仓库目录：\(error.localizedDescription)")
            }
            for child in children {
                try lockSource(child.appendingPathComponent("repository.lock"), label: "Beta Kopia")
                try lockSource(child.appendingPathComponent("publish.lock"), label: "Beta publish")
            }
        }

        clearInterruptedStaging(target: target)
        let result = try migrate(
            source: resolved.url,
            target: target,
            requestID: request.id,
            replaceRoot: request.allowReplaceRoot == true
        )
        maybeCrash(at: "after-complete")
        // CT-089: Request deletion failure must not report success. If the
        // request file persists, the next startup would re-execute the migration
        // and overwrite Release data created after the first migration.
        do {
            try FileManager.default.removeItem(at: requestURL)
        } catch {
            throw MigrationError.verificationFailed(
                "迁移成功但迁移请求删除失败（\(error.localizedDescription)）。"
                + "请手动删除 \(requestURL.path) 以避免重复迁移。"
            )
        }
        return result
    }

    private static func copySQLiteDatabase(from source: URL, to target: URL) throws {
        var sourceDB: OpaquePointer?
        var targetDB: OpaquePointer?
        guard sqlite3_open_v2(source.path, &sourceDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = sourceDB.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let sourceDB { sqlite3_close(sourceDB) }
            throw MigrationError.sourceUnreadable("无法打开旧数据库：\(message)")
        }
        defer { sqlite3_close(sourceDB) }
        guard sqlite3_open_v2(
            target.path,
            &targetDB,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        ) == SQLITE_OK else {
            let message = targetDB.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let targetDB { sqlite3_close(targetDB) }
            throw MigrationError.verificationFailed("无法创建迁移数据库：\(message)")
        }
        defer { sqlite3_close(targetDB) }
        guard let backup = sqlite3_backup_init(targetDB, "main", sourceDB, "main") else {
            throw MigrationError.verificationFailed("无法启动 SQLite 备份")
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else {
            throw MigrationError.verificationFailed(
                "SQLite 备份未完成（step=\(step), finish=\(finish)）"
            )
        }
    }

    private static func verifySQLiteDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db { sqlite3_close(db) }
            throw MigrationError.verificationFailed("无法打开迁移后的数据库：\(message)")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw MigrationError.verificationFailed(
                "无法校验迁移后的数据库：\(message)（\(url.path)，存在=\(FileManager.default.fileExists(atPath: url.path))）"
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0),
              String(cString: text) == "ok" else {
            throw MigrationError.verificationFailed("迁移后的数据库完整性校验未通过")
        }
    }

    private static func regularFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: []
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
