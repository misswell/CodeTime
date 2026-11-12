import XCTest
import Foundation
@testable import CodeTimeCore
@testable import SharedModels
@testable import CodeTimeSecurity
@testable import BackupEngine

/// Task-book CT-290…CT-299: restore protection must be an engine boundary, not a
/// Service convention, and a failed bookmark must never fall back to a stale path.
final class TaskBookRestoreSecurityTests: XCTestCase {
    private var workspace: URL!
    private var paths: AppPaths!
    private var keychain: KeychainStore!
    private var service: CodeTimeService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskbook-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        paths = AppPaths(root: workspace.appendingPathComponent("data", isDirectory: true))
        keychain = KeychainStore(service: "com.codetime.test.taskbook.restore.\(UUID().uuidString)")
        service = try CodeTimeService(paths: paths, keychain: keychain)
    }

    override func tearDownWithError() throws {
        if let keychain { keychain.deleteAllSecrets() }
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        service = nil
        try super.tearDownWithError()
    }

    private func configureV3() async throws -> (Project, URL, String) {
        let mirror = workspace.appendingPathComponent("mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        var settings = try await service.currentSettings()
        settings.engineMode = .cloudFirst
        settings.iCloudEnabled = false
        settings.localMirrorPath = mirror.path
        settings.cachePreset = .minimal
        _ = try await service.saveSettings(settings)
        _ = try await service.bootstrap()

        let root = workspace.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("immutable".utf8).write(to: root.appendingPathComponent("a.txt"))
        let project = try await service.addProject(url: root, name: "taskbook")
        let outcome = try await service.createSnapshot(projectID: project.id, trigger: .manual)
        XCTAssertNil(outcome.cloudError)
        return (project, root, outcome.snapshot.id)
    }

    private func assertRestoreRejected(
        destination: URL,
        project: Project,
        snapshot: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            _ = try await service.restore(RestoreRequest(
                projectID: project.id,
                snapshotID: snapshot,
                relativePath: nil,
                mode: .wholeProject,
                destination: destination
            ))
            XCTFail("恢复目标必须被拒绝：\(destination.path)", file: file, line: line)
        } catch let error as CodeTimeError {
            switch error {
            case .pathOverlap, .pathOutsideProject, .unauthorized:
                break
            default:
                XCTFail("错误类型不符合预期：\(error)", file: file, line: line)
            }
        }
    }

    func testCT290_NoPublicDisasterBooleanCanBypassProtection() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Packages/CodeTimeKit/Sources/BackupEngine/CloudRestoreEngine.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertFalse(text.contains("public var isDisasterRecovery"), "不得保留公开灾难恢复 Boolean")
    }

    func testProtectedRootsRejectAppData() throws {
        let appData = workspace.appendingPathComponent("data", isDirectory: true)
        let boundary = RestoreProtectedRoots(sourceRoots: [], protectedRoots: [appData])
        XCTAssertThrowsError(try boundary.validate(appData.appendingPathComponent("restore")))
    }

    func testCT292_DatabaseFailureIsNotAnEmptyProjectList() async throws {
        let (project, _, snapshot) = try await configureV3()
        await service.database.close()
        do {
            _ = try await service.restore(RestoreRequest(
                projectID: project.id,
                snapshotID: snapshot,
                relativePath: nil,
                mode: .wholeProject,
                destination: workspace.appendingPathComponent("export-292")
            ))
            XCTFail("数据库不可读时恢复必须拒绝，而不是假定没有项目")
        } catch {
            // expected: fail closed
        }
    }

    func testCT293_UnresolvableBookmarkRejectsRestore() async throws {
        let (project, root, snapshot) = try await configureV3()
        var broken = project
        broken.bookmark = Data([0, 1, 2, 3])
        try await service.database.upsertProject(broken)
        try await assertRestoreRejected(
            destination: workspace.appendingPathComponent("export-293"),
            project: broken,
            snapshot: snapshot
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
    }

    func testCT294_OldRootPathDoesNotReplaceFailedBookmark() async throws {
        let (project, root, snapshot) = try await configureV3()
        var broken = project
        broken.bookmark = Data([9, 9, 9])
        try await service.database.upsertProject(broken)
        // The old rootPath exists, so falling back would be a security downgrade.
        try await assertRestoreRejected(
            destination: root.appendingPathComponent("inside"),
            project: broken,
            snapshot: snapshot
        )
    }

    func testCT295_TargetEqualProjectIsRejected() async throws {
        let (project, root, snapshot) = try await configureV3()
        try await assertRestoreRejected(destination: root, project: project, snapshot: snapshot)
    }

    func testCT296_TargetChildOfProjectIsRejected() async throws {
        let (project, root, snapshot) = try await configureV3()
        try await assertRestoreRejected(
            destination: root.appendingPathComponent("child"),
            project: project,
            snapshot: snapshot
        )
    }

    func testCT297_TargetAncestorOfProjectIsRejected() async throws {
        let (project, _, snapshot) = try await configureV3()
        try await assertRestoreRejected(destination: workspace, project: project, snapshot: snapshot)
    }

    func testCT298_TargetOverlappingAppDataIsRejected() async throws {
        let (project, _, snapshot) = try await configureV3()
        try await assertRestoreRejected(
            destination: paths.root.appendingPathComponent("export"),
            project: project,
            snapshot: snapshot
        )
    }

    func testCT299_TargetOverlappingCloudRepositoryIsRejected() async throws {
        let (project, _, snapshot) = try await configureV3()
        let settings = try await service.currentSettings()
        let mirror = try XCTUnwrap(settings.localMirrorPath)
        try await assertRestoreRejected(
            destination: URL(fileURLWithPath: mirror, isDirectory: true)
                .appendingPathComponent("export"),
            project: project,
            snapshot: snapshot
        )
    }
}
