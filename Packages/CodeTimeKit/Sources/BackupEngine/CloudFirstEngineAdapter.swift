import Foundation
import CryptoKit
import SharedModels

/// Coordinates one snapshot: scan → streaming chunks → Merkle upload → manifest
/// → commit. The heavy lifting lives in `CloudFirstBackupEngine`; this type is
/// the single entry point the service uses when it needs an explicit snapshot
/// operation rather than a bare engine call.
public struct SnapshotCoordinator: Sendable {
    private let engine: CloudFirstBackupEngine
    private let index: CloudSnapshotIndex

    public init(engine: CloudFirstBackupEngine, index: CloudSnapshotIndex) {
        self.engine = engine
        self.index = index
    }

    public func createSnapshot(
        projectID: UUID,
        root: URL,
        matcher: ExclusionMatcher,
        snapshotID: String = UUID().uuidString,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> BackupRunReport {
        try await engine.run(
            projectID: projectID,
            root: root,
            matcher: matcher,
            snapshotID: snapshotID,
            isCancelled: isCancelled
        )
    }

    /// What would the baseline upload cost? Used only for the migration warning.
    public func estimateUploadBytes(projectID: UUID) async throws -> Int64 {
        let files = try await index.fileNodes(projectID: projectID)
        return files.reduce(0) { $0 + $1.size }
    }
}

/// `BackupEngine` facade over Cloud Format v3.
///
/// The service and the UI keep talking to `Snapshot` / `FileEntry` / `RestoreRequest`;
/// this adapter translates those calls into the cloud-first engine and its
/// on-demand reader. There is no local repository underneath: `createSnapshot`
/// streams chunks to iCloud and commits, browsing reads the manifest and only the
/// chunks the requested file needs, and verification walks the Merkle tree
/// checking every referenced chunk.
public struct CloudFirstEngineAdapter: BackupEngine {
    private let masterKey: Data
    private let deviceID: String
    private let index: CloudSnapshotIndex
    private let sink: CloudObjectSink
    private let source: CloudObjectSource
    private let options: BackupRunOptions
    private let cache: RestoreObjectCache?
    private let git: GitCapturing?
    private let snapshotProjectProvider: @Sendable (String) async -> UUID?
    private let sourceRootsProvider: (@Sendable () async throws -> [URL])?
    private let prepareStore: (@Sendable () async throws -> Void)?
    private let clock: @Sendable () -> Date

    public init(
        masterKey: Data,
        deviceID: String,
        index: CloudSnapshotIndex,
        sink: CloudObjectSink,
        source: CloudObjectSource,
        options: BackupRunOptions = .default,
        cache: RestoreObjectCache? = nil,
        git: GitCapturing? = nil,
        snapshotProjectProvider: @escaping @Sendable (String) async -> UUID?,
        sourceRootsProvider: (@Sendable () async throws -> [URL])? = nil,
        prepareStore: (@Sendable () async throws -> Void)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.masterKey = masterKey
        self.deviceID = deviceID
        self.index = index
        self.sink = sink
        self.source = source
        self.options = options
        self.cache = cache
        self.git = git
        self.snapshotProjectProvider = snapshotProjectProvider
        self.sourceRootsProvider = sourceRootsProvider
        self.prepareStore = prepareStore
        self.clock = clock
    }

    // MARK: - BackupEngine

    public func ensureRepository() async throws {
        try await prepareStore?()
    }

    public func createSnapshot(
        project: Project,
        policy: BackupPolicy,
        trigger: BackupTrigger
    ) async throws -> Snapshot {
        let root = URL(fileURLWithPath: project.rootPath, isDirectory: true)
        let matcher = ExclusionMatcher(
            rules: policy.excludeRules + KopiaIgnore.rules(at: root),
            includeEnvFiles: policy.includeEnvFiles,
            includeGitDirectory: policy.includeGitDirectory
        )
        let engine = CloudFirstBackupEngine(
            masterKey: masterKey,
            deviceID: deviceID,
            index: index,
            sink: sink,
            options: options,
            clock: clock
        )
        let coordinator = SnapshotCoordinator(engine: engine, index: index)
        let report = try await coordinator.createSnapshot(
            projectID: project.id,
            root: root,
            matcher: matcher,
            // Propagate the caller's cancellation all the way to scan/chunk/
            // upload/commit. The service cancels the work Task; `Task.isCancelled`
            // is observed by the engine's cooperative checks.
            isCancelled: { Task.isCancelled }
        )
        guard report.committed else {
            throw CodeTimeError.cloudPublishIncomplete("快照未提交（缺少 Commit Marker）")
        }
        let now = clock()
        return Snapshot(
            id: report.snapshotID,
            projectID: project.id,
            createdAt: now,
            finishedAt: now,
            summary: "\(report.nodeCount) 个节点 · \(CodeTimeFormat.bytes(report.bytesRead))",
            trigger: trigger,
            status: .complete,
            consistency: .consistent,
            fileCount: report.filesScanned,
            totalSize: report.totalBytes,
            errorCount: 0,
            excludedFileCount: report.excludedFileCount,
            excludedSize: report.excludedSize,
            git: git?.capture(repositoryPath: root.path),
            cloudState: .synced
        )
    }

    public func listSnapshots(project: Project) async throws -> [Snapshot] {
        let commits = try await source.commits(projectID: project.id)
        return commits.map { commit in
            Snapshot(
                id: commit.snapshotID,
                projectID: commit.projectID,
                createdAt: commit.committedAt,
                finishedAt: commit.committedAt,
                summary: "\(commit.fileCount) 个文件",
                trigger: .scheduled,
                status: .complete,
                consistency: .consistent,
                fileCount: commit.fileCount,
                totalSize: commit.totalBytes,
                cloudState: .synced
            )
        }
    }

    public func listDirectory(snapshotID: String, path: String) async throws -> [FileEntry] {
        let projectID = try await projectID(for: snapshotID)
        let reader = restorer()
        return try await reader.listDirectory(
            projectID: projectID,
            snapshotID: snapshotID,
            path: path
        )
    }

    public func readFile(snapshotID: String, path: String, maxBytes: Int) async throws -> Data {
        let projectID = try await projectID(for: snapshotID)
        return try await restorer().readFileData(
            projectID: projectID,
            snapshotID: snapshotID,
            path: path,
            maxBytes: maxBytes
        )
    }

    public func restore(
        snapshotID: String,
        path: String?,
        destination: URL,
        overwrite: Bool
    ) async throws {
        // Original projects are permanently read-only. This public entry point
        // must never become a bypass around the service-level policy.
        guard !overwrite else {
            throw CodeTimeError.unsupported(
                "CodeTime 对原始项目永久只读，覆盖恢复已禁用；请恢复到独立目录"
            )
        }
        let projectID = try await projectID(for: snapshotID)
        let sourceRoots = try await sourceRootsProvider?() ?? []
        if sourceRoots.contains(where: { CloudRestoreEngine.pathsOverlap(destination, $0) }) {
            throw CodeTimeError.pathOverlap(
                path: destination.path,
                conflictsWith: "恢复目标与原始项目重叠；恢复只能写入独立目录"
            )
        }
        let target: RestoreTarget
        if let path, !path.isEmpty {
            target = (try? await restorer().directoryNodeForTarget(
                projectID: projectID,
                snapshotID: snapshotID,
                path: path
            )) == true ? .directory(path: path) : .file(path: path)
        } else {
            target = .project
        }
        _ = try await restorer(sourceRoots: sourceRoots).restore(
            projectID: projectID,
            snapshotID: snapshotID,
            target: target,
            destination: destination
        )
    }

    /// Path search over the manifest only — no chunk is downloaded and no
    /// directory is walked on disk. The limits are reported, never silently
    /// exceeded.
    public func searchFiles(
        snapshotID: String,
        query: String,
        limits: SearchLimits
    ) async throws -> FileSearchResult {
        let started = clock()
        let projectID = try await projectID(for: snapshotID)
        let reader = restorer()
        let manifest = try await reader.manifest(projectID: projectID, snapshotID: snapshotID)
        let needle = query.lowercased()
        var entries: [FileEntry] = []
        var visited = 0
        var truncated = false
        var reason: String?
        try await reader.forEachFile(rootNodeID: manifest.rootNodeID) { path, file in
            visited += 1
            if visited > limits.maxFiles {
                truncated = true
                reason = "已达到文件上限 \(limits.maxFiles)"
                return false
            }
            guard path.lowercased().contains(needle) else { return true }
            entries.append(FileEntry(
                path: file.path,
                name: MerkleTreeBuilder.lastComponent(of: file.path),
                isDirectory: false,
                isSymlink: file.kind == .symlink,
                size: file.size,
                modifiedAt: file.modifiedAt,
                objectID: file.contentHash
            ))
            if entries.count >= limits.maxResults {
                truncated = true
                reason = "已达到结果上限 \(limits.maxResults)"
                return false
            }
            return true
        }
        entries.sort { $0.path < $1.path }
        return FileSearchResult(
            entries: entries,
            truncated: truncated,
            truncationReason: reason,
            visitedDirectories: 0,
            visitedFiles: visited,
            duration: clock().timeIntervalSince(started)
        )
    }

    public func diff(from snapshotA: String, to snapshotB: String) async throws -> SnapshotDiff {
        let projectA = try await projectID(for: snapshotA)
        let projectB = try await projectID(for: snapshotB)
        guard projectA == projectB else {
            throw CodeTimeError.unsupported("只能比较同一项目的快照")
        }
        let reader = restorer()
        let left = try await reader.manifest(projectID: projectA, snapshotID: snapshotA)
        let right = try await reader.manifest(projectID: projectB, snapshotID: snapshotB)

        // Keep only the left map in memory. The right tree is streamed, and a
        // matched path is removed from the left map; whatever remains at the end
        // is exactly the removed set. This halves peak memory versus loading two
        // full dictionaries.
        var leftFiles = try await reader.recursiveFiles(rootNodeID: left.rootNodeID)
        var diff = SnapshotDiff()
        let limit = 500
        try await reader.forEachFile(rootNodeID: right.rootNodeID) { path, file in
            if let previous = leftFiles.removeValue(forKey: path) {
                if previous.contentHash != file.contentHash
                    || previous.kind != file.kind
                    || previous.linkTarget != file.linkTarget {
                    diff.modified += 1
                    if diff.files.count < limit {
                        diff.files.append(ChangedFile(
                            path: path,
                            kind: .modified,
                            detail: previous.contentHash == nil
                                ? "内容变化"
                                : "\(previous.contentHash!.prefix(8)) → \(file.contentHash?.prefix(8) ?? "—")"
                        ))
                    } else {
                        diff.isTruncated = true
                    }
                }
            } else {
                diff.added += 1
                if diff.files.count < limit {
                    diff.files.append(ChangedFile(path: path, kind: .added))
                } else {
                    diff.isTruncated = true
                }
            }
            return true
        }
        diff.removed = leftFiles.count
        for path in leftFiles.keys.sorted() {
            if diff.files.count < limit {
                diff.files.append(ChangedFile(path: path, kind: .removed))
            } else {
                diff.isTruncated = true
            }
        }
        return diff
    }

    /// Full verification: every node is readable and every referenced chunk
    /// decrypts to exactly the bytes the manifest promises. This downloads the
    /// version's data, which is what "云端完整性" means — an existence check would
    /// not catch corruption.
    public func verify(snapshotID: String) async throws -> VerificationResult {
        let projectID = try await projectID(for: snapshotID)
        let reader = restorer()
        let manifest = try await reader.manifest(projectID: projectID, snapshotID: snapshotID)
        var bytes: Int64 = 0
        var chunks = 0
        var files = 0
        var errors: [String] = []
        // Remote-only verification: no DiskChunkCache is passed here, and the
        // verifier reads actual object/pack bytes. A cache hit can never prove a
        // cloud object exists.
        let verifier = RemoteIntegrityVerifier(masterKey: masterKey, source: source)

        func walk(_ node: DirectoryNode) async throws {
            for file in node.files {
                switch file.kind {
                case .directory, .symlink:
                    continue
                case .file:
                    do {
                        var hasher = SHA256()
                        for chunk in file.chunks {
                            let data = try await verifier.verifiedChunk(chunk)
                            try await index.markChunkVerified(chunk.objectID, at: clock())
                            hasher.update(data: data)
                            bytes += Int64(data.count)
                            chunks += 1
                        }
                        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                        if let expected = file.contentHash, expected != digest {
                            errors.append("\(file.path)：内容哈希不一致")
                        }
                        files += 1
                    } catch {
                        errors.append("\(file.path)：\(error)")
                    }
                }
            }
            for directory in node.directories {
                let child = try await source.readNode(directory.nodeID)
                try await walk(child)
            }
        }
        try await walk(try await source.readNode(manifest.rootNodeID))

        return VerificationResult(
            snapshotID: snapshotID,
            projectID: projectID,
            level: .cloudIntegrity,
            outcome: errors.isEmpty ? .passed : .failed,
            details: errors.isEmpty
                ? "云端版本完整：\(files) 个文件，\(chunks) 个数据块"
                : errors.prefix(10).joined(separator: "；"),
            bytesChecked: bytes
        )
    }

    // MARK: - Helpers

    private func projectID(for snapshotID: String) async throws -> UUID {
        guard let id = await snapshotProjectProvider(snapshotID) else {
            throw CodeTimeError.snapshotNotFound(snapshotID)
        }
        return id
    }

    private func restorer(sourceRoots: [URL] = []) -> CloudRestoreEngine {
        CloudRestoreEngine(
            masterKey: masterKey,
            source: source,
            options: RestoreOptions(
                verifyHashes: true,
                cache: cache,
                sourceRoots: sourceRoots
            )
        )
    }
}

extension CloudRestoreEngine {
    /// The manifest lookup is needed by the adapter; expose it under the name the
    /// adapter uses instead of pretending a file exists when it does not.
    public func manifest(projectID: UUID, snapshotID: String) async throws -> SnapshotManifest {
        try await loadManifest(projectID: projectID, snapshotID: snapshotID)
    }

    /// All non-directory nodes in a tree, keyed by relative path.
    public func recursiveFiles(rootNodeID: String) async throws -> [String: FileNode] {
        var result: [String: FileNode] = [:]
        try await forEachFile(rootNodeID: rootNodeID) { path, file in
            result[path] = file
            return true
        }
        return result
    }

    /// Streaming tree walk. Only one directory node is held at a time, and the
    /// visitor can stop early so search/diff limits never load the whole tree.
    public func forEachFile(
        rootNodeID: String,
        visit: (String, FileNode) async throws -> Bool
    ) async throws {
        var keepGoing = true
        func walk(_ node: DirectoryNode) async throws {
            guard keepGoing else { return }
            for file in node.files.sorted(by: { $0.path < $1.path }) {
                guard try await visit(file.path, file) else {
                    keepGoing = false
                    return
                }
            }
            for directory in node.directories.sorted(by: { $0.name < $1.name }) {
                guard keepGoing else { return }
                try await walk(try await source.readNode(directory.nodeID))
            }
        }
        try await walk(try await source.readNode(rootNodeID))
    }

    /// True when the path names a directory in this snapshot.
    func directoryNodeForTarget(projectID: UUID, snapshotID: String, path: String) async throws -> Bool {
        let manifest = try await loadManifest(projectID: projectID, snapshotID: snapshotID)
        do {
            _ = try await directoryNode(at: path, rootNodeID: manifest.rootNodeID)
            return true
        } catch CloudRestoreError.pathNotFound {
            return false
        }
    }
}
