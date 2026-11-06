import Foundation
import SharedModels

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

        public init(
            repositoryID: UUID,
            repositoriesRoot: URL,
            cacheURL: URL,
            logsURL: URL,
            binaryURL: URL,
            passwordProvider: any RepositoryPasswordProviding,
            gitProvider: (any GitCapturing)? = nil,
            defaultParallelism: Int = 2,
            snapshotTimeout: TimeInterval = 7200
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
        }
    }

    private let configuration: Configuration
    private let runner = ProcessRunner()
    private var repositoryReady = false
    private var cachedPassword: String?
    private var cachedRootObjects: [String: String] = [:]
    private var directoryCache: [String: KopiaDirectoryJSON] = [:]

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public nonisolated var repositoryURL: URL {
        configuration.repositoriesRoot
            .appendingPathComponent(configuration.repositoryID.uuidString, isDirectory: true)
            .appendingPathComponent("repo", isDirectory: true)
    }

    public nonisolated var repositoryLockURL: URL {
        configuration.repositoriesRoot
            .appendingPathComponent(configuration.repositoryID.uuidString, isDirectory: true)
            .appendingPathComponent("repository.lock")
    }

    public nonisolated var configFileURL: URL {
        configuration.repositoriesRoot
            .appendingPathComponent(configuration.repositoryID.uuidString, isDirectory: true)
            .appendingPathComponent("kopia.config")
    }

    private var repositoryCacheURL: URL {
        configuration.cacheURL.appendingPathComponent(configuration.repositoryID.uuidString, isDirectory: true)
    }

    private var lockURL: URL {
        configuration.repositoriesRoot
            .appendingPathComponent(configuration.repositoryID.uuidString, isDirectory: true)
            .appendingPathComponent("repository.lock")
    }

    // MARK: - Repository lifecycle

    public func ensureRepository() async throws {
        if repositoryReady { return }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: configFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: configuration.logsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: repositoryCacheURL, withIntermediateDirectories: true)

        if let status = try? await kopia(["repository", "status", "--json"], timeout: 30), status.status == 0 {
            repositoryReady = true
            return
        }

        let configExists = fileManager.fileExists(atPath: configFileURL.path)
        let contents = (try? fileManager.contentsOfDirectory(atPath: repositoryURL.path)) ?? []
        if configExists || !contents.isEmpty {
            let connect = try await kopia(
                ["repository", "connect", "filesystem", "--path=\(repositoryURL.path)"],
                timeout: 120,
                allowFailure: true
            )
            guard connect.status == 0 else {
                throw CodeTimeError.repositoryUnavailable(connect.stderrText.suffix(400).description)
            }
            repositoryReady = true
            return
        }

        let create = try await kopia(
            ["repository", "create", "filesystem", "--path=\(repositoryURL.path)"],
            timeout: 600,
            allowFailure: true
        )
        guard create.status == 0 else {
            throw CodeTimeError.repositoryUnavailable(create.stderrText.suffix(400).description)
        }
        repositoryReady = true
    }

    // MARK: - Snapshot creation

    public func createSnapshot(
        project: Project,
        policy: BackupPolicy,
        trigger: BackupTrigger
    ) async throws -> Snapshot {
        try await ensureRepository()

        let root = URL(fileURLWithPath: project.rootPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CodeTimeError.repositoryUnavailable("项目目录不存在：\(project.rootPath)")
        }

        let git = policy.backupGitMetadata ? configuration.gitProvider?.capture(repositoryPath: root.path) : nil
        let lock = RepositoryLock(path: lockURL.path)
        try lock.acquire(timeout: 180)
        defer { lock.release() }

        try await applyPolicy(policy, to: root)
        directoryCache.removeAll()

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
        let detailed = (try? await rawSnapshots(sourcePath: root.path))?.first { $0.id == created.id }
        let merged = detailed ?? created
        var snapshot = mapSnapshot(merged, projectID: project.id, fallbackTrigger: trigger)
        if snapshot.git == nil { snapshot.git = git }
        if snapshot.trigger == .scheduled, trigger != .scheduled { snapshot.trigger = trigger }
        return snapshot
    }

    public func listSnapshots(project: Project) async throws -> [Snapshot] {
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

    /// Breadth-first search across a snapshot. Bounded so a pathological tree cannot
    /// stall the UI indefinitely.
    public func searchFiles(snapshotID: String, query: String, limit: Int = 300) async throws -> [FileEntry] {
        try await ensureRepository()
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }
        let rootID = try await rootObjectID(snapshotID: snapshotID)
        var queue: [(path: String, objectID: String, depth: Int)] = [("", rootID, 0)]
        var results: [FileEntry] = []
        var visited = 0
        var index = 0

        while index < queue.count, visited < 20_000, results.count < limit {
            let node = queue[index]
            index += 1
            guard node.depth <= 24 else { continue }
            let directory: KopiaDirectoryJSON
            do { directory = try await directoryObject(objectID: node.objectID) }
            catch { continue }
            for entry in directory.entries ?? [] {
                visited += 1
                let name = entry.name ?? ""
                let childPath = node.path.isEmpty ? name : node.path + "/" + name
                if entry.type == "d" {
                    queue.append((childPath, entry.obj ?? "", node.depth + 1))
                }
                if name.lowercased().contains(needle) || childPath.lowercased().contains(needle) {
                    results.append(FileEntry(
                        path: childPath,
                        name: name,
                        isDirectory: entry.type == "d",
                        isSymlink: entry.type == "s",
                        size: entry.size ?? entry.summ?.size ?? 0,
                        modifiedAt: KopiaDateParser.parse(entry.mtime),
                        objectID: entry.obj
                    ))
                    if results.count >= limit { break }
                }
            }
        }
        return results
    }

    public func readFile(snapshotID: String, path: String, maxBytes: Int) async throws -> Data {
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
        if result.stdout.count > maxBytes {
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

    // MARK: - Diff

    public func diff(from snapshotA: String, to snapshotB: String) async throws -> SnapshotDiff {
        try await ensureRepository()
        let result = try await kopia(["diff", snapshotA, snapshotB], timeout: 600, allowFailure: true)
        guard result.status == 0 else {
            throw commandError(result)
        }
        var diff = SnapshotDiff()
        var seen = Set<String>()
        for line in result.stdoutText.split(separator: "\n") {
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
        }
        diff.files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return diff
    }

    // MARK: - Verify

    public func verify(snapshotID: String) async throws -> VerificationResult {
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
        let lines = result.stdoutText
            .split(separator: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }
        var errors = 0
        var bytes: Int64 = 0
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(KopiaVerifyJSON.self, from: data) else { continue }
            errors = max(errors, parsed.errorCount ?? 0)
            bytes = max(bytes, parsed.stats?.processedBytes ?? parsed.stats?.expectedTotalBytes ?? 0)
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
        guard result.status == 0 else { return [] }
        return try KopiaJSON.decode([KopiaSnapshotJSON].self, from: result.stdout)
    }

    private func rootObjectID(snapshotID: String) async throws -> String {
        if let cached = cachedRootObjects[snapshotID] { return cached }
        let result = try await kopia(["snapshot", "list", "--json", "--all"], timeout: 180)
        let snapshots = try KopiaJSON.decode([KopiaSnapshotJSON].self, from: result.stdout)
        guard let snapshot = snapshots.first(where: { $0.id == snapshotID }),
              let objectID = snapshot.rootEntry?.obj else {
            throw CodeTimeError.snapshotNotFound(snapshotID)
        }
        cachedRootObjects[snapshotID] = objectID
        return objectID
    }

    private func directoryObject(objectID: String) async throws -> KopiaDirectoryJSON {
        if let cached = directoryCache[objectID] { return cached }
        let result = try await runner.run(
            executable: configuration.binaryURL,
            arguments: globalArguments + ["show", objectID],
            environment: environment(),
            timeout: 120
        )
        guard result.status == 0 else { throw commandError(result) }
        let decoded = try KopiaJSON.decode(KopiaDirectoryJSON.self, from: result.stdout)
        guard decoded.stream == "kopia:directory" else {
            throw CodeTimeError.invalidOutput("对象不是目录：\(objectID)")
        }
        directoryCache[objectID] = decoded
        return decoded
    }

    private func resolveEntry(snapshotID: String, components: [String]) async throws -> (objectID: String, entry: KopiaEntryJSON) {
        let rootID = try await rootObjectID(snapshotID: snapshotID)
        guard !components.isEmpty else {
            return (rootID, KopiaEntryJSON(name: "", type: "d", obj: rootID))
        }
        var currentID = rootID
        var currentEntry: KopiaEntryJSON?
        for (index, component) in components.enumerated() {
            let directory = try await directoryObject(objectID: currentID)
            guard let entry = directory.entries?.first(where: { $0.name == component }) else {
                throw CodeTimeError.snapshotNotFound(components.prefix(index + 1).joined(separator: "/"))
            }
            currentEntry = entry
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
