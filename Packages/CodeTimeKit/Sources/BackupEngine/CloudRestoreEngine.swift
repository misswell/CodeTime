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

public enum RestoreTarget: Sendable, Equatable {
    case project
    case directory(path: String)
    case file(path: String)
}

public struct RestoreOptions: Sendable {
    /// Replace an existing destination. Default false: restore never clobbers a
    /// directory the user already has.
    public var overwriteDestination: Bool
    /// Re-hash every restored file against the manifest. Default true.
    public var verifyHashes: Bool
    /// Bounded chunk cache; nil disables caching (every chunk downloaded).
    public var cache: RestoreObjectCache?

    public init(
        overwriteDestination: Bool = false,
        verifyHashes: Bool = true,
        cache: RestoreObjectCache? = nil
    ) {
        self.overwriteDestination = overwriteDestination
        self.verifyHashes = verifyHashes
        self.cache = cache
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
        commited: Bool = false
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
        let manifest = try await loadManifest(projectID: projectID, snapshotID: snapshotID)
        var report = CloudRestoreReport(snapshotID: snapshotID)

        let fm = FileManager.default
        let destinationExists = fm.fileExists(atPath: destination.path)
        if destinationExists && !options.overwriteDestination {
            throw CloudRestoreError.destinationExists(destination.path)
        }

        let packCache = PackCache(limit: 2)
        // Deterministic staging per (destination, snapshot): an interrupted run
        // can resume and skip files that already hash correctly. It stays hidden
        // and is removed by the successful atomic move.
        let staging = Self.stagingURL(for: destination, snapshotID: snapshotID)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

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
                report: &report,
                packCache: packCache,
                isCancelled: isCancelled
            )
        } else {
            try await restoreDirectory(
                startNode,
                basePath: startNode.path,
                into: staging,
                report: &report,
                packCache: packCache,
                isCancelled: isCancelled
            )
        }

        // Commit: nothing user-visible happens until every byte is written and
        // (optionally) re-hashed.
        if destinationExists {
            var trashed: NSURL?
            try fm.trashItem(at: destination, resultingItemURL: &trashed)
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
        report: inout CloudRestoreReport,
        packCache: PackCache,
        isCancelled: @Sendable () -> Bool
    ) async throws {
        let fm = FileManager.default
        let target = try safeURL(for: node.path.isEmpty ? basePath : node.path, in: staging)
        if !fm.fileExists(atPath: target.path) {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            report.directoriesCreated += 1
        }

        for file in node.files {
            if isCancelled() { throw CloudRestoreError.cancelled }
            try await restoreFile(
                file, writingTo: file.path, into: staging,
                report: &report, packCache: packCache, isCancelled: isCancelled
            )
        }
        for directory in node.directories {
            if isCancelled() { throw CloudRestoreError.cancelled }
            let child = try await source.readNode(directory.nodeID)
            try await restoreDirectory(
                child,
                basePath: basePath,
                into: staging,
                report: &report,
                packCache: packCache,
                isCancelled: isCancelled
            )
        }
    }

    private func restoreFile(
        _ file: FileNode,
        writingTo relative: String,
        into staging: URL,
        report: inout CloudRestoreReport,
        packCache: PackCache,
        isCancelled: @Sendable () -> Bool
    ) async throws {
        let fm = FileManager.default
        let target = try safeURL(for: relative, in: staging)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

        switch file.kind {
        case .directory:
            if !fm.fileExists(atPath: target.path) {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                report.directoriesCreated += 1
            }
            return
        case .symlink:
            if fm.fileExists(atPath: target.path) {
                report.filesSkippedExisting += 1
                return
            }
            let linkTarget = file.linkTarget ?? ""
            guard !linkTarget.isEmpty else { throw CloudRestoreError.fileHashMismatch(path: relative) }
            try fm.createSymbolicLink(atPath: target.path, withDestinationPath: linkTarget)
            report.symlinksRestored += 1
            return
        case .file:
            break
        }

        // Resume: a staged file that already hashes correctly is kept.
        if fm.fileExists(atPath: target.path),
           let existing = try? Data(contentsOf: target),
           options.verifyHashes == false || CanonicalHashing.sha256Hex(existing) == file.contentHash {
            report.filesSkippedExisting += 1
            return
        }

        fm.createFile(atPath: target.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: target) else {
            throw CloudRestoreError.fileHashMismatch(path: relative)
        }
        var hasher = SHA256()
        var written: Int64 = 0
        do {
            for chunk in file.chunks {
                if isCancelled() {
                    try? handle.close()
                    throw CloudRestoreError.cancelled
                }
                let data: Data
                if let cache = options.cache,
                   let cached = try await cache.cachedChunk(objectID: chunk.objectID) {
                    data = cached
                    report.chunksFromCache += 1
                } else {
                    let payload: Data
                    if let packID = chunk.packID {
                        let pack: Data
                        if let cached = packCache.get(packID) {
                            pack = cached
                        } else {
                            pack = try await source.readPack(packID)
                            packCache.put(packID, pack)
                            report.packsDownloaded += 1
                        }
                        payload = try ObjectPackReader().object(chunk.objectID, in: pack)
                    } else {
                        payload = try await source.readObject(chunk.objectID)
                    }
                    data = try ObjectEncoder(masterKey: masterKey).decode(
                        payload,
                        objectID: chunk.objectID,
                        expectingSize: Int(chunk.plaintextSize)
                    )
                    if let cache = options.cache {
                        try await cache.storeChunk(objectID: chunk.objectID, data: data)
                    }
                    report.chunksDownloaded += 1
                }
                hasher.update(data: data)
                try handle.write(contentsOf: data)
                written += Int64(data.count)
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if options.verifyHashes, let expected = file.contentHash, digest != expected {
            try? fm.removeItem(at: target)
            throw CloudRestoreError.fileHashMismatch(path: relative)
        }
        if let mode = file.mode {
            try? fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: target.path)
        }
        if let modified = file.modifiedAt {
            try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: target.path)
        }
        // Bound the cache to roughly one file's worth of overshoot. Pinned entries
        // still win, and a failure to enforce never affects the restored file.
        if let cache = options.cache as? DiskChunkCache {
            _ = try? await cache.enforceBudget()
        }
        report.filesRestored += 1
        report.bytesWritten += written
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
        if options.verifyHashes, let expected = file.contentHash {
            guard CanonicalHashing.sha256Hex(data) == expected else {
                throw CloudRestoreError.fileHashMismatch(path: path)
            }
        }
        if let cache = options.cache as? DiskChunkCache {
            _ = try? await cache.enforceBudget()
        }
        return data
    }

    func directoryNode(at path: String, rootNodeID: String) async throws -> DirectoryNode {
        let resolved = try await node(at: path, rootNodeID: rootNodeID)
        // A path that names a file is not a directory.
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

    /// One chunk: cache → pack → standalone object, then decrypt and check the
    /// plaintext size. Never trusts the local index over the actual bytes.
    func decodedChunk(_ chunk: ChunkRef, packCache: PackCache) async throws -> Data {
        if let cache = options.cache, let cached = try await cache.cachedChunk(objectID: chunk.objectID) {
            return cached
        }
        let payload: Data
        if let packID = chunk.packID {
            let pack: Data
            if let cached = packCache.get(packID) {
                pack = cached
            } else {
                pack = try await source.readPack(packID)
                packCache.put(packID, pack)
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
        if let cache = options.cache {
            try await cache.storeChunk(objectID: chunk.objectID, data: data)
        }
        return data
    }

    static func stagingURL(for destination: URL, snapshotID: String) -> URL {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in destination.standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".codetime-restore-\(snapshotID.prefix(8))-\(String(hash, radix: 16))",
                isDirectory: true
            )
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
