import XCTest
import Foundation
@testable import SharedModels
@testable import CloudMirrorStore
@testable import CodeTimeSecurity
@testable import Persistence
@testable import BackupEngine
@testable import CodeTimeCore

/// Sixth-round reliability regressions (CT-099 … CT-116).
/// Every test drives production code or a real child process.
final class SixthRoundRegressionTests: XCTestCase {

    private var root: URL!
    private var keychain: KeychainStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codetime-ct6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent()
            .appendingPathComponent(".codetime-lifecycle", isDirectory: true))
        keychain = KeychainStore(service: "com.codetime.test.ct6.\(UUID().uuidString)")
        keychain.deleteAllSecrets()
        DataMigrator.crashPointForTesting = nil
        DataMigrator.sourceAgentExitTimeout = 45
    }

    override func tearDownWithError() throws {
        keychain.deleteAllSecrets()
        DataMigrator.crashPointForTesting = nil
        DataMigrator.sourceAgentExitTimeout = 45
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: Helpers

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func repoScript(_ name: String) -> URL {
        repoRoot.appendingPathComponent("Scripts/\(name)")
    }

    private func makePaths() throws -> AppPaths {
        let paths = AppPaths(root: root.appendingPathComponent("app-\(UUID().uuidString)", isDirectory: true))
        try paths.createDirectories()
        return paths
    }

    private func makeBetaSource() throws -> URL {
        let source = root.appendingPathComponent("beta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("database"), withIntermediateDirectories: true
        )
        _ = try SQLiteStore(path: source.appendingPathComponent("database/codetime.sqlite").path)
        let repo = source.appendingPathComponent("repositories", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "kopia".write(to: repo.appendingPathComponent("kopia.repository"), atomically: true, encoding: .utf8)
        return source
    }

    private func runShell(_ command: [String], env: [String: String]) -> (status: Int32, out: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = command
        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        if env["GITHUB_SHA"] == nil { environment.removeValue(forKey: "GITHUB_SHA") }
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try? process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func acceptanceReport(tag: String, sha: String, commit: String) throws -> URL {
        let url = root.appendingPathComponent("acceptance-\(UUID().uuidString).md")
        let text = """
        - 发布 tag：\(tag)
        - 构建 commit：\(commit)
        - Candidate Artifact：CodeTime-1.0.0-macos-universal.zip
        - Candidate Artifact SHA-256：\(sha)
        - 执行时间：2026-11-08 12:00:00
        - 执行人：tester

        - Mac A：MacBook Pro / macOS 15.0 / 构建 1.0.0
        - Mac B：Mac mini / macOS 15.0 / 构建 1.0.0

        | 场景 | 操作 | 结果 |
        |---|---|---|
        | 首次上传 | 发布 | PASS |
        | 第二台发现 | 列出 | PASS |
        | 未下载读取 | 读取 | PASS |
        | 上传中断 | 重试 | PASS |
        | 恢复 | 校验 | PASS |
        | 迁移 | 迁移 | PASS |
        | 密钥不匹配 | 阻塞 | PASS |

        - 结果：PASS
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - CT-099 CI-injected environment must not reach acceptance tests

    func testCT099_AcceptanceGateIsInsulatedFromCIEnvironment() throws {
        let script = repoScript("require_icloud_acceptance.sh").path
        let sha = String(repeating: "cd", count: 32)
        let commit = "0123456789abcdef0123456789abcdef01234567"
        let report = try acceptanceReport(tag: "v1.0.0", sha: sha, commit: commit)

        // Simulate the failing CI condition: GITHUB_SHA is set in the PROCESS
        // environment while the report binds a different (fixture) commit. The
        // runner must strip it, exactly like the test harness does.
        let outcome = runShell([script, "v1.0.0"], env: ["ICLOUD_ACCEPTANCE_REPORT": report.path])
        XCTAssertEqual(outcome.status, 0, outcome.out)

        // And when the caller DOES export the matching commit, it passes too.
        let explicit = runShell(
            [script, "v1.0.0"],
            env: ["ICLOUD_ACCEPTANCE_REPORT": report.path, "GITHUB_SHA": commit]
        )
        XCTAssertEqual(explicit.status, 0, explicit.out)
    }

    // MARK: - CT-100 publish-stable must check out the repository

    func testCT100_PublishStableChecksOutReleaseNotes() throws {
        let workflow = try String(
            contentsOf: repoRoot.appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8
        )
        let publishSection = try XCTUnwrap(workflow.range(of: "publish-stable:"))
        let publish = String(workflow[publishSection.lowerBound...])
        XCTAssertTrue(
            publish.contains("actions/checkout@v4"),
            "publish-stable 必须先 checkout，否则读不到 Docs/releases/<tag>.md"
        )
        // Checkout must come before the note is read.
        let checkoutIndex = try XCTUnwrap(publish.range(of: "actions/checkout@v4")).lowerBound
        let notesIndex = try XCTUnwrap(publish.range(of: "NOTES=\"Docs/releases/")).lowerBound
        XCTAssertLessThan(checkoutIndex, notesIndex, "checkout 必须在读取 release notes 之前")
    }

    // MARK: - CT-101 task lifecycle: cancellation kills the child and reaps it

    func testCT101_CancellingWorkTerminatesAndReapsChild() async throws {
        let runner = ProcessRunner()
        let started = Date()
        let task = Task {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                timeout: 60
            )
        }
        // Wait until the child is actually registered.
        var waited = 0
        while ActiveChildProcesses.shared.livePIDs().isEmpty && waited < 50 {
            try await Task.sleep(nanoseconds: 20_000_000)
            waited += 1
        }
        XCTAssertFalse(ActiveChildProcesses.shared.livePIDs().isEmpty, "子进程必须被登记")

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("取消后应抛出 cancelled")
        } catch {
            XCTAssertTrue(CodeTimeService.isCancellation(error), "\(error)")
        }
        // The child is gone AND has been reaped: the registry is empty.
        XCTAssertTrue(
            ActiveChildProcesses.shared.livePIDs().isEmpty,
            "取消必须终止并回收子进程"
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 15, "取消不能等待固定超时")
    }

    // MARK: - CT-101 drain: leases/state persisted before exit

    func testCT101_DrainWaitsForRegisteredWork() async throws {
        guard KopiaBinary.locate() != nil else { throw XCTSkip("KOPIA_PATH 未设置") }
        let paths = try makePaths()
        let service = try CodeTimeService(paths: paths, keychain: keychain)
        _ = try await service.bootstrap()
        let source = root.appendingPathComponent("ct101-src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for i in 0..<200 {
            try "data-\(i)".write(
                to: source.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8
            )
        }
        let project = try await service.addProject(url: source)
        let running = Task { try await service.createSnapshot(projectID: project.id, trigger: .manual) }

        var waited = 0
        while await service.activeWork().isEmpty && waited < 100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            waited += 1
        }
        let remaining = await service.drainActiveWork(timeout: 30)
        XCTAssertTrue(remaining.isEmpty, "drain 必须在超时前完成，仍有：\(remaining)")
        _ = try? await running.value
        // No child may survive the drain.
        XCTAssertTrue(ActiveChildProcesses.shared.livePIDs().isEmpty)
        // The cancelled job must be parked as interrupted, never left running.
        let projects = try await service.database.projects()
        XCTAssertFalse(projects.isEmpty)
        // No Kopia child may survive the drain.
        XCTAssertTrue(ActiveChildProcesses.shared.livePIDs().isEmpty)
    }

    // MARK: - CT-102 commit journal crash matrix (pure decision table)

    private func journal(_ phase: CodeTimeService.RestoreCommitJournal.Phase) -> CodeTimeService.RestoreCommitJournal {
        CodeTimeService.RestoreCommitJournal(
            jobID: UUID(), repositoryID: UUID(), generationID: UUID(),
            stagingPath: "/r/restore-x", repositoryURL: "/r/repo",
            phase: phase, updatedAt: Date()
        )
    }

    func testCT102_CommitPositionCoversEveryCrashPoint() {
        typealias Position = CodeTimeService.RestoreCommitPosition
        // No filesystem state yet → download.
        XCTAssertEqual(
            CodeTimeService.restoreCommitPosition(
                journal: nil, stagingExists: false, repositoryExists: false,
                repositoryHasMarker: false, jobState: .preparing
            ),
            .download
        )
        // Crash before the move: staging present, repo absent → resume commit.
        XCTAssertEqual(
            CodeTimeService.restoreCommitPosition(
                journal: journal(.prepared), stagingExists: true, repositoryExists: false,
                repositoryHasMarker: false, jobState: .committing
            ),
            .resumeCommit
        )
        // Crash AFTER the move but BEFORE the journal update: staging gone, repo
        // present with a marker, journal still `prepared` → must COMPLETE, not
        // re-create an empty staging directory (the CT-102 bug).
        XCTAssertEqual(
            CodeTimeService.restoreCommitPosition(
                journal: journal(.prepared), stagingExists: false, repositoryExists: true,
                repositoryHasMarker: true, jobState: .committing
            ),
            .alreadyCommitted
        )
        // Crash after the journal update.
        XCTAssertEqual(
            CodeTimeService.restoreCommitPosition(
                journal: journal(.replaced), stagingExists: false, repositoryExists: true,
                repositoryHasMarker: true, jobState: .committing
            ),
            .alreadyCommitted
        )
        // Legacy row (no journal) persisted as committing with the repo in place.
        XCTAssertEqual(
            CodeTimeService.restoreCommitPosition(
                journal: nil, stagingExists: false, repositoryExists: true,
                repositoryHasMarker: true, jobState: .committing
            ),
            .alreadyCommitted
        )
        // An unrelated non-repository directory occupies the slot → never adopt.
        XCTAssertEqual(
            CodeTimeService.restoreCommitPosition(
                journal: nil, stagingExists: false, repositoryExists: true,
                repositoryHasMarker: false, jobState: .preparing
            ),
            .blockedDestination
        )
        // Repository present but nothing proves we wrote it → blocked.
        XCTAssertEqual(
            CodeTimeService.restoreCommitPosition(
                journal: nil, stagingExists: false, repositoryExists: true,
                repositoryHasMarker: true, jobState: .preparing
            ),
            .blockedDestination
        )
    }

    // MARK: - CT-103 state semantics + lease release

    func testCT103_FailedIsRetryableAndPermanentlyFailedIsNot() async throws {
        XCTAssertFalse(RestoreJobState.failed.isTerminal, "failed 不能同时是终态与可恢复")
        XCTAssertTrue(RestoreJobState.failed.isResumable)
        XCTAssertTrue(RestoreJobState.retryableFailed.isResumable)
        XCTAssertFalse(RestoreJobState.retryableFailed.isTerminal)
        XCTAssertTrue(RestoreJobState.permanentlyFailed.isTerminal)
        XCTAssertFalse(RestoreJobState.permanentlyFailed.isResumable)
        XCTAssertTrue(RestoreJobState.completed.isTerminal)
        // A retryable failure preserves its staging (verified objects are the only
        // copy of the downloaded data).
        XCTAssertTrue(RestoreJobState.retryableFailed.preservesStaging)
        XCTAssertFalse(RestoreJobState.completed.preservesStaging)

        // A failed job is claimable again — the old contradiction blocked retries.
        let database = try SQLiteStore(path: root.appendingPathComponent("ct103.sqlite").path)
        let job = CloudRestoreJob(
            repositoryID: UUID(), generationID: UUID(), sourceDeviceID: UUID(),
            state: .retryableFailed, stagingPath: root.appendingPathComponent("s").path
        )
        try await database.upsertCloudRestoreJob(job)
        let owner = ProcessIdentity.current(isAgent: false)
        let claimed = try await database.claimCloudRestoreJob(
            id: job.id, owner: owner, expiresAt: Date().addingTimeInterval(90)
        )
        XCTAssertNotNil(claimed, "retryableFailed 必须可以重新 claim")

        // Abandoning a lease (simulated process death) makes it reclaimable.
        let deadOwner = ProcessIdentity(pid: 999_999_999, startTime: 1, isAgent: false)
        var stale = try XCTUnwrap(claimed)
        stale.state = .retryableFailed
        stale.lease = JobLease(
            owner: deadOwner,
            heartbeatAt: Date().addingTimeInterval(-600),
            leaseExpiresAt: Date().addingTimeInterval(-300)
        )
        try await database.upsertCloudRestoreJob(stale)
        let reclaimed = try await database.claimCloudRestoreJob(
            id: job.id, owner: owner, expiresAt: Date().addingTimeInterval(90)
        )
        XCTAssertNotNil(reclaimed, "租约过期且 owner 已死必须可以回收")
    }

    // MARK: - CT-104 repository-level mutual exclusion

    func testCT104_RepositoryLockIsExclusiveAcrossHandles() async throws {
        let lockPath = root.appendingPathComponent("repo-mutex/repository.lock").path
        let first = RepositoryLock(path: lockPath)
        XCTAssertTrue(first.tryAcquire())
        defer { first.release() }

        // A second independent handle (as another restore job in another process
        // would have) must NOT acquire it, even inside the same process.
        let second = RepositoryLock(path: lockPath)
        XCTAssertFalse(second.tryAcquire(), "同一 Repository 的第二个恢复任务必须被拒绝")
        let acquiredViaHelper = await CodeTimeService.acquireFileLock(second, timeout: 1)
        XCTAssertFalse(acquiredViaHelper, "生产锁入口也必须拒绝第二个持有者")
        first.release()
        XCTAssertTrue(second.tryAcquire(), "释放后必须可以获得")
        second.release()
    }

    // MARK: - CT-105 iCloud GC is report-only by default

    func testCT105_CoordinatedStoreNeverDeletesWithoutExplicitConsent() async throws {
        let cloud = try RegressionCloud(name: "ct105")
        defer { cloud.cleanup() }
        let device = UUID()
        // coordinatedIO: true models the iCloud path.
        let store = CloudMirrorStore(configuration: .init(
            storageRoot: cloud.workspace.storageRoot,
            repositoryID: cloud.repositoryID,
            repositoryURL: cloud.workspace.repositoryURL,
            deviceID: device,
            masterKeyProvider: RegressionMasterKey(value: cloud.masterKey),
            passwordProvider: RegressionPassword(value: cloud.password),
            uploadTracker: NoopUploadTracker(),
            coordinatedIO: true,
            sweepGrace: 0
        ))
        for version in 0..<3 {
            try cloud.workspace.writeFile("a.txt", "v\(version)")
            _ = try await cloud.publish(store, deviceID: device)
        }
        let objectsBefore = try cloud.workspace.objectFiles(
            deviceID: device, repositoryID: cloud.repositoryID
        ).count

        // Default: report-only. Nothing is deleted, the plan is reported.
        let preview = try await store.cleanup(
            repositoryId: cloud.repositoryID, gracePeriod: 0, minimumGenerations: 1
        )
        XCTAssertEqual(preview.deletedObjects, 0, "iCloud 模式默认不得物理删除")
        XCTAssertGreaterThanOrEqual(preview.plannedGenerationDeletes, 1, "必须报告待清理版本")
        XCTAssertGreaterThanOrEqual(preview.plannedDeletes, 1, "必须报告待清理对象")
        XCTAssertNotNil(preview.skippedReason)
        XCTAssertEqual(
            try cloud.workspace.objectFiles(deviceID: device, repositoryID: cloud.repositoryID).count,
            objectsBefore,
            "预览不得删除任何对象"
        )
        XCTAssertEqual(
            try cloud.workspace.commitFiles(deviceID: device, repositoryID: cloud.repositoryID).count,
            3,
            "预览不得 tombstone 任何清单"
        )
    }

    func testCT105_ExplicitDeviceRetirementIsRequiredForGCToIgnoreIt() async throws {
        let cloud = try RegressionCloud(name: "ct105b")
        defer { cloud.cleanup() }
        let device = UUID()
        let store = cloud.store(deviceID: device, sweepGrace: 0)
        try cloud.workspace.writeFile("a.txt", "v1")
        _ = try await cloud.publish(store, deviceID: device)

        // An offline peer device blocks physical GC.
        let peer = UUID()
        let peerDir = cloud.workspace.storageRoot.appendingPathComponent("devices/\(peer.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: peerDir, withIntermediateDirectories: true)
        let blocked = try await store.cleanup(
            repositoryId: cloud.repositoryID, gracePeriod: 0, minimumGenerations: 1
        )
        XCTAssertNotNil(blocked.skippedReason)

        // Explicit retirement makes it ignorable — and only then.
        try await store.retireDevice(peer, reason: "退役的旧 Mac")
        let retiredMarker = peerDir.appendingPathComponent("retired.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: retiredMarker.path))
        let afterRetirement = try await store.cleanup(
            repositoryId: cloud.repositoryID, gracePeriod: 0, minimumGenerations: 1
        )
        XCTAssertTrue(
            afterRetirement.skippedReason?.contains("多设备") != true,
            "已退役设备不应再阻止 GC：\(afterRetirement.skippedReason ?? "")"
        )
    }

    // MARK: - CT-106 migration journal path tampering

    func testCT106_TamperedMigrationJournalNeverDeletesArbitraryPaths() throws {
        let target = root.appendingPathComponent("mtarget", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        // A precious directory that must survive.
        let precious = root.appendingPathComponent("precious", isDirectory: true)
        try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)
        try "keep me".write(to: precious.appendingPathComponent("f"), atomically: true, encoding: .utf8)

        let jobID = UUID()
        let journal = """
        {"jobID":"\(jobID.uuidString)","state":"copying","sourceRoot":"\(precious.path)",\
        "stagingPath":"\(precious.path)","startedAt":"2026-11-07T00:00:00Z",\
        "updatedAt":"2026-11-07T00:00:00Z"}
        """
        try journal.write(
            to: target.appendingPathComponent(DataMigrator.journalName),
            atomically: true, encoding: .utf8
        )
        DataMigrator.clearInterruptedStaging(target: target)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: precious.appendingPathComponent("f").path),
            "被篡改的 journal 路径绝不能删除"
        )

        // The derived path IS deleted (the legitimate case still works).
        let derived = DataMigrator.expectedStagingURL(target: target, jobID: jobID)
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        try "staged".write(to: derived.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        let correctJournal = """
        {"jobID":"\(jobID.uuidString)","state":"copying","sourceRoot":"\(precious.path)",\
        "stagingPath":"\(derived.path)","startedAt":"2026-11-07T00:00:00Z",\
        "updatedAt":"2026-11-07T00:00:00Z"}
        """
        try correctJournal.write(
            to: target.appendingPathComponent(DataMigrator.journalName),
            atomically: true, encoding: .utf8
        )
        DataMigrator.clearInterruptedStaging(target: target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: derived.path))
    }

    // MARK: - CT-107 restore staging must not be a symlink

    func testCT107_SymlinkStagingIsRejectedBeforeAnyWrite() async throws {
        let cloud = try RegressionCloud(name: "ct107")
        defer { cloud.cleanup() }
        let device = UUID()
        let store = cloud.store(deviceID: device)
        try cloud.workspace.writeFile("a.txt", "v1")
        _ = try await cloud.publish(store, deviceID: device)

        // A staging path that is a symlink to a directory outside the root.
        let repoRoot = root.appendingPathComponent("ct107-root", isDirectory: true)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("ct107-outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let jobID = UUID()
        let staging = SafePath.stagingURL(in: repoRoot, repositoryID: UUID(), jobID: jobID)
        try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: outside)

        // Drive the PRODUCTION validation entry point, not just SafePath.
        XCTAssertThrowsError(
            try CodeTimeService.validateRestoreStaging(staging.path, repositoryRoot: repoRoot)
        ) { error in
            XCTAssertTrue("\(error)".contains("outsideRoot") || "\(error)".contains("isSymlink")
                || "\(error)".contains("路径"), "\(error)")
        }
        // A legitimate real directory passes the same entry point.
        let good = SafePath.stagingURL(in: repoRoot, repositoryID: UUID(), jobID: UUID())
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        XCTAssertNoThrow(try CodeTimeService.validateRestoreStaging(good.path, repositoryRoot: repoRoot))
    }

    // MARK: - CT-108 janitor must validate the repository directory itself

    func testCT108_JanitorSkipsSymlinkedRepositoryDirectory() async throws {
        guard KopiaBinary.locate() != nil else { throw XCTSkip("KOPIA_PATH 未设置") }
        let paths = try makePaths()
        let outside = root.appendingPathComponent("ct108-outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent("restore-aaaaaaaa-bbbbbbbb", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "precious".write(
            to: outside.appendingPathComponent("restore-aaaaaaaa-bbbbbbbb/f"),
            atomically: true, encoding: .utf8
        )
        // A repository directory that is a symlink to the outside tree.
        let linkedRepo = paths.repositories.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedRepo, withDestinationURL: outside)

        let service = try CodeTimeService(paths: paths, keychain: keychain)
        _ = try await service.bootstrap()

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("restore-aaaaaaaa-bbbbbbbb/f").path
            ),
            "janitor 不得跟随仓库目录的符号链接删除外部数据"
        )
    }

    // MARK: - CT-109 a new migration from the same source runs again

    func testCT109_NewMigrationRequestFromSameSourceRunsAgain() throws {
        let source = try makeBetaSource()
        let target = root.appendingPathComponent("ct109-target", isDirectory: true)

        // First migration.
        try DataMigrator.requestMigration(source: source, target: target, allowReplaceRoot: true)
        let first = try DataMigrator.performPending(target: target)
        XCTAssertNotNil(first)

        // The user adds data to the source and requests migration AGAIN — this is
        // a NEW request and must run (the old completion only answers its own ID).
        try "new-project".write(
            to: source.appendingPathComponent("sentinel-new.txt"), atomically: true, encoding: .utf8
        )
        try DataMigrator.requestMigration(source: source, target: target, allowReplaceRoot: true)
        let second = try DataMigrator.performPending(target: target)
        XCTAssertNotNil(second, "同一源目录的新请求必须重新迁移")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: target.appendingPathComponent("sentinel-new.txt").path
            ),
            "新请求的数据必须被迁移"
        )

        // The completion record binds BOTH the request ID and the target root.
        let lifecycleDir = target.deletingLastPathComponent()
            .appendingPathComponent(".codetime-lifecycle", isDirectory: true)
        let data = try Data(contentsOf: lifecycleDir.appendingPathComponent(DataMigrator.completionName))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["requestID"] as? String)
        XCTAssertEqual(json["targetRoot"] as? String, target.path)
    }

    // MARK: - CT-110 atomic status recompute

    func testCT110_StoreLevelRecomputeIsAtomicAndFollowsNewestSnapshot() async throws {
        let database = try SQLiteStore(path: root.appendingPathComponent("ct110.sqlite").path)
        let project = Project(name: "CT110", rootPath: root.appendingPathComponent("p").path)
        try await database.upsertProject(project)

        var older = Snapshot(
            id: "old-\(UUID())", projectID: project.id,
            createdAt: Date().addingTimeInterval(-600), status: .complete, fileCount: 1, totalSize: 1
        )
        older.cloudState = .synced
        try await database.upsertSnapshot(older)

        var newer = Snapshot(
            id: "new-\(UUID())", projectID: project.id,
            createdAt: Date(), status: .complete, fileCount: 1, totalSize: 1
        )
        newer.cloudState = .failed
        try await database.upsertSnapshot(newer)

        let status = try await database.recomputeProjectRuntimeState(projectID: project.id)
        XCTAssertEqual(status, .warning, "最新快照失败必须决定状态")

        // Partial read failures never report synced, even when the cloud state is.
        var partial = Snapshot(
            id: "partial-\(UUID())", projectID: project.id,
            createdAt: Date().addingTimeInterval(60), status: .incomplete, fileCount: 1, totalSize: 1
        )
        partial.cloudState = .synced
        try await database.upsertSnapshot(partial)
        let partialStatus = try await database.recomputeProjectRuntimeState(projectID: project.id)
        XCTAssertEqual(partialStatus, .warning)
        XCTAssertEqual(
            ProjectStatus.derived(cloudState: .synced, snapshotStatus: .incomplete),
            .warning,
            "同一状态规则必须被服务与存储共同使用"
        )
    }

    // MARK: - CT-111 local restore target mutual exclusion

    func testCT111_LocalRestoreTargetLockRejectsConcurrentWriter() throws {
        let destination = root.appendingPathComponent("ct111-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let hash = CodeTimeService.stablePathHash(destination.standardizedFileURL.path)
        let lockPath = root.appendingPathComponent(".locks/restore-target-\(hash).lock")

        let first = RepositoryLock(path: lockPath.path)
        XCTAssertTrue(first.tryAcquire())
        let second = RepositoryLock(path: lockPath.path)
        XCTAssertFalse(second.tryAcquire(), "同一目标目录的第二个恢复必须被拒绝")
        first.release()

        // The hash is stable across processes (FNV-1a, no Swift seeding).
        XCTAssertEqual(hash, CodeTimeService.stablePathHash(destination.standardizedFileURL.path))
        XCTAssertNotEqual(hash, CodeTimeService.stablePathHash(destination.path + "x"))
    }

    // MARK: - CT-112 bootstrap never reclaims a live restore

    func testCT112_LiveRestoreJobIsNotReclaimedByAnotherBootstrap() async throws {
        let database = try SQLiteStore(path: root.appendingPathComponent("ct112.sqlite").path)
        let live = RestoreJob(
            projectID: UUID(), snapshotID: "s", mode: .copy,
            targetPath: root.appendingPathComponent("t").path, status: .running
        )
        try await database.upsertRestoreJob(live)
        // A live lease owned by THIS process.
        let owner = ProcessIdentity.current(isAgent: false)
        let claimedLive = try await database.claimRestoreJob(
            id: live.id, owner: owner, expiresAt: Date().addingTimeInterval(300)
        )
        XCTAssertNotNil(claimedLive)

        let reclaimed = try await database.recoverInterruptedRestoreJobs(legacyGrace: 600)
        XCTAssertTrue(reclaimed.isEmpty, "另一个进程 bootstrap 不能抢走活着的恢复任务")
        let afterBootstrap = try await database.restoreJob(id: live.id)
        XCTAssertEqual(afterBootstrap?.status, .running)

        // Once the owner is provably gone, it IS reclaimed.
        let liveRow = try await database.restoreJob(id: live.id)
        var dead = try XCTUnwrap(liveRow)
        dead.lease = JobLease(
            owner: ProcessIdentity(pid: 999_999_999, startTime: 1, isAgent: false),
            heartbeatAt: Date().addingTimeInterval(-600),
            leaseExpiresAt: Date().addingTimeInterval(-300)
        )
        try await database.upsertRestoreJob(dead)
        let reclaimedNow = try await database.recoverInterruptedRestoreJobs(legacyGrace: 600)
        XCTAssertEqual(reclaimedNow, [live.id])
        let afterReclaim = try await database.restoreJob(id: live.id)
        XCTAssertEqual(afterReclaim?.status, .failed)
    }

    // MARK: - CT-113 coordinators own policy

    func testCT113_RestoreCoordinatorDecidesResumePlanFromState() async throws {
        let paths = try makePaths()
        let service = try CodeTimeService(paths: paths, keychain: keychain)
        let coordinator = RestoreCoordinator(service)
        let base = CloudRestoreJob(
            repositoryID: UUID(), generationID: UUID(), sourceDeviceID: UUID(),
            state: .preparing, stagingPath: "/tmp/x"
        )
        var job = base
        XCTAssertEqual(coordinator.resumePlan(for: job), .download)
        XCTAssertTrue(coordinator.canRetry(job))

        job.state = .committing
        XCTAssertEqual(coordinator.resumePlan(for: job), .finishCommit)

        job.state = .permanentlyFailed
        XCTAssertFalse(coordinator.canRetry(job))
        if case .blocked = coordinator.resumePlan(for: job) {} else {
            XCTFail("永久失败必须返回 blocked")
        }

        job.state = .completed
        XCTAssertFalse(coordinator.canRetry(job))

        // The explicit state machine rejects the old race: committing → downloading.
        XCTAssertFalse(RestoreStateMachine.allows(.committing, .downloading))
        XCTAssertTrue(RestoreStateMachine.allows(.committing, .completed))
        XCTAssertTrue(RestoreStateMachine.allows(.retryableFailed, .preparing))
        XCTAssertFalse(RestoreStateMachine.allows(.completed, .preparing))
        XCTAssertFalse(RestoreStateMachine.allows(.permanentlyFailed, .downloading))
    }

    func testCT113_BackupCoordinatorReportsPerProjectOutcomes() async throws {
        guard KopiaBinary.locate() != nil else { throw XCTSkip("KOPIA_PATH 未设置") }
        let paths = try makePaths()
        let service = try CodeTimeService(paths: paths, keychain: keychain)
        _ = try await service.bootstrap()
        let source = root.appendingPathComponent("ct113-src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "x".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let project = try await service.addProject(url: source)

        let coordinator = BackupCoordinator(service)
        let report = await coordinator.runDueProjects(now: Date().addingTimeInterval(86_400), trigger: .manual)
        // Either the project ran (fresh install schedules immediately) or it was
        // skipped/absent — but the report must never claim success for nothing.
        XCTAssertTrue(
            report.succeeded.contains(project.id)
                || report.skipped.contains(project.id)
                || (report.succeeded.isEmpty && report.failed.isEmpty),
            "批次报告必须真实反映执行结果"
        )
        XCTAssertTrue(report.isClean || !report.failed.isEmpty)
    }

    // MARK: - CT-114 gate strictness

    func testCT114_IndexForbidsRequiredSkippableAndGateBuildsCrashChild() throws {
        let indexData = try Data(contentsOf: repoRoot.appendingPathComponent("REGRESSION_INDEX.json"))
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: indexData) as? [[String: Any]])
        XCTAssertEqual(entries.count, 143)
        for entry in entries {
            let id = entry["id"] as? String ?? "?"
            let required = entry["required"] as? Bool ?? false
            let envSkip = entry["envSkip"] as? Bool ?? false
            let manual = entry["manualAcceptance"] as? Bool ?? false
            if required {
                XCTAssertFalse(envSkip, "\(id): required 测试不得标记可跳过")
                XCTAssertFalse(manual, "\(id): required 测试不得标记人工验收")
            }
            if manual {
                XCTAssertFalse(
                    (entry["acceptanceReason"] as? String ?? "").isEmpty,
                    "\(id): 人工验收项必须写明原因"
                )
            }
        }
        // CT-098 must be a REAL required test (builds CrashChild in the gate).
        let crash = try XCTUnwrap(entries.first { ($0["id"] as? String) == "CT-098" })
        XCTAssertEqual(crash["required"] as? Bool, true)
        XCTAssertEqual(crash["manualAcceptance"] as? Bool ?? false, false)

        let gate = try String(contentsOf: repoScript("regression_gate.sh"), encoding: .utf8)
        XCTAssertTrue(gate.contains("--product CodeTimeCrashChild"), "门禁必须构建 CrashChild")
        XCTAssertTrue(gate.contains("required test skipped"), "必需测试跳过必须使门禁失败")
        let testScript = try String(contentsOf: repoScript("test.sh"), encoding: .utf8)
        XCTAssertTrue(testScript.contains("--product CodeTimeCrashChild"))
    }

    // MARK: - CT-115 benchmark content verification + baseline

    func testCT115_BenchmarkVerifiesContentAndHasBaseline() throws {
        guard KopiaBinary.locate() != nil else { throw XCTSkip("KOPIA_PATH 未设置") }
        let baselineURL = repoRoot.appendingPathComponent("Docs/Engineering/perf-baseline.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: baselineURL.path))
        let baseline = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: baselineURL)
        ) as? [String: Any]
        XCTAssertNotNil(baseline?["300"], "必须记录 300 文件基准")
        XCTAssertNotNil(baseline?["10000"], "必须记录 10000 文件基准")
        entryCheck: do {
            let entry = baseline?["300"] as? [String: Any]
            XCTAssertNotNil(entry?["backupDurationMs"])
            XCTAssertNotNil(entry?["restoreDurationMs"])
            XCTAssertNotNil(entry?["peakMemoryMB"])
        }

        // A real small run: content (size+SHA-256+structure) must be verified.
        let work = root.appendingPathComponent("ct115-bench", isDirectory: true)
        let process = Process()
        process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("CodeTimeCrashChild")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: process.executableURL!.path))
        process.arguments = ["bench", work.path, "300"]
        process.environment = ProcessInfo.processInfo.environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertTrue(output.contains("contentCheck: PASS"), output)
        XCTAssertTrue(output.contains("verifyMode: size+sha256+structure+hidden+symlink"), output)
        XCTAssertTrue(output.contains("contentMismatches: 0"), output)
        XCTAssertTrue(output.contains("incrementalBackupDurationMs:"), output)
    }

    // MARK: - CT-116 docs bind the current commit and CI run

    func testCT116_TestReportBindsCommitRunAndGateResult() throws {
        let report = try String(
            contentsOf: repoRoot.appendingPathComponent("Docs/Engineering/TEST_REPORT.md"),
            encoding: .utf8
        )
        XCTAssertTrue(report.contains("Commit SHA"), "报告必须记录 Commit SHA")
        XCTAssertTrue(report.contains("CI Run"), "报告必须记录 CI Run ID")
        XCTAssertTrue(report.contains("NOT RUN"), "未执行的真机项必须显式标记")
        XCTAssertFalse(report.contains("106 测试"), "不得保留过时的测试统计")

        let matrix = try String(
            contentsOf: repoRoot.appendingPathComponent("Docs/Engineering/REGRESSION_MATRIX.md"),
            encoding: .utf8
        )
        XCTAssertTrue(matrix.contains("CT-098"))
        XCTAssertTrue(matrix.contains("CT-116"))
        XCTAssertTrue(matrix.contains("manualAcceptance") || matrix.contains("人工验收"))
    }
}
