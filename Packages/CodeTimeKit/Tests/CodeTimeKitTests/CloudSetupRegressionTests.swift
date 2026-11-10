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
}
