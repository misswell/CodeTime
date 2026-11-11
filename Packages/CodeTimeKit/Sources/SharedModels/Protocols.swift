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
}
