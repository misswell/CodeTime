import Foundation

/// A snapshot-creation and restore engine. Implementations must not modify user files
/// except inside `restore`, and writes are always explicit.
public protocol BackupEngine: Sendable {
    func ensureRepository() async throws

    func createSnapshot(
        project: Project,
        policy: BackupPolicy,
        trigger: BackupTrigger
    ) async throws -> Snapshot

    func listSnapshots(project: Project) async throws -> [Snapshot]

    func listDirectory(snapshotID: String, path: String) async throws -> [FileEntry]

    func readFile(snapshotID: String, path: String, maxBytes: Int) async throws -> Data

    func restore(
        snapshotID: String,
        path: String?,
        destination: URL,
        overwrite: Bool
    ) async throws

    func diff(from snapshotA: String, to snapshotB: String) async throws -> SnapshotDiff

    func verify(snapshotID: String) async throws -> VerificationResult
}

/// Cloud mirror abstraction. Generations are only visible once fully uploaded and
/// their manifest has been published.
public protocol CloudStore: Sendable {
    func publish(
        repositoryId: UUID,
        generation: CloudGeneration
    ) async throws

    func listGenerations(
        repositoryId: UUID
    ) async throws -> [CloudGeneration]

    func restoreRepository(
        generationId: UUID,
        destination: URL
    ) async throws

    func verifyGeneration(_ generationId: UUID) async throws -> VerificationResult

    func storageSummary(repositoryId: UUID) async throws -> CloudStorageSummary

    func cleanup(
        repositoryId: UUID,
        gracePeriod: TimeInterval,
        minimumGenerations: Int
    ) async throws -> CloudCleanupReport
}

public struct CloudCleanupReport: Codable, Hashable, Sendable {
    public var deletedObjects: Int
    public var freedBytes: Int64
    public var retainedGenerations: Int
    public var skippedReason: String?
    /// CT-105: objects that WOULD be deleted. Populated even when physical
    /// deletion is disabled, so the UI can show a safe cleanup preview.
    public var plannedDeletes: Int
    /// Generations that would be retired (tombstoned) by a full GC run.
    public var plannedGenerationDeletes: Int

    public init(
        deletedObjects: Int = 0,
        freedBytes: Int64 = 0,
        retainedGenerations: Int = 0,
        skippedReason: String? = nil,
        plannedDeletes: Int = 0,
        plannedGenerationDeletes: Int = 0
    ) {
        self.deletedObjects = deletedObjects
        self.freedBytes = freedBytes
        self.retainedGenerations = retainedGenerations
        self.skippedReason = skippedReason
        self.plannedDeletes = plannedDeletes
        self.plannedGenerationDeletes = plannedGenerationDeletes
    }
}

public protocol CloudUploadTracking: Sendable {
    /// Wait until the file has been confirmed as uploaded by the storage provider.
    func waitForUpload(_ url: URL, timeout: TimeInterval) async throws
}

public protocol MasterKeyProviding: Sendable {
    func masterKey() throws -> Data
}

public protocol RepositoryPasswordProviding: Sendable {
    func repositoryPassword() throws -> String
}

public protocol ActivityLogging: Sendable {
    func log(_ event: ActivityEvent) async
}

public protocol GitCapturing: Sendable {
    func capture(repositoryPath: String) -> GitMetadata?
}

public struct VerificationReport: Codable, Hashable, Sendable {
    public var errorCount: Int
    public var details: String
    public var bytesChecked: Int64

    public init(errorCount: Int = 0, details: String = "", bytesChecked: Int64 = 0) {
        self.errorCount = errorCount
        self.details = details
        self.bytesChecked = bytesChecked
    }
}

// MARK: - Cloud Format v3 seams

/// Where v3 objects, nodes, manifests and commit markers go. Implemented by
/// `CloudObjectStoreV3` on the real container and by an in-memory double in tests.
public protocol CloudObjectSink: Sendable {
    func hasObject(_ objectID: String) async throws -> Bool
    @discardableResult
    func putObject(_ payload: Data, objectID: String) async throws -> Bool
    @discardableResult
    func putNode(_ node: DirectoryNode) async throws -> Bool
    /// Immutable pack of already-encrypted objects (see ObjectPackFormat).
    @discardableResult
    func putPack(_ payload: Data, packID: String) async throws -> Bool
    func hasPack(_ packID: String) async throws -> Bool
    /// Returns the SHA-256 of the stored payload; the commit marker binds to it.
    func putManifest(_ payload: Data, projectID: UUID, snapshotID: String) async throws -> String
    /// Must only succeed when the manifest exists and still matches its hash.
    func putCommit(_ commit: SnapshotCommit) async throws
}

/// The rebuildable local index the engine consults before doing work.
public protocol CloudSnapshotIndex: Sendable {
    func fileNodes(projectID: UUID) async throws -> [FileNode]
    func replaceFileIndex(projectID: UUID, files: [FileNode], snapshotID: String) async throws
    func knownObjectIDs(_ objectIDs: [String]) async throws -> Set<String>
    /// Full records for known chunks. A packed chunk must be reused through its
    /// pack reference — the object does not exist as a standalone cloud item.
    func knownChunks(_ objectIDs: [String]) async throws -> [String: ChunkRecordV3]
    func upsertChunks(_ chunks: [ChunkRecordV3]) async throws
    func upsertSnapshot(_ record: SnapshotRecordV3) async throws
    func updateSnapshot(
        _ snapshotID: String,
        uploadState: SnapshotUploadState?,
        commitState: SnapshotCommitState?,
        manifestPayloadHash: String?
    ) async throws
    func snapshotRecords(projectID: UUID, limit: Int) async throws -> [SnapshotRecordV3]
    func enqueueUploads(_ uploads: [PendingUploadV3]) async throws
    func removeUpload(_ taskID: String) async throws
    /// Durable upload journal: everything still owed to the cloud, including
    /// tasks that failed or were interrupted mid-upload.
    func pendingUploads(state: UploadTaskState?, limit: Int) async throws -> [PendingUploadV3]
    func updateUploadState(_ taskID: String, state: UploadTaskState, bumpRetry: Bool) async throws
    func pendingUploadBytes() async throws -> Int64
}

/// Read side of Cloud Format v3, used by restore and verification.
public protocol CloudObjectSource: Sendable {
    func readObject(_ objectID: String) async throws -> Data
    func readPack(_ packID: String) async throws -> Data
    func readNode(_ nodeID: String) async throws -> DirectoryNode
    func readManifestPayload(projectID: UUID, snapshotID: String) async throws -> Data
    func readCommit(projectID: UUID, snapshotID: String) async throws -> SnapshotCommit?
    func commits(projectID: UUID) async throws -> [SnapshotCommit]
}

/// Small bounded cache for decrypted chunks during restore.
public protocol RestoreObjectCache: Sendable {
    func cachedChunk(objectID: String) async throws -> Data?
    func storeChunk(objectID: String, data: Data) async throws
}

/// Cache bookkeeping for the bounded download cache.
public protocol ChunkCacheIndex: Sendable {
    func cacheEntry(_ key: String) async throws -> CacheEntryV3?
    func upsertCacheEntry(_ entry: CacheEntryV3) async throws
    func cacheEntries(pinned: Bool?, limit: Int) async throws -> [CacheEntryV3]
    func removeCacheEntry(_ key: String) async throws
    func cacheBytes() async throws -> Int64
}

/// Migration journal seam (lives here so Persistence can conform without
/// depending on the engine).
public protocol MigrationJournaling: Sendable {
    func appendMigrationEvent(_ entry: MigrationJournalEntryV3) async throws
    func latestMigrationPhase() async throws -> String?
}
