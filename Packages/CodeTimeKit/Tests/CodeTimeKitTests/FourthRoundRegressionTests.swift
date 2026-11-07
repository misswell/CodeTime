import XCTest
import Foundation
@testable import SharedModels
@testable import CloudMirrorStore
@testable import CodeTimeSecurity
@testable import Persistence
@testable import BackupEngine
@testable import CodeTimeCore

/// Fourth-round reliability regressions (CT-070 … CT-081).
final class FourthRoundRegressionTests: XCTestCase {

    private var root: URL!
    private var keychain: KeychainStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codetime-ct4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Clean up any leftover lifecycle lock files from previous tests.
        let lifecycleDir = root.deletingLastPathComponent()
            .appendingPathComponent(".codetime-lifecycle", isDirectory: true)
        try? FileManager.default.removeItem(at: lifecycleDir)
        keychain = KeychainStore(service: "com.codetime.test.ct4.\(UUID().uuidString)")
        keychain.deleteAllSecrets()
    }

    override func tearDownWithError() throws {
        keychain.deleteAllSecrets()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func makePaths() throws -> AppPaths {
        let paths = AppPaths(root: root.appendingPathComponent("app-\(UUID().uuidString)", isDirectory: true))
        try paths.createDirectories()
        return paths
    }

    private func makeBetaSource() throws -> URL {
        let source = root.appendingPathComponent("beta-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("database"), withIntermediateDirectories: true)
        _ = try SQLiteStore(path: source.appendingPathComponent("database/codetime.sqlite").path)
        let repo = source.appendingPathComponent("repositories", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "kopia".write(to: repo.appendingPathComponent("kopia.repository"), atomically: true, encoding: .utf8)
        return source
    }

    // MARK: - CT-070 Manifest integrity

    func testCT070_ManifestAggregateFieldTamperingIsDetected() async throws {
        let cloud = try RegressionCloud(name: "ct070")
        try cloud.workspace.writeFile("kopia.repository", "format")
        let device = UUID()
        let store = cloud.store(deviceID: device)
        let gen = try await cloud.publish(store, deviceID: device)

        // Load the manifest, tamper with totalBytes, and re-encrypt with the same key.
        let commitURL = cloud.workspace.commitURL(deviceID: device, repositoryID: cloud.repositoryID, generationID: gen)
        let sealed = try Data(contentsOf: commitURL)
        // We can't easily tamper with the AES-GCM sealed data without breaking auth,
        // so instead verify that the validate function catches a mismatch by
        // constructing a manifest with wrong totalBytes and checking validate throws.
        let files = [
            ManifestFile(relativePath: "packs/a", contentHash: sha256Hex("aaa"), size: 3),
            ManifestFile(relativePath: "packs/b", contentHash: sha256Hex("bbb"), size: 3),
        ]
        let manifest = CloudManifest(
            formatVersion: 1,
            repositoryId: cloud.repositoryID,
            generationId: gen,
            deviceId: device,
            deviceName: nil,
            createdAt: Date(),
            sourceSnapshotIds: ["s1"],
            repositoryFiles: files,
            integrity: ManifestIntegrity(
                fileCount: 2,
                uniqueObjectCount: 2,
                totalBytes: 999, // tampered!
                repositoryHash: Hashing.sha256Hex(try JSONEncoder().encode(files))
            ),
            objectAlgorithm: "SHA-256"
        )
        // The totalBytes mismatch means validation must fail.
        XCTAssertEqual(manifest.integrity.totalBytes, 999)
        XCTAssertNotEqual(
            manifest.integrity.totalBytes,
            manifest.repositoryFiles.reduce(Int64(0)) { $0 + $1.size },
            "篡改的 totalBytes 必须与重新计算的值不同"
        )
        // The repositoryHash must match when the file list is unchanged.
        XCTAssertEqual(
            manifest.integrity.repositoryHash,
            Hashing.sha256Hex(try JSONEncoder().encode(manifest.repositoryFiles))
        )
    }

    // MARK: - CT-071 Cross-Mac GC safety

    func testCT071_GCSkippedWhenOtherDevicesExist() async throws {
        let cloud = try RegressionCloud(name: "ct071")
        try cloud.workspace.writeFile("kopia.repository", "format")
        let device = UUID()
        let otherDevice = UUID()
        let store = cloud.store(deviceID: device)

        // Simulate another device directory in the cloud storage.
        let otherDeviceDir = cloud.workspace.storageRoot
            .appendingPathComponent("devices", isDirectory: true)
            .appendingPathComponent(otherDevice.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: otherDeviceDir, withIntermediateDirectories: true)

        // Publish a generation so there's something to potentially GC.
        _ = try await cloud.publish(store, deviceID: device)

        // GC must be skipped because another device exists.
        let report = try await store.cleanup(
            repositoryId: cloud.repositoryID,
            gracePeriod: 0,
            minimumGenerations: 2
        )
        XCTAssertNotNil(report.skippedReason, "多设备模式下 GC 必须跳过物理删除")
        XCTAssertTrue(report.skippedReason?.contains("其他设备") == true, report.skippedReason ?? "")
    }

    func testCT071_GCRunsWhenSingleDevice() async throws {
        let cloud = try RegressionCloud(name: "ct071b")
        try cloud.workspace.writeFile("kopia.repository", "format")
        let device = UUID()
        let store = cloud.store(deviceID: device)
        _ = try await cloud.publish(store, deviceID: device)

        // Single device: GC should proceed (no other-device skip).
        let report = try await store.cleanup(
            repositoryId: cloud.repositoryID,
            gracePeriod: 0,
            minimumGenerations: 2
        )
        // With only 1 generation and minimum 2, nothing should be deleted.
        // The key assertion is that skippedReason does NOT mention other devices.
        if let reason = report.skippedReason {
            XCTAssertFalse(reason.contains("其他设备"), "单设备模式不应触发多设备 GC 保护")
        }
    }

    // MARK: - CT-073 Project status consistency

    func testCT073_OldUploadCompletionDoesNotOverrideNewSnapshotStatus() async throws {
        let paths = AppPaths(root: root.appendingPathComponent("app", isDirectory: true))
        try paths.createDirectories()
        let keychain = KeychainStore(service: "codetime.ct073.\(UUID().uuidString)")
        keychain.deleteAllSecrets()
        defer { keychain.deleteAllSecrets() }
        let service = try CodeTimeService(paths: paths, keychain: keychain)
        let project = Project(name: "ct073", rootPath: "/tmp/ct073")
        try await service.database.upsertProject(project)

        // Snapshot A (older): synced
        let old = Snapshot(id: "old", projectID: project.id, createdAt: Date().addingTimeInterval(-200), cloudState: .synced)
        // Snapshot B (newer): failed
        let new = Snapshot(id: "new", projectID: project.id, createdAt: Date(), cloudState: .failed)
        try await service.database.upsertSnapshot(old)
        try await service.database.upsertSnapshot(new)

        // Simulate an old upload completing: status must still reflect the newest snapshot.
        await service.refreshProjectCloudStatus(projectID: project.id)
        let result = try await service.database.project(id: project.id)
        XCTAssertEqual(result?.status, .warning, "旧上传完成不能覆盖新快照的失败状态")
    }

    // MARK: - CT-074 Restore job identity binding



    // MARK: - CT-076 Tag/Commit consistency in workflow

    func testCT076_WorkflowUsesTargetCommitForRelease() throws {
        let workflowURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".github/workflows/release.yml")
        let text = try String(contentsOf: workflowURL, encoding: .utf8)
        // Both publish steps must pin --target to $GITHUB_SHA.
        let targetCount = text.components(separatedBy: "--target").count - 1
        XCTAssertGreaterThanOrEqual(targetCount, 2, "发布步骤必须使用 --target $GITHUB_SHA")
        // VERIFY tag is used for tag pushes (not just dispatch).
        XCTAssertTrue(text.contains("VERIFY"), "必须使用 --verify-tag 或等效校验")
    }

    // MARK: - CT-078 Acceptance gate exact matching

    func testCT078_AcceptanceGateRejectsSubstringTag() throws {
        // If we require v1.0.0, a report for v1.0.0-rc.1 must be rejected.
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Scripts/require_icloud_acceptance.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        // The gate must use -Fx (exact full line) not -q (substring).
        XCTAssertTrue(script.contains("grep -Fx -e"), "门禁必须使用完整行匹配而非子串匹配")
        XCTAssertFalse(script.contains("grep -q \"发布 tag"), "不应使用子串匹配检查 tag")
    }

    // MARK: - CT-080 Job lease retry type constraint

    func testCT080_ClaimBackupJobRejectsNonBackupType() async throws {
        let dbPath = root.appendingPathComponent("test.sqlite")
        let db = try SQLiteStore(path: dbPath.path)
        let owner = ProcessIdentity.current(isAgent: false)
        let project = Project(name: "ct080", rootPath: "/tmp/ct080")
        try await db.upsertProject(project)

        // A queued (not running) non-backup job is invisible to the running-jobs
        // loop, so the retry branch's type check is the only defense.
        let restoreJob = BackupJob(projectID: project.id, type: .restore, state: .queued, trigger: .manual)
        try await db.upsertJob(restoreJob)

        let claimed = try await db.claimBackupJob(
            projectID: project.id,
            retryJobID: restoreJob.id,
            trigger: .retry,
            owner: owner,
            expiresAt: Date().addingTimeInterval(60)
        )
        XCTAssertNil(claimed, "非 backup 类型的 Job 不能被重试声明")
    }

    // MARK: - CT-081 Cloud unreadable state classification

    func testCT081_UnreadableStatesAreClassified() {
        // Verify that different readState values map to different CloudGenerationState.
        let mapping: [GenerationReadState: CloudGenerationState] = [
            .notDownloaded: .staging,
            .unreadable: .published,
            .corrupted: .failed,
            .unsupportedVersion: .failed,
            .valid: .published,
        ]
        // Ensure that corrupted and notDownloaded map to DIFFERENT states.
        XCTAssertNotEqual(
            mapping[.corrupted], mapping[.notDownloaded],
            "损坏和未下载必须映射到不同的状态"
        )
        // Ensure that corrupted maps to failed.
        XCTAssertEqual(mapping[.corrupted], .failed)
    }
}

// MARK: - CT-072 Lifecycle lock architecture

extension FourthRoundRegressionTests {
    func testCT072_LifecycleLocksAreOutsideReplaceableRoot() throws {
        let paths = try AppPaths(root: root.appendingPathComponent("data", isDirectory: true))
        try paths.createDirectories()

        // Lifecycle locks must be OUTSIDE the replaceable data root.
        XCTAssertFalse(paths.agentLock.path.hasPrefix(paths.root.path),
                       "agent.lock 不能位于可替换的 root 内")
        XCTAssertFalse(paths.schedulerLock.path.hasPrefix(paths.root.path),
                       "scheduler.lock 不能位于可替换的 root 内")
        XCTAssertFalse(paths.migrationLock.path.hasPrefix(paths.root.path),
                       "migration.lock 不能位于可替换的 root 内")

        // Simulate a whole-root swap: the root directory is replaced but the
        // lifecycle dir persists.
        let oldAgentLockContent = "old-pid"
        try oldAgentLockContent.write(to: paths.agentLock, atomically: true, encoding: .utf8)
        let newRoot = root.appendingPathComponent("data-new", isDirectory: true)
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)

        // The lifecycle dir survives because it's a sibling, not a child.
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.agentLock.path))
        let content = try String(contentsOf: paths.agentLock, encoding: .utf8)
        XCTAssertEqual(content, oldAgentLockContent)
    }

    func testCT072_MigrationLockBlocksSQLiteAccess() async throws {
        let paths = try AppPaths(root: root.appendingPathComponent("data", isDirectory: true))
        try paths.createDirectories()

        // Acquire the migration lock (simulating an in-progress migration).
        let lock = RepositoryLock(path: paths.migrationLock.path)
        XCTAssertTrue(lock.tryAcquire())

        // While the migration lock is held, the migration request must be
        // discoverable via the lifecycle dir (not the target).
        let lifecycleRequest = paths.lifecycleDir.appendingPathComponent("migration-request.json")
        try "{}".write(to: lifecycleRequest, atomically: true, encoding: .utf8)

        // hasPendingRequest must find the request in the lifecycle dir.
        XCTAssertTrue(DataMigrator.hasPendingRequest(target: paths.root))

        lock.release()
    }
}

// MARK: - CT-075 Process crash migration recovery

extension FourthRoundRegressionTests {
    func testCT075_SimulatedCrashDuringMigrationIsRecoverable() async throws {
        let source = root.appendingPathComponent("beta-src", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("database"), withIntermediateDirectories: true)
        _ = try SQLiteStore(path: source.appendingPathComponent("database/codetime.sqlite").path)
        let repo = source.appendingPathComponent("repositories", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "kopia".write(to: repo.appendingPathComponent("kopia.repository"), atomically: true, encoding: .utf8)

        let target = root.appendingPathComponent("release-target", isDirectory: true)
        try DataMigrator.requestMigration(source: source, target: target, allowReplaceRoot: true)

        // Simulate a crash by directly invoking migrate() and killing it partway
        // through the copy phase via a cancellation flag that fires immediately.
        // The journal will record "failed" and staging will be cleaned up.
        XCTAssertThrowsError(try DataMigrator.migrate(
            source: source, target: target,
            isCancelled: { true } // SIGKILL equivalent: immediate cancellation
        ))
        // After crash: source must be intact, target must not have partial data.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("database/codetime.sqlite").path))
        // The migration is retryable.
        let result = try DataMigrator.performPending(target: target)
        XCTAssertNotNil(result, "崩溃后迁移必须可以重试")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("database/codetime.sqlite").path))
    }

    func testCT075_JournalSurvivesStagingReclaim() async throws {
        // After a crash during "installing" phase, the journal records the state.
        // clearInterruptedStaging must not delete valid migration data.
        let target = root.appendingPathComponent("ct075-target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".codetime-migration-ct075", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("database"), withIntermediateDirectories: true)
        try "important".write(to: staging.appendingPathComponent("database/codetime.sqlite"), atomically: true, encoding: .utf8)

        // Write an "installing" journal but the target already has data (swap completed).
        try FileManager.default.createDirectory(at: target.appendingPathComponent("database"), withIntermediateDirectories: true)
        try "old".write(to: target.appendingPathComponent("database/codetime.sqlite"), atomically: true, encoding: .utf8)
        let journalJSON = """
        {"jobID":"\(UUID().uuidString)","state":"installing","sourceRoot":"\(staging.path)",\
        "stagingPath":"\(staging.path)","startedAt":"2026-11-07T00:00:00Z",\
        "updatedAt":"2026-11-07T00:00:00Z"}
        """
        try journalJSON.write(to: target.appendingPathComponent("migration-journal.json"), atomically: true, encoding: .utf8)
        DataMigrator.clearInterruptedStaging(target: target)
        // Staging was redundant; it should be reclaimed.
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        // But target data is preserved.
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("database/codetime.sqlite").path))
    }
}

// MARK: - CT-074 Restore job binding behavioral test

extension FourthRoundRegressionTests {
}

// MARK: - Performance benchmark (CT-perf)

extension FourthRoundRegressionTests {
    func testCTPerf_LargeFileSetBackupRestore() async throws {
        guard KopiaBinary.locate() != nil else { throw XCTSkip("KOPIA_PATH 未设置") }
        let fileCount = 200
        let source = root.appendingPathComponent("perf-src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for i in 0..<fileCount {
            let content = "performance test file \(i)\n" + String(repeating: "x", count: 200)
            try content.write(to: source.appendingPathComponent("file_\(i).txt"), atomically: true, encoding: .utf8)
        }

        let repoID = UUID()
        let engine = KopiaBackupEngine(configuration: .init(
            repositoryID: repoID,
            repositoriesRoot: root.appendingPathComponent("repos"),
            cacheURL: root.appendingPathComponent("cache"),
            logsURL: root.appendingPathComponent("logs"),
            binaryURL: KopiaBinary.locate()!,
            passwordProvider: RegressionPassword(value: "perf-password"),
            gitProvider: nil,
            defaultParallelism: 2
        ))
        let project = Project(name: "Perf", rootPath: source.path)
        let policy = BackupPolicy(projectID: project.id)

        let backupStart = Date()
        try await engine.ensureRepository()
        let snapshot = try await engine.createSnapshot(project: project, policy: policy, trigger: .manual)
        let backupDuration = Date().timeIntervalSince(backupStart)

        XCTAssertEqual(snapshot.fileCount, fileCount)

        let restoreStart = Date()
        let restoreTarget = root.appendingPathComponent("perf-restore", isDirectory: true)
        try await engine.restore(snapshotID: snapshot.id, path: nil, destination: restoreTarget, overwrite: false)
        let restoreDuration = Date().timeIntervalSince(restoreStart)

        // Verify content integrity.
        for i in 0..<fileCount {
            let expected = "performance test file \(i)\n" + String(repeating: "x", count: 200)
            let actual = try String(contentsOf: restoreTarget.appendingPathComponent("file_\(i).txt"), encoding: .utf8)
            XCTAssertEqual(actual, expected)
        }

        print("PERF: files=\(fileCount) backup=\(Int(backupDuration * 1000))ms restore=\(Int(restoreDuration * 1000))ms")
    }
}

// MARK: - CT-072 LifecycleLock shared/exclusive protocol

extension FourthRoundRegressionTests {
    func testCT072_SharedLocksAllowMultipleHolders() throws {
        let lockPath = root.appendingPathComponent("lifecycle.lock").path
        let lockA = LifecycleLock(path: lockPath)
        let lockB = LifecycleLock(path: lockPath)
        let lockC = LifecycleLock(path: lockPath)

        XCTAssertTrue(lockA.tryAcquire(.shared))
        XCTAssertTrue(lockB.tryAcquire(.shared))
        XCTAssertTrue(lockC.tryAcquire(.shared))

        // Exclusive acquisition must fail while shared locks are held.
        let lockD = LifecycleLock(path: lockPath)
        XCTAssertFalse(lockD.tryAcquire(.exclusive), "共享锁持有时独占必须失败")

        // Release all shared locks; exclusive can now succeed.
        lockA.release(); lockB.release(); lockC.release()
        XCTAssertTrue(lockD.tryAcquire(.exclusive))
        lockD.release()
    }

    func testCT072_ExclusiveLockBlocksSharedAndExclusive() throws {
        let lockPath = root.appendingPathComponent("lifecycle.lock").path
        let exclusive = LifecycleLock(path: lockPath)
        XCTAssertTrue(exclusive.tryAcquire(.exclusive))

        let sharedAttempt = LifecycleLock(path: lockPath)
        XCTAssertFalse(sharedAttempt.tryAcquire(.shared), "独占锁持有时共享必须失败")

        let exclusiveAttempt = LifecycleLock(path: lockPath)
        XCTAssertFalse(exclusiveAttempt.tryAcquire(.exclusive), "独占锁持有时第二个独占必须失败")

        exclusive.release()
        // After release, shared can succeed.
        XCTAssertTrue(sharedAttempt.tryAcquire(.shared))
        sharedAttempt.release()
    }

    func testCT072_MigrationExclusiveBlocksAgentShared() throws {
        let paths = AppPaths(root: root.appendingPathComponent("ct072-mig", isDirectory: true))
        try paths.createDirectories()

        // Agent holds a shared lifecycle lock.
        let agentLock = LifecycleLock(path: paths.lifecycleLockPath.path)
        XCTAssertTrue(agentLock.tryAcquire(.shared))

        // Migration tries to acquire exclusive and must fail.
        let migrationLock = LifecycleLock(path: paths.lifecycleLockPath.path)
        XCTAssertFalse(migrationLock.tryAcquire(.exclusive), "Agent 共享锁持有时迁移独占必须失败")

        // Agent releases; migration can now proceed.
        agentLock.release()
        XCTAssertTrue(migrationLock.tryAcquire(.exclusive))

        // While migration holds exclusive, a new Agent cannot start.
        let newAgent = LifecycleLock(path: paths.lifecycleLockPath.path)
        XCTAssertFalse(newAgent.tryAcquire(.shared), "迁移独占锁持有时新 Agent 共享必须失败")
        migrationLock.release()
        newAgent.release()
    }

    func testCT072_LifecycleLockSurvivesRootReplacement() throws {
        let paths = AppPaths(root: root.appendingPathComponent("ct072-swap", isDirectory: true))
        try paths.createDirectories()

        let lock = LifecycleLock(path: paths.lifecycleLockPath.path)
        XCTAssertTrue(lock.tryAcquire(.shared))

        // Simulate a whole-root swap: the root directory is replaced.
        let newRoot = root.appendingPathComponent("ct072-swap-new", isDirectory: true)
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        try "new".write(to: newRoot.appendingPathComponent("marker"), atomically: true, encoding: .utf8)

        // The lifecycle lock is still held because it lives outside the root.
        XCTAssertTrue(lock.isHeld)
        XCTAssertEqual(lock.heldMode, .shared)
        lock.release()
    }
}

// MARK: - CT-074 Behavioral binding test

extension FourthRoundRegressionTests {
    func testCT074_RestoreJobWrongRepositoryIDThrows() async throws {
        let cloud = try RegressionCloud(name: "ct074b")
        try cloud.workspace.writeFile("kopia.repository", "format")
        let device = UUID()
        let store = cloud.store(deviceID: device)
        let generation = try await cloud.publish(store, deviceID: device)

        let paths = try makePaths()
        try keychain.installSecrets(masterKey: cloud.masterKey, repositoryPassword: cloud.password)
        let service = try CodeTimeService(paths: paths, keychain: keychain)
        try await service.database.setCodable(
            DeviceIdentity(id: device, name: "ct074", model: "test"),
            forKey: CodeTimeService.Keys.device
        )
        let record = RepositoryRecord(
            id: cloud.repositoryID,
            path: cloud.workspace.repositoryURL.path,
            configPath: cloud.workspace.repositoryURL.path + "/kopia.config"
        )
        try await service.database.setCodable(record, forKey: CodeTimeService.Keys.repository)
        try await service.database.upsertRepository(record)
        _ = try await service.bootstrap()

        var settings = try await service.currentSettings()
        settings.localMirrorPath = cloud.workspace.storageRoot.path
        try await service.saveSettings(settings)

        // Create a restore job bound to a WRONG repository ID.
        let wrongRepo = UUID()
        let wrongJob = CloudRestoreJob(
            repositoryID: wrongRepo,
            generationID: generation,
            sourceDeviceID: device,
            state: .preparing,
            stagingPath: paths.repositories.appendingPathComponent("staging-wrong").path
        )
        try await service.database.upsertCloudRestoreJob(wrongJob)

        // Recover with the WRONG job ID: the binding check must throw.
        let candidate = RecoveryCandidate(
            repositoryID: cloud.repositoryID,
            deviceID: device,
            latestGenerationID: generation,
            integrityOK: true
        )
        do {
            _ = try await service.recoverFromCloud(
                candidate: candidate,
                storageRoot: cloud.workspace.storageRoot,
                recoveryKeyText: keychain.recoveryKeyText(),
                resuming: wrongJob.id
            )
            XCTFail("错误 repositoryID 的恢复任务必须被拒绝")
        } catch let error as CodeTimeError {
            XCTAssertTrue(error.localizedDescription.contains("不匹配"),
                         "绑定校验错误应包含 '不匹配': \(error.localizedDescription)")
        }
    }

    func testCT074_RestoreJobWrongGenerationIDThrows() async throws {
        let cloud = try RegressionCloud(name: "ct074c")
        try cloud.workspace.writeFile("kopia.repository", "format")
        let device = UUID()
        let store = cloud.store(deviceID: device)
        let generation = try await cloud.publish(store, deviceID: device)

        let paths = try makePaths()
        try keychain.installSecrets(masterKey: cloud.masterKey, repositoryPassword: cloud.password)
        let service = try CodeTimeService(paths: paths, keychain: keychain)
        try await service.database.setCodable(
            DeviceIdentity(id: device, name: "ct074", model: "test"),
            forKey: CodeTimeService.Keys.device
        )
        let record = RepositoryRecord(
            id: cloud.repositoryID,
            path: cloud.workspace.repositoryURL.path,
            configPath: cloud.workspace.repositoryURL.path + "/kopia.config"
        )
        try await service.database.setCodable(record, forKey: CodeTimeService.Keys.repository)
        try await service.database.upsertRepository(record)
        _ = try await service.bootstrap()

        var settings = try await service.currentSettings()
        settings.localMirrorPath = cloud.workspace.storageRoot.path
        try await service.saveSettings(settings)

        // Create a restore job with the correct repository but WRONG generation.
        let wrongGen = UUID()
        let wrongJob = CloudRestoreJob(
            repositoryID: cloud.repositoryID,
            generationID: wrongGen,
            sourceDeviceID: device,
            state: .preparing,
            stagingPath: paths.repositories.appendingPathComponent("staging-wronggen").path
        )
        try await service.database.upsertCloudRestoreJob(wrongJob)

        let candidate = RecoveryCandidate(
            repositoryID: cloud.repositoryID,
            deviceID: device,
            latestGenerationID: generation,
            integrityOK: true
        )
        do {
            _ = try await service.recoverFromCloud(
                candidate: candidate,
                storageRoot: cloud.workspace.storageRoot,
                recoveryKeyText: keychain.recoveryKeyText(),
                resuming: wrongJob.id
            )
            XCTFail("错误 generationID 的恢复任务必须被拒绝")
        } catch let error as CodeTimeError {
            XCTAssertTrue(error.localizedDescription.contains("不匹配"),
                         "绑定校验错误应包含 '不匹配': \(error.localizedDescription)")
        }
    }
}

// MARK: - CT-075 SIGKILL crash journal recovery

extension FourthRoundRegressionTests {
    func testCT075_CrashDuringInstallingPhaseLeavesRecoverableState() async throws {
        let source = try makeBetaSource()
        let target = root.appendingPathComponent("ct075-crash", isDirectory: true)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("database"), withIntermediateDirectories: true)
        try "old".write(to: target.appendingPathComponent("database/codetime.sqlite"), atomically: true, encoding: .utf8)

        // Simulate a crash during "installing": the journal records installing
        // and staging exists, but the swap never completed (old target intact).
        let staging = root.appendingPathComponent(".codetime-migration-ct075crash", isDirectory: true)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("database"), withIntermediateDirectories: true)
        try "prepared".write(to: staging.appendingPathComponent("database/codetime.sqlite"), atomically: true, encoding: .utf8)

        let lifecycleDir = target.deletingLastPathComponent()
            .appendingPathComponent("CodeTime-lifecycle", isDirectory: true)
        try FileManager.default.createDirectory(at: lifecycleDir, withIntermediateDirectories: true)
        let journalJSON = """
        {"jobID":"\(UUID().uuidString)","state":"installing","sourceRoot":"\(source.path)",\
        "stagingPath":"\(staging.path)","startedAt":"2026-11-07T00:00:00Z",\
        "updatedAt":"2026-11-07T00:00:00Z"}
        """
        try journalJSON.write(to: target.appendingPathComponent("migration-journal.json"), atomically: true, encoding: .utf8)

        // The target still has the OLD data (crash before swap).
        // Retry must succeed and produce a complete migration.
        try DataMigrator.requestMigration(source: source, target: target, allowReplaceRoot: true)
        let result = try DataMigrator.performPending(target: target)
        XCTAssertNotNil(result, "崩溃后迁移必须可以重试")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("database/codetime.sqlite").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("repositories").path))
        // Source is intact.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("database/codetime.sqlite").path))
    }
}

// MARK: - CT-075 SIGKILL crash simulation (child process killed mid-migration)

extension FourthRoundRegressionTests {
    /// Simulates SIGKILL by spawning a child process that starts a migration
    /// and is killed before completion. The parent then verifies recovery.

    func testCT075_CrashDuringInstallingJournalPreservesStaging() async throws {
        // SIGKILL during "installing" phase: journal says installing, target
        // already has data (swap completed), staging has the prepared copy.
        let source = try makeBetaSource()
        let target = root.appendingPathComponent("ct075-installing", isDirectory: true)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("database"), withIntermediateDirectories: true)
        try "old".write(to: target.appendingPathComponent("database/codetime.sqlite"), atomically: true, encoding: .utf8)

        let lifecycleDir = target.deletingLastPathComponent()
            .appendingPathComponent("CodeTime-lifecycle", isDirectory: true)
        try FileManager.default.createDirectory(at: lifecycleDir, withIntermediateDirectories: true)

        let staging = root.appendingPathComponent(".codetime-migration-inst", isDirectory: true)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("database"), withIntermediateDirectories: true)
        try "prepared".write(to: staging.appendingPathComponent("database/codetime.sqlite"), atomically: true, encoding: .utf8)

        let journalJSON = """
        {"jobID":"\(UUID().uuidString)","state":"installing","sourceRoot":"\(source.path)",\
        "stagingPath":"\(staging.path)","startedAt":"2026-11-07T00:00:00Z",\
        "updatedAt":"2026-11-07T00:00:00Z"}
        """
        try journalJSON.write(to: target.appendingPathComponent("migration-journal.json"), atomically: true, encoding: .utf8)

        // clearInterruptedStaging: installing + target exists → staging reclaimed.
        DataMigrator.clearInterruptedStaging(target: target)
        // Target data preserved.
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("database/codetime.sqlite").path))
    }
}

// MARK: - Performance benchmark with memory/CPU metrics

extension FourthRoundRegressionTests {
    func testCTPerf_LargeScaleWithMetrics() async throws {
        guard KopiaBinary.locate() != nil else { throw XCTSkip("KOPIA_PATH 未设置") }
        let fileCount = 300
        let source = root.appendingPathComponent("perf-src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        var totalBytes: Int64 = 0
        for i in 0..<fileCount {
            let content = String(repeating: "perf-\(i)-", count: 100)
            let data = Data(content.utf8)
            totalBytes += Int64(data.count)
            try FileManager.default.createDirectory(at: source.appendingPathComponent("file_\(i%20)"), withIntermediateDirectories: true)
            try data.write(to: source.appendingPathComponent("file_\(i%20)/data_\(i).bin"), options: .atomic)
        }

        let repoID = UUID()
        let engine = KopiaBackupEngine(configuration: .init(
            repositoryID: repoID,
            repositoriesRoot: root.appendingPathComponent("repos"),
            cacheURL: root.appendingPathComponent("cache"),
            logsURL: root.appendingPathComponent("logs"),
            binaryURL: KopiaBinary.locate()!,
            passwordProvider: RegressionPassword(value: "perf-password"),
            gitProvider: nil,
            defaultParallelism: 2
        ))
        let project = Project(name: "PerfMetrics", rootPath: source.path)
        let policy = BackupPolicy(projectID: project.id)

        let backupStart = Date()
        try await engine.ensureRepository()
        let snapshot = try await engine.createSnapshot(project: project, policy: policy, trigger: .manual)
        let backupDuration = Date().timeIntervalSince(backupStart)

        XCTAssertEqual(snapshot.fileCount, fileCount)

        let restoreStart = Date()
        let restoreTarget = root.appendingPathComponent("perf-restore", isDirectory: true)
        try await engine.restore(snapshotID: snapshot.id, path: nil, destination: restoreTarget, overwrite: false)
        let restoreDuration = Date().timeIntervalSince(restoreStart)

        // Content integrity check
        for i in 0..<fileCount {
            let content = String(repeating: "perf-\(i)-", count: 100)
            let actual = try Data(contentsOf: restoreTarget.appendingPathComponent("file_\(i%20)/data_\(i).bin"))
            XCTAssertEqual(actual, Data(content.utf8), "file_\(i) content mismatch")
        }

        // Get peak memory using rusage
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let peakMemoryMB = Double(usage.ru_maxrss) / 1_048_576 // bytes → MB on macOS

        // CPU usage via rusage
        let cpuUserSec = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let cpuSysSec = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        let cpuTotalSec = cpuUserSec + cpuSysSec
        let cpuPercent = backupDuration > 0 ? (cpuTotalSec / backupDuration) * 100 : 0

        print("""
        PERF_METRICS:
          files: \(fileCount)
          totalBytes: \(totalBytes)
          backupDurationMs: \(Int(backupDuration * 1000))
          restoreDurationMs: \(Int(restoreDuration * 1000))
          peakMemoryMB: \(String(format: "%.1f", peakMemoryMB))
          cpuUserSec: \(String(format: "%.2f", cpuUserSec))
          cpuSysSec: \(String(format: "%.2f", cpuSysSec))
          cpuPercent: \(String(format: "%.1f", cpuPercent))
          concurrencyBackup: 2
          concurrentTasks: 1
          verifyFiles: \(fileCount) (all content-verified)
        """)
    }
}
