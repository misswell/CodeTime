import Foundation
import SharedModels
import Persistence
import BackupEngine
import CloudMirrorStore

/// BackupCoordinator provides a typed, narrow API over `CodeTimeService`
/// for snapshot creation and listing. Extracted from the ~2300-line
/// `CodeTimeService` to satisfy §13 architecture review.
public struct BackupCoordinator: Sendable {
    private let service: CodeTimeService

    public init(_ service: CodeTimeService) { self.service = service }

    @discardableResult
    public func createSnapshot(projectID: UUID, trigger: BackupTrigger) async throws -> BackupOutcome {
        try await service.createSnapshot(projectID: projectID, trigger: trigger)
    }

    public func dueProjects(now: Date = Date()) async throws -> [Project] {
        try await service.dueProjects(now: now)
    }

    public func refreshSnapshots(projectID: UUID) async throws -> [Snapshot] {
        try await service.refreshSnapshots(projectID: projectID)
    }

    public func snapshots(projectID: UUID? = nil, limit: Int = 500) async throws -> [Snapshot] {
        try await service.snapshots(projectID: projectID, limit: limit)
    }

    public func snapshot(id: String) async throws -> Snapshot? {
        try await service.snapshot(id: id)
    }

}

/// RestoreCoordinator provides a typed, narrow API over `CodeTimeService`
/// for restore and disaster recovery operations.
public struct RestoreCoordinator: Sendable {
    private let service: CodeTimeService

    public init(_ service: CodeTimeService) { self.service = service }

    @discardableResult
    public func restore(_ request: RestoreRequest) async throws -> RestoreJob {
        try await service.restore(request)
    }

    public func restoreJobs(limit: Int = 100) async throws -> [RestoreJob] {
        try await service.restoreJobs(limit: limit)
    }

    public func recoverFromCloud(candidate: RecoveryCandidate, storageRoot: URL,
                                 recoveryKeyText: String) async throws -> CloudRecoveryResult {
        try await service.recoverFromCloud(candidate: candidate, storageRoot: storageRoot,
                                           recoveryKeyText: recoveryKeyText)
    }

    public func installSecretsFromCloud(storageRoot: URL, recoveryKeyText: String) async throws {
        try await service.installSecretsFromCloud(storageRoot: storageRoot, recoveryKeyText: recoveryKeyText)
    }

    public func latestCloudRestoreJob() async throws -> CloudRestoreJob? {
        try await service.latestCloudRestoreJob()
    }
}

/// CloudPublishCoordinator provides a typed, narrow API over `CodeTimeService`
/// for cloud publish, summary and cleanup operations.
public struct CloudPublishCoordinator: Sendable {
    private let service: CodeTimeService

    public init(_ service: CodeTimeService) { self.service = service }

    public func cloudSummary() async throws -> CloudStorageSummary? {
        try await service.cloudSummary()
    }

    public func cloudGenerations() async throws -> [CloudGeneration] {
        try await service.cloudGenerations()
    }

    @discardableResult
    public func cleanupCloud() async throws -> CloudCleanupReport? {
        try await service.cleanupCloud()
    }

    @discardableResult
    public func verifyCloud() async throws -> VerificationResult? {
        try await service.verifyCloud()
    }

    public func runPeriodicVerificationIfNeeded() async {
        await service.runPeriodicVerificationIfNeeded()
    }

    public func cleanupCloudIfNeeded() async {
        await service.cleanupCloudIfNeeded()
    }
}

/// VerificationCoordinator provides a typed, narrow API over `CodeTimeService`
/// for snapshot and cloud verification operations.
public struct VerificationCoordinator: Sendable {
    private let service: CodeTimeService

    public init(_ service: CodeTimeService) { self.service = service }

    @discardableResult
    public func verifySnapshot(projectID: UUID, snapshotID: String) async throws -> VerificationResult {
        try await service.verifySnapshot(projectID: projectID, snapshotID: snapshotID)
    }

    @discardableResult
    public func verifyCloud() async throws -> VerificationResult? {
        try await service.verifyCloud()
    }

    public func runPeriodicVerificationIfNeeded() async {
        await service.runPeriodicVerificationIfNeeded()
    }
}
