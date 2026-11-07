import XCTest
import Foundation
@testable import SharedModels
@testable import BackupEngine
@testable import Persistence

/// Permanent regressions CT-021 … CT-028 and CT-041 (concurrency, leases, retry).
final class ConcurrencyPersistenceRegressionTests: XCTestCase {
    private func makeDatabase() throws -> (URL, SQLiteStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codetime-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("codetime.sqlite")
        return (directory, try SQLiteStore(path: url.path))
    }

    // CT-021: 项目在备份过程中被删除后，运行时回写不得复活它。
    func testCT021_DeletedProjectIsNotResurrectedByRuntimeUpdate() async throws {
        let (directory, store) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = Project(name: "Deleting", rootPath: directory.path)
        try await store.upsertProject(project)
        let job = BackupJob(projectID: project.id, type: .backup, state: .running)
        try await store.upsertJob(job)

        try await store.markProjectDeleting(id: project.id)
        let update = try await store.updateProjectRuntime(id: project.id, lastBackupAt: Date())
        XCTAssertNil(update, "已进入删除流程的项目不得接受运行时写入")

        let reloaded = try await store.project(id: project.id)
        XCTAssertEqual(reloaded?.lifecycle, .deleting)
        XCTAssertEqual(reloaded?.status, .disabled)
        XCTAssertFalse(reloaded?.enabled ?? true)

        try await store.markProjectDeleted(id: project.id)
        let afterDelete = try await store.updateProjectRuntime(id: project.id, status: .synced)
        XCTAssertNil(afterDelete)
        let deleted = try await store.project(id: project.id)
        XCTAssertEqual(deleted?.lifecycle, .deleted)

        await assertThrowsAsync(
            try await store.updateProjectConfig(id: project.id) { $0.name = "resurrected" }
        ) { error in
            guard let persistence = error as? PersistenceError, case .conflict = persistence else {
                return XCTFail("删除后的配置写入必须被拒绝，实际：\(error)")
            }
        }
        let retainedJob = try await store.job(id: job.id)
        XCTAssertEqual(retainedJob?.id, job.id, "任务记录保留给清理流程处理")
    }

    // CT-022: 用户暂停必须保留，不能被一次运行时状态回写覆盖。
    func testCT022_PauseIsNotOverwrittenByRuntimeUpdate() async throws {
        let (directory, store) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = Project(name: "Paused", rootPath: directory.path)
        try await store.upsertProject(project)
        let paused = try await store.setProjectEnabled(id: project.id, enabled: false)
        XCTAssertFalse(paused.enabled)
        XCTAssertEqual(paused.status, .disabled)
        let revision = paused.configRevision

        try await store.updateProjectRuntime(
            id: project.id,
            status: .synced,
            lastBackupAt: Date(),
            lastSnapshotID: "snap-1"
        )

        let reloaded = try await store.project(id: project.id)
        XCTAssertFalse(reloaded?.enabled ?? true, "运行时回写不得恢复已暂停的项目")
        XCTAssertEqual(reloaded?.configRevision, revision, "运行时回写不改变配置修订号")
        XCTAssertEqual(reloaded?.lastSnapshotID, "snap-1")

        await assertThrowsAsync(
            try await store.updateProjectConfig(id: project.id, expectedRevision: 0) { $0.name = "stale" }
        ) { error in
            guard let persistence = error as? PersistenceError, case .conflict = persistence else {
                return XCTFail("过期修订号必须冲突，实际：\(error)")
            }
        }
    }

    // CT-023: Agent 持有租约时，UI 不得在同一任务上并发启动第二个执行者。
    func testCT023_LeaseBlocksSecondExecutor() async throws {
        let (directory, store) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = Project(name: "Lease", rootPath: directory.path)
        try await store.upsertProject(project)
        let job = BackupJob(projectID: project.id, type: .backup)
        try await store.upsertJob(job)

        let agent = ProcessIdentity.current(isAgent: true)
        let agentLease = try await store.acquireJobLease(
            id: job.id,
            owner: agent,
            expiresAt: Date().addingTimeInterval(600)
        )
        XCTAssertNotNil(agentLease)
        let runningJob = try await store.job(id: job.id)
        XCTAssertEqual(runningJob?.state, .running)

        let deadUI = ProcessIdentity(pid: 999_999, startTime: 1, isAgent: false)
        let blocked = try await store.acquireJobLease(
            id: job.id,
            owner: deadUI,
            expiresAt: Date().addingTimeInterval(600)
        )
        XCTAssertNil(blocked, "租约未过期且持有者存活时不得抢占")

        let agentRenewed = try await store.renewJobLease(
            id: job.id,
            owner: agent,
            expiresAt: Date().addingTimeInterval(900)
        )
        XCTAssertTrue(agentRenewed)
        let impostorRenewed = try await store.renewJobLease(
            id: job.id,
            owner: deadUI,
            expiresAt: Date().addingTimeInterval(900)
        )
        XCTAssertFalse(impostorRenewed)
    }

    // CT-024: 设置通过修订号传播，过期写入必须冲突而不是覆盖新值。
    func testCT024_SettingsPropagationUsesRevision() async throws {
        let (directory, store) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        let initial = try await store.saveSettingsCAS(AppSettings(), expectedRevision: nil)
        XCTAssertEqual(initial.configRevision, 1)

        var changed = initial
        changed.globalIntervalMinutes = 45
        let second = try await store.saveSettingsCAS(changed, expectedRevision: initial.configRevision)
        XCTAssertEqual(second.configRevision, 2)
        XCTAssertEqual(second.globalIntervalMinutes, 45)

        await assertThrowsAsync(
            try await store.saveSettingsCAS(initial, expectedRevision: initial.configRevision)
        ) { error in
            guard let persistence = error as? PersistenceError, case .conflict = persistence else {
                return XCTFail("过期设置写入必须冲突，实际：\(error)")
            }
        }

        // A second connection (the LaunchAgent) sees the same revision and value.
        let agentStore = try SQLiteStore(path: directory.appendingPathComponent("codetime.sqlite").path)
        let agentRevision = try await agentStore.settingsRevision()
        XCTAssertEqual(agentRevision, 2)
        let stored = try await agentStore.codable(AppSettings.self, forKey: "app.settings")
        XCTAssertEqual(stored?.globalIntervalMinutes, 45)
    }

    // CT-025: 全局暂停/禁用必须关闭调度闸门。
    func testCT025_PauseClosesSchedulingGate() {
        XCTAssertFalse(SchedulerSettings(enabled: true, globallyPaused: true).allowsScheduling)
        XCTAssertFalse(SchedulerSettings(enabled: false, globallyPaused: false).allowsScheduling)
        XCTAssertTrue(SchedulerSettings(enabled: true, globallyPaused: false).allowsScheduling)

        var settings = AppSettings(launchAgentEnabled: true)
        settings.scheduler.globallyPaused = true
        settings.pauseOnBattery = true
        let synchronized = settings.synchronizingScheduler()
        XCTAssertFalse(synchronized.scheduler.allowsScheduling)
        XCTAssertTrue(synchronized.scheduler.pauseOnLowPowerMode)
    }

    // CT-026: 两个 Agent 竞争同一把仓库锁时只能有一个成为 leader。
    func testCT026_TwoAgentsElectSingleLeader() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codetime-leader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("scheduler.lock").path

        let first = RepositoryLock(path: path)
        XCTAssertTrue(first.tryAcquire())
        let second = RepositoryLock(path: path)
        XCTAssertFalse(second.tryAcquire(), "同一时刻只能有一个进程持有调度领导权")
        XCTAssertEqual(first.currentOwner()?.pid, getpid())

        first.release()
        XCTAssertTrue(second.tryAcquire(), "释放后另一个进程必须能接管")
        second.release()
    }

    // CT-027: 崩溃遗留的 running 任务在重启后被标记中断并可安排重试。
    func testCT027_CrashLeavesInterruptedJobsRetryable() async throws {
        let (directory, store) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = Project(name: "Crash", rootPath: directory.path)
        try await store.upsertProject(project)
        let deadOwner = ProcessIdentity(pid: 999_999, startTime: 1, isAgent: true)
        let crashed = BackupJob(
            projectID: project.id,
            type: .backup,
            state: .running,
            startedAt: Date().addingTimeInterval(-600),
            lease: JobLease(owner: deadOwner, leaseExpiresAt: Date().addingTimeInterval(-300))
        )
        try await store.upsertJob(crashed)

        let liveOwner = ProcessIdentity.current(isAgent: true)
        let live = BackupJob(
            projectID: project.id,
            type: .backup,
            state: .running,
            startedAt: Date(),
            lease: JobLease(owner: liveOwner, leaseExpiresAt: Date().addingTimeInterval(-1))
        )
        try await store.upsertJob(live)

        let recovered = try await store.recoverInterruptedJobs(now: Date())
        XCTAssertEqual(recovered, [crashed.id])
        let crashedState = try await store.job(id: crashed.id)
        let liveState = try await store.job(id: live.id)
        XCTAssertEqual(crashedState?.state, .interrupted)
        XCTAssertEqual(liveState?.state, .running, "存活进程的任务不得被抢占")

        guard let interrupted = try await store.job(id: crashed.id) else {
            return XCTFail("任务丢失")
        }
        try await store.scheduleRetry(interrupted, after: 60, errorClass: .transientNetwork, message: "网络中断")
        let dueNow = try await store.dueRetryJobs(now: Date())
        XCTAssertTrue(dueNow.isEmpty)
        let dueLater = try await store.dueRetryJobs(now: Date().addingTimeInterval(120))
        XCTAssertEqual(dueLater.map(\.id), [crashed.id])
        XCTAssertEqual(dueLater.first?.retryCount, 1)
        XCTAssertEqual(dueLater.first?.errorClass, .transientNetwork)
    }

    // CT-028: 复用 PID 的新进程不能被误认成租约持有者。
    func testCT028_PIDReuseIsNotTreatedAsAliveOwner() {
        let pid = getpid()
        let start = ProcessIdentity.processStartTime(pid)
        let live = ProcessIdentity(pid: pid, startTime: start, isAgent: false)
        XCTAssertTrue(live.isAlive)

        let expiredLive = JobLease(owner: live, leaseExpiresAt: Date().addingTimeInterval(-10))
        XCTAssertFalse(expiredLive.isReclaimable(), "持有者仍存活时，过期租约也不能被回收")

        let reused = ProcessIdentity(pid: pid, startTime: start + 100, isAgent: false)
        XCTAssertFalse(reused.isAlive, "启动时间不同说明 PID 已被复用")
        let deadReused = JobLease(owner: reused, leaseExpiresAt: Date().addingTimeInterval(-10))
        XCTAssertTrue(deadReused.isReclaimable())

        let notYetExpired = JobLease(owner: reused, leaseExpiresAt: Date().addingTimeInterval(60))
        XCTAssertFalse(notYetExpired.isReclaimable(), "租约未到期也不能回收")
    }

    // CT-041: 退避时序、抖动范围与永久错误分类必须稳定。
    func testCT041_RetryBackoffAndClassification() {
        let policy = RetryPolicy.default
        XCTAssertEqual(policy.delay(attempt: 0, errorClass: .transientNetwork, random: 0.5), 60)
        XCTAssertEqual(policy.delay(attempt: 1, errorClass: .transientNetwork, random: 0.5), 300)
        XCTAssertEqual(policy.delay(attempt: 2, errorClass: .transientNetwork, random: 0.5), 900)
        XCTAssertEqual(policy.delay(attempt: 3, errorClass: .transientNetwork, random: 0.5), 1_800)
        XCTAssertEqual(policy.delay(attempt: 4, errorClass: .transientNetwork, random: 0.5), 3_600)
        XCTAssertNil(policy.delay(attempt: 8, errorClass: .transientNetwork, random: 0.5))

        let low = policy.delay(attempt: 0, errorClass: .unknown, random: 0)
        let high = policy.delay(attempt: 0, errorClass: .unknown, random: 1)
        XCTAssertEqual(low, 48)
        XCTAssertEqual(high, 72)

        for errorClass in [RetryErrorClass.permission, .repositoryCorrupted, .userCancelled, .configuration] {
            XCTAssertNil(policy.delay(attempt: 0, errorClass: errorClass), "\(errorClass) 不应自动重试")
            XCTAssertTrue(errorClass.isPermanent)
        }

        XCTAssertEqual(RetryPolicy.classify(CodeTimeError.cancelled), .userCancelled)
        XCTAssertEqual(RetryPolicy.classify(CodeTimeError.projectDeleted("p")), .userCancelled)
        XCTAssertEqual(RetryPolicy.classify(CodeTimeError.unauthorized("scope")), .permission)
        XCTAssertEqual(RetryPolicy.classify(CodeTimeError.repositoryMissing("gone")), .repositoryCorrupted)
        XCTAssertEqual(RetryPolicy.classify(CodeTimeError.cloudUploadFailed("offline")), .transientNetwork)
        XCTAssertEqual(
            RetryPolicy.classify(CodeTimeError.insufficientDiskSpace(required: 10, available: 1)),
            .diskSpace
        )
        XCTAssertEqual(RetryPolicy.classify(CodeTimeError.cloudStateUnknown("n/a")), .iCloudNotDownloaded)
    }
}
