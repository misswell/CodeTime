import Foundation
import CryptoKit
import SharedModels
import CodeTimeSecurity

public enum CloudFirstEngineError: Error, Sendable, Equatable {
    case scanIncomplete(reason: String, paths: [String])
    case unstableFile(path: String, attempts: Int)
    case fileReadFailed(path: String, detail: String)
    case uploadFailed(path: String, detail: String)
    case spoolFull(pendingBytes: Int64, limitBytes: Int64)
    case cancelled

    public var diagnosticCode: String {
        switch self {
        case .scanIncomplete: return "ICLOUD_DIRECTORY_UNAVAILABLE"
        case .unstableFile, .fileReadFailed: return "ICLOUD_RESTORE_FAILED"
        case .uploadFailed: return "ICLOUD_UPLOAD_FAILED"
        case .spoolFull: return "ICLOUD_UPLOAD_TIMEOUT"
        case .cancelled: return "ICLOUD_UPLOAD_TIMEOUT"
        }
    }
}

public struct BackupRunOptions: Sendable {
    public var chunker: ChunkerConfig
    /// Uploads in flight. 2 by default, 4 for a "balanced" profile.
    public var uploadConcurrency: Int
    /// Attempts for a file whose identity moves while it is being read.
    public var maxReadAttempts: Int
    /// Publish even when part of the tree could not be read. Default false: a
    /// snapshot that silently misses files is worse than a failed backup.
    public var allowIncompleteScan: Bool
    /// Pack encoded objects at or below this size into immutable packs instead of
    /// writing one iCloud item per chunk (CT-157). nil disables packing.
    public var packObjectsUpTo: Int?

    public init(
        chunker: ChunkerConfig = .default,
        uploadConcurrency: Int = 2,
        maxReadAttempts: Int = 3,
        allowIncompleteScan: Bool = false,
        packObjectsUpTo: Int? = 128 * 1024
    ) {
        self.chunker = chunker
        self.uploadConcurrency = max(1, uploadConcurrency)
        self.maxReadAttempts = max(1, maxReadAttempts)
        self.allowIncompleteScan = allowIncompleteScan
        self.packObjectsUpTo = packObjectsUpTo
    }

    public static let `default` = BackupRunOptions()
}

public struct BackupRunReport: Sendable, Equatable {
    public var snapshotID: String
    public var parentSnapshotID: String?
    public var filesScanned: Int
    public var filesChanged: Int
    public var filesReused: Int
    public var filesRemoved: Int
    public var bytesRead: Int64
    public var bytesUploaded: Int64
    public var bytesDeduped: Int64
    public var objectsUploaded: Int
    public var objectsReused: Int
    public var nodesUploaded: Int
    public var packsUploaded: Int
    public var nodeCount: Int
    public var totalBytes: Int64
    public var excludedFileCount: Int
    public var excludedSize: Int64
    public var committed: Bool
    public var manifestPayloadHash: String?
    /// Non-fatal notes (excluded content, allowed partial scans).
    public var notes: [String]

    public init(
        snapshotID: String,
        parentSnapshotID: String? = nil,
        filesScanned: Int = 0,
        filesChanged: Int = 0,
        filesReused: Int = 0,
        filesRemoved: Int = 0,
        bytesRead: Int64 = 0,
        bytesUploaded: Int64 = 0,
        bytesDeduped: Int64 = 0,
        objectsUploaded: Int = 0,
        objectsReused: Int = 0,
        nodesUploaded: Int = 0,
        packsUploaded: Int = 0,
        nodeCount: Int = 0,
        totalBytes: Int64 = 0,
        excludedFileCount: Int = 0,
        excludedSize: Int64 = 0,
        committed: Bool = false,
        manifestPayloadHash: String? = nil,
        notes: [String] = []
    ) {
        self.snapshotID = snapshotID
        self.parentSnapshotID = parentSnapshotID
        self.filesScanned = filesScanned
        self.filesChanged = filesChanged
        self.filesReused = filesReused
        self.filesRemoved = filesRemoved
        self.bytesRead = bytesRead
        self.bytesUploaded = bytesUploaded
        self.bytesDeduped = bytesDeduped
        self.objectsUploaded = objectsUploaded
        self.objectsReused = objectsReused
        self.nodesUploaded = nodesUploaded
        self.packsUploaded = packsUploaded
        self.nodeCount = nodeCount
        self.totalBytes = totalBytes
        self.excludedFileCount = excludedFileCount
        self.excludedSize = excludedSize
        self.committed = committed
        self.manifestPayloadHash = manifestPayloadHash
        self.notes = notes
    }
}

/// Cloud-first backup engine for Cloud Format v3.
///
/// Streaming end to end: a file is chunked, encoded, deduplicated and uploaded
/// chunk by chunk, so peak memory is one chunk plus one encoded object — never
/// the file, never the project. Nothing is copied into a local repository; after
/// the commit marker is confirmed the only local state is the index plus any
/// uploads that have not been confirmed yet.
///
/// Publication is ordered and observable:
/// chunks → nodes → manifest (encrypted) → commit marker.
/// A version that did not reach its commit marker is invisible to readers.
public struct CloudFirstBackupEngine: Sendable {
    private let masterKey: Data
    private let deviceID: String
    private let index: CloudSnapshotIndex
    private let sink: CloudObjectSink
    private let options: BackupRunOptions
    private let clock: @Sendable () -> Date

    public init(
        masterKey: Data,
        deviceID: String,
        index: CloudSnapshotIndex,
        sink: CloudObjectSink,
        options: BackupRunOptions = .default,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.masterKey = masterKey
        self.deviceID = deviceID
        self.index = index
        self.sink = sink
        self.options = options
        self.clock = clock
    }

    public func manifestContext(projectID: UUID, snapshotID: String) -> String {
        "v3:manifest:\(projectID.uuidString):\(snapshotID)"
    }

    // MARK: - Run

    public func run(
        projectID: UUID,
        root: URL,
        matcher: ExclusionMatcher,
        scanOptions: ScanOptions = .default,
        snapshotID: String = UUID().uuidString,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> BackupRunReport {
        if isCancelled() { throw CloudFirstEngineError.cancelled }

        let scanner = ProjectScanner(matcher: matcher, options: scanOptions)
        let scan = scanner.scan(root: root)
        if !scan.isComplete && !options.allowIncompleteScan {
            throw CloudFirstEngineError.scanIncomplete(
                reason: scan.truncatedReason ?? "项目扫描不完整",
                paths: Array(scan.permissionErrors.prefix(20))
            )
        }

        let previousFiles = try await index.fileNodes(projectID: projectID)
        let previousByPath = Dictionary(previousFiles.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let parent = try await index
            .snapshotRecords(projectID: projectID, limit: 20)
            .first { $0.isCommitted }

        var report = BackupRunReport(
            snapshotID: snapshotID,
            parentSnapshotID: parent?.snapshotID,
            filesScanned: scan.fileCount,
            excludedFileCount: scan.excludedCount,
            excludedSize: scan.excludedBytes
        )

        let encoder = ObjectEncoder(masterKey: masterKey)
        let packBuffer = options.packObjectsUpTo.map {
            PackBuffer(threshold: $0, sink: sink, builder: ObjectPackBuilder())
        }
        let registry = ObjectRegistry(
            known: try await index.knownChunks(previousFiles.flatMap { $0.chunks.map(\.objectID) })
        )

        // Reuse: unchanged size+mtime lets the previous node's chunk list stand.
        var pending: [ScannedEntry] = []
        var reused: [FileNode] = []
        var seen = Set<String>()
        for entry in scan.entries where entry.kind != .directory {
            seen.insert(entry.path)
            if let previous = previousByPath[entry.path],
               Self.looksUnchanged(entry: entry, previous: previous) {
                reused.append(previous)
                report.filesReused += 1
            } else {
                pending.append(entry)
            }
        }
        report.filesRemoved = previousByPath.keys.filter { !seen.contains($0) }.count
        report.filesChanged = pending.count

        if isCancelled() { throw CloudFirstEngineError.cancelled }

        var produced = reused
        if !pending.isEmpty {
            let results = try await withThrowingTaskGroup(
                of: (Int, FileNode, FileOutcome).self
            ) { group -> [(Int, FileNode, FileOutcome)] in
                var nextOffset = 0
                let window = min(options.uploadConcurrency, pending.count)

                func enqueue() {
                    guard nextOffset < pending.count else { return }
                    let offset = nextOffset
                    let entry = pending[offset]
                    nextOffset += 1
                    group.addTask {
                        let outcome = try await self.buildFileNode(
                            entry: entry,
                            root: root,
                            encoder: encoder,
                            registry: registry,
                            packBuffer: packBuffer,
                            isCancelled: isCancelled
                        )
                        return (offset, outcome.0, outcome.1)
                    }
                }

                for _ in 0..<window { enqueue() }
                var collected: [(Int, FileNode, FileOutcome)] = []
                while let result = try await group.next() {
                    collected.append(result)
                    enqueue()
                }
                return collected
            }

            for (_, node, outcome) in results.sorted(by: { $0.0 < $1.0 }) {
                produced.append(node)
                report.bytesRead += outcome.bytesRead
                report.bytesUploaded += outcome.bytesUploaded
                report.bytesDeduped += outcome.bytesDeduped
                report.objectsUploaded += outcome.objectsUploaded
                report.objectsReused += outcome.objectsReused
            }
        }

        // Flush packs and rewrite the references that landed in one.
        if let packBuffer {
            do {
                try await packBuffer.flush()
            } catch let error as UploadQueueError {
                throw Self.mapUploadError(error)
            }
            let locations = await packBuffer.locations
            report.packsUploaded = await packBuffer.uploadedPackCount
            if !locations.isEmpty {
                produced = produced.map { node in
                    var copy = node
                    copy.chunks = node.chunks.map { ref in
                        guard let location = locations[ref.objectID] else { return ref }
                        var updated = ref
                        updated.packID = location.packID
                        updated.packOffset = Int64(location.offset)
                        return updated
                    }
                    return copy.withComputedID()
                }
            }
        }

        // Structural entries (empty directories) must survive a restore.
        var scannedFiles: [ScannedFile] = produced.map { node in
            ScannedFile(
                path: node.path,
                kind: node.kind,
                size: node.size,
                modifiedAt: node.modifiedAt,
                mode: node.mode,
                linkTarget: node.linkTarget,
                contentHash: node.contentHash,
                chunks: node.chunks
            )
        }
        for entry in scan.entries where entry.kind == .directory {
            scannedFiles.append(
                ScannedFile(
                    path: entry.path,
                    kind: .directory,
                    size: 0,
                    modifiedAt: entry.modifiedAt,
                    mode: entry.mode
                )
            )
        }

        let tree = MerkleTreeBuilder().build(files: scannedFiles)

        // Nodes are content addressed: unchanged subtrees upload nothing.
        var nodesUploaded = 0
        for node in tree.directories {
            if try await sink.putNode(node) { nodesUploaded += 1 }
        }
        if try await sink.putNode(tree.root) { nodesUploaded += 1 }
        report.nodesUploaded = nodesUploaded
        report.nodeCount = tree.nodeCount
        report.totalBytes = tree.totalBytes

        let manifest = SnapshotManifest(
            snapshotID: snapshotID,
            projectID: projectID,
            deviceID: deviceID,
            createdAt: clock(),
            parentSnapshotID: parent?.snapshotID,
            rootNodeID: tree.root.nodeID,
            fileCount: tree.fileCount,
            totalBytes: tree.totalBytes,
            chunkCount: Set(tree.files.flatMap { $0.chunks.map(\.objectID) }).count,
            formatVersion: CloudFormatV3.version,
            keyVersion: encoder.keyVersion
        )
        let sealedManifest = try CryptoBox.seal(
            JSONEncoder().encode(manifest),
            masterKey: masterKey,
            context: manifestContext(projectID: projectID, snapshotID: snapshotID)
        )

        var record = SnapshotRecordV3(
            snapshotID: snapshotID,
            projectID: projectID,
            parentSnapshotID: parent?.snapshotID,
            createdAt: manifest.createdAt,
            rootNodeID: tree.root.nodeID,
            fileCount: manifest.fileCount,
            totalBytes: manifest.totalBytes,
            uploadState: .uploading,
            commitState: .pending
        )
        try await index.upsertSnapshot(record)

        let manifestHash = try await sink.putManifest(
            sealedManifest,
            projectID: projectID,
            snapshotID: snapshotID
        )
        record.manifestPayloadHash = manifestHash
        record.uploadState = .uploaded
        try await index.upsertSnapshot(record)

        // Commit last. If this throws, the version stays invisible — the correct
        // outcome for a half-published snapshot.
        let commit = SnapshotCommit(
            snapshotID: snapshotID,
            projectID: projectID,
            deviceID: deviceID,
            parentSnapshotID: parent?.snapshotID,
            committedAt: clock(),
            manifestPayloadHash: manifestHash,
            nodeCount: tree.nodeCount,
            fileCount: manifest.fileCount,
            totalBytes: manifest.totalBytes,
            formatVersion: CloudFormatV3.version
        )
        try await sink.putCommit(commit)
        record.commitState = .committed
        try await index.upsertSnapshot(record)

        // Index the committed tree. A crash here costs a rescan, never a false
        // "backed up", because the commit is already the source of truth.
        try await index.replaceFileIndex(
            projectID: projectID,
            files: tree.files,
            snapshotID: snapshotID
        )
        var chunkRecords: [String: ChunkRecordV3] = [:]
        for ref in tree.files.flatMap(\.chunks) where chunkRecords[ref.objectID] == nil {
            chunkRecords[ref.objectID] = ChunkRecordV3(
                objectID: ref.objectID,
                plaintextSize: Int(ref.plaintextSize),
                storedSize: Int(ref.storedSize),
                keyVersion: encoder.keyVersion,
                packID: ref.packID,
                packOffset: ref.packOffset,
                verifiedAt: nil // an upload is not a verified download
            )
        }
        try await index.upsertChunks(Array(chunkRecords.values))

        report.committed = true
        report.manifestPayloadHash = manifestHash
        if !scan.isComplete {
            report.notes.append("扫描不完整（allowIncompleteScan）：部分文件未纳入本快照")
        }
        if scan.excludedCount > 0 {
            report.notes.append("已按排除规则跳过 \(scan.excludedCount) 项（\(scan.excludedBytes) 字节）")
        }
        return report
    }

    // MARK: - Per file

    public struct FileOutcome: Sendable, Equatable {
        public var bytesRead: Int64
        public var bytesUploaded: Int64
        public var bytesDeduped: Int64
        public var objectsUploaded: Int
        public var objectsReused: Int

        public init(
            bytesRead: Int64 = 0,
            bytesUploaded: Int64 = 0,
            bytesDeduped: Int64 = 0,
            objectsUploaded: Int = 0,
            objectsReused: Int = 0
        ) {
            self.bytesRead = bytesRead
            self.bytesUploaded = bytesUploaded
            self.bytesDeduped = bytesDeduped
            self.objectsUploaded = objectsUploaded
            self.objectsReused = objectsReused
        }
    }

    func buildFileNode(
        entry: ScannedEntry,
        root: URL,
        encoder: ObjectEncoder,
        registry: ObjectRegistry,
        packBuffer: PackBuffer?,
        isCancelled: @Sendable () -> Bool
    ) async throws -> (FileNode, FileOutcome) {
        switch entry.kind {
        case .symlink:
            let node = FileNode(
                path: entry.path,
                kind: .symlink,
                size: entry.size,
                modifiedAt: entry.modifiedAt,
                mode: entry.mode,
                linkTarget: entry.linkTarget,
                contentHash: CanonicalHashing.sha256Hex(Data((entry.linkTarget ?? "").utf8)),
                chunks: []
            ).withComputedID()
            return (node, FileOutcome())
        case .directory:
            let node = FileNode(
                path: entry.path, kind: .directory, size: 0,
                modifiedAt: entry.modifiedAt, mode: entry.mode
            ).withComputedID()
            return (node, FileOutcome())
        case .file:
            break
        }

        let url = root.appendingPathComponent(entry.path)
        var attempt = 0
        while true {
            attempt += 1
            if isCancelled() { throw CloudFirstEngineError.cancelled }
            let before = ProjectScanner.identity(of: url)

            var refs: [ChunkRef] = []
            var digest = SHA256()
            var outcome = FileOutcome()

            do {
                var iterator = try FastCDCChunker(config: options.chunker).makeIterator(ofFile: url)
                while let chunk = try iterator.next(isCancelled: isCancelled) {
                    if isCancelled() { throw CloudFirstEngineError.cancelled }
                    digest.update(data: chunk.data)
                    outcome.bytesRead += Int64(chunk.size)

                    let objectID = encoder.objectID(for: chunk.data)
                    if let known = registry.chunk(objectID) {
                        outcome.bytesDeduped += Int64(chunk.size)
                        outcome.objectsReused += 1
                        // A packed chunk must keep its pack reference: the object
                        // does not exist as a standalone cloud item.
                        refs.append(
                            ChunkRef(
                                objectID: objectID,
                                plaintextSize: chunk.size,
                                storedSize: known.storedSize,
                                compression: 0,
                                packID: known.packID,
                                packOffset: known.packOffset
                            )
                        )
                        continue
                    }
                    if try await sink.hasObject(objectID) {
                        registry.insert(objectID, storedSize: chunk.size)
                        outcome.bytesDeduped += Int64(chunk.size)
                        outcome.objectsReused += 1
                        refs.append(Self.reusedRef(objectID: objectID, size: chunk.size))
                        continue
                    }
                    let encoded = try encoder.encode(chunk: chunk.data)
                    if let packBuffer, let threshold = options.packObjectsUpTo,
                       encoded.storedSize <= threshold {
                        // Small objects go into an immutable pack; the reference
                        // gets its pack offset after the flush.
                        try await packBuffer.append(objectID: objectID, payload: encoded.payload)
                    } else {
                        try await sink.putObject(encoded.payload, objectID: objectID)
                    }
                    registry.insert(objectID, storedSize: encoded.storedSize)
                    outcome.bytesUploaded += Int64(encoded.storedSize)
                    outcome.objectsUploaded += 1
                    refs.append(
                        ChunkRef(
                            objectID: objectID,
                            plaintextSize: encoded.originalSize,
                            storedSize: encoded.storedSize,
                            compression: encoded.compression.rawValue
                        )
                    )
                }
            } catch let error as ChunkerError {
                throw CloudFirstEngineError.fileReadFailed(path: entry.path, detail: "\(error)")
            } catch let error as UploadQueueError {
                throw Self.mapUploadError(error)
            } catch let error as CloudFirstEngineError {
                throw error
            } catch {
                throw CloudFirstEngineError.fileReadFailed(
                    path: entry.path,
                    detail: error.localizedDescription
                )
            }

            let after = ProjectScanner.identity(of: url)
            if let before, let after, before != after {
                // The file changed while streaming: discard and retry rather than
                // publish chunks that never existed in one consistent state.
                if attempt >= options.maxReadAttempts {
                    throw CloudFirstEngineError.unstableFile(path: entry.path, attempts: attempt)
                }
                continue
            }

            let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
            let node = FileNode(
                path: entry.path,
                kind: .file,
                size: outcome.bytesRead,
                modifiedAt: entry.modifiedAt,
                mode: entry.mode,
                contentHash: hash,
                chunks: refs
            ).withComputedID()
            return (node, outcome)
        }
    }

    /// A chunk that already exists remotely: plaintext size is authoritative,
    /// stored size is unknown without re-encoding and is reported as plaintext.
    static func reusedRef(objectID: String, size: Int) -> ChunkRef {
        ChunkRef(objectID: objectID, plaintextSize: size, storedSize: size, compression: 0)
    }

    static func mapUploadError(_ error: UploadQueueError) -> CloudFirstEngineError {
        switch error {
        case .spoolFull(let pending, let limit):
            return .spoolFull(pendingBytes: pending, limitBytes: limit)
        default:
            return .uploadFailed(path: "spool", detail: "\(error)")
        }
    }

    // MARK: - Reuse heuristic

    /// A file whose size and mtime match the index can reuse its chunks without
    /// reading. Content is still verified on restore; a `touch` only costs a
    /// re-read, never a wrong backup.
    static func looksUnchanged(entry: ScannedEntry, previous: FileNode) -> Bool {
        guard previous.kind == entry.kind else { return false }
        if entry.kind == .symlink {
            return previous.linkTarget == entry.linkTarget
        }
        guard previous.size == entry.size, previous.contentHash != nil else { return false }
        let previousModified = previous.modifiedAt?.timeIntervalSince1970 ?? 0
        let current = entry.modifiedAt?.timeIntervalSince1970 ?? 0
        // Filesystems differ in sub-second precision; 1s tolerance avoids churn.
        return abs(previousModified - current) <= 1
    }
}

/// Object IDs already handled in this run: duplicate chunks within one snapshot
/// (and across files) are uploaded exactly once. For known chunks the record is
/// kept, because a packed object must be referenced through its pack.
final class ObjectRegistry: @unchecked Sendable {
    struct Known: Sendable {
        var storedSize: Int
        var packID: String?
        var packOffset: Int64?
    }

    private var known: [String: Known]
    private let lock = NSLock()

    init(known: [String: ChunkRecordV3]) {
        self.known = known.mapValues {
            Known(storedSize: $0.storedSize, packID: $0.packID, packOffset: $0.packOffset)
        }
    }

    func chunk(_ id: String) -> Known? {
        lock.lock()
        defer { lock.unlock() }
        return known[id]
    }

    func insert(_ id: String, storedSize: Int) {
        lock.lock()
        defer { lock.unlock() }
        known[id] = Known(storedSize: storedSize, packID: nil, packOffset: nil)
    }
}

/// Accumulates small encrypted objects and flushes them into immutable packs.
/// Bounded by the pack builder's target size, so memory stays constant even for
/// projects with hundreds of thousands of tiny files.
actor PackBuffer {
    private let threshold: Int
    private let sink: CloudObjectSink
    private let builder: ObjectPackBuilder
    private var pending: [(objectID: String, payload: Data)] = []
    private var pendingBytes = 0
    /// Concurrent files can produce the same chunk before either consults the
    /// registry; a pack must contain each object exactly once.
    private var stagedIDs: Set<String> = []
    private(set) var locations: [String: (packID: String, offset: Int)] = [:]
    private(set) var uploadedPackCount = 0

    init(threshold: Int, sink: CloudObjectSink, builder: ObjectPackBuilder) {
        self.threshold = threshold
        self.sink = sink
        self.builder = builder
    }

    func append(objectID: String, payload: Data) async throws {
        guard locations[objectID] == nil, stagedIDs.insert(objectID).inserted else { return }
        pending.append((objectID, payload))
        pendingBytes += payload.count
        if pendingBytes >= builder.options.targetBytes {
            try await flush()
        }
    }

    func flush() async throws {
        guard !pending.isEmpty else { return }
        let packs = try builder.build(pending.map { (objectID: $0.objectID, payload: $0.payload) })
        for pack in packs {
            try await sink.putPack(pack.payload, packID: pack.packID)
            uploadedPackCount += 1
            for entry in pack.entries {
                locations[entry.objectID] = (pack.packID, entry.offset)
            }
        }
        pending.removeAll(keepingCapacity: true)
        pendingBytes = 0
        stagedIDs.removeAll(keepingCapacity: true)
    }
}
