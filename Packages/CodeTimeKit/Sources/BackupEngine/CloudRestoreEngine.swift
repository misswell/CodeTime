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

public struct RestoreOptions: Sendable {
    /// Replace an existing destination. Default false: restore never clobbers a
    /// directory the user already has.
    public var overwriteDestination: Bool
    /// Re-hash every restored file against the manifest. Default true.
    public var verifyHashes: Bool
    /// Bounded chunk cache; nil disables caching (every chunk downloaded).
    public var cache: RestoreObjectCache?
    public var readPolicy: ObjectReadPolicy

    public init(
        overwriteDestination: Bool = false,
        verifyHashes: Bool = true,
        cache: RestoreObjectCache? = nil,
        readPolicy: ObjectReadPolicy = .cachePreferred
    ) {
        self.overwriteDestination = overwriteDestination
        self.verifyHashes = verifyHashes
        self.cache = cache
        self.readPolicy = readPolicy
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
        let journalURL = staging.deletingLastPathComponent()
            .appendingPathComponent(".\(staging.lastPathComponent)-journal.jsonl")
        let journal = try RestoreJournal(url: journalURL)
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
                try await restoreSymlink(link, into: staging, report: &report, journal: journal)
            }
        }

        journal.flush()
        journal.close()
        try? fm.removeItem(at: journalURL)

        // Commit with rollback: an existing destination is moved aside, never
        // deleted before the new tree is in place.
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".codetime-backup-\(UUID().uuidString)", isDirectory: true)
        var movedAside = false
        if destinationExists {
            try fm.moveItem(at: destination, to: backup)
            movedAside = true
        }
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch {
            if movedAside {
                try? fm.moveItem(at: backup, to: destination)
            }
            throw error
        }
        if movedAside {
            var trashed: NSURL?
            try? fm.trashItem(at: backup, resultingItemURL: &trashed)
        }
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
        journal: RestoreJournal,
        symlinks: inout [FileNode],
        isCancelled: @Sendable () -> Bool
    ) async throws {
        let fm = FileManager.default
        let target = try safeURL(for: node.path.isEmpty ? basePath : node.path, in: staging)
        if !fm.fileExists(atPath: target.path) {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            report.directoriesCreated += 1
        }

        // Regular files first, then subdirectories, then symlinks (collected for
        // a final pass). This ordering prevents writes through restored links.
        for file in node.files where file.kind != .symlink {
            if isCancelled() { throw CloudRestoreError.cancelled }
            try await restoreFile(
                file, writingTo: file.path, into: staging,
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
        if let mode = node.mode {
            try? fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: target.path)
        }
        if let modified = node.modifiedAt {
            try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: target.path)
        }
    }

    private func restoreFile(
        _ file: FileNode,
        writingTo relative: String,
        into staging: URL,
        report: inout CloudRestoreReport,
        packCache: PackCache,
        journal: RestoreJournal,
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
            if let mode = file.mode {
                try? fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: target.path)
            }
            if let modified = file.modifiedAt {
                try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: target.path)
            }
            return
        case .symlink:
            try await restoreSymlink(file, into: staging, report: &report, journal: journal)
            return
        case .file:
            break
        }

        // Resume only a file that proves it is complete: size and hash must match.
        if let existingSize = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil,
           Int64(existingSize) == file.size,
           let expected = file.contentHash,
           let existing = try? Data(contentsOf: target),
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

        let partial = target.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        guard let handle = openNoFollow(partial) else {
            throw CloudRestoreError.fileHashMismatch(path: relative)
        }
        var hasher = SHA256()
        var written: Int64 = 0
        do {
            for chunk in file.chunks {
                if isCancelled() {
                    try? handle.close()
                    try? fm.removeItem(at: partial)
                    throw CloudRestoreError.cancelled
                }
                let data: Data
                if options.readPolicy == .cachePreferred,
                   let cache = options.cache,
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
                    if options.readPolicy != .verifyRemote, let cache = options.cache {
                        try await cache.storeChunk(objectID: chunk.objectID, data: data)
                    }
                    report.chunksDownloaded += 1
                }
                hasher.update(data: data)
                try handle.write(contentsOf: data)
                written += Int64(data.count)
            }
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(at: partial)
            throw error
        }

        // Basic correctness cannot be disabled: length and full-file SHA-256 are
        // always checked before the file becomes visible.
        guard written == file.size else {
            try? fm.removeItem(at: partial)
            throw CloudRestoreError.fileHashMismatch(path: relative)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let expected = file.contentHash, digest != expected {
            try? fm.removeItem(at: partial)
            throw CloudRestoreError.fileHashMismatch(path: relative)
        }
        if file.mode != nil || file.modifiedAt != nil {
            var attributes: [FileAttributeKey: Any] = [:]
            if let mode = file.mode {
                attributes[.posixPermissions] = NSNumber(value: mode)
            }
            if let modified = file.modifiedAt {
                attributes[.modificationDate] = modified
            }
            try? fm.setAttributes(attributes, ofItemAtPath: partial.path)
        }
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.moveItem(at: partial, to: target)
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
        report: inout CloudRestoreReport,
        journal: RestoreJournal
    ) async throws {
        let fm = FileManager.default
        let target = try safeURL(for: file.path, in: staging)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let linkTarget = file.linkTarget ?? ""
        guard !linkTarget.isEmpty else { throw CloudRestoreError.fileHashMismatch(path: file.path) }
        if fm.fileExists(atPath: target.path) {
            // Resume is only safe if the existing link points at the same target;
            // an unrelated symlink must never be silently accepted.
            if let existing = try? fm.destinationOfSymbolicLink(atPath: target.path),
               existing == linkTarget {
                report.filesSkippedExisting += 1
                return
            }
            throw CloudRestoreError.invalidPath(file.path)
        }
        try fm.createSymbolicLink(atPath: target.path, withDestinationPath: linkTarget)
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

    /// One chunk: cache → pack → standalone object, then decrypt and check the
    /// plaintext size. Never trusts the local index over the actual bytes.
    func decodedChunk(_ chunk: ChunkRef, packCache: PackCache) async throws -> Data {
        if options.readPolicy == .cachePreferred,
           let cache = options.cache,
           let cached = try await cache.cachedChunk(objectID: chunk.objectID) {
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
        if options.readPolicy != .verifyRemote, let cache = options.cache {
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

    private func openNoFollow(_ url: URL) -> FileHandle? {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else { return nil }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
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

    init(url: URL) throws {
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        if handle == nil {
            throw CloudRestoreError.invalidPath("无法写入恢复日志：\(url.lastPathComponent)")
        }
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
