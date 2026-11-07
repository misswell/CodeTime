import XCTest
import Foundation
@testable import SharedModels
@testable import BackupEngine
@testable import CloudMirrorStore
@testable import CodeTimeSecurity
@testable import Persistence
@testable import CodeTimeCore

/// Third-round reliability regressions (CT-058 … CT-069).
/// These tests pin the fixes for the second review round: the iCloud acceptance
/// gate, repository discovery fail-closed behavior, migration coordination,
/// job-lease atomicity, cloud verification state, project status derivation,
/// lock scoping, staging reclamation, the manual release workflow and the
/// regression gate itself.
final class ThirdRoundRegressionTests: XCTestCase {
    private var root: URL!
    private var keychain: KeychainStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codetime-ct3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Clean up any leftover lifecycle lock files from previous tests.
        let lifecycleDir = root.deletingLastPathComponent()
            .appendingPathComponent(".codetime-lifecycle", isDirectory: true)
        try? FileManager.default.removeItem(at: lifecycleDir)
        keychain = KeychainStore(service: "com.codetime.test.ct3.\(UUID().uuidString)")
        keychain.deleteAllSecrets()
    }

    override func tearDownWithError() throws {
        keychain.deleteAllSecrets()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CodeTimeKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // CodeTimeKit
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    private func makePaths() throws -> AppPaths {
        let paths = AppPaths(root: root.appendingPathComponent("app-\(UUID().uuidString)", isDirectory: true))
        try paths.createDirectories()
        return paths
    }

    private func runScript(_ script: URL, arguments: [String], environment: [String: String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        var environment = environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = stdout
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - CT-058 iCloud acceptance gate

    private func acceptanceReport(
        tag: String,
        commit: String?,
        results: [String],
        conclusion: String = "PASS",
        failures: String = "无 FAIL 项",
        templateMarker: Bool = false
    ) -> String {
        var lines: [String] = ["# iCloud 双 Mac 验收记录"]
        if templateMarker {
            lines.append("将本文件复制为 Docs/releases/<tag>-icloud-acceptance.md")
        }
        lines.append("- 发布 tag：\(tag)")
        if let commit { lines.append("- 构建 commit：\(commit)") }
        lines.append("- 执行时间：2026-11-07 14:00:00")
        lines.append("- 执行人：regression-operator")
        lines.append("- Mac A：MacBook Pro / macOS 15.0 / 构建 100")
        lines.append("- Mac B：Mac mini / macOS 15.0 / 构建 100")
        lines.append("")
        lines.append("| 场景 | 操作 | 结果 |")
        lines.append("|---|---|---|")
        let operations = ["首次上传", "第二台发现", "未下载读取", "上传中断", "恢复", "迁移", "密钥不匹配"]
        for (index, operation) in operations.enumerated() {
            lines.append("| \(operation) | 执行场景 \(index + 1) | \(results[index]) |")
        }
        lines.append("")
        lines.append("- 结果：\(conclusion)")
        lines.append("- 未通过项与原因：\(failures)")
        return lines.joined(separator: "\n") + "\n"
    }

    private func writeAcceptanceReport(_ text: String, tag: String) throws -> String {
        let report = root.appendingPathComponent("acceptance-\(UUID().uuidString).md")
        try text.write(to: report, atomically: true, encoding: .utf8)
        return report.path
    }

    private func runAcceptanceGate(tag: String, report: String) throws -> (status: Int32, output: String) {
        try runScript(
            packageRoot.appendingPathComponent("Scripts/require_icloud_acceptance.sh"),
            arguments: [tag],
            environment: ["ICLOUD_ACCEPTANCE_REPORT": report]
        )
    }

    func testCT058_AcceptanceGateAcceptsCompletePassReport() throws {
        let tag = "v9.9.9-ct058.\(UUID().uuidString.prefix(4))"
        let results = [String](repeating: "PASS", count: 7)
        let report = try writeAcceptanceReport(
            acceptanceReport(tag: tag, commit: ProcessInfo.processInfo.environment["GITHUB_SHA"], results: results),
            tag: tag
        )
        let (status, output) = try runAcceptanceGate(tag: tag, report: report)
        XCTAssertEqual(status, 0, output)
        // A summary line saying "no FAIL items" must not be mistaken for a failure.
        XCTAssertTrue(output.contains("PASS"), output)
    }

    func testCT058_AcceptanceGateRejectsTemplateAndIncompleteReports() throws {
        let tag = "v9.9.9-ct058.\(UUID().uuidString.prefix(4))"

        // 1. A straight copy of the template is rejected.
        let template = try String(
            contentsOf: packageRoot.appendingPathComponent("Docs/releases/ICLOUD_ACCEPTANCE_TEMPLATE.md"),
            encoding: .utf8
        )
        let templateCopy = try writeAcceptanceReport(template, tag: tag)
        XCTAssertEqual(try runAcceptanceGate(tag: tag, report: templateCopy).status != 0, true)

        // 2. All rows filled FAIL is rejected even though the template text is gone.
        let failed = try writeAcceptanceReport(
            acceptanceReport(tag: tag, commit: nil, results: [String](repeating: "FAIL", count: 7), conclusion: "FAIL", failures: "全部失败"),
            tag: tag
        )
        XCTAssertNotEqual(try runAcceptanceGate(tag: tag, report: failed).status, 0)

        // 3. One missing PASS row is rejected.
        var mixed = [String](repeating: "PASS", count: 7)
        mixed[3] = "RESULT_PLACEHOLDER"
        let placeholder = try writeAcceptanceReport(
            acceptanceReport(tag: tag, commit: nil, results: mixed),
            tag: tag
        )
        XCTAssertNotEqual(try runAcceptanceGate(tag: tag, report: placeholder).status, 0)

        // 4. Tag mismatch is rejected.
        let wrongTag = try writeAcceptanceReport(
            acceptanceReport(tag: "v0.0.0-other", commit: nil, results: [String](repeating: "PASS", count: 7)),
            tag: tag
        )
        XCTAssertNotEqual(try runAcceptanceGate(tag: tag, report: wrongTag).status, 0)

        // 5. Missing operator is rejected.
        let noOperator = acceptanceReport(tag: tag, commit: nil, results: [String](repeating: "PASS", count: 7))
            .replacingOccurrences(of: "- 执行人：regression-operator", with: "- 执行人：")
        let noOperatorPath = try writeAcceptanceReport(noOperator, tag: tag)
        XCTAssertNotEqual(try runAcceptanceGate(tag: tag, report: noOperatorPath).status, 0)
    }

    // MARK: - CT-059 repository discovery

    private func record(_ id: UUID, name: String) -> RepositoryRecord {
        RepositoryRecord(id: id, path: "/tmp/\(name)/repo", configPath: "/tmp/\(name)/kopia.config")
    }

    func testCT059_SelectPrefersRegisteredRepositoryAmongDiscovered() throws {
        let registered = UUID()
        let otherA = UUID()
        let otherB = UUID()

        // Registered repository present among several: the registered one wins.
        let preferred = try RepositoryDiscovery.select(
            stored: record(registered, name: "a"),
            discovered: [record(otherA, name: "b"), record(registered, name: "a"), record(otherB, name: "c")]
        )
        XCTAssertEqual(preferred?.id, registered)

        // Registered repository lost while other repositories exist: never switch.
        XCTAssertThrowsError(try RepositoryDiscovery.select(
            stored: record(registered, name: "a"),
            discovered: [record(otherA, name: "b"), record(otherB, name: "c")]
        ))
        XCTAssertThrowsError(try RepositoryDiscovery.select(
            stored: record(registered, name: "a"),
            discovered: [record(otherA, name: "b")]
        ))

        // Registered repository lost and nothing on disk: keep the record so the
        // app reports an uninitialized/missing state instead of minting a new ID.
        let kept = try RepositoryDiscovery.select(stored: record(registered, name: "a"), discovered: [])
        XCTAssertEqual(kept?.id, registered)

        // No registration: adopt exactly one, refuse to guess among many.
        XCTAssertEqual(try RepositoryDiscovery.select(stored: nil, discovered: [record(otherA, name: "b")])?.id, otherA)
        XCTAssertNil(try RepositoryDiscovery.select(stored: nil, discovered: []))
        XCTAssertThrowsError(try RepositoryDiscovery.select(
            stored: nil,
            discovered: [record(otherA, name: "b"), record(otherB, name: "c")]
        ))
    }

    func testCT059_LostDatabaseAndKeychainFailsClosed() async throws {
        let paths = try makePaths()
        let repoID = UUID()
        // Simulate a leftover Beta repository directory without any SQLite/Keychain.
        try FileManager.default.createDirectory(
            at: paths.repositories.appendingPathComponent(repoID.uuidString, isDirectory: true)
                .appendingPathComponent("repo", isDirectory: true),
            withIntermediateDirectories: true
        )

        let service = try CodeTimeService(paths: paths, keychain: keychain)
        do {
            _ = try await service.bootstrap()
            XCTFail("发现已有仓库但 Keychain 为空时必须 fail-closed")
        } catch {
            // The bootstrap must stop; it must not have minted replacement keys.
            XCTAssertThrowsError(try keychain.masterKey())
        }

        // The discovered repository is adopted into the database (with its real
        // ID) so the recovery UI can target it, and no second repository exists.
        let adopted = try await service.database.codable(
            RepositoryRecord.self,
            forKey: CodeTimeService.Keys.repository
        )
        XCTAssertEqual(adopted?.id, repoID)
        XCTAssertEqual(try RepositoryDiscovery.discover(in: paths.repositories).count, 1)
    }

    // MARK: - CT-060/061 migration coordination

    private func makeBetaSource() throws -> URL {
        let source = root.appendingPathComponent("beta-data-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("database"), withIntermediateDirectories: true)
        // A real SQLite database: the migration verifies the backup with a real
        // SQLite backup/step check, a text file would fail verification.
        _ = try SQLiteStore(path: source.appendingPathComponent("database/codetime.sqlite").path)
        let repository = source
            .appendingPathComponent("repositories", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try "kopia-format".write(to: repository.appendingPathComponent("kopia.repository"), atomically: true, encoding: .utf8)
        return source
    }

    func testCT060_MigrationBlocksWhileBetaAgentLockIsHeld() async throws {
        let source = try makeBetaSource()
        let target = root.appendingPathComponent("release-data", isDirectory: true)
        try DataMigrator.requestMigration(source: source, target: target, allowReplaceRoot: true)

        let agentLock = RepositoryLock(path: target.appendingPathComponent("agent.lock").path)
        // The Release agent itself must back off while a migration is pending.
        XCTAssertTrue(DataMigrator.hasPendingRequest(target: target))

        let sourceAgentLock = RepositoryLock(path: source.appendingPathComponent("agent.lock").path)
        XCTAssertTrue(sourceAgentLock.tryAcquire())
        do {
            _ = try DataMigrator.performPending(target: target)
            XCTFail("源 Beta Agent 持锁时迁移必须被拒绝")
        } catch let error as MigrationError {
            XCTAssertTrue(error.localizedDescription.contains("Beta Agent"), error.localizedDescription)
        }
        sourceAgentLock.release()

        // Once the source app is gone the same request completes end to end.
        let result = try DataMigrator.performPending(target: target)
        XCTAssertGreaterThanOrEqual(result?.fileCount ?? 0, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("database/codetime.sqlite").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("migration-complete.json").path))
        XCTAssertFalse(DataMigrator.hasPendingRequest(target: target))
        // The Beta source is never destroyed.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("database/codetime.sqlite").path))
    }

    func testCT061_PendingMigrationRequestLifecycle() async throws {
        let source = try makeBetaSource()
        let target = root.appendingPathComponent("release-data", isDirectory: true)
        XCTAssertFalse(DataMigrator.hasPendingRequest(target: target))
        XCTAssertNil(try DataMigrator.performPending(target: target))

        try DataMigrator.requestMigration(source: source, target: target, allowReplaceRoot: true)
        XCTAssertTrue(DataMigrator.hasPendingRequest(target: target))

        _ = try DataMigrator.performPending(target: target)
        XCTAssertFalse(DataMigrator.hasPendingRequest(target: target))
    }

    // MARK: - CT-062 keychain repair after Beta → Release

    func testCT062_KeychainRepairFromCloudRestoresAccess() async throws {
        let paths = try makePaths()
        let mirror = root.appendingPathComponent("mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)

        let service = try CodeTimeService(paths: paths, keychain: keychain)
        _ = try await service.bootstrap()
        let recoveryKey = try keychain.recoveryKeyText()
        let originalPassword = try keychain.repositoryPassword()

        var settings = try await service.currentSettings()
        settings.localMirrorPath = mirror.path
        try await service.saveSettings(settings)

        let source = root.appendingPathComponent("project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "func repair() {}\n".write(to: source.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        let project = try await service.addProject(url: source)
        let outcome = try await service.createSnapshot(projectID: project.id, trigger: .manual)
        XCTAssertNil(outcome.cloudError, "云端发布必须先写入恢复凭据")

        // Simulate the Release binary being unable to read the Beta Keychain item.
        keychain.deleteAllSecrets()
        XCTAssertThrowsError(try keychain.masterKey())

        // A wrong recovery key is rejected; nothing is installed.
        let wrongKey = RecoveryKey.format(try CryptoBox.randomBytes(count: 32))
        do {
            _ = try await service.installSecretsFromCloud(storageRoot: mirror, recoveryKeyText: wrongKey)
            XCTFail("错误的恢复密钥必须被拒绝")
        } catch { }
        XCTAssertThrowsError(try keychain.masterKey())

        // The real recovery key restores both secrets without touching the repo.
        try await service.installSecretsFromCloud(storageRoot: mirror, recoveryKeyText: recoveryKey)
        XCTAssertEqual(try keychain.repositoryPassword(), originalPassword)
        XCTAssertEqual(try keychain.masterKey(), try RecoveryKey.parse(recoveryKey))
        _ = try await service.bootstrap()
        XCTAssertEqual(try keychain.repositoryPassword(), originalPassword)
    }

    // MARK: - CT-063 job lease atomicity

    func testCT063_LeaseClaimAndOwnerChecksAreAtomic() async throws {
        let paths = try makePaths()
        let databaseA = try SQLiteStore(path: paths.database.path)
        let databaseB = try SQLiteStore(path: paths.database.path)
        // Two distinct identities (the test process is one, so the second is
        // synthesized with a different PID to model another machine/process).
        let realOwner = ProcessIdentity.current(isAgent: false)
        let ownerA = ProcessIdentity(pid: realOwner.pid, startTime: realOwner.startTime, isAgent: false)
        let ownerB = ProcessIdentity(pid: realOwner.pid &+ 77_777, startTime: realOwner.startTime + 5, isAgent: true)
        let project = Project(name: "lease", rootPath: "/tmp/lease")
        try await databaseA.upsertProject(project)

        // A wins the project; a second plain claim is rejected while the lease lives.
        let first = try await databaseA.claimBackupJob(
            projectID: project.id, retryJobID: nil, trigger: .manual,
            owner: ownerA, expiresAt: Date().addingTimeInterval(60)
        )
        let firstJob = try XCTUnwrap(first?.job)
        let blockedPlain = try await databaseB.claimBackupJob(
            projectID: project.id, retryJobID: nil, trigger: .manual,
            owner: ownerB, expiresAt: Date().addingTimeInterval(60)
        )
        XCTAssertNil(blockedPlain)

        // A retry claim must never steal a live lease by job ID.
        let blockedSteal = try await databaseB.claimBackupJob(
            projectID: project.id, retryJobID: firstJob.id, trigger: .retry,
            owner: ownerB, expiresAt: Date().addingTimeInterval(60)
        )
        XCTAssertNil(blockedSteal, "重试声明不得窃取活跃租约")

        // Owner-checked terminal updates: a stale worker cannot finish the job.
        try await databaseB.finishJob(id: firstJob.id, state: .succeeded, owner: ownerB)
        let afterStaleFinish = try await databaseA.job(id: firstJob.id)
        XCTAssertEqual(afterStaleFinish?.state, .running)
        XCTAssertNotNil(afterStaleFinish?.lease)

        try await databaseA.finishJob(id: firstJob.id, state: .succeeded, owner: ownerA)
        let afterOwnerFinish = try await databaseA.job(id: firstJob.id)
        XCTAssertEqual(afterOwnerFinish?.state, .succeeded)
        XCTAssertNil(afterOwnerFinish?.lease)

        // Retry scheduling is owner-checked too.
        let second = try await databaseA.claimBackupJob(
            projectID: project.id, retryJobID: nil, trigger: .scheduled,
            owner: ownerA, expiresAt: Date().addingTimeInterval(60)
        )
        let secondJob = try XCTUnwrap(second?.job)
        let staleRetry = try await databaseB.scheduleRetry(
            id: secondJob.id, owner: ownerB, after: 60, errorClass: .unknown, message: "b"
        )
        XCTAssertFalse(staleRetry)
        let ownerRetry = try await databaseA.scheduleRetry(
            id: secondJob.id, owner: ownerA, after: 60, errorClass: .unknown, message: "a"
        )
        XCTAssertTrue(ownerRetry)
        let retried = try await databaseA.job(id: secondJob.id)
        XCTAssertEqual(retried?.state, .queued)
        XCTAssertNil(retried?.lease)

        // An expired lease may only be reclaimed when its owner is provably gone.
        // A live process with an expired lease still blocks the project.
        let liveOwnerExpired = try await databaseA.claimBackupJob(
            projectID: project.id, retryJobID: nil, trigger: .manual,
            owner: ownerA, expiresAt: Date().addingTimeInterval(-1)
        )
        XCTAssertNotNil(liveOwnerExpired)
        let blockedWhileOwnerAlive = try await databaseB.claimBackupJob(
            projectID: project.id, retryJobID: nil, trigger: .manual,
            owner: ownerB, expiresAt: Date().addingTimeInterval(60)
        )
        XCTAssertNil(blockedWhileOwnerAlive)

        // The live owner finishes its own job; the project is free again.
        try await databaseA.finishJob(id: liveOwnerExpired!.job.id, state: .succeeded, owner: ownerA)

        // A dead owner (fabricated PID that no longer exists) with an expired
        // lease may claim, and the project becomes reclaimable by the next job.
        let deadOwner = ProcessIdentity(pid: 2_000_000_001, startTime: 123.0, isAgent: false)
        XCTAssertFalse(deadOwner.isAlive)
        let expired = try await databaseA.claimBackupJob(
            projectID: project.id, retryJobID: nil, trigger: .manual,
            owner: deadOwner, expiresAt: Date().addingTimeInterval(-1)
        )
        XCTAssertNotNil(expired)
        let reclaimed = try await databaseB.claimBackupJob(
            projectID: project.id, retryJobID: nil, trigger: .manual,
            owner: ownerB, expiresAt: Date().addingTimeInterval(60)
        )
        XCTAssertNotNil(reclaimed)
        XCTAssertNotEqual(reclaimed?.job.id, secondJob.id)
    }

    func testCT063_TwoServicesProduceExactlyOneSnapshot() async throws {
        let paths = try makePaths()
        let serviceA = try CodeTimeService(paths: paths, keychain: keychain)
        let serviceB = try CodeTimeService(paths: paths, keychain: keychain)
        _ = try await serviceA.bootstrap()
        _ = try await serviceB.bootstrap()

        let source = root.appendingPathComponent("project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "one\n".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let project = try await serviceA.addProject(url: source)

        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await serviceA.createSnapshot(projectID: project.id, trigger: .manual)) != nil }
            group.addTask { (try? await serviceB.createSnapshot(projectID: project.id, trigger: .manual)) != nil }
            var successes = 0
            for try await succeeded in group where succeeded { successes += 1 }
            XCTAssertEqual(successes, 1, "两个进程竞争同一项目时只允许一个快照成功")
        }

        let snapshots = try await serviceA.database.snapshots(projectID: project.id)
        XCTAssertEqual(snapshots.count, 1)
    }

    // MARK: - CT-064 stale verified state

    func testCT064_VerifyCloudClearsStaleVerifiedOnUnreadableNewest() async throws {
        let cloud = try RegressionCloud(name: "ct064")
        try cloud.workspace.writeFile("kopia.repository", "format-block")
        let device = UUID()
        let store = cloud.store(deviceID: device)
        let generation1 = try await cloud.publish(store, deviceID: device)
        let generation2 = try await cloud.publish(store, deviceID: device)

        let paths = try makePaths()
        try keychain.installSecrets(masterKey: cloud.masterKey, repositoryPassword: cloud.password)
        let service = try CodeTimeService(paths: paths, keychain: keychain)
        try await service.database.setCodable(
            DeviceIdentity(id: device, name: "ct064", model: "test"),
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

        // Both generations were verified in the past.
        for generation in [generation1, generation2] {
            try await service.database.upsertGeneration(CloudGeneration(
                id: generation,
                repositoryID: cloud.repositoryID,
                deviceID: device,
                createdAt: Date(),
                state: .verified,
                verifiedAt: Date()
            ))
        }

        // The newest manifest becomes unreadable (wrong key / corruption).
        try Data("corrupted-manifest".utf8).write(
            to: cloud.workspace.commitURL(deviceID: device, repositoryID: cloud.repositoryID, generationID: generation2)
        )

        let result = try await service.verifyCloud()
        XCTAssertEqual(result?.outcome, .failed)
        XCTAssertEqual(result?.generationID, generation2)

        // The stale verified state on the newest generation is gone; the older
        // generation keeps its history.
        let storedNewest = try await service.database.generation(id: generation2)
        XCTAssertNil(storedNewest?.verifiedAt)
        let storedOlder = try await service.database.generation(id: generation1)
        XCTAssertNotNil(storedOlder?.verifiedAt)

        // The unreadable newest generation stays visible instead of being
        // silently dropped in favor of the older one.
        let listed = try await service.cloudGenerations()
        XCTAssertEqual(listed.first?.id, generation2)
        XCTAssertEqual(listed.first?.state, .failed)
        XCTAssertTrue(listed.contains { $0.id == generation1 })
    }

    // MARK: - CT-065 project status follows the newest snapshot

    func testCT065_ProjectStatusFollowsNewestSnapshot() async throws {
        let paths = try makePaths()
        let service = try CodeTimeService(paths: paths, keychain: keychain)
        let project = Project(name: "status", rootPath: "/tmp/status-\(UUID().uuidString)")
        try await service.database.upsertProject(project)

        let older = Snapshot(id: "old", projectID: project.id, createdAt: Date().addingTimeInterval(-100), cloudState: .synced)
        let newest = Snapshot(id: "new", projectID: project.id, createdAt: Date(), cloudState: .failed)
        try await service.database.upsertSnapshot(older)
        try await service.database.upsertSnapshot(newest)

        // An older upload success must not mark the project synced while its
        // newest snapshot is still failed.
        await service.refreshProjectCloudStatus(projectID: project.id)
        let warningProject = try await service.database.project(id: project.id)
        XCTAssertEqual(warningProject?.status, .warning)

        var newestFixed = newest
        newestFixed.cloudState = .synced
        try await service.database.upsertSnapshot(newestFixed)
        await service.refreshProjectCloudStatus(projectID: project.id)
        let syncedProject = try await service.database.project(id: project.id)
        XCTAssertEqual(syncedProject?.status, .synced)
        XCTAssertNil(syncedProject?.lastError)
    }

    // MARK: - CT-066 lock scoping

    actor LockProbeTracker: CloudUploadTracking {
        let lockPath: String
        private(set) var violations = 0

        init(lockPath: String) {
            self.lockPath = lockPath
        }

        func waitForUpload(_ url: URL, timeout: TimeInterval) async throws {
            let lock = RepositoryLock(path: lockPath)
            if lock.tryAcquire() {
                lock.release()
            } else {
                violations += 1
            }
        }
    }

    func testCT066_GCPublishDoNotHoldRepositoryLock() async throws {
        let cloud = try RegressionCloud(name: "ct066")
        try cloud.workspace.writeFile("kopia.repository", "format-block")
        let device = UUID()
        let lockURL = cloud.workspace.root.appendingPathComponent("repository.lock")
        let publishLockURL = cloud.workspace.root.appendingPathComponent("publish.lock")
        let tracker = LockProbeTracker(lockPath: lockURL.path)
        let journals = MemoryJournalStore()
        journals.fastForwardGraceDeadline = true
        let store = cloud.store(
            deviceID: device, tracker: tracker, lockURL: lockURL, publishLockURL: publishLockURL,
            journalStore: journals
        )

        // Fresh publish: the repository lock must be released before the cloud
        // upload waits begin.
        let generation = try await cloud.publish(store, deviceID: device)

        // Idempotent republish of the same manifest: same requirement.
        let repeated = CloudGeneration(
            id: generation,
            repositoryID: cloud.repositoryID,
            deviceID: device,
            createdAt: Date(),
            snapshotIDs: []
        )
        try await store.publish(repositoryId: cloud.repositoryID, generation: repeated)
        let publishViolations = await tracker.violations
        XCTAssertEqual(publishViolations, 0, "上传等待期间不得持有本地仓库锁")

        // GC only touches cloud objects: it completes while the local Kopia
        // repository lock is held by someone else.
        let heldLock = RepositoryLock(path: lockURL.path)
        XCTAssertTrue(heldLock.tryAcquire())
        defer { heldLock.release() }
        // The first sweep may arm the synchronization grace journal; a resumed
        // sweep (fast-forwarded deadline) must complete while the lock is held.
        _ = try await store.cleanup(
            repositoryId: cloud.repositoryID,
            gracePeriod: 0,
            minimumGenerations: 2
        )
        let report = try await store.cleanup(
            repositoryId: cloud.repositoryID,
            gracePeriod: 0,
            minimumGenerations: 2
        )
        XCTAssertNil(report.skippedReason, report.skippedReason ?? "")
        let cleanupViolations = await tracker.violations
        XCTAssertEqual(cleanupViolations, 0)
    }

    // MARK: - CT-067 interrupted migration staging

    private func writeMigrationJournal(target: URL, state: String, staging: URL) throws {
        let json = """
        {"jobID":"\(UUID().uuidString)","state":"\(state)","sourceRoot":"\(staging.path)",\
        "stagingPath":"\(staging.path)","startedAt":"2026-11-07T00:00:00Z",\
        "updatedAt":"2026-11-07T00:00:00Z"}
        """
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try json.write(to: target.appendingPathComponent(DataMigrator.journalName), atomically: true, encoding: .utf8)
    }

    func testCT067_InterruptedMigrationStagingIsReclaimed() async throws {
        // installing + target present: the prepared copy is redundant and must go.
        let parentA = root.appendingPathComponent("case-a", isDirectory: true)
        try FileManager.default.createDirectory(at: parentA, withIntermediateDirectories: true)
        let targetA = parentA.appendingPathComponent("target", isDirectory: true)
        let stagingA = parentA.appendingPathComponent(".codetime-migration-aaaa", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingA, withIntermediateDirectories: true)
        try "data".write(to: stagingA.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        try writeMigrationJournal(target: targetA, state: "installing", staging: stagingA)
        DataMigrator.clearInterruptedStaging(target: targetA)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingA.path))

        // Any pre-install state is always safe to reclaim.
        let parentB = root.appendingPathComponent("case-b", isDirectory: true)
        try FileManager.default.createDirectory(at: parentB, withIntermediateDirectories: true)
        let targetB = parentB.appendingPathComponent("target", isDirectory: true)
        let stagingB = parentB.appendingPathComponent(".codetime-migration-bbbb", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingB, withIntermediateDirectories: true)
        try writeMigrationJournal(target: targetB, state: "copying", staging: stagingB)
        DataMigrator.clearInterruptedStaging(target: targetB)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingB.path))

        // No journal: never touch unrelated directories.
        let parentC = root.appendingPathComponent("case-c", isDirectory: true)
        try FileManager.default.createDirectory(at: parentC, withIntermediateDirectories: true)
        let stagingC = parentC.appendingPathComponent(".codetime-migration-cccc", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingC, withIntermediateDirectories: true)
        DataMigrator.clearInterruptedStaging(target: parentC.appendingPathComponent("target", isDirectory: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingC.path))

        // A cancelled migration cleans its staging and leaves a retryable source.
        let source = try makeBetaSource()
        let cancelParent = root.appendingPathComponent("case-d", isDirectory: true)
        try FileManager.default.createDirectory(at: cancelParent, withIntermediateDirectories: true)
        let target = cancelParent.appendingPathComponent("target", isDirectory: true)
        var cancellations = 0
        XCTAssertThrowsError(try DataMigrator.migrate(
            source: source,
            target: target,
            isCancelled: { cancellations += 1; return cancellations > 1 }
        ))
        // Staging lives next to the target root, not inside it.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: cancelParent.path))?
            .filter { $0.hasPrefix(".codetime-migration-") } ?? []
        XCTAssertTrue(leftovers.isEmpty, "取消后残留 staging：\(leftovers)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("database/codetime.sqlite").path))

        // The retry then completes and installs the whole root.
        let result = try DataMigrator.migrate(source: source, target: target, replaceRoot: true)
        XCTAssertEqual(result.fileCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("database/codetime.sqlite").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("repositories").path))
    }

    // MARK: - CT-068 manual dispatch release

    func testCT068_ManualDispatchPublishesRelease() throws {
        let workflowURL = packageRoot.appendingPathComponent(".github/workflows/release.yml")
        let text = try String(contentsOf: workflowURL, encoding: .utf8)

        // The manual dispatch input exists and every publish step is gated on it.
        XCTAssertTrue(text.contains("publish_release:"), "缺少 publish_release 手动输入")
        XCTAssertTrue(text.contains("actions/upload-artifact@v4"), "手动运行必须上传 dist 产物")
        let gated = text.components(separatedBy: .newlines).filter { $0.contains("inputs.publish_release") }
        XCTAssertGreaterThanOrEqual(gated.count, 2, "pre-release 与 stable 发布步骤都必须支持手动发布")

        // The workflow must remain structurally valid YAML.
        // Prefer a known-working interpreter; /usr/bin/ruby on some hosts is a
        // shim that cannot execute, so a failed attempt falls through to text
        // assertions instead of failing the regression.
        let rubyCandidates = [
            "/opt/homebrew/opt/ruby/bin/ruby", "/opt/homebrew/bin/ruby",
            "/usr/bin/ruby",
        ]
        var ruby: String?
        for candidate in rubyCandidates where FileManager.default.isExecutableFile(atPath: candidate) {
            if let (_, output) = try? runScript(URL(fileURLWithPath: candidate), arguments: ["-e", "puts 1"], environment: [:]),
               output.contains("1") {
                ruby = candidate
                break
            }
        }
        guard let ruby else {
            // No usable interpreter: the text assertions above still hold.
            return
        }
        let script = root.appendingPathComponent("ct068-check.rb")
        try """
        require "yaml"
        doc = YAML.load_file(ARGV[0])
        triggers = doc[true] || doc["on"] || {}
        dispatch = triggers["workflow_dispatch"] || triggers[:workflow_dispatch]
        abort "missing workflow_dispatch" unless dispatch
        inputs = dispatch["inputs"] || dispatch[:inputs] || {}
        abort "missing publish_release input" unless inputs["publish_release"] || inputs[:publish_release]
        jobs = doc["jobs"] || {}
        gated = 0
        jobs.each_value do |job|
          (job["steps"] || []).each do |step|
            name = (step["name"] || step[:name] || "").to_s
            condition = (step["if"] || step[:if] || "").to_s
            gated += 1 if name.include?("Publish") && condition.include?("inputs.publish_release")
          end
        end
        abort "expected at least two gated publish steps, got #{gated}" unless gated >= 2
        puts "CT068_YAML_OK"
        """.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        let (status, output) = try runScript(URL(fileURLWithPath: ruby), arguments: [script.path, workflowURL.path], environment: [:])
        XCTAssertEqual(status, 0, output)
        XCTAssertTrue(output.contains("CT068_YAML_OK"), output)
    }

    // MARK: - CT-069 regression gate

    private func gateTranscript(including ids: ClosedRange<Int> = 1...69, skipped: [String] = []) -> String {
        var lines: [String] = []
        for number in ids {
            lines.append("Test Case '-[CodeTimeKitTests.RegressionTests testCT\(String(format: "%03d", number))_x]' passed (0.1 seconds).")
        }
        for name in skipped {
            lines.append("Test Case '-[CodeTimeKitTests.RegressionTests \(name)]' skipped (0.00 seconds).")
        }
        lines.append("Executed \(ids.count + skipped.count) tests, with 0 failures (0 unexpected) in 1.0 seconds")
        return lines.joined(separator: "\n") + "\n"
    }

    private func runGate(output: String) throws -> (status: Int32, output: String) {
        let transcript = root.appendingPathComponent("gate-output-\(UUID().uuidString).txt")
        try output.write(to: transcript, atomically: true, encoding: .utf8)
        return try runScript(
            packageRoot.appendingPathComponent("Scripts/regression_gate.sh"),
            arguments: [],
            environment: ["REGRESSION_OUTPUT_FILE": transcript.path]
        )
    }

    func testCT069_GateRejectsMissingTestsAndUnexpectedSkips() throws {
        // Complete transcript: only documented skips are allowed.
        let complete = try runGate(
            output: gateTranscript(skipped: ["testSingleMacICloudRoundTrip", "testCT036_LargeFileSet"])
        )
        XCTAssertEqual(complete.status, 0, complete.output)
        XCTAssertTrue(complete.output.contains("regression gate: PASS"), complete.output)

        // A missing permanent regression fails the gate.
        let missing = try runGate(output: gateTranscript(including: 1...68))
        XCTAssertNotEqual(missing.status, 0, missing.output)
        XCTAssertTrue(missing.output.contains("CT-069"), missing.output)

        // An undocumented skip fails the gate even though the test name exists.
        let undocumentedSkip = try runGate(
            output: gateTranscript(skipped: ["testCT010_LegacyBehavior"])
        )
        XCTAssertNotEqual(undocumentedSkip.status, 0, undocumentedSkip.output)
        XCTAssertTrue(undocumentedSkip.output.contains("unexpected skipped test"), undocumentedSkip.output)

        // A failing suite still fails the gate.
        let failing = gateTranscript().replacingOccurrences(of: "with 0 failures", with: "with 1 failure")
        let failedGate = try runGate(output: failing)
        XCTAssertNotEqual(failedGate.status, 0, failedGate.output)
    }
}
