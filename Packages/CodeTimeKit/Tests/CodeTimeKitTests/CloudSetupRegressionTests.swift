import XCTest
import Foundation
@testable import SharedModels
@testable import Persistence
@testable import BackupEngine
@testable import CodeTimeSecurity
@testable import CloudMirrorStore
@testable import CodeTimeCore

/// CT-129 … CT-137: iCloud auto-setup, storage switching, honest sync states.
final class CloudSetupRegressionTests: XCTestCase {

    private var root: URL!
    private var keychain: KeychainStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codetime-cloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent()
            .appendingPathComponent(".codetime-lifecycle", isDirectory: true))
        keychain = KeychainStore(service: "com.codetime.test.cloud.\(UUID().uuidString)")
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

    private func probe(
        build: Bool = true,
        account: Bool = true,
        container: URL?,
        defaultContainer: URL?
    ) -> CloudEnvironmentProbe {
        CloudEnvironmentProbe(
            buildSupportsICloud: { build },
            hasUbiquityIdentity: { account },
            containerURL: { _ in container },
            defaultContainerURL: { defaultContainer }
        )
    }

    // MARK: - CT-129 build capability

    func testCT129_BuildCapabilityDecidesICloudAvailability() async throws {
        let container = root.appendingPathComponent("container", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)

        // A build without the entitlement (Beta/Debug) must say so explicitly and
        // must never claim "not configured".
        let unsupported = await CloudSetupService.detect(
            probe: probe(build: false, container: container, defaultContainer: container)
        )
        XCTAssertEqual(unsupported.state, .unsupportedBuild)
        XCTAssertFalse(unsupported.isReady)
        XCTAssertTrue(unsupported.detail.contains("Beta") || unsupported.detail.contains("权限"))

        // The Release entitlements declare the iCloud container; the Beta/Debug
        // entitlements must NOT (otherwise an unsigned build would look capable).
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        func plist(_ name: String) throws -> String {
            try String(contentsOf: repoRoot.appendingPathComponent("Apps/CodeTime/\(name)"), encoding: .utf8)
        }
        let release = try plist("CodeTime.entitlements")
        XCTAssertTrue(release.contains("iCloud.com.codetime.app"))
        XCTAssertFalse(try plist("CodeTime-Beta.entitlements").contains("iCloud.com.codetime.app"))
        XCTAssertFalse(try plist("CodeTime-Debug.entitlements").contains("iCloud.com.codetime.app"))
    }

    // MARK: - CT-130 environment matrix

    func testCT130_EnvironmentMatrixIsExplicit() async throws {
        let container = root.appendingPathComponent("c1", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)

        // No account.
        let noAccount = await CloudSetupService.detect(
            probe: probe(account: false, container: container, defaultContainer: container)
        )
        XCTAssertEqual(noAccount.state, .accountNotSignedIn)
        XCTAssertTrue(noAccount.requiresSystemSettings)

        // Drive off: neither the app container nor the default container exists.
        let driveOff = await CloudSetupService.detect(
            probe: probe(container: nil, defaultContainer: nil)
        )
        XCTAssertEqual(driveOff.state, .driveDisabled)
        XCTAssertTrue(driveOff.requiresSystemSettings)

        // Drive on but our container missing.
        let containerMissing = await CloudSetupService.detect(
            probe: probe(container: nil, defaultContainer: root)
        )
        XCTAssertEqual(containerMissing.state, .containerUnavailable)

        // Ready: directory is created and write-probed.
        let ready = await CloudSetupService.detect(
            probe: probe(container: container, defaultContainer: container)
        )
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(
            ready.storageRoot?.lastPathComponent,
            CloudSetupService.storageFolderName
        )
        var isDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ready.storageRoot!.path, isDirectory: &isDir)
        )
        XCTAssertTrue(isDir.boolValue)
        // The probe file must not be left behind.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: ready.storageRoot!.path))?
            .filter { $0.hasPrefix(".codetime-setup-") } ?? []
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testCT130_NotWritableContainerIsReported() async throws {
        let container = root.appendingPathComponent("readonly", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: container.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: container.path)
        }
        let status = await CloudSetupService.detect(
            probe: probe(container: container, defaultContainer: container)
        )
        XCTAssertEqual(status.state, .notWritable)
        XCTAssertFalse(status.isReady)
        XCTAssertFalse(status.detail.isEmpty)
    }

    // MARK: - CT-131 storage switching keeps data and config

    func testCT131_EnablingICloudOnUnsupportedBuildDoesNotMutateSettings() async throws {
        let paths = try makePaths()
        let service = try CodeTimeService(paths: paths, keychain: keychain)
        _ = try await service.bootstrap()

        // Seed a mirror so we can prove it is NOT cleared by a failed switch.
        let mirror = root.appendingPathComponent("mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        _ = try await service.setLocalMirror(mirror)
        let before = try await service.currentSettings()
        XCTAssertEqual(before.localMirrorPath, mirror.path)
        XCTAssertFalse(before.iCloudEnabled)

        // This test binary has no iCloud entitlement → enabling must fail...
        do {
            _ = try await service.configureStorage(.iCloud)
            XCTFail("无 iCloud 能力时必须拒绝启用")
        } catch {}

        let after = try await service.currentSettings()
        XCTAssertFalse(after.iCloudEnabled, "失败不得写入新配置")
        XCTAssertEqual(after.localMirrorPath, mirror.path, "失败不得清空原有镜像")
        XCTAssertNotNil(after.localMirrorBookmark, "失败不得丢失授权书签")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mirror.path), "切换失败不得删除数据")
    }

    func testCT131_StorageModeDerivationMatchesLegacySettings() {
        XCTAssertEqual(
            BackupDestination.derived(
                iCloudEnabled: true, localMirrorPath: "/tmp/m", localMirrorAccessState: .granted
            ),
            .iCloud
        )
        XCTAssertEqual(
            BackupDestination.derived(
                iCloudEnabled: false, localMirrorPath: "/tmp/m", localMirrorAccessState: .stale
            ),
            .customLocal(path: "/tmp/m")
        )
        XCTAssertEqual(
            BackupDestination.derived(
                iCloudEnabled: false, localMirrorPath: nil, localMirrorAccessState: .notRequired
            ),
            .localOnly
        )
    }

    // MARK: - CT-132 cloud state machine

    func testCT132_CloudStateMachineForbidsFalseSuccess() {
        // The only exit from uploading/publishing towards "confirmed" is via the
        // manifest publish step — uploading → verified is illegal.
        XCTAssertFalse(CloudBackupState.allows(from: .uploading, to: .verified))
        XCTAssertFalse(CloudBackupState.allows(from: .uploading, to: .uploaded))
        XCTAssertTrue(CloudBackupState.allows(from: .uploading, to: .publishing))
        XCTAssertTrue(CloudBackupState.allows(from: .publishing, to: .uploaded))
        XCTAssertTrue(CloudBackupState.allows(from: .uploaded, to: .verifying))
        XCTAssertTrue(CloudBackupState.allows(from: .verifying, to: .verified))
        XCTAssertFalse(CloudBackupState.allows(from: .verified, to: .notConfigured))
        XCTAssertTrue(CloudBackupState.allows(from: .retrying, to: .uploading))

        XCTAssertFalse(CloudBackupState.uploading.isCloudConfirmed)
        XCTAssertFalse(CloudBackupState.publishing.isCloudConfirmed)
        XCTAssertTrue(CloudBackupState.uploaded.isCloudConfirmed)
        XCTAssertTrue(CloudBackupState.verified.isCloudConfirmed)
    }

    // MARK: - CT-133 project sync display never conflates local and cloud

    func testCT133_ProjectSyncDisplaySeparatesLocalUploadAndFailure() {
        let local = ProjectSyncDisplay.derived(status: .localOnly, cloudState: .localOnly)
        XCTAssertEqual(local.kind, .localOnly)
        XCTAssertFalse(local.isCloudConfirmed)
        XCTAssertTrue(local.title.contains("仅本机") || local.title.contains("本地"))

        let uploading = ProjectSyncDisplay.derived(status: .publishing, cloudState: .uploading)
        XCTAssertEqual(uploading.kind, .uploading)
        XCTAssertFalse(uploading.isCloudConfirmed)

        let synced = ProjectSyncDisplay.derived(status: .synced, cloudState: .synced)
        XCTAssertTrue(synced.isCloudConfirmed)
        XCTAssertTrue(synced.title.contains("iCloud"))

        // Local snapshot fine, cloud failed → must NOT read as synced.
        let cloudFailed = ProjectSyncDisplay.derived(status: .warning, cloudState: .failed)
        XCTAssertEqual(cloudFailed.kind, .cloudFailed)
        XCTAssertFalse(cloudFailed.isCloudConfirmed)
        XCTAssertTrue(cloudFailed.title.contains("本地备份安全"))

        let retrying = ProjectSyncDisplay.derived(status: .warning, cloudState: .pending)
        XCTAssertEqual(retrying.kind, .awaitingRetry)

        let localFailed = ProjectSyncDisplay.derived(status: .failed, cloudState: nil)
        XCTAssertEqual(localFailed.kind, .failed)
        XCTAssertFalse(localFailed.isCloudConfirmed)
    }

    // MARK: - CT-134 first backup end to end (local mirror = cloud path)

    func testCT134_FirstBackupPublishesBeforeReportingSynced() async throws {
        guard KopiaBinary.locate() != nil else { throw XCTSkip("KOPIA_PATH 未设置") }
        let paths = try makePaths()
        let service = try CodeTimeService(paths: paths, keychain: keychain)
        _ = try await service.bootstrap()

        let mirror = root.appendingPathComponent("mirror-ct134", isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        _ = try await service.setLocalMirror(mirror)

        let source = root.appendingPathComponent("ct134-src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "hello".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let project = try await service.addProject(url: source)

        let outcome = try await service.createSnapshot(projectID: project.id, trigger: .manual)
        XCTAssertNil(outcome.cloudError, "本地镜像可用时首次上传必须成功")
        XCTAssertEqual(outcome.snapshot.cloudState, .synced, "只有发布确认后才允许 synced")

        // The persisted project state must reflect the same truth.
        let stored = try await service.database.projects().first
        XCTAssertEqual(stored?.lastCloudState, .synced)
        XCTAssertEqual(stored?.status, .synced)
        let display = ProjectSyncDisplay.derived(
            status: stored?.status ?? .idle,
            cloudState: stored?.lastCloudState
        )
        XCTAssertTrue(display.isCloudConfirmed)

        // The generation must exist in the mirror and be readable.
        let summary = try await service.cloudSummary()
        XCTAssertGreaterThan(summary?.generationCount ?? 0, 0)
    }

    func testCT134_CloudFailureKeepsLocalSnapshotAndReportsHonestly() async throws {
        guard KopiaBinary.locate() != nil else { throw XCTSkip("KOPIA_PATH 未设置") }
        let paths = try makePaths()
        let service = try CodeTimeService(paths: paths, keychain: keychain)
        _ = try await service.bootstrap()

        // A mirror path that becomes invalid after configuration reproduces a
        // cloud failure without touching the local repository.
        let mirror = root.appendingPathComponent("mirror-ct134b", isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        _ = try await service.setLocalMirror(mirror)

        let source = root.appendingPathComponent("ct134b-src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "hello".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let project = try await service.addProject(url: source)

        // Break the mirror: replace it with a regular file.
        try FileManager.default.removeItem(at: mirror)
        try "not-a-directory".write(to: mirror, atomically: true, encoding: .utf8)

        let outcome = try await service.createSnapshot(projectID: project.id, trigger: .manual)
        XCTAssertNotNil(outcome.cloudError, "云端失败必须如实报告")
        XCTAssertEqual(outcome.snapshot.status, .complete, "本地快照必须仍然有效")
        XCTAssertNotEqual(outcome.snapshot.cloudState, .synced)

        let stored = try await service.database.projects().first
        let display = ProjectSyncDisplay.derived(
            status: stored?.status ?? .idle,
            cloudState: stored?.lastCloudState
        )
        XCTAssertFalse(display.isCloudConfirmed, "云端失败不得显示已同步")
    }

    // MARK: - CT-135 retry schedule is idempotent

    func testCT135_RetryPendingPublishesIsIdempotentAndKeepsSyncedProjectsAlone() async throws {
        guard KopiaBinary.locate() != nil else { throw XCTSkip("KOPIA_PATH 未设置") }
        let paths = try makePaths()
        let service = try CodeTimeService(paths: paths, keychain: keychain)
        _ = try await service.bootstrap()
        let mirror = root.appendingPathComponent("mirror-ct135", isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        _ = try await service.setLocalMirror(mirror)
        let source = root.appendingPathComponent("ct135-src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "x".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let project = try await service.addProject(url: source)
        _ = try await service.createSnapshot(projectID: project.id, trigger: .manual)

        // Already synced → nothing to retry.
        let attempted = try await service.retryPendingCloudPublishes()
        XCTAssertEqual(attempted, 0, "已同步的项目不应被重复上传")

        // The same call twice must not create extra generations.
        let before = try await service.cloudSummary()?.generationCount ?? 0
        _ = try await service.retryPendingCloudPublishes()
        let after = try await service.cloudSummary()?.generationCount ?? 0
        XCTAssertEqual(before, after)
    }

    // MARK: - CT-136 recovery discovers the container without a folder picker

    func testCT136_RecoveryAutoDetectsContainerStorageRoot() async throws {
        let container = root.appendingPathComponent("recovery-container", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let status = await CloudSetupService.detect(
            probe: probe(container: container, defaultContainer: container)
        )
        XCTAssertEqual(status.state, .ready)
        let expected = container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(CloudSetupService.storageFolderName, isDirectory: true)
        XCTAssertEqual(status.storageRoot?.standardizedFileURL.path, expected.standardizedFileURL.path)
        // The container identifier is centralized (no default-container lookup).
        XCTAssertEqual(CloudLocation.containerIdentifier, "iCloud.com.codetime.app")
        XCTAssertEqual(CloudSetupService.containerIdentifier, "iCloud.com.codetime.app")
    }

    // MARK: - CT-137 signed-product entitlement verification

    func testCT137_ReleaseValidationChecksTheSignedProduct() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: repoRoot.appendingPathComponent("Scripts/validate_entitlements.sh"),
            encoding: .utf8
        )
        // The script must inspect the SIGNED app, not only the source plist.
        XCTAssertTrue(script.contains("codesign -d --entitlements :-"))
        XCTAssertTrue(script.contains("iCloud.com.codetime.app"))
        XCTAssertTrue(script.contains("embedded.provisionprofile"))
        XCTAssertTrue(script.contains("application-groups"))
        XCTAssertTrue(script.contains("keychain-access-groups"))

        // And the release workflow must run it on the packaged artifact.
        let workflow = try String(
            contentsOf: repoRoot.appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(workflow.contains("verify_release.sh") || workflow.contains("validate_entitlements.sh"))
    }

    // MARK: - CT-138 stress test stays out of the regular gate

    func testCT138_StressTestIsOptInSeparatelyFromScale() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let stress = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Packages/CodeTimeKit/Tests/CodeTimeKitTests/SandboxPerformanceRegressionTests.swift"
            ),
            encoding: .utf8
        )
        // The million-file test must be gated by the STRESS flag, not the scale
        // flag that CI sets (otherwise the gate job exceeds its timeout).
        XCTAssertTrue(stress.contains("CODETIME_STRESS_TESTS"))
        let ci = try String(
            contentsOf: repoRoot.appendingPathComponent(".github/workflows/ci.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(ci.contains("CODETIME_SCALE_TESTS"), "门禁仍需运行 10 万文件 scale 预览")
        XCTAssertFalse(
            ci.contains("CODETIME_STRESS_TESTS: \"1\""),
            "常规 CI 不得启用百万文件压力测试"
        )

        // And the index must keep the stress test as manual acceptance only.
        let indexData = try Data(contentsOf: repoRoot.appendingPathComponent("REGRESSION_INDEX.json"))
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: indexData) as? [[String: Any]])
        let ct037 = try XCTUnwrap(entries.first { ($0["id"] as? String) == "CT-037" })
        XCTAssertEqual(ct037["manualAcceptance"] as? Bool, true)
        XCTAssertEqual(ct037["required"] as? Bool, false)
    }

    // MARK: - CT-139 recovery candidates expose device / time / projects

    func testCT139_RecoveryCandidateListsProjectsBeforeDownload() async throws {
        let cloud = try RegressionCloud(name: "ct139")
        defer { cloud.cleanup() }
        let device = UUID()
        let store = cloud.store(deviceID: device)
        try cloud.workspace.writeFile("repo/a.txt", "v1")
        _ = try await cloud.publish(store, deviceID: device)

        // The service records project roots after a confirmed publish; here we
        // exercise the store API that does the recording.
        try await store.recordProjectPaths(["/Users/dev/Code/Alpha"])
        try await store.recordProjectPaths(["/Users/dev/Code/Beta", "/Users/dev/Code/Alpha/"])
        // A later publish must not erase what was already recorded.
        _ = try await cloud.publish(store, deviceID: device)

        let candidates = try await CloudMirrorStore.recoverCandidates(
            storageRoot: cloud.workspace.storageRoot,
            recoveryKey: cloud.masterKey
        )
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.projectPaths.count, 2, "项目路径必须去重")
        XCTAssertEqual(
            candidate.projectPaths,
            ["/Users/dev/Code/Alpha", "/Users/dev/Code/Beta"],
            "路径必须规范化并排序"
        )
        XCTAssertNotNil(candidate.latestBackupAt, "必须同时提供最近备份时间")
        XCTAssertFalse(candidate.deviceName.isEmpty, "必须提供设备名称")

        // The wizard renders last path components.
        XCTAssertEqual(
            candidate.projectPaths.map { URL(fileURLWithPath: $0).lastPathComponent },
            ["Alpha", "Beta"]
        )
    }

    // MARK: - CT-140 iCloud beta build is opt-in and honestly gated

    func testCT140_ICloudBetaBuildIsOptInAndRequiresProfile() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: repoRoot.appendingPathComponent("Scripts/package_beta.sh"),
            encoding: .utf8
        )
        // Opt-in only, and it refuses to continue without identity + profile.
        XCTAssertTrue(script.contains("CODETIME_BETA_ICLOUD"))
        XCTAssertTrue(script.contains("PROVISIONING_PROFILE_SPECIFIER"))
        // CT-143: the entitlement switch lives in the BetaICloud configuration;
        // the script must select it and must NOT pass CODE_SIGN_ENTITLEMENTS on
        // the command line (that would leak into the SwiftPM package targets).
        XCTAssertTrue(script.contains("CONFIGURATION=\"BetaICloud\"") || script.contains("Configuration=\"BetaICloud\""))
        XCTAssertFalse(script.contains("CODE_SIGN_ENTITLEMENTS=Apps/CodeTime/CodeTime.entitlements"))
        XCTAssertTrue(
            script.contains("CODETIME_BETA_ICLOUD=1 需要 Developer ID 身份"),
            "缺少身份时必须明确失败，而不是静默退回 ad-hoc"
        )

        // The workflow exposes the switch so a two-Mac acceptance run can be
        // triggered without editing the pipeline.
        let workflow = try String(
            contentsOf: repoRoot.appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(workflow.contains("icloud_beta"))
        XCTAssertTrue(workflow.contains("APPLE_PROVISIONING_PROFILE"))

        // Default beta entitlements stay EMPTY: an unpackaged/ad-hoc beta must
        // never advertise iCloud it cannot use.
        let betaEnt = try String(
            contentsOf: repoRoot.appendingPathComponent("Apps/CodeTime/CodeTime-Beta.entitlements"),
            encoding: .utf8
        )
        XCTAssertFalse(betaEnt.contains("icloud"))
        // And the Release entitlements remain the single iCloud source.
        let releaseEnt = try String(
            contentsOf: repoRoot.appendingPathComponent("Apps/CodeTime/CodeTime.entitlements"),
            encoding: .utf8
        )
        XCTAssertTrue(releaseEnt.contains("iCloud.com.codetime.app"))
    }

    // MARK: - CT-141 two-Mac acceptance evidence is real and unfakeable

    private func runScript(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [path] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    func testCT141_AcceptanceHarnessDetectsMismatchAndRefusesFakeReport() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repoRoot.appendingPathComponent("Scripts/icloud_acceptance.sh").path

        // Fixture with plain files (no exclusion rules match).
        let source = root.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("src"), withIntermediateDirectories: true
        )
        try "alpha\n".write(to: source.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "beta\n".write(to: source.appendingPathComponent("src/util.txt"), atomically: true, encoding: .utf8)

        let a = root.appendingPathComponent("A.json")
        let prepare = runScript(script, ["prepare", "--project", source.path, "--out", a.path])
        XCTAssertEqual(prepare.status, 0, prepare.out)

        // A byte-identical copy verifies.
        let restored = root.appendingPathComponent("restored", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: restored)
        let b = root.appendingPathComponent("B.json")
        let ok = runScript(script, ["verify", "--evidence", a.path, "--restored", restored.path, "--out", b.path])
        XCTAssertEqual(ok.status, 0, ok.out)
        XCTAssertTrue(ok.out.contains("RESULT: PASS"))

        // A tampered restore fails and is reported with the file name.
        try "tampered\n".write(
            to: restored.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8
        )
        let bad = root.appendingPathComponent("B-bad.json")
        let failRun = runScript(script, ["verify", "--evidence", a.path, "--restored", restored.path, "--out", bad.path])
        XCTAssertNotEqual(failRun.status, 0, "篡改必须导致校验失败")
        XCTAssertTrue(failRun.out.contains("mismatched"))

        // The report refuses to be produced from a failed verification.
        let report = root.appendingPathComponent("report.md")
        let refused = runScript(script, [
            "report", "--a", a.path, "--b", bad.path,
            "--tag", "v1.0.0", "--commit", String(repeating: "a", count: 40),
            "--candidate-sha", String(repeating: "b", count: 64),
            "--candidate-name", "CodeTime-1.0.0-macos-universal.zip",
            "--run", "123456", "--operator", "tester",
            "--out", report.path,
        ])
        XCTAssertNotEqual(refused.status, 0, "校验未通过时不得生成验收报告")
        XCTAssertFalse(FileManager.default.fileExists(atPath: report.path))
    }

    // MARK: - CT-142 distributed app must launch

    func testCT142_LaunchSmokeDetectsCrashAndHangFreeSuccess() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let smoke = repoRoot.appendingPathComponent("Scripts/smoke_launch.sh").path

        // A process that stays alive passes.
        let alive = runScript(smoke, ["/bin/sleep", "1", "--", "5"])
        XCTAssertEqual(alive.status, 0, alive.out)

        // A process that exits immediately fails.
        let crashed = runScript(smoke, ["/usr/bin/false", "1"])
        XCTAssertNotEqual(crashed.status, 0, "启动即退出必须被判定为失败")

        // verify_release.sh must use this check (and honour the skip flag).
        let verify = try String(
            contentsOf: repoRoot.appendingPathComponent("Scripts/verify_release.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(verify.contains("smoke_launch.sh"))
        XCTAssertTrue(verify.contains("CODETIME_SKIP_LAUNCH_SMOKE"))
    }

    // MARK: - CT-143 iCloud beta uses a config, not CLI entitlement overrides

    func testCT143_ICloudBetaUsesDedicatedConfiguration() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()

        // A dedicated configuration exists and carries the Release entitlements.
        let project = try String(
            contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8
        )
        XCTAssertTrue(project.contains("BetaICloud:"), "缺少 BetaICloud 配置")
        let betaICloudBlock = project.components(separatedBy: "BetaICloud:").last ?? ""
        XCTAssertTrue(
            betaICloudBlock.contains("CODE_SIGN_ENTITLEMENTS: Apps/CodeTime/CodeTime.entitlements"),
            "BetaICloud 必须使用 Release entitlements"
        )
        XCTAssertTrue(betaICloudBlock.contains("ENABLE_HARDENED_RUNTIME: YES"))

        // The packaging script selects the configuration and never passes
        // CODE_SIGN_ENTITLEMENTS on the command line (that leaks into the SwiftPM
        // package targets and breaks them with a bogus relative path).
        let script = try String(
            contentsOf: repoRoot.appendingPathComponent("Scripts/package_beta.sh"), encoding: .utf8
        )
        XCTAssertTrue(script.contains("CONFIGURATION=\"BetaICloud\""))
        XCTAssertFalse(
            script.contains("CODE_SIGN_ENTITLEMENTS=Apps/CodeTime/CodeTime.entitlements"),
            "不得在命令行覆盖 CODE_SIGN_ENTITLEMENTS（会污染 SwiftPM 目标）"
        )
    }

    // MARK: - CT-144 doctor reports accurate, actionable blockers

    func testCT144_DoctorReportsStructuredBlockers() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let doctor = repoRoot.appendingPathComponent("Scripts/doctor.sh").path

        let result = runScript(doctor, ["--json"])
        let data = try XCTUnwrap(result.out.data(using: .utf8))
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "doctor --json 必须输出合法 JSON：\(result.out.prefix(200))"
        )
        XCTAssertNotNil(json["ready"] as? Bool)
        let blocked = try XCTUnwrap(json["blocked"] as? Int)
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        XCTAssertFalse(checks.isEmpty)
        for check in checks {
            XCTAssertNotNil(check["status"] as? String)
            XCTAssertNotNil(check["id"] as? String)
            XCTAssertNotNil(check["detail"] as? String)
        }
        // Exit code must agree with the report: blocked>0 ⇒ non-zero.
        XCTAssertEqual(result.status != 0, blocked > 0, "退出码必须与 blocked 计数一致")

        // Every blocker must carry the next action, so the report is actionable.
        for check in checks where (check["status"] as? String) == "BLOCKED" {
            let next = (check["next"] as? String) ?? ""
            XCTAssertFalse(next.isEmpty, "\(check["id"] ?? "?") 缺少下一步操作")
        }

        // The iCloud check must not rely on the non-existent MobileMeAccounts
        // domain (verified on this machine: the CloudDocs folder is the signal).
        let script = try String(contentsOfFile: doctor, encoding: .utf8)
        XCTAssertTrue(script.contains("com~apple~CloudDocs"))
        XCTAssertFalse(script.contains("defaults read MobileMeAccounts"))
    }
}
