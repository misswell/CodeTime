import Foundation
import SharedModels

/// Bounded LRU used for hot, derived data. An unbounded dictionary inside a
/// long-lived agent is a memory leak with extra steps.
private struct LRUCache<Key: Hashable, Value> {
    private var storage: [Key: Value] = [:]
    private var order: [Key] = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func value(for key: Key) -> Value? {
        guard let value = storage[key] else { return nil }
        touch(key)
        return value
    }

    mutating func insert(_ value: Value, for key: Key) {
        storage[key] = value
        touch(key)
        while order.count > capacity {
            let evicted = order.removeFirst()
            storage.removeValue(forKey: evicted)
        }
    }

    mutating func removeAll() {
        storage.removeAll()
        order.removeAll()
    }

    private mutating func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
    }
}

public actor KopiaBackupEngine: BackupEngine {
    public struct Configuration: Sendable {
        public var repositoryID: UUID
        public var repositoriesRoot: URL
        public var cacheURL: URL
        public var logsURL: URL
        public var binaryURL: URL
        public var passwordProvider: any RepositoryPasswordProviding
        public var gitProvider: (any GitCapturing)?
        public var defaultParallelism: Int
        public var snapshotTimeout: TimeInterval
        public var directoryCacheCapacity: Int
        public var rootObjectCacheCapacity: Int
        public var maxDiffEntries: Int
        public var searchLimits: SearchLimits

        public init(
            repositoryID: UUID,
            repositoriesRoot: URL,
            cacheURL: URL,
            logsURL: URL,
            binaryURL: URL,
            passwordProvider: any RepositoryPasswordProviding,
            gitProvider: (any GitCapturing)? = nil,
            defaultParallelism: Int = 2,
            snapshotTimeout: TimeInterval = 7200,
            directoryCacheCapacity: Int = 512,
            rootObjectCacheCapacity: Int = 128,
            maxDiffEntries: Int = 20_000,
            searchLimits: SearchLimits = .default
        ) {
            self.repositoryID = repositoryID
            self.repositoriesRoot = repositoriesRoot
            self.cacheURL = cacheURL
            self.logsURL = logsURL
            self.binaryURL = binaryURL
            self.passwordProvider = passwordProvider
            self.gitProvider = gitProvider
            self.defaultParallelism = defaultParallelism
            self.snapshotTimeout = snapshotTimeout
            self.directoryCacheCapacity = directoryCacheCapacity
            self.rootObjectCacheCapacity = rootObjectCacheCapacity
            self.maxDiffEntries = maxDiffEntries
            self.searchLimits = searchLimits
        }
    }

    private let configuration: Configuration
    private let runner = ProcessRunner()
    private var repositoryReady = false
    private var cachedPassword: String?
    private var cachedRootObjects: LRUCache<String, String>
    private var directoryCache: LRUCache<String, KopiaDirectoryJSON>

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.cachedRootObjects = LRUCache(capacity: configuration.rootObjectCacheCapacity)
        self.directoryCache = LRUCache(capacity: configuration.directoryCacheCapacity)
    }

    public nonisolated var repositoryRootURL: URL {
        configuration.repositoriesRoot
            .appendingPathComponent(configuration.repositoryID.uuidString, isDirectory: true)
    }

    public nonisolated var repositoryURL: URL {
        repositoryRootURL.appendingPathComponent("repo", isDirectory: true)
    }

    public nonisolated var repositoryLockURL: URL {
        repositoryRootURL.appendingPathComponent("repository.lock")
    }

    public nonisolated var configFileURL: URL {
        repositoryRootURL.appendingPathComponent("kopia.config")
    }

    public nonisolated var metadataURL: URL {
        repositoryRootURL.appendingPathComponent("repository.json")
    }

    private var repositoryCacheURL: URL {
        configuration.cacheURL.appendingPathComponent(configuration.repositoryID.uuidString, isDirectory: true)
    }

    // MARK: - Repository lifecycle (§5)

    public func repositoryMetadata() -> RepositoryMetadata? {
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        return try? JSONDecoder().decode(RepositoryMetadata.self, from: data)
    }

    /// Derives the authoritative state from disk + metadata. This never mutates the
    /// repository: only `ensureRepository()` may create one, and only from `.uninitialized`.
    public func repositoryState() async -> RepositoryState {
        let fileManager = FileManager.default
        let metadata: RepositoryMetadata?
        if fileManager.fileExists(atPath: metadataURL.path) {
            guard let data = try? Data(contentsOf: metadataURL),
                  let decoded = try? JSONDecoder().decode(RepositoryMetadata.self, from: data) else {
                return .corrupted
            }
            metadata = decoded
        } else {
            metadata = nil
        }
        if let metadata, metadata.repositoryID != configuration.repositoryID {
            return .corrupted
        }
        let configExists = fileManager.fileExists(atPath: configFileURL.path)
        let repoContents: [String]
        do {
            repoContents = try fileManager.contentsOfDirectory(atPath: repositoryURL.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
            repoContents = []
        } catch {
            // An unreadable directory is not an empty one. Guessing "uninitialized"
            // here would let ensureRepository() build a new repository over data we
            // could not even list.
            return .corrupted
        }
        let repoHasData = configExists || !repoContents.isEmpty

        if let metadata {
            switch metadata.state {
            case .recovering:
                return .recovering
            case .recoveryFailed:
                return .recoveryFailed
            case .initializing:
                // A crash mid-create leaves a half-built repository. Never overwrite it.
                return .corrupted
            case .uninitialized:
                return repoHasData ? .corrupted : .uninitialized
            case .missing:
                return repoHasData ? .corrupted : .missing
            case .corrupted:
                return .corrupted
            case .ready:
                if !repoHasData { return .missing }
                return await canConnect() ? .ready : .corrupted
            }
        }

        // Legacy beta repository: data exists but no CodeTime metadata. Adopt it only
        // if kopia can actually connect; otherwise report corruption.
        if repoHasData {
            return await canConnect() ? .ready : .corrupted
        }
        return .uninitialized
    }

    /// The only path that may initialize a repository. `missing`, `corrupted`,
    /// `recovering` and `recoveryFailed` are hard errors that require user action.
    public func ensureRepository() async throws {
        if repositoryReady { return }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: repositoryRootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: configuration.logsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: repositoryCacheURL, withIntermediateDirectories: true)

        let state = await repositoryState()
        // A repository restored from the cloud (or created by v1.0.0-beta.1) has
        // data but no local kopia.config. Reconnecting rewrites the local config
        // only; it never creates or overwrites repository data. If the password is
        // wrong the connect fails and the corruption verdict stands.
        if state == .corrupted, repositoryMetadata() == nil, !fileManager.fileExists(atPath: configFileURL.path) {
            let contents = (try? fileManager.contentsOfDirectory(atPath: repositoryURL.path)) ?? []
            if !contents.isEmpty {
                let connect = try await kopia(
                    ["repository", "connect", "filesystem", "--path=\(repositoryURL.path)"],
                    timeout: 120,
                    allowFailure: true
                )
                if connect.status == 0 {
                    var metadata = RepositoryMetadata(
                        repositoryID: configuration.repositoryID,
                        kopiaVersion: await KopiaBinary.version(at: configuration.binaryURL) ?? ""
                    )
                    metadata.state = .ready
                    metadata.kopiaUniqueID = await repositoryUniqueID()
                    try write(metadata: metadata)
                    repositoryReady = true
                    return
                }
            }
        }
        switch state {
        case .ready:
            try await adoptOrRefreshMetadata()
            repositoryReady = true
            return
        case .uninitialized:
            break
        case .missing:
            throw CodeTimeError.repositoryMissing("本地仓库目录已丢失，CodeTime 不会自动创建空仓库")
        case .corrupted:
            throw CodeTimeError.repositoryCorrupted("仓库内容无法连接或元数据损坏，CodeTime 不会覆盖现有数据")
        case .initializing:
            throw CodeTimeError.repositoryStateForbidden(state: state.displayName, operation: "备份")
        case .recovering, .recoveryFailed:
            throw CodeTimeError.repositoryStateForbidden(state: state.displayName, operation: "备份")
        }

        let lock = RepositoryLock(path: repositoryLockURL.path)
        try lock.acquire(timeout: 180)
        defer { lock.release() }

        // Re-check under the cross-process lock: another process may have created it.
        let lockedState = await repositoryState()
        if lockedState == .ready {
            try await adoptOrRefreshMetadata()
            repositoryReady = true
            return
        }
        guard lockedState == .uninitialized else {
            throw CodeTimeError.repositoryStateForbidden(state: lockedState.displayName, operation: "初始化")
        }

        try fileManager.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        var metadata = RepositoryMetadata(
            repositoryID: configuration.repositoryID,
            kopiaVersion: await KopiaBinary.version(at: configuration.binaryURL) ?? "",
            state: .initializing
        )
        try write(metadata: metadata)

        let create = try await kopia(
            ["repository", "create", "filesystem", "--path=\(repositoryURL.path)"],
            timeout: 600,
            allowFailure: true
        )
        guard create.status == 0 else {
            // Leave `.initializing` on disk so the next launch reports corruption
            // instead of silently creating a second repository over partial data.
            throw CodeTimeError.repositoryUnavailable(String(create.stderrText.suffix(400)))
        }
        metadata.state = .ready
        metadata.initializedAt = Date()
        metadata.kopiaUniqueID = await repositoryUniqueID()
        try write(metadata: metadata)
        repositoryReady = true
    }

    /// Called after a cloud restore commits a new repository directory.
    public func markRecovering(reason: String) throws {
        var metadata = repositoryMetadata() ?? RepositoryMetadata(repositoryID: configuration.repositoryID)
        metadata.state = .recovering
        metadata.stateReason = reason
        try write(metadata: metadata)
        repositoryReady = false
    }

    public func markReadyAfterRecovery(uniqueID: String?) throws {
        var metadata = repositoryMetadata() ?? RepositoryMetadata(repositoryID: configuration.repositoryID)
        metadata.state = .ready
        metadata.stateReason = nil
        metadata.initializedAt = metadata.initializedAt ?? Date()
        if let uniqueID { metadata.kopiaUniqueID = uniqueID }
        try write(metadata: metadata)
        repositoryReady = true
    }

    public func markRecoveryFailed(reason: String) throws {
        var metadata = repositoryMetadata() ?? RepositoryMetadata(repositoryID: configuration.repositoryID)
        metadata.state = .recoveryFailed
        metadata.stateReason = reason
        try write(metadata: metadata)
        repositoryReady = false
    }

    /// Rebuilds CodeTime metadata for a repository that predates the state machine.
    private func adoptOrRefreshMetadata() async throws {
        var metadata = repositoryMetadata() ?? RepositoryMetadata(
            repositoryID: configuration.repositoryID,
            kopiaVersion: "",
            createdAt: Date()
        )
        if metadata.repositoryID != configuration.repositoryID {
            throw CodeTimeError.repositoryIdentityMismatch(
                expected: configuration.repositoryID.uuidString,
                actual: metadata.repositoryID.uuidString
            )
        }
        let wasReady = metadata.state == .ready
        metadata.state = .ready
        metadata.initializedAt = metadata.initializedAt ?? Date()
        if metadata.kopiaUniqueID == nil || !wasReady {
            if metadata.kopiaVersion.isEmpty {
                metadata.kopiaVersion = await KopiaBinary.version(at: configuration.binaryURL) ?? ""
            }
        }
        try write(metadata: metadata)
    }

    private func write(metadata: RepositoryMetadata) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try FileManager.default.createDirectory(
            at: metadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: metadataURL, options: [.atomic])
    }

    private func canConnect() async -> Bool {
        guard let result = try? await kopia(
            ["repository", "status", "--json"],
            timeout: 30,
            allowFailure: true
        ) else { return false }
        return result.status == 0
    }

    private func repositoryUniqueID() async -> String? {
        guard let result = try? await kopia(
            ["repository", "status", "--json"],
            timeout: 30,
            allowFailure: true
        ), result.status == 0 else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            return nil
        }
        return object["uniqueIDHex"] as? String
    }

    // MARK: - Snapshot creation

    public func createSnapshot(
        project: Project,
        policy: BackupPolicy,
        trigger: BackupTrigger
    ) async throws -> Snapshot {
        try Task.checkCancellation()
        try await ensureRepository()
        try Task.checkCancellation()

        let root = URL(fileURLWithPath: project.rootPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CodeTimeError.repositoryUnavailable("项目目录不存在：\(project.rootPath)")
        }

        let git = policy.backupGitMetadata ? configuration.gitProvider?.capture(repositoryPath: root.path) : nil
        let lock = RepositoryLock(path: repositoryLockURL.path)
        try lock.acquire(timeout: 180)
        defer { lock.release() }

        try await applyPolicy(policy, to: root)
        directoryCache.removeAll()
        cachedRootObjects.removeAll()

        // Shrink the parallelism estimate for very large roots so kopia does not
        // exhaust file descriptors; the user profile remains the upper bound.
        let parallelism = max(1, min(8, configuration.defaultParallelism))
        let description = "CodeTime · \(trigger.displayName)"
        let result = try await kopia(
            [
                "snapshot", "create", root.path,
                "--json",
                "--parallel=\(parallelism)",
                "--description=\(description)",
                "--tags=trigger:\(trigger.rawValue)",
                "--tags=project:\(project.id.uuidString)",
            ],
            timeout: configuration.snapshotTimeout
        )

        let created = try KopiaJSON.decode(KopiaSnapshotJSON.self, from: result.stdout)
        let detailed = try? await rawSnapshots(sourcePath: root.path)
        let merged = detailed?.first { $0.id == created.id } ?? created
        var snapshot = mapSnapshot(merged, projectID: project.id, fallbackTrigger: trigger)
        if snapshot.git == nil { snapshot.git = git }
        if snapshot.trigger == .scheduled, trigger != .scheduled { snapshot.trigger = trigger }
        return snapshot
    }

    // MARK: - Snapshot queries (§11.1)

    /// Throws instead of returning an empty list. A failed query must never be
    /// rendered as "this project has no backups".
    public func listSnapshots(project: Project) async throws -> [Snapshot] {
        try Task.checkCancellation()
        try await ensureRepository()
        let root = URL(fileURLWithPath: project.rootPath).standardizedFileURL
        let raw = try await rawSnapshots(sourcePath: root.path)
        return raw
            .filter { URL(fileURLWithPath: $0.source.path).standardizedFileURL.path == root.path }
            .map { mapSnapshot($0, projectID: project.id, fallbackTrigger: .scheduled) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Browse

    /// Used by disaster recovery to discover which source directories have snapshots
    /// in a repository restored from iCloud.
    public func snapshotSourcePaths() async throws -> [String] {
        try await ensureRepository()
        let result = try await kopia(["snapshot", "list", "--json", "--all"], timeout: 180)
        let snapshots = try KopiaJSON.decode([KopiaSnapshotJSON].self, from: result.stdout)
        var seen = Set<String>()
        var paths: [String] = []
        for snapshot in snapshots where seen.insert(snapshot.source.path).inserted {
            paths.append(snapshot.source.path)
        }
        return paths.sorted()
    }

    public func listDirectory(snapshotID: String, path: String) async throws -> [FileEntry] {
        try Task.checkCancellation()
        try await ensureRepository()
        let components = try validated(path: path)
        let objectID = try await resolveObjectID(snapshotID: snapshotID, components: components)
        let directory = try await directoryObject(objectID: objectID)
        let entries = directory.entries ?? []
        let base = components.joined(separator: "/")
        return entries.map { entry in
            let entryPath = base.isEmpty ? entry.name ?? "" : base + "/" + (entry.name ?? "")
            return FileEntry(
                path: entryPath,
                name: entry.name ?? "",
                isDirectory: entry.type == "d",
                isSymlink: entry.type == "s",
                size: entry.size ?? entry.summ?.size ?? 0,
                modifiedAt: KopiaDateParser.parse(entry.mtime),
                objectID: entry.obj
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Breadth-first search with explicit, configurable limits. A truncated result is
    /// reported as truncated; it is never presented as a complete answer.
    public func searchFiles(
        snapshotID: String,
        query: String,
        limits: SearchLimits = .default
    ) async throws -> FileSearchResult {
        try Task.checkCancellation()
        try await ensureRepository()
        let start = Date()
        let needle = query.lowercased()
        var result = FileSearchResult()
        guard !needle.isEmpty else {
            result.duration = Date().timeIntervalSince(start)
            return result
        }
        let rootID = try await rootObjectID(snapshotID: snapshotID)
        var queue: [(path: String, objectID: String, depth: Int)] = [("", rootID, 0)]
        var index = 0
        var visitedFiles = 0
        var visitedDirectories = 0

        searchLoop: while index < queue.count {
            try Task.checkCancellation()
            if Date().timeIntervalSince(start) > limits.maxDuration {
                result.truncated = true
                result.truncationReason = "超过最长运行时间 \(Int(limits.maxDuration)) 秒"
                break
            }
            if visitedDirectories >= limits.maxDirectories {
                result.truncated = true
                result.truncationReason = "超过最大目录数 \(limits.maxDirectories)"
                break
            }
            if visitedFiles >= limits.maxFiles {
                result.truncated = true
                result.truncationReason = "超过最大文件数 \(limits.maxFiles)"
                break
            }
            let node = queue[index]
            index += 1
            guard node.depth <= limits.maxDepth else { continue }
            visitedDirectories += 1
            let directory: KopiaDirectoryJSON
            do {
                directory = try await directoryObject(objectID: node.objectID)
            } catch {
                result.failedDirectories.append(node.path.isEmpty ? "/" : node.path)
                continue
            }
            for entry in directory.entries ?? [] {
                visitedFiles += 1
                let name = entry.name ?? ""
                let childPath = node.path.isEmpty ? name : node.path + "/" + name
                if entry.type == "d" {
                    queue.append((childPath, entry.obj ?? "", node.depth + 1))
                }
                if name.lowercased().contains(needle) || childPath.lowercased().contains(needle) {
                    result.entries.append(FileEntry(
                        path: childPath,
                        name: name,
                        isDirectory: entry.type == "d",
                        isSymlink: entry.type == "s",
                        size: entry.size ?? entry.summ?.size ?? 0,
                        modifiedAt: KopiaDateParser.parse(entry.mtime),
                        objectID: entry.obj
                    ))
                    if result.entries.count >= limits.maxResults {
                        result.truncated = true
                        result.truncationReason = "结果超过 \(limits.maxResults) 条"
                        break searchLoop
                    }
                }
            }
        }
        result.visitedDirectories = visitedDirectories
        result.visitedFiles = visitedFiles
        result.duration = Date().timeIntervalSince(start)
        return result
    }

    public func readFile(snapshotID: String, path: String, maxBytes: Int) async throws -> Data {
        try Task.checkCancellation()
        try await ensureRepository()
        let components = try validated(path: path)
        guard !components.isEmpty else {
            throw CodeTimeError.pathOutsideProject(path)
        }
        let resolved = try await resolveEntry(snapshotID: snapshotID, components: components)
        guard resolved.entry.type != "d" else {
            throw CodeTimeError.pathOutsideProject("目标是目录：\(path)")
        }
        let size = resolved.entry.size ?? resolved.entry.summ?.size ?? 0
        if size > Int64(maxBytes) {
            throw CodeTimeError.fileTooLarge(size, limit: maxBytes)
        }
        guard let objectID = resolved.entry.obj else {
            throw CodeTimeError.invalidOutput("文件缺少对象 ID：\(path)")
        }
        let result = try await runner.run(
            executable: configuration.binaryURL,
            arguments: globalArguments + ["show", objectID],
            environment: environment(),
            timeout: 120
        )
        guard result.status == 0 else {
            throw commandError(result)
        }
        if result.stdoutTruncated || result.stdout.count > maxBytes {
            throw CodeTimeError.fileTooLarge(Int64(result.stdout.count), limit: maxBytes)
        }
        return result.stdout
    }

    // MARK: - Restore

    public func restore(
        snapshotID: String,
        path: String?,
        destination: URL,
        overwrite: Bool
    ) async throws {
        try Task.checkCancellation()
        try await ensureRepository()
        let fileManager = FileManager.default
        let dest = destination.standardizedFileURL

        var source = snapshotID
        if let path, !path.isEmpty {
            let components = try validated(path: path)
            source += "/" + components.joined(separator: "/")
            let parent = dest.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: dest.path), !overwrite {
                throw CodeTimeError.destinationExists(dest.path)
            }
        } else {
            if fileManager.fileExists(atPath: dest.path) {
                let contents = try fileManager.contentsOfDirectory(atPath: dest.path)
                if !contents.isEmpty, !overwrite {
                    throw CodeTimeError.destinationExists(dest.path)
                }
            } else {
                try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
            }
        }

        var arguments = ["restore", source, dest.path, "--parallel=4", "--write-files-atomically"]
        if !overwrite {
            arguments.append("--no-overwrite-files")
            arguments.append("--no-overwrite-directories")
            arguments.append("--no-overwrite-symlinks")
        }
        let result = try await kopia(arguments, timeout: 3600)
        guard result.status == 0 else {
            throw commandError(result)
        }
    }

    // MARK: - Diff (§11.2)

    public func diff(from snapshotA: String, to snapshotB: String) async throws -> SnapshotDiff {
        try Task.checkCancellation()
        try await ensureRepository()
        let result = try await kopia(["diff", snapshotA, snapshotB], timeout: 600, allowFailure: true)
        guard result.status == 0 else {
            throw CodeTimeError.diffUnavailable(result.stderrText.suffix(500).description)
        }
        var diff = SnapshotDiff()
        var seen = Set<String>()
        for line in result.stdoutText.split(separator: "\n") {
            try Task.checkCancellation()
            let text = String(line)
            var path: String?
            var kind: DiffKind?
            if text.hasPrefix("added ") {
                path = String(text.dropFirst("added ".count))
                kind = .added
            } else if text.hasPrefix("removed ") {
                path = String(text.dropFirst("removed ".count))
                kind = .removed
            } else if text.hasPrefix("changed ") {
                var changedPath = String(text.dropFirst("changed ".count))
                if let range = changedPath.range(of: " at ") {
                    changedPath = String(changedPath[..<range.lowerBound])
                }
                path = changedPath
                kind = .modified
            }
            guard var entryPath = path, let kind else { continue }
            if entryPath.hasPrefix("./") { entryPath.removeFirst(2) }
            entryPath = entryPath.trimmingCharacters(in: .whitespaces)
            guard !entryPath.isEmpty, seen.insert(entryPath).inserted else { continue }
            diff.files.append(ChangedFile(path: entryPath, kind: kind))
            switch kind {
            case .added: diff.added += 1
            case .removed: diff.removed += 1
            case .modified: diff.modified += 1
            }
            if diff.files.count >= configuration.maxDiffEntries {
                diff.isTruncated = true
                break
            }
        }
        diff.files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return diff
    }

    // MARK: - Verify

    public func verify(snapshotID: String) async throws -> VerificationResult {
        try Task.checkCancellation()
        try await ensureRepository()
        let result = try await kopia(
            ["snapshot", "verify", snapshotID, "--json"],
            timeout: 7200,
            allowFailure: true
        )
        guard result.status == 0 else {
            return VerificationResult(
                snapshotID: snapshotID,
                level: .localRestore,
                outcome: .failed,
                details: result.stderrText.suffix(500).description
            )
        }
        if result.stdoutTruncated {
            return VerificationResult(
                snapshotID: snapshotID,
                level: .localRestore,
                outcome: .failed,
                details: "校验输出超过缓冲上限，无法确认完整结果"
            )
        }
        let lines = result.stdoutText
            .split(separator: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }
        var errors = 0
        var bytes: Int64 = 0
        var parsedAny = false
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(KopiaVerifyJSON.self, from: data) else {
                continue
            }
            parsedAny = true
            errors = max(errors, parsed.errorCount ?? 0)
            bytes = max(bytes, parsed.stats?.processedBytes ?? parsed.stats?.expectedTotalBytes ?? 0)
        }
        guard parsedAny else {
            return VerificationResult(
                snapshotID: snapshotID,
                level: .localRestore,
                outcome: .failed,
                details: "校验命令成功，但无法解析任何校验统计；结果未知，按失败处理"
            )
        }
        return VerificationResult(
            snapshotID: snapshotID,
            level: .localRestore,
            outcome: errors == 0 ? .passed : .failed,
            details: errors == 0 ? "快照对象校验通过" : "发现 \(errors) 个错误对象",
            bytesChecked: bytes
        )
    }

    // MARK: - Policy

    private func applyPolicy(_ policy: BackupPolicy, to root: URL) async throws {
        let matcher = ExclusionMatcher(
            rules: policy.excludeRules + KopiaIgnore.rules(at: root),
            includeEnvFiles: policy.includeEnvFiles,
            includeGitDirectory: policy.includeGitDirectory
        )
        // Preserve rule order and de-duplicate while keeping Kopia-compatible syntax.
        var patterns: [String] = []
        var seen = Set<String>()
        for compiled in matcher.compiled where seen.insert(compiled.rule.pattern).inserted {
            patterns.append(compiled.rule.pattern)
        }

        _ = try await kopia(
            ["policy", "set", "--clear-ignore", root.path],
            timeout: 60,
            allowFailure: true
        )

        var arguments = ["policy", "set"]
        for pattern in patterns {
            arguments.append("--add-ignore=\(pattern)")
        }
        arguments.append("--keep-latest=\(max(1, policy.retention.keepLatest))")
        arguments.append("--keep-hourly=0")
        arguments.append("--keep-daily=\(max(0, policy.retention.keepDaily))")
        arguments.append("--keep-weekly=\(max(0, policy.retention.keepWeekly))")
        arguments.append("--keep-monthly=\(max(0, policy.retention.keepMonthly))")
        arguments.append(root.path)
        _ = try await kopia(arguments, timeout: 120)
    }

    // MARK: - Repository objects

    private func rawSnapshots(sourcePath: String) async throws -> [KopiaSnapshotJSON] {
        let result = try await kopia(
            ["snapshot", "list", "--json", "--all", sourcePath],
            timeout: 180,
            allowFailure: true
        )
        guard result.status == 0 else {
            throw CodeTimeError.repositoryUnavailable(String(result.stderrText.suffix(400)))
        }
        if result.stdoutTruncated {
            throw CodeTimeError.outputTruncated(limit: result.stdout.count)
        }
        do {
            return try KopiaJSON.decode([KopiaSnapshotJSON].self, from: result.stdout)
        } catch {
            throw CodeTimeError.invalidOutput("无法解析快照列表：\(error.localizedDescription)")
        }
    }

    private func rootObjectID(snapshotID: String) async throws -> String {
        if let cached = cachedRootObjects.value(for: snapshotID) { return cached }
        let result = try await kopia(["snapshot", "list", "--json", "--all"], timeout: 180)
        if result.stdoutTruncated {
            throw CodeTimeError.outputTruncated(limit: result.stdout.count)
        }
        let snapshots = try KopiaJSON.decode([KopiaSnapshotJSON].self, from: result.stdout)
        guard let snapshot = snapshots.first(where: { $0.id == snapshotID }),
              let objectID = snapshot.rootEntry?.obj else {
            throw CodeTimeError.snapshotNotFound(snapshotID)
        }
        cachedRootObjects.insert(objectID, for: snapshotID)
        return objectID
    }

    private func directoryObject(objectID: String) async throws -> KopiaDirectoryJSON {
        if let cached = directoryCache.value(for: objectID) { return cached }
        let result = try await runner.run(
            executable: configuration.binaryURL,
            arguments: globalArguments + ["show", objectID],
            environment: environment(),
            timeout: 120
        )
        guard result.status == 0 else { throw commandError(result) }
        if result.stdoutTruncated {
            throw CodeTimeError.outputTruncated(limit: result.stdout.count)
        }
        let decoded = try KopiaJSON.decode(KopiaDirectoryJSON.self, from: result.stdout)
        guard decoded.stream == "kopia:directory" else {
            throw CodeTimeError.invalidOutput("对象不是目录：\(objectID)")
        }
        directoryCache.insert(decoded, for: objectID)
        return decoded
    }

    private func resolveEntry(snapshotID: String, components: [String]) async throws -> (objectID: String, entry: KopiaEntryJSON) {
        let rootID = try await rootObjectID(snapshotID: snapshotID)
        guard !components.isEmpty else {
            return (rootID, KopiaEntryJSON(name: "", type: "d", obj: rootID))
        }
        var currentID = rootID
        for (index, component) in components.enumerated() {
            let directory = try await directoryObject(objectID: currentID)
            guard let entry = directory.entries?.first(where: { $0.name == component }) else {
                throw CodeTimeError.snapshotNotFound(components.prefix(index + 1).joined(separator: "/"))
            }
            if index < components.count - 1 {
                guard entry.type == "d", let next = entry.obj else {
                    throw CodeTimeError.pathOutsideProject(components.prefix(index + 1).joined(separator: "/"))
                }
                currentID = next
            } else {
                guard let objectID = entry.obj else {
                    throw CodeTimeError.invalidOutput("条目缺少对象 ID")
                }
                return (objectID, entry)
            }
        }
        throw CodeTimeError.snapshotNotFound(snapshotID)
    }

    private func resolveObjectID(snapshotID: String, components: [String]) async throws -> String {
        if components.isEmpty {
            return try await rootObjectID(snapshotID: snapshotID)
        }
        let resolved = try await resolveEntry(snapshotID: snapshotID, components: components)
        guard resolved.entry.type == "d" else {
            throw CodeTimeError.pathOutsideProject("不是目录：\(components.joined(separator: "/"))")
        }
        return resolved.objectID
    }

    // MARK: - Mapping

    private func mapSnapshot(
        _ raw: KopiaSnapshotJSON,
        projectID: UUID,
        fallbackTrigger: BackupTrigger
    ) -> Snapshot {
        let errorCount = max(raw.stats?.errorCount ?? 0, raw.rootEntry?.summ?.numFailed ?? 0)
        let fileCount = raw.stats?.fileCount ?? raw.rootEntry?.summ?.files ?? 0
        let totalSize = raw.stats?.totalSize ?? raw.rootEntry?.summ?.size ?? 0
        var trigger = raw.tags?["trigger"].flatMap(BackupTrigger.init(rawValue:)) ?? fallbackTrigger
        if raw.tags?["trigger"] == nil, let description = raw.description {
            if let matched = BackupTrigger.allCases.first(where: { description.contains($0.displayName) }) {
                trigger = matched
            }
        }
        let createdAt = KopiaDateParser.parse(raw.startTime) ?? KopiaDateParser.parse(raw.endTime) ?? Date()
        return Snapshot(
            id: raw.id,
            projectID: projectID,
            createdAt: createdAt,
            finishedAt: KopiaDateParser.parse(raw.endTime),
            summary: raw.description ?? "",
            trigger: trigger,
            status: errorCount == 0 ? .complete : .incomplete,
            consistency: errorCount == 0 ? .consistent : .possiblyInconsistent,
            fileCount: fileCount,
            totalSize: totalSize,
            errorCount: errorCount,
            excludedFileCount: raw.stats?.excludedFileCount ?? 0,
            excludedSize: raw.stats?.excludedTotalSize ?? 0,
            git: nil,
            cloudState: .localOnly
        )
    }

    // MARK: - Process helpers

    private var globalArguments: [String] {
        [
            "--config-file=\(configFileURL.path)",
            "--disable-file-logging",
            "--no-progress",
        ]
    }

    private func environment() throws -> [String: String] {
        let password: String
        if let cachedPassword {
            password = cachedPassword
        } else {
            password = try configuration.passwordProvider.repositoryPassword()
            cachedPassword = password
        }
        return [
            "KOPIA_PASSWORD": password,
            "KOPIA_LOG_DIR": configuration.logsURL.path,
            "KOPIA_CACHE_DIRECTORY": repositoryCacheURL.path,
        ]
    }

    private func kopia(
        _ arguments: [String],
        timeout: TimeInterval,
        allowFailure: Bool = false
    ) async throws -> CommandResult {
        let result = try await runner.run(
            executable: configuration.binaryURL,
            arguments: globalArguments + arguments,
            environment: try environment(),
            timeout: timeout
        )
        if !allowFailure, result.status != 0 {
            throw commandError(result)
        }
        return result
    }

    private func commandError(_ result: CommandResult) -> CodeTimeError {
        let message = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        return .commandFailed(
            command: "kopia",
            status: result.status,
            message: message.isEmpty ? "无错误输出" : String(message.suffix(800))
        )
    }

    private func validated(path: String) throws -> [String] {
        guard !path.contains("\0") else { throw CodeTimeError.pathOutsideProject(path) }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/") else { throw CodeTimeError.pathOutsideProject(path) }
        let components = normalized
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
        guard !components.contains("..") else {
            throw CodeTimeError.pathOutsideProject(path)
        }
        return components
    }
}
