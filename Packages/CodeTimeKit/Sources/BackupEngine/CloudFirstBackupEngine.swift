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
    /// Re-read every file at least once per calendar day. Size+mtime reuse is a
    /// performance heuristic, never a guarantee; this is the periodic full
    /// content verification §7.2 requires.
    public var verifyUnchangedContentDaily: Bool

    public init(
        chunker: ChunkerConfig = .default,
        uploadConcurrency: Int = 2,
        maxReadAttempts: Int = 3,
        allowIncompleteScan: Bool = false,
        packObjectsUpTo: Int? = 128 * 1024,
        verifyUnchangedContentDaily: Bool = true
    ) {
        self.chunker = chunker
        self.uploadConcurrency = max(1, uploadConcurrency)
        self.maxReadAttempts = max(1, maxReadAttempts)
        self.allowIncompleteScan = allowIncompleteScan
        self.packObjectsUpTo = packObjectsUpTo
        self.verifyUnchangedContentDaily = verifyUnchangedContentDaily
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
        var scan = scanner.scan(root: root, isCancelled: isCancelled)
        if isCancelled() { throw CloudFirstEngineError.cancelled }
        if !scan.isComplete && !options.allowIncompleteScan {
            throw CloudFirstEngineError.scanIncomplete(
                reason: scan.truncatedReason ?? "项目扫描不完整",
                paths: Array(scan.permissionErrors.prefix(20))
            )
        }

        var previousFiles = try await index.fileNodes(projectID: projectID)
        var previousByPath = Dictionary(previousFiles.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
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
        let registry = ObjectRegistry(
            known: try await index.knownChunks(previousFiles.flatMap { $0.chunks.map(\.objectID) })
        )
        let packBuffer = options.packObjectsUpTo.map {
            PackBuffer(
                threshold: $0,
                sink: sink,
                builder: ObjectPackBuilder(),
                registry: registry
            )
        }

        // Reuse: unchanged size+mtime lets the previous node's chunk list stand.
        // At least once per day every file is re-read (periodic full verification).
        let now = clock()
        let forceFullRead = options.verifyUnchangedContentDaily
            && parent.map { !Calendar.current.isDate($0.createdAt, inSameDayAs: now) } == true
        var pending: [ScannedEntry] = []
        var reused: [FileNode] = []
        var seen = Set<String>()
        for entry in scan.entries where entry.kind != .directory {
            seen.insert(entry.path)
            if !forceFullRead,
               let previous = previousByPath[entry.path],
               Self.looksUnchanged(entry: entry, previous: previous) {
                reused.append(previous)
                report.filesReused += 1
            } else {
                pending.append(entry)
            }
        }
        report.filesRemoved = previousByPath.keys.filter { !seen.contains($0) }.count
        report.filesChanged = pending.count
        // The reuse decision is complete. Release the previous index and path map
        // before chunking: holding a second copy of every FileNode through the
        // upload phase is what makes large projects exceed the memory budget.
        previousFiles.removeAll(keepingCapacity: false)
        previousByPath.removeAll(keepingCapacity: false)

        if isCancelled() { throw CloudFirstEngineError.cancelled }

        var produced = reused
        if !pending.isEmpty {
            let results = try await withThrowingTaskGroup(
                of: (Int, FileNode, FileOutcome).self
            ) { group -> [(Int, FileNode, FileOutcome)] in
                var nextOffset = 0
                let window = min(options.uploadConcurrency, pending.count)

                func enqueue() {
                    // Cancellation stops scheduling NEW files; files already in
                    // flight finish uploading their current chunk and are allowed
                    // to settle before the snapshot is abandoned.
                    guard !isCancelled() else { return }
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

        // Flush packs and rewrite the references that landed in one. A cancelled
        // run still lets an in-progress pack finish: those bytes are safe to reuse
        // and deleting them would only waste work; it must not publish, though.
        if let packBuffer {
            do {
                let locations = try await packBuffer.finalize()
                report.packsUploaded = await packBuffer.uploadedPackCount
                if !locations.isEmpty {
                    produced = produced.map { node in
                        var copy = node
                        copy.chunks = node.chunks.map { ref in
                            guard let location = locations[ref.objectID] else { return ref }
                            var updated = ref
                            updated.packID = location.packID
                            updated.packOffset = location.offset
                            return updated
                        }
                        return copy.withComputedID()
                    }
                }
            } catch let error as UploadQueueError {
                throw Self.mapUploadError(error)
            }
        }

        // Structural entries (empty directories) must survive a restore. Build
        // the ScannedFile array in place and release the FileNode array so the
        // two full representations do not coexist longer than necessary.
        var scannedFiles: [ScannedFile] = []
        scannedFiles.reserveCapacity(produced.count + scan.entries.count)
        for node in produced {
            scannedFiles.append(
                ScannedFile(
                    path: node.path,
                    kind: node.kind,
                    size: node.size,
                    modifiedAt: node.modifiedAt,
                    mode: node.mode,
                    linkTarget: node.linkTarget,
                    contentHash: node.contentHash,
                    chunks: node.chunks,
                    identity: node.identity
                )
            )
        }
        produced.removeAll(keepingCapacity: false)
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

        var directoryMetadata: [String: DirectoryMetadata] = [:]
        for entry in scan.entries where entry.kind == .directory {
            directoryMetadata[entry.path] = DirectoryMetadata(
                path: entry.path, mode: entry.mode, modifiedAt: entry.modifiedAt
            )
        }
        // From here on the run publishes metadata. A cancelled run must leave the
        // version invisible: uploaded objects stay reusable, but no nodes,
        // manifest or commit marker are published.
        if isCancelled() { throw CloudFirstEngineError.cancelled }
        let tree = MerkleTreeBuilder().buildInPlace(
            files: &scannedFiles,
            directoryMetadata: directoryMetadata
        )
        // The scanner entries are no longer needed once the tree owns the
        // metadata; drop them before node/manifest publication.
        directoryMetadata.removeAll(keepingCapacity: false)
        scan.entries.removeAll(keepingCapacity: false)

        // Nodes are content addressed: unchanged subtrees upload nothing.
        var nodesUploaded = 0
        for node in tree.directories {
            if isCancelled() { throw CloudFirstEngineError.cancelled }
            if try await sink.putNode(node) { nodesUploaded += 1 }
        }
        if isCancelled() { throw CloudFirstEngineError.cancelled }
        if try await sink.putNode(tree.root) { nodesUploaded += 1 }
        report.nodesUploaded = nodesUploaded
        report.nodeCount = tree.nodeCount
        report.totalBytes = tree.totalBytes

        if isCancelled() { throw CloudFirstEngineError.cancelled }
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

        if isCancelled() { throw CloudFirstEngineError.cancelled }
        let manifestHash = try await sink.putManifest(
            sealedManifest,
            projectID: projectID,
            snapshotID: snapshotID
        )
        record.manifestPayloadHash = manifestHash
        record.uploadState = .uploaded
        try await index.upsertSnapshot(record)

        // Commit last. If this throws, the version stays invisible — the correct
        // outcome for a half-published snapshot. Cancellation is checked here, at
        // the last point where publishing can still be prevented.
        if isCancelled() { throw CloudFirstEngineError.cancelled }
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
                chunks: [],
                identity: entry.identity
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
            // Open once and read from this descriptor. A path swap after opening
            // cannot redirect the bytes; O_NOFOLLOW rejects a symlink planted at
            // the final component.
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                if attempt >= options.maxReadAttempts {
                    throw CloudFirstEngineError.fileReadFailed(path: entry.path, detail: "无法打开文件")
                }
                continue
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            let before = ProjectScanner.identity(descriptor: descriptor)

            var refs: [ChunkRef] = []
            var digest = SHA256()
            var outcome = FileOutcome()

            do {
                var iterator = FastCDCChunker(config: options.chunker).makeIterator(handle: handle)
                while let chunk = try iterator.next(isCancelled: isCancelled) {
                    if isCancelled() { throw CloudFirstEngineError.cancelled }
                    digest.update(data: chunk.data)
                    outcome.bytesRead += Int64(chunk.size)

                    let objectID = encoder.objectID(for: chunk.data)
                    if let ready = await registry.readyLocation(objectID) {
                        outcome.bytesDeduped += Int64(chunk.size)
                        outcome.objectsReused += 1
                        // A packed chunk must keep its pack reference: the object
                        // does not exist as a standalone cloud item.
                        refs.append(
                            ChunkRef(
                                objectID: objectID,
                                plaintextSize: chunk.size,
                                storedSize: ready.storedSize,
                                compression: 0,
                                packID: ready.packID,
                                packOffset: ready.packOffset
                            )
                        )
                        continue
                    }
                    let encoded = try encoder.encode(chunk: chunk.data)
                    if let packBuffer, let threshold = options.packObjectsUpTo,
                       encoded.storedSize <= threshold {
                        // If a standalone writer already owns this ID, wait for its
                        // confirmed location instead of creating a second copy.
                        if await registry.isUploading(objectID) {
                            if let ready = try await registry.waitForReady(objectID) {
                                outcome.bytesDeduped += Int64(chunk.size)
                                outcome.objectsReused += 1
                                refs.append(
                                    ChunkRef(
                                        objectID: objectID,
                                        plaintextSize: chunk.size,
                                        storedSize: ready.storedSize,
                                        compression: 0,
                                        packID: ready.packID,
                                        packOffset: ready.packOffset
                                    )
                                )
                                continue
                            }
                        }
                        // Small objects go into an immutable pack. The reference is
                        // a placeholder until finalize() confirms the pack; the
                        // pack buffer deduplicates the same object ID across files.
                        let staged = try await packBuffer.append(
                            objectID: objectID,
                            payload: encoded.payload
                        )
                        if staged {
                            outcome.bytesUploaded += Int64(encoded.storedSize)
                            outcome.objectsUploaded += 1
                        } else {
                            outcome.bytesDeduped += Int64(chunk.size)
                            outcome.objectsReused += 1
                        }
                        refs.append(
                            ChunkRef(
                                objectID: objectID,
                                plaintextSize: encoded.originalSize,
                                storedSize: encoded.storedSize,
                                compression: encoded.compression.rawValue
                            )
                        )
                        continue
                    }

                    switch try await registry.acquireStandalone(objectID) {
                    case .ready(let ready):
                        outcome.bytesDeduped += Int64(chunk.size)
                        outcome.objectsReused += 1
                        refs.append(
                            ChunkRef(
                                objectID: objectID,
                                plaintextSize: chunk.size,
                                storedSize: ready.storedSize,
                                compression: 0,
                                packID: ready.packID,
                                packOffset: ready.packOffset
                            )
                        )
                    case .upload:
                        do {
                            let location = try await sink.ensureObjectReady(
                                objectID,
                                payload: encoded.payload,
                                storedSize: encoded.storedSize
                            )
                            await registry.complete(objectID, location: location)
                            outcome.bytesUploaded += Int64(encoded.storedSize)
                            outcome.objectsUploaded += 1
                            refs.append(
                                ChunkRef(
                                    objectID: objectID,
                                    plaintextSize: encoded.originalSize,
                                    storedSize: location.storedSize,
                                    compression: encoded.compression.rawValue,
                                    packID: location.packID,
                                    packOffset: location.packOffset
                                )
                            )
                        } catch {
                            await registry.fail(objectID, error: error)
                            throw error
                        }
                    }
                }
            } catch let error as ChunkerError {
                if case .cancelled = error {
                    throw CloudFirstEngineError.cancelled
                }
                throw CloudFirstEngineError.fileReadFailed(path: entry.path, detail: "\(error)")
            } catch let error as UploadQueueError {
                throw Self.mapUploadError(error)
            } catch let error as CloudFirstEngineError {
                throw error
            } catch {
                if isCancelled() || error is CancellationError {
                    throw CloudFirstEngineError.cancelled
                }
                throw CloudFirstEngineError.fileReadFailed(
                    path: entry.path,
                    detail: error.localizedDescription
                )
            }

            let after = ProjectScanner.identity(descriptor: descriptor)
            if let before, let after, before != after {
                // The file changed while streaming: discard and retry rather than
                // publish chunks that never existed in one consistent state.
                if attempt >= options.maxReadAttempts {
                    throw CloudFirstEngineError.unstableFile(path: entry.path, attempts: attempt)
                }
                continue
            }

            let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
            let modified = before.map { Date(timeIntervalSince1970: Double($0.modifiedNanos) / 1_000_000_000) }
                ?? entry.modifiedAt
            let node = FileNode(
                path: entry.path,
                kind: .file,
                size: outcome.bytesRead,
                modifiedAt: modified,
                mode: entry.mode,
                contentHash: hash,
                chunks: refs,
                identity: before
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
        // Without a stored identity (old index) content is re-read once; a size
        // and mtime match alone must never be treated as proof.
        guard let previousIdentity = previous.identity else { return false }
        return previousIdentity.matches(entry.identity)
    }
}
