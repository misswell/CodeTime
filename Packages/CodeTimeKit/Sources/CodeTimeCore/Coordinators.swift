import Foundation
import SharedModels
import Persistence
import BackupEngine
import CloudMirrorStore

/// CT-113: Coordinators own real policy/business logic, not just forwarding.
/// Each one makes decisions (which projects to run, which jobs may retry, what a
/// resume implies) and aggregates results; the underlying IO still goes through
/// `CodeTimeService`, which stays the compatibility facade for the UI.
///
/// Dependency boundaries:
///   UI / Agent ──> Coordinator ──> CodeTimeService ──> Store / Engine / CloudStore
/// A coordinator never talks to another coordinator, so there is no cycle.

// MARK: - Backup

/// Owns the backup scheduling decisions: which due projects to run, how failures
/// are classified, and what the aggregate outcome is.
public struct BackupCoordinator: Sendable {
    private let service: CodeTimeService

    public init(_ service: CodeTimeService) { self.service = service }

    public struct BatchReport: Sendable {
        public var succeeded: [UUID] = []
        public var failed: [(projectID: UUID, message: String)] = []
        public var skipped: [UUID] = []

        public init() {}
        public var isClean: Bool { failed.isEmpty }
    }

    @discardableResult
    public func createSnapshot(projectID: UUID, trigger: BackupTrigger) async throws -> BackupOutcome {
        try await service.createSnapshot(projectID: projectID, trigger: trigger)
    }

    public func dueProjects(now: Date = Date()) async throws -> [Project] {
        try await service.dueProjects(now: now)
    }

    /// Runs every due project once. One project's failure never aborts the batch —
    /// this is the logic the scheduler and `--once` both rely on. A lease conflict
    /// is a SKIP (another process owns the project), not a failure.
    public func runDueProjects(now: Date = Date(), trigger: BackupTrigger = .scheduled) async -> BatchReport {
        var report = BatchReport()
        let due: [Project]
        do {
            due = try await dueProjects(now: now)
        } catch {
            await service.logger.error("调度轮询失败：\(error.localizedDescription)")
            return report
        }
        for project in due {
            guard project.isSchedulable else {
                report.skipped.append(project.id)
                continue
            }
            do {
                _ = try await service.createSnapshot(projectID: project.id, trigger: trigger)
                report.succeeded.append(project.id)
            } catch {
                if let code = error as? CodeTimeError, case .leaseConflict = code {
                    report.skipped.append(project.id)
                    continue
                }
                report.failed.append((project.id, error.localizedDescription))
                await service.logger.warning(
                    "调度备份失败（\(project.name)）：\(error.localizedDescription)"
                )
            }
        }
        return report
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

    /// Which queued retry jobs are actually due, oldest first. Retry POLICY stays
    /// in one place (`RetryPolicy`); the coordinator only orders the work.
    public func dueRetryJobs(now: Date = Date()) async throws -> [BackupJob] {
        try await service.dueRetryJobs(now: now)
            .sorted { ($0.nextRetryAt ?? .distantPast) < ($1.nextRetryAt ?? .distantPast) }
    }
}

// MARK: - Restore

/// Owns restore decisions: whether a failed job may be retried, what a resume
/// will do, and the aggregate restore outcome.
public struct RestoreCoordinator: Sendable {
    private let service: CodeTimeService

    public init(_ service: CodeTimeService) { self.service = service }

    public enum ResumePlan: Sendable, Equatable {
        /// Start (or restart) the download into the derived staging directory.
        case download
        /// The commit journal proves the repository was already moved: finish the
        /// metadata + verification only.
        case finishCommit
        /// The job cannot proceed; the caller must surface the reason.
        case blocked(String)
    }

    @discardableResult
    public func restore(_ request: RestoreRequest) async throws -> RestoreJob {
        try await service.restore(request)
    }

    public func restoreJobs(limit: Int = 100) async throws -> [RestoreJob] {
        try await service.restoreJobs(limit: limit)
    }

    /// CT-113: the retry decision is a state-machine question, not a per-caller
    /// guess. Permanently failed jobs are refused with an explanation.
    public func canRetry(_ job: CloudRestoreJob) -> Bool {
        job.state.isResumable
    }

    /// What a resume of this job will do, based only on the persisted state.
    public func resumePlan(for job: CloudRestoreJob) -> ResumePlan {
        switch job.state {
        case .committing:
            return .finishCommit
        case .preparing, .downloading, .verifying, .interrupted, .failed, .retryableFailed:
            return .download
        case .completed:
            return .blocked("该恢复任务已经完成")
        case .permanentlyFailed:
            return .blocked(job.lastError ?? "该恢复任务无法重试，请重新开始恢复")
        case .cancelled:
            return .blocked("该恢复任务已被取消")
        }
    }

    public func recoverFromCloud(
        candidate: RecoveryCandidate,
        storageRoot: URL,
        recoveryKeyText: String
    ) async throws -> CloudRecoveryResult {
        try await service.recoverFromCloud(
            candidate: candidate,
            storageRoot: storageRoot,
            recoveryKeyText: recoveryKeyText
        )
    }

    public func installSecretsFromCloud(storageRoot: URL, recoveryKeyText: String) async throws {
        try await service.installSecretsFromCloud(storageRoot: storageRoot, recoveryKeyText: recoveryKeyText)
    }

    public func latestCloudRestoreJob() async throws -> CloudRestoreJob? {
        try await service.latestCloudRestoreJob()
    }
}

// MARK: - Cloud publish

/// Owns upload retry ordering and publish status reporting.
public struct CloudPublishCoordinator: Sendable {
    private let service: CodeTimeService

    public init(_ service: CodeTimeService) { self.service = service }

    public func cloudSummary() async throws -> CloudStorageSummary? {
        try await service.cloudSummary()
    }

    public func cloudGenerations() async throws -> [CloudGeneration] {
        try await service.cloudGenerations()
    }

    /// Retries every due upload job (oldest first). A job another process owns is
    /// skipped, never forced.
    @discardableResult
    public func retryDueUploads(now: Date = Date()) async -> (retried: Int, failed: Int) {
        var retried = 0
        var failed = 0
        do {
            let jobs = try await service.dueRetryJobs(now: now).filter { $0.type == .upload }
            for job in jobs {
                if await service.retryCloudPublish(job: job) {
                    retried += 1
                } else {
                    failed += 1
                }
            }
        } catch {
            await service.logger.error("云端重试扫描失败：\(error.localizedDescription)")
        }
        return (retried, failed)
    }

    /// CT-105: preview by default; physical deletion requires explicit consent.
    @discardableResult
    public func cleanupCloud(allowPhysicalDelete: Bool = false) async throws -> CloudCleanupReport? {
        try await service.cleanupCloud(allowPhysicalDelete: allowPhysicalDelete)
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

// MARK: - Verification

/// Owns the verification policy: which snapshots are stale enough to need a
/// re-check, and how the per-project outcomes aggregate.
public struct VerificationCoordinator: Sendable {
    private let service: CodeTimeService

    public init(_ service: CodeTimeService) { self.service = service }

    /// Snapshots older than this are re-verified on request.
    public static let staleVerificationInterval: TimeInterval = 7 * 86_400

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

    /// Verifies the newest snapshot of every schedulable project whose last
    /// verification is missing or older than the interval.
    public func verifyStaleProjects(now: Date = Date()) async -> [(projectID: UUID, result: VerificationResult?)] {
        var outcomes: [(UUID, VerificationResult?)] = []
        do {
            for project in try await service.projects() where project.isSchedulable {
                guard let latest = try await service.snapshots(projectID: project.id, limit: 1).first else {
                    continue
                }
                let isStale = latest.verifiedAt.map {
                    now.timeIntervalSince($0) > Self.staleVerificationInterval
                } ?? true
                guard isStale else { continue }
                do {
                    let result = try await service.verifySnapshot(projectID: project.id, snapshotID: latest.id)
                    outcomes.append((project.id, result))
                } catch {
                    await service.logger.warning(
                        "校验失败（\(project.name)）：\(error.localizedDescription)"
                    )
                    outcomes.append((project.id, nil))
                }
            }
        } catch {
            await service.logger.error("校验扫描失败：\(error.localizedDescription)")
        }
        return outcomes
    }
}

// MARK: - Lifecycle

/// Owns the process-lifecycle policy: the migration stop protocol and the
/// "can we safely exit?" decision. It never releases a lock it cannot prove safe.
public struct LifecycleCoordinator: Sendable {
    private let service: CodeTimeService

    public init(_ service: CodeTimeService) { self.service = service }

    public enum ShutdownDecision: Sendable, Equatable {
        /// Nothing is running; locks may be released and the process may exit.
        case safeToExit
        /// Work is still running; the caller must keep the locks and stay alive.
        case unsafeToExit(remaining: [String])
    }

    /// Stops all in-flight work and reports whether exiting is provably safe.
    /// This is the single decision point used by the agent's shutdown paths.
    public func prepareForExit(timeout: TimeInterval = 30) async -> ShutdownDecision {
        let remaining = await service.drainActiveWork(timeout: timeout)
        guard remaining.isEmpty else {
            return .unsafeToExit(remaining: remaining.map(\.kind.rawValue))
        }
        let childrenGone = await service.terminateOrphanChildren(grace: 5)
        guard childrenGone else {
            return .unsafeToExit(remaining: ["kopia-child"])
        }
        return .safeToExit
    }

    public func activeWork() async -> [CodeTimeService.ActiveWorkInfo] {
        await service.activeWork()
    }
}
