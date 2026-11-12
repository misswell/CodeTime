import Foundation
import CryptoKit
import SharedModels
import CodeTimeSecurity

public enum CloudRestoreError: Error, Sendable, Equatable {
    case commitMissing(String)
    case manifestCorrupt
    case manifestHashMismatch
    case snapshotNotFound(String)
    case pathNotFound(String)
    case invalidPath(String)
    case destinationExists(String)
    case chunkMissing(String)
    case fileHashMismatch(path: String)
    case fileTooLarge(path: String, size: Int64, limit: Int)
    case cancelled

    public var diagnosticCode: String {
        switch self {
        case .commitMissing, .snapshotNotFound: return "ICLOUD_MANIFEST_UNREADABLE"
        case .manifestCorrupt, .manifestHashMismatch: return "ICLOUD_MANIFEST_UNREADABLE"
        case .pathNotFound: return "ICLOUD_RESTORE_FAILED"
        case .chunkMissing: return "ICLOUD_OBJECT_CORRUPTED"
        case .fileHashMismatch: return "ICLOUD_OBJECT_CORRUPTED"
        case .invalidPath, .destinationExists: return "ICLOUD_RESTORE_FAILED"
        case .fileTooLarge: return "ICLOUD_RESTORE_FAILED"
        case .cancelled: return "ICLOUD_RESTORE_FAILED"
        }
    }
}

/// How object bytes are sourced during restore/verification.
public enum ObjectReadPolicy: String, Sendable, Equatable {
    /// Normal restore: a verified cached chunk is acceptable.
    case cachePreferred
    /// Ignore cached bytes but still populate the cache with fetched data.
    case remoteOnly
    /// Never read or write the cache; every byte must come from the remote store.
    case verifyRemote
}

public enum RestoreTarget: Sendable, Equatable {
    case project
    case directory(path: String)
    case file(path: String)
}

/// Complete boundary for a restore. Normal restores carry every registered
/// source root; recovery carries the app/data/cloud roots even when no local
/// source exists. `validate` is bidirectional and component-wise.
public struct RestoreProtectedRoots: Sendable, Equatable {
    public var sourceRoots: [URL]
    public var protectedRoots: [URL]

    public init(sourceRoots: [URL], protectedRoots: [URL] = []) {
        self.sourceRoots = sourceRoots
        self.protectedRoots = protectedRoots
    }

    public func validate(_ destination: URL) throws {
        for root in sourceRoots + protectedRoots where CloudRestoreEngine.pathsOverlap(destination, root) {
            throw CloudRestoreError.invalidPath(
                "恢复目标与受保护目录重叠：\(destination.path) ↔ \(root.path)"
            )
        }
    }
}

public struct RestoreOptions: Sendable {
    /// Replace an existing destination. Default false: restore never clobbers a
    /// directory the user already has.
    public var overwriteDestination: Bool
    /// Re-hash every restored file against the manifest. Default true.
    public var verifyHashes: Bool
    /// Bounded chunk cache; nil disables caching (every chunk downloaded).
    public var cache: RestoreObjectCache?
    public var readPolicy: ObjectReadPolicy
    /// Original project roots this restore must never write into. The service
    /// and adapter always supply every registered project.
    public var sourceRoots: [URL]
    /// App data, lifecycle, repository and cloud roots that must never receive
    /// restore writes even during disaster recovery.
    public var protectedRoots: [URL]
    public init(
        overwriteDestination: Bool = false,
        verifyHashes: Bool = true,
        cache: RestoreObjectCache? = nil,
        readPolicy: ObjectReadPolicy = .cachePreferred,
        sourceRoots: [URL] = [],
        protectedRoots: [URL] = []
    ) {
        self.overwriteDestination = overwriteDestination
        self.verifyHashes = verifyHashes
        self.cache = cache
        self.readPolicy = readPolicy
        self.sourceRoots = sourceRoots
        self.protectedRoots = protectedRoots
    }

    public var boundary: RestoreProtectedRoots {
        RestoreProtectedRoots(sourceRoots: sourceRoots, protectedRoots: protectedRoots)
    }

    public static let `default` = RestoreOptions()
}

public struct CloudRestoreReport: Sendable, Equatable {
    public var snapshotID: String
    public var filesRestored: Int
    public var directoriesCreated: Int
    public var symlinksRestored: Int
    public var filesSkippedExisting: Int
    public var bytesWritten: Int64
    public var chunksDownloaded: Int
    public var chunksFromCache: Int
    public var packsDownloaded: Int
    public var commited: Bool
    /// Content is complete but one or more POSIX mode/mtime restores failed.
    /// This is reported, never silently treated as fully successful.
    public var metadataIncompleteCount: Int
    public var metadataWarnings: [String]

    public init(
        snapshotID: String,
        filesRestored: Int = 0,
        directoriesCreated: Int = 0,
        symlinksRestored: Int = 0,
        filesSkippedExisting: Int = 0,
        bytesWritten: Int64 = 0,
        chunksDownloaded: Int = 0,
        chunksFromCache: Int = 0,
        packsDownloaded: Int = 0,
        commited: Bool = false,
        metadataIncompleteCount: Int = 0,
        metadataWarnings: [String] = []
    ) {
        self.snapshotID = snapshotID
        self.filesRestored = filesRestored
        self.directoriesCreated = directoriesCreated
        self.symlinksRestored = symlinksRestored
        self.filesSkippedExisting = filesSkippedExisting
        self.bytesWritten = bytesWritten
        self.chunksDownloaded = chunksDownloaded
        self.chunksFromCache = chunksFromCache
        self.packsDownloaded = packsDownloaded
        self.commited = commited
        self.metadataIncompleteCount = metadataIncompleteCount
        self.metadataWarnings = metadataWarnings
    }
}

/// On-demand restore for Cloud Format v3.
///
/// Only the chunks a file actually needs are downloaded — restoring one file does
/// not pull the project, and restoring a directory does not pull its siblings.
/// Everything is written into a staging directory and verified against the
/// manifest's content hash before the destination is touched, so a failed or
/// interrupted restore leaves the user's existing tree exactly as it was.
public struct CloudRestoreEngine: Sendable {
    private let masterKey: Data
    let source: CloudObjectSource
    private let options: RestoreOptions
    private let chunker: ChunkerConfig

    public init(
        masterKey: Data,
        source: CloudObjectSource,
        options: RestoreOptions = .default,
        chunker: ChunkerConfig = .default
    ) {
        self.masterKey = masterKey
        self.source = source
        self.options = options
        self.chunker = chunker
    }

    public static func manifestContext(projectID: UUID, snapshotID: String) -> String {
        "v3:manifest:\(projectID.uuidString):\(snapshotID)"
    }

    // MARK: - Manifest

    public func loadManifest(projectID: UUID, snapshotID: String) async throws -> SnapshotManifest {
        guard let commit = try await source.readCommit(projectID: projectID, snapshotID: snapshotID) else {
            throw CloudRestoreError.commitMissing(snapshotID)
        }
        let payload = try await source.readManifestPayload(projectID: projectID, snapshotID: snapshotID)
        guard CanonicalHashing.sha256Hex(payload) == commit.manifestPayloadHash else {
            throw CloudRestoreError.manifestHashMismatch
        }
        let plaintext: Data
        do {
            plaintext = try CryptoBox.open(
                payload,
                masterKey: masterKey,
                context: Self.manifestContext(projectID: projectID, snapshotID: snapshotID)
            )
        } catch {
            throw CloudRestoreError.manifestCorrupt
        }
        let manifest = try JSONDecoder().decode(SnapshotManifest.self, from: plaintext)
        guard manifest.digestMatches else {
            throw CloudRestoreError.manifestCorrupt
        }
        return manifest
    }

    // MARK: - Restore

    public func restore(
        projectID: UUID,
        snapshotID: String,
        target: RestoreTarget,
        destination: URL,
        isCancelled: @Sendable () -> Bool = { false }
    ) async throws -> CloudRestoreReport {
        // A normal restore must name the source boundary. Without it the engine
        // cannot prove the destination is independent, so it fails closed. Only
        // an explicit disaster-recovery export (no local source) may omit it.
        guard !options.sourceRoots.isEmpty else {
            throw CloudRestoreError.invalidPath(
                "恢复必须提供原始项目边界；未提供边界的普通恢复已拒绝"
            )
        }
        // Overwriting is not a restore primitive anymore. Even a caller that
        // bypasses the service must not be able to replace an existing tree,
        // including an original project. A fresh destination is mandatory.
        guard !options.overwriteDestination else {
            throw CloudRestoreError.invalidPath(
                "覆盖恢复已禁用：CodeTime 只允许恢复到独立的新目录"
            )
        }
        // Refuse before reading the manifest: a destination that equals, lives
        // inside, or contains an original project can never be written to.
        try options.boundary.validate(destination)
        let manifest = try await loadManifest(projectID: projectID, snapshotID: snapshotID)
        var report = CloudRestoreReport(snapshotID: snapshotID)

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            throw CloudRestoreError.destinationExists(destination.path)
        }

        let packCache = PackCache(limit: 2)
        // Staging identity includes the full snapshot ID, the restore target and
        // the destination hash. Reusing staging from a different target would
        // leak old files into the exported tree.
        let staging = Self.stagingURL(
            for: destination,
            snapshotID: snapshotID,
            target: target
        )
        try Self.ensureSafeStagingDirectory(
            staging,
            destination: destination,
            sourceRoots: options.sourceRoots + options.protectedRoots
        )
        let fs = try RestoreDirectoryFS(rootURL: staging)
        let journalFS = try RestoreDirectoryFS(rootURL: staging.deletingLastPathComponent())
        let journalName = ".\(staging.lastPathComponent)-journal.jsonl"
        let journal = try RestoreJournal(
            directory: journalFS,
            name: journalName,
            identity: staging.lastPathComponent
        )
        defer { journal.close() }

        // Resolve target → the directory node to walk and an optional single file.
        let startNode: DirectoryNode
        var singleFile: FileNode?
        switch target {
        case .project:
            startNode = try await source.readNode(manifest.rootNodeID)
        case .directory(let path):
            startNode = try await node(at: path, rootNodeID: manifest.rootNodeID)
        case .file(let path):
            let parentPath = MerkleTreeBuilder.parentPath(of: path)
            let parent = parentPath.isEmpty
                ? try await source.readNode(manifest.rootNodeID)
                : try await node(at: parentPath, rootNodeID: manifest.rootNodeID)
            let name = MerkleTreeBuilder.lastComponent(of: path)
            guard let node = parent.files.first(where: { $0.path == path || $0.path.hasSuffix("/" + name) }) else {
                throw CloudRestoreError.pathNotFound(path)
            }
            singleFile = node
            startNode = parent
        }

        if let singleFile {
            // A single-file restore lands as `<destination>/<name>` rather than
            // reproducing the whole relative path the user did not ask for.
            try await restoreFile(
                singleFile,
                writingTo: MerkleTreeBuilder.lastComponent(of: singleFile.path),
                into: staging,
                fs: fs,
                report: &report,
                packCache: packCache,
                journal: journal,
                isCancelled: isCancelled
            )
        } else {
            var symlinks: [FileNode] = []
            try await restoreDirectory(
                startNode,
                basePath: startNode.path,
                into: staging,
                fs: fs,
                report: &report,
                packCache: packCache,
                journal: journal,
                symlinks: &symlinks,
                isCancelled: isCancelled
            )
            // Symlinks are created last: no later write can be redirected through
            // a symlink planted by the version being restored.
            for link in symlinks {
                if isCancelled() { throw CloudRestoreError.cancelled }
                try await restoreSymlink(link, into: staging, fs: fs, report: &report, journal: journal)
            }
        }

        journal.flush()
        journal.close()
        try? journalFS.remove(journalName)

        // The destination was proven absent before staging began. Re-check right
        // before the commit so a concurrently created path is never replaced.
        guard !fm.fileExists(atPath: destination.path) else {
            throw CloudRestoreError.destinationExists(destination.path)
        }
        try fm.moveItem(at: staging, to: destination)
        report.commited = true
        return report
    }

    // MARK: - Tree walking

    func node(at path: String, rootNodeID: String) async throws -> DirectoryNode {
        guard !path.isEmpty else {
            return try await source.readNode(rootNodeID)
        }
        var current = try await source.readNode(rootNodeID)
        for component in path.split(separator: "/").map(String.init) {
            guard let entry = current.directories.first(where: { $0.name == component }) else {
                throw CloudRestoreError.pathNotFound(path)
            }
            current = try await source.readNode(entry.nodeID)
        }
        return current
    }

    private func restoreDirectory(
        _ node: DirectoryNode,
        basePath: String,
        into staging: URL,
        fs: RestoreDirectoryFS,
        report: inout CloudRestoreReport,
        packCache: PackCache,
        journal: RestoreJournal,
        symlinks: inout [FileNode],
        isCancelled: @Sendable () -> Bool
    ) async throws {
        let relative = node.path.isEmpty ? basePath : node.path
        _ = try safeURL(for: relative, in: staging)
        if !relative.isEmpty, !fs.exists(relative) {
            try fs.ensureDirectory(relative)
            report.directoriesCreated += 1
        }

        // Regular files first, then subdirectories, then symlinks (collected for
        // a final pass). This ordering prevents writes through restored links.
        for file in node.files where file.kind != .symlink {
            if isCancelled() { throw CloudRestoreError.cancelled }
            try await restoreFile(
                file, writingTo: file.path, into: staging, fs: fs,
                report: &report, packCache: packCache, journal: journal,
                isCancelled: isCancelled
            )
        }
        for directory in node.directories {
            if isCancelled() { throw CloudRestoreError.cancelled }
            let child = try await source.readNode(directory.nodeID)
            try await restoreDirectory(
                child,
                basePath: basePath,
                into: staging,
                fs: fs,
                report: &report,
                packCache: packCache,
                journal: journal,
                symlinks: &symlinks,
                isCancelled: isCancelled
            )
        }
        for file in node.files where file.kind == .symlink {
            symlinks.append(file)
        }
        // Directory metadata is applied after children exist, otherwise writing a
        // child would change the timestamps again.
        applyDirectoryMetadata(
            path: relative,
            mode: node.mode,
            modifiedAt: node.modifiedAt,
            fs: fs,
            report: &report
        )
    }

    private func restoreFile(
        _ file: FileNode,
        writingTo relative: String,
        into staging: URL,
        fs: RestoreDirectoryFS,
        report: inout CloudRestoreReport,
        packCache: PackCache,
        journal: RestoreJournal,
        isCancelled: @Sendable () -> Bool
    ) async throws {
        _ = try safeURL(for: relative, in: staging)

        switch file.kind {
        case .directory:
            if !fs.exists(relative) {
                try fs.ensureDirectory(relative)
                report.directoriesCreated += 1
            }
            applyDirectoryMetadata(
                path: file.path,
                mode: file.mode,
                modifiedAt: file.modifiedAt,
                fs: fs,
                report: &report
            )
            return
        case .symlink:
            try await restoreSymlink(file, into: staging, fs: fs, report: &report, journal: journal)
            return
        case .file:
            break
        }

        // Resume only a file that proves it is complete: size and hash must match.
        if let existing = try fs.readFile(relative),
           Int64(existing.count) == file.size,
           let expected = file.contentHash,
           CanonicalHashing.sha256Hex(existing) == expected {
            report.filesSkippedExisting += 1
            try journal.append(RestoreJournalEntry(
                snapshotID: report.snapshotID,
                path: relative,
                expectedSize: file.size,
                expectedHash: expected,
                restoredSize: Int64(existing.count),
                completed: true
            ))
            return
        }

        let partial = relative + ".partial"
        try? fs.remove(partial)
        let handle = FileHandle(
            fileDescriptor: try fs.openFile(
                partial,
                flags: O_WRONLY | O_CREAT | O_TRUNC
            ),
            closeOnDealloc: true
        )
        var hasher = SHA256()
        var written: Int64 = 0
        do {
            for chunk in file.chunks {
                if isCancelled() {
                    try? handle.close()
                    try? fs.remove(partial)
                    throw CloudRestoreError.cancelled
                }
                let result = try await readVerifiedChunk(chunk, packCache: packCache)
                if result.fromCache {
                    report.chunksFromCache += 1
                } else {
                    report.chunksDownloaded += 1
                    report.packsDownloaded += result.packsDownloaded
                }
                hasher.update(data: result.data)
                try handle.write(contentsOf: result.data)
                written += Int64(result.data.count)
            }
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? fs.remove(partial)
            throw error
        }

        // Basic correctness cannot be disabled: length and full-file SHA-256 are
        // always checked before the file becomes visible.
        guard written == file.size else {
            try? fs.remove(partial)
            throw CloudRestoreError.fileHashMismatch(path: relative)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let expected = file.contentHash, digest != expected {
            try? fs.remove(partial)
            throw CloudRestoreError.fileHashMismatch(path: relative)
        }
        if file.mode != nil || file.modifiedAt != nil {
            do {
                try fs.applyMetadata(partial, mode: file.mode, modifiedAt: file.modifiedAt)
            } catch {
                report.metadataIncompleteCount += 1
                report.metadataWarnings.append("\(relative)：权限/时间恢复失败：\(error.localizedDescription)")
            }
        }
        if fs.exists(relative) {
            try fs.remove(relative)
        }
        try fs.rename(partial, to: relative)
        try journal.append(RestoreJournalEntry(
            snapshotID: report.snapshotID,
            path: relative,
            expectedSize: file.size,
            expectedHash: file.contentHash,
            restoredSize: written,
            completed: true
        ))
        report.filesRestored += 1
        report.bytesWritten += written
    }

    private func restoreSymlink(
        _ file: FileNode,
        into staging: URL,
        fs: RestoreDirectoryFS,
        report: inout CloudRestoreReport,
        journal: RestoreJournal
    ) async throws {
        _ = try safeURL(for: file.path, in: staging)
        let linkTarget = file.linkTarget ?? ""
        guard !linkTarget.isEmpty else { throw CloudRestoreError.fileHashMismatch(path: file.path) }
        if let existing = try fs.readSymlink(file.path) {
            // Resume is only safe if the existing link points at the same target;
            // an unrelated symlink must never be silently accepted.
            if existing == linkTarget {
                report.filesSkippedExisting += 1
                return
            }
            throw CloudRestoreError.invalidPath(file.path)
        }
        if fs.exists(file.path) {
            throw CloudRestoreError.invalidPath(file.path)
        }
        try fs.createSymlink(target: linkTarget, at: file.path)
        try journal.append(RestoreJournalEntry(
            snapshotID: report.snapshotID,
            path: file.path,
            expectedSize: file.size,
            expectedHash: file.contentHash,
            restoredSize: 0,
            completed: true
        ))
        report.symlinksRestored += 1
    }

    // MARK: - Browsing / single-file read

    /// Directory listing straight from the manifest's tree. Directories come
    /// first, then files, both sorted by path so the UI is stable.
    public func listDirectory(
        projectID: UUID,
        snapshotID: String,
        path: String
    ) async throws -> [FileEntry] {
        let manifest = try await loadManifest(projectID: projectID, snapshotID: snapshotID)
        let node = try await directoryNode(at: path, rootNodeID: manifest.rootNodeID)
        var entries: [FileEntry] = []
        for directory in node.directories {
            let childPath = node.path.isEmpty
                ? directory.name
                : node.path + "/" + directory.name
            entries.append(FileEntry(
                path: childPath,
                name: directory.name,
                isDirectory: true,
                size: directory.totalBytes
            ))
        }
        for file in node.files {
            entries.append(FileEntry(
                path: file.path,
                name: MerkleTreeBuilder.lastComponent(of: file.path),
                isDirectory: file.kind == .directory,
                isSymlink: file.kind == .symlink,
                size: file.size,
                modifiedAt: file.modifiedAt,
                objectID: file.contentHash
            ))
        }
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            return $0.path < $1.path
        }
    }

    /// Reads exactly one file, downloading only the chunks it references.
    public func readFileData(
        projectID: UUID,
        snapshotID: String,
        path: String,
        maxBytes: Int,
        isCancelled: @Sendable () -> Bool = { false }
    ) async throws -> Data {
        let manifest = try await loadManifest(projectID: projectID, snapshotID: snapshotID)
        guard let file = try await fileNode(path: path, rootNodeID: manifest.rootNodeID) else {
            throw CloudRestoreError.pathNotFound(path)
        }
        guard file.kind == .file else {
            throw CloudRestoreError.pathNotFound(path)
        }
        if file.size > Int64(maxBytes) {
            throw CloudRestoreError.fileTooLarge(path: path, size: file.size, limit: maxBytes)
        }

        let packCache = PackCache(limit: 2)
        var data = Data()
        data.reserveCapacity(Int(file.size))
        for chunk in file.chunks {
            if isCancelled() { throw CloudRestoreError.cancelled }
            let decoded = try await decodedChunk(chunk, packCache: packCache)
            data.append(decoded)
            if data.count > maxBytes {
                throw CloudRestoreError.fileTooLarge(path: path, size: file.size, limit: maxBytes)
            }
        }
        if let expected = file.contentHash {
            guard CanonicalHashing.sha256Hex(data) == expected else {
                throw CloudRestoreError.fileHashMismatch(path: path)
            }
        }
        return data
    }

    func directoryNode(at path: String, rootNodeID: String) async throws -> DirectoryNode {
        let resolved = try await node(at: path, rootNodeID: rootNodeID)
        if path.isEmpty { return resolved }
        let parentPath = MerkleTreeBuilder.parentPath(of: path)
        let parent = parentPath.isEmpty
            ? try await source.readNode(rootNodeID)
            : try await node(at: parentPath, rootNodeID: rootNodeID)
        let name = MerkleTreeBuilder.lastComponent(of: path)
        if parent.files.contains(where: { MerkleTreeBuilder.lastComponent(of: $0.path) == name }) {
            throw CloudRestoreError.pathNotFound(path)
        }
        return resolved
    }

    func fileNode(path: String, rootNodeID: String) async throws -> FileNode? {
        let parentPath = MerkleTreeBuilder.parentPath(of: path)
        let parent = parentPath.isEmpty
            ? try await source.readNode(rootNodeID)
            : try await node(at: parentPath, rootNodeID: rootNodeID)
        let name = MerkleTreeBuilder.lastComponent(of: path)
        return parent.files.first { file in
            file.path == path || MerkleTreeBuilder.lastComponent(of: file.path) == name
        }
    }

    struct VerifiedChunk {
        var data: Data
        var fromCache: Bool
        var packsDownloaded: Int
    }

    /// The one verified read path used by both full restore and previews.
    /// Cache → pack → standalone; AEAD, object identity and plaintext size are
    /// always checked, and only a verified plaintext is written to the cache.
    func readVerifiedChunk(_ chunk: ChunkRef, packCache: PackCache) async throws -> VerifiedChunk {
        if options.readPolicy == .cachePreferred,
           let cache = options.cache,
           let cached = try await cache.cachedChunk(objectID: chunk.objectID) {
            return VerifiedChunk(data: cached, fromCache: true, packsDownloaded: 0)
        }
        var packsDownloaded = 0
        let payload: Data
        if let packID = chunk.packID {
            let pack: Data
            if let cached = packCache.get(packID) {
                pack = cached
            } else {
                pack = try await source.readPack(packID)
                packCache.put(packID, pack)
                packsDownloaded = 1
            }
            payload = try ObjectPackReader().object(chunk.objectID, in: pack)
        } else {
            payload = try await source.readObject(chunk.objectID)
        }
        let data = try ObjectEncoder(masterKey: masterKey).decode(
            payload,
            objectID: chunk.objectID,
            expectingSize: Int(chunk.plaintextSize)
        )
        if options.readPolicy != .verifyRemote, let cache = options.cache {
            try await cache.storeChunk(objectID: chunk.objectID, data: data)
        }
        return VerifiedChunk(data: data, fromCache: false, packsDownloaded: packsDownloaded)
    }

    func decodedChunk(_ chunk: ChunkRef, packCache: PackCache) async throws -> Data {
        try await readVerifiedChunk(chunk, packCache: packCache).data
    }

    private func applyDirectoryMetadata(
        path: String,
        mode: UInt16?,
        modifiedAt: Date?,
        fs: RestoreDirectoryFS,
        report: inout CloudRestoreReport
    ) {
        do {
            try fs.applyMetadata(path, mode: mode, modifiedAt: modifiedAt)
        } catch {
            report.metadataIncompleteCount += 1
            report.metadataWarnings.append(
                "\(path)：目录权限/时间恢复失败：\(error.localizedDescription)"
            )
        }
    }

    /// Bidirectional, component-wise overlap check on resolved paths. Kept local
    /// to BackupEngine so the engine enforces the invariant even when called
    /// without CodeTimeCore's SafePath helper.
    static func pathsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
        // Case-fold: default macOS volumes are case-insensitive, and a false
        // positive is safer than writing through a case-variant source path.
        let left = lhs.standardizedFileURL.resolvingSymlinksInPath().pathComponents.map { $0.lowercased() }
        let right = rhs.standardizedFileURL.resolvingSymlinksInPath().pathComponents.map { $0.lowercased() }
        let shared = min(left.count, right.count)
        return Array(left.prefix(shared)) == Array(right.prefix(shared))
    }

    static func stagingURL(
        for destination: URL,
        snapshotID: String,
        target: RestoreTarget,
        caseSensitive: Bool? = nil
    ) -> URL {
        let targetKey: String
        switch target {
        case .project:
            targetKey = "project"
        case .directory(let path):
            targetKey = "directory:" + path
        case .file(let path):
            targetKey = "file:" + path
        }
        let resolvedDestination = destination.standardizedFileURL
            .resolvingSymlinksInPath().path
        let detectedCaseSensitivity: Bool
        if let caseSensitive {
            detectedCaseSensitivity = caseSensitive
        } else {
            let volume = destination.deletingLastPathComponent()
            detectedCaseSensitivity = (try? volume.resourceValues(
                forKeys: [.volumeSupportsCaseSensitiveNamesKey]
            ))?.volumeSupportsCaseSensitiveNames ?? true
        }
        // On case-sensitive volumes /Export and /export are different targets;
        // only fold case when the volume actually ignores it.
        let destinationPath = detectedCaseSensitivity
            ? resolvedDestination
            : resolvedDestination.lowercased()
        let material = "\(snapshotID)\u{0}\(targetKey)\u{0}\(destinationPath)"
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".codetime-restore-\(digest.prefix(32))",
                isDirectory: true
            )
    }

    /// Creates staging without following a pre-planted symlink and verifies the
    /// real directory is disjoint from every source root. `mkdir` does not follow
    /// a symlink at the final component; O_NOFOLLOW re-proves the result.
    static func ensureSafeStagingDirectory(
        _ staging: URL,
        destination: URL,
        sourceRoots: [URL]
    ) throws {
        // Check before creating anything: a parent symlink can make the staging
        // path resolve into a source project.
        for source in sourceRoots {
            if Self.pathsOverlap(staging, source) || Self.pathsOverlap(destination, source) {
                throw CloudRestoreError.invalidPath(
                    "恢复临时目录位于原始项目内，已拒绝：\(staging.path)"
                )
            }
        }
        let parent = staging.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var info = stat()
        if lstat(staging.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw CloudRestoreError.invalidPath(
                    "恢复 staging 不是真实目录，已拒绝：\(staging.path)"
                )
            }
        } else if errno != ENOENT {
            throw CloudRestoreError.invalidPath(
                "无法检查恢复 staging：\(staging.path)"
            )
        } else if mkdir(staging.path, 0o700) != 0 {
            throw CloudRestoreError.invalidPath(
                "无法创建恢复 staging：\(staging.path)"
            )
        }

        guard lstat(staging.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw CloudRestoreError.invalidPath(
                "恢复 staging 被符号链接或文件替换：\(staging.path)"
            )
        }
        let fd = open(staging.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw CloudRestoreError.invalidPath(
                "恢复 staging 未通过 O_NOFOLLOW 校验：\(staging.path)"
            )
        }
        close(fd)

        // A symlinked parent can redirect the staging path after lexical checks.
        // Compare the real staging and destination paths against source roots.
        for source in sourceRoots {
            if Self.pathsOverlap(staging, source) || Self.pathsOverlap(destination, source) {
                throw CloudRestoreError.invalidPath(
                    "恢复临时目录位于原始项目内，已拒绝：\(staging.path)"
                )
            }
        }
    }

    // MARK: - Path safety

    /// Rejects absolute paths, `..` and anything that resolves outside staging.
    /// A malicious or corrupted manifest must not be able to write outside the
    /// restore directory (or through a symlinked parent).
    func safeURL(for relativePath: String, in staging: URL) throws -> URL {
        guard !relativePath.isEmpty else { return staging }
        guard !relativePath.hasPrefix("/") else {
            throw CloudRestoreError.invalidPath(relativePath)
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CloudRestoreError.invalidPath(relativePath)
        }
        let candidate = staging.appendingPathComponent(relativePath)
        let resolvedStaging = staging.resolvingSymlinksInPath().standardizedFileURL.path
        let parent = candidate.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        guard parent == resolvedStaging || parent.hasPrefix(resolvedStaging + "/") else {
            throw CloudRestoreError.invalidPath(relativePath)
        }
        return candidate
    }
}

/// Append-only restore journal. It is diagnostic/audit state kept outside the
/// staging tree; completeness is always re-proved from the file bytes.
struct RestoreJournalEntry: Codable, Sendable {
    var snapshotID: String
    var path: String
    var expectedSize: Int64
    var expectedHash: String?
    var restoredSize: Int64
    var completed: Bool
}

final class RestoreJournal: @unchecked Sendable {
    private let handle: FileHandle?
    private let lock = NSLock()

    struct Header: Codable, Sendable {
        var version: Int
        var identity: String
        var createdAt: Date
    }

    init(directory: RestoreDirectoryFS, name: String, identity: String) throws {
        // The journal is opened relative to the staging parent directory FD, so a
        // pre-planted symlink at any path component cannot redirect the write.
        let fd = try directory.openFile(
            name,
            flags: O_WRONLY | O_CREAT | O_APPEND
        )
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        handle.seekToEndOfFile()
        var info = stat()
        if fstat(fd, &info) == 0, info.st_size == 0 {
            var header = try JSONEncoder().encode(Header(
                version: 2,
                identity: identity,
                createdAt: Date()
            ))
            header.append(0x0A)
            try handle.write(contentsOf: header)
            try handle.synchronize()
        }
        self.handle = handle
    }

    func append(_ entry: RestoreJournalEntry) throws {
        guard let handle else { throw CloudRestoreError.invalidPath("恢复日志不可写") }
        var data = try JSONEncoder().encode(entry)
        data.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        try handle.write(contentsOf: data)
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.synchronize()
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
    }
}

/// Tiny LRU for packs during a restore. A pack can hold many small objects, so
/// keeping the last two avoids re-downloading for sibling chunks while bounding
/// memory to a couple of pack sizes.
final class PackCache: @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private var order: [String] = []
    private let limit: Int
    private let lock = NSLock()

    init(limit: Int = 2) { self.limit = max(1, limit) }

    func get(_ key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let data = storage[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return data
    }

    func put(_ key: String, _ data: Data) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = data
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit {
            let evicted = order.removeFirst()
            storage.removeValue(forKey: evicted)
        }
    }
}
