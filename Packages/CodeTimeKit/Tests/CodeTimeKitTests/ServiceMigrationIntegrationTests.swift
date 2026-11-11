import XCTest
import Foundation
@testable import CodeTimeCore
@testable import SharedModels
@testable import CodeTimeSecurity

/// CT-162: the service-level v2→v3 migration. A legacy Kopia snapshot exists,
/// gets published/verified, a v3 baseline is created and verified, the local
/// repository is only released with explicit consent, and old history stays
/// visible and restorable afterwards.
final class ServiceMigrationIntegrationTests: XCTestCase {
    private var workspace: URL!
    private var paths: AppPaths!
    private var keychain: KeychainStore!
    private var service: CodeTimeService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("service-migrate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        paths = AppPaths(root: workspace.appendingPathComponent("data", isDirectory: true))
        keychain = KeychainStore(service: "com.codetime.test.ct162.\(UUID().uuidString)")
        service = try CodeTimeService(paths: paths, keychain: keychain)
    }

    override func tearDownWithError() throws {
        if let keychain { keychain.deleteAllSecrets() }
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        service = nil
        try super.tearDownWithError()
    }

    func testCT162_MigrationReleasesLegacyOnlyWithConsentAndKeepsHistory() async throws {
        _ = try await service.bootstrap()
        let mirror = workspace.appendingPathComponent("mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        var settings = try await service.currentSettings()
        settings.localMirrorPath = mirror.path
        settings.iCloudEnabled = false
        settings = try await service.saveSettings(settings)

        let projectRoot = workspace.appendingPathComponent("legacy-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try Data("legacy file".utf8).write(to: projectRoot.appendingPathComponent("old.txt"))
        let project = try await service.addProject(url: projectRoot, name: "legacy")
        let legacy = try await service.createSnapshot(projectID: project.id, trigger: .manual)
        XCTAssertEqual(legacy.snapshot.cloudState, .synced)

        // Baseline (no consent): v3 is verified, old data still on disk.
        let pending = await service.runBackupMigration()
        XCTAssertEqual(pending.phase, .legacyLocalCleanupPending, pending.detail)
        XCTAssertTrue(pending.requiresUserAction)
        let repoContents = try FileManager.default.contentsOfDirectory(atPath: paths.repositories.path)
        XCTAssertFalse(repoContents.isEmpty, "未获同意时不得清理旧仓库")
        let afterBaseline = try await service.currentSettings()
        XCTAssertEqual(afterBaseline.engineMode, .cloudFirst, "基线验证后新备份应使用 v3")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: mirror.appendingPathComponent("v3/format.json").path
        ))

        // Both the old version and the new baseline remain visible.
        let history = try await service.refreshSnapshots(projectID: project.id)
        XCTAssertTrue(history.contains { $0.id == legacy.snapshot.id }, "旧历史不得消失")
        XCTAssertGreaterThanOrEqual(history.count, 2)

        // Explicit consent releases the local repository; the old version is
        // still listed (it lives in Cloud Format v2 from now on).
        let done = await service.runBackupMigration(releaseLegacyLocalSpace: true)
        XCTAssertEqual(done.phase, .complete, done.detail)
        let cleaned = try FileManager.default.contentsOfDirectory(atPath: paths.repositories.path)
        XCTAssertTrue(cleaned.isEmpty, "同意后才允许释放旧本地仓库")
        let finalSettings = try await service.currentSettings()
        XCTAssertEqual(finalSettings.engineMode, .cloudFirst)
        XCTAssertTrue(finalSettings.legacyLocalCleanupApproved)

        let historyAfterCleanup = try await service.refreshSnapshots(projectID: project.id)
        XCTAssertTrue(historyAfterCleanup.contains { $0.id == legacy.snapshot.id })
        XCTAssertTrue(historyAfterCleanup.contains { $0.id != legacy.snapshot.id })

        // §14.4: the old version is still restorable after the local repository
        // was released. The service downloads the v2 generation to a temporary
        // repository, restores, and leaves the user's tree verified.
        let restored = workspace.appendingPathComponent("legacy-restored", isDirectory: true)
        let job = try await service.restore(RestoreRequest(
            projectID: project.id,
            snapshotID: legacy.snapshot.id,
            relativePath: nil,
            mode: .wholeProject,
            destination: restored
        ))
        XCTAssertEqual(job.status, .completed)
        XCTAssertEqual(
            try Data(contentsOf: restored.appendingPathComponent("old.txt")),
            Data("legacy file".utf8)
        )
        await service.releaseLegacyRecoveryRepository()
    }
}
