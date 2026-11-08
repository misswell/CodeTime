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
