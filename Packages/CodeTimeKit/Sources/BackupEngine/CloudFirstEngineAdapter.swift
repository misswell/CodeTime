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
            matcher: matcher
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
            totalSize: report.bytesRead,
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
        let projectID = try await projectID(for: snapshotID)
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
        _ = try await restorer(overwrite: overwrite).restore(
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
        let files = try await reader.recursiveFiles(rootNodeID: manifest.rootNodeID)
        let needle = query.lowercased()
        var entries: [FileEntry] = []
        var visited = 0
        var truncated = false
        var reason: String?
        for (path, file) in files.sorted(by: { $0.key < $1.key }) {
            visited += 1
            if visited > limits.maxFiles {
                truncated = true
                reason = "已达到文件上限 \(limits.maxFiles)"
                break
            }
            guard path.lowercased().contains(needle) else { continue }
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
                break
            }
        }
        return FileSearchResult(
            entries: entries,
            truncated: truncated,
            truncationReason: reason,
            visitedDirectories: 0,
            visitedFiles: visited,
            duration: clock().timeIntervalSince(started)
        )
    }

    public func diff(from snapshotA: String, to snapshotB: String) async throws -> SnapshotDiff {        let projectA = try await projectID(for: snapshotA)
        let projectB = try await projectID(for: snapshotB)
        guard projectA == projectB else {
            throw CodeTimeError.unsupported("只能比较同一项目的快照")
        }
        let reader = restorer()
        let left = try await reader.manifest(projectID: projectA, snapshotID: snapshotA)
        let right = try await reader.manifest(projectID: projectB, snapshotID: snapshotB)

        let leftFiles = try await reader.recursiveFiles(rootNodeID: left.rootNodeID)
        let rightFiles = try await reader.recursiveFiles(rootNodeID: right.rootNodeID)

        var diff = SnapshotDiff()
        let limit = 500
        for (path, file) in leftFiles where rightFiles[path] == nil {
            diff.removed += 1
            if diff.files.count < limit {
                diff.files.append(ChangedFile(path: path, kind: .removed))
            } else {
                diff.isTruncated = true
            }
        }
        for (path, file) in rightFiles {
            if let previous = leftFiles[path] {
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
        let packCache = PackCache(limit: 4)

        func walk(_ node: DirectoryNode) async throws {
            for file in node.files {
                switch file.kind {
                case .directory, .symlink:
                    continue
                case .file:
                    do {
                        var hasher = SHA256()
                        for chunk in file.chunks {
                            let data = try await reader.decodedChunk(
                                chunk,
                                packCache: packCache
                            )
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

    private func restorer(overwrite: Bool = false) -> CloudRestoreEngine {
        CloudRestoreEngine(
            masterKey: masterKey,
            source: source,
            options: RestoreOptions(
                overwriteDestination: overwrite,
                verifyHashes: true,
                cache: cache
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
        func walk(_ node: DirectoryNode) async throws {
            for file in node.files {
                result[file.path] = file
            }
            for directory in node.directories {
                try await walk(try await source.readNode(directory.nodeID))
            }
        }
        try await walk(try await source.readNode(rootNodeID))
        return result
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
