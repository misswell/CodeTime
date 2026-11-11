import XCTest
import Foundation
@testable import CodeTimeCore
@testable import SharedModels
@testable import CodeTimeSecurity
@testable import BackupEngine

/// CT-161: the service actually drives the cloud-first engine.
///
/// A local mirror stands in for iCloud so the whole path — settings, project
/// policy, engine selection, snapshot commit, browse/read/restore and local-space
/// reporting — runs without a signed iCloud container.
final class ServiceV3IntegrationTests: XCTestCase {
    private var workspace: URL!
    private var paths: AppPaths!
    private var keychain: KeychainStore!
    private var service: CodeTimeService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("service-v3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        paths = AppPaths(root: workspace.appendingPathComponent("data", isDirectory: true))
        keychain = KeychainStore(service: "com.codetime.test.ct161.\(UUID().uuidString)")
        service = try CodeTimeService(paths: paths, keychain: keychain)
    }

    override func tearDownWithError() throws {
        if let keychain { keychain.deleteAllSecrets() }
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        service = nil
        try super.tearDownWithError()
    }

    private func configureV3() async throws -> (Project, URL) {
        _ = try await service.bootstrap()
        let mirror = workspace.appendingPathComponent("mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        var settings = try await service.currentSettings()
        settings.engineMode = .cloudFirst
        settings.iCloudEnabled = false
        settings.localMirrorPath = mirror.path
        settings.cachePreset = .minimal
        settings.spoolSoftLimitBytes = 64 * 1024 * 1024
        settings = try await service.saveSettings(settings)

        let projectRoot = workspace.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent("src"),
            withIntermediateDirectories: true
        )
        try Data("hello v3".utf8).write(to: projectRoot.appendingPathComponent("README.md"))
        try Data(String(repeating: "z", count: 60_000).utf8)
            .write(to: projectRoot.appendingPathComponent("src/data.txt"))
        let project = try await service.addProject(url: projectRoot, name: "v3")
        _ = settings
        return (project, mirror)
    }

    func testCT161_ServiceBacksUpBrowsesRestoresAndReportsSpace() async throws {        let (project, mirror) = try await configureV3()

        let outcome = try await service.createSnapshot(projectID: project.id, trigger: .manual)
        XCTAssertNil(outcome.cloudError)
        XCTAssertEqual(outcome.snapshot.cloudState, .synced)
        XCTAssertTrue(outcome.snapshot.fileCount >= 2)

        // v3 namespace, not a v2 generation directory.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: mirror.appendingPathComponent("v3/format.json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: mirror.appendingPathComponent("devices").path
        ), "v3 不应写入 v2 设备目录")

        let listing = try await service.listDirectory(snapshotID: outcome.snapshot.id, path: "")
        XCTAssertTrue(listing.contains { $0.path == "README.md" && !$0.isDirectory })
        XCTAssertTrue(listing.contains { $0.path == "src" && $0.isDirectory })

        let data = try await service.readFile(
            snapshotID: outcome.snapshot.id,
            path: "README.md",
            maxBytes: 1024
        )
        XCTAssertEqual(data, Data("hello v3".utf8))

        // The snapshot list is refreshed from cloud commits, not invented locally.
        let refreshed = try await service.refreshSnapshots(projectID: project.id)
        XCTAssertTrue(refreshed.contains { $0.id == outcome.snapshot.id })

        let destination = workspace.appendingPathComponent("restored", isDirectory: true)
        let job = try await service.restore(RestoreRequest(
            projectID: project.id,
            snapshotID: outcome.snapshot.id,
            relativePath: nil,
            mode: .wholeProject,
            destination: destination
        ))
        XCTAssertEqual(job.status, .completed)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("README.md")),
            Data("hello v3".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("src/data.txt")),
            Data(String(repeating: "z", count: 60_000).utf8)
        )

        let storageStatus = await service.v3StorageStatus()
        let storage = try XCTUnwrap(storageStatus)
        XCTAssertEqual(storage.pendingTasks, 0, "上传确认后不应残留待上传任务")
        XCTAssertEqual(storage.cacheBudgetBytes, 128 * 1024 * 1024)
        XCTAssertGreaterThan(storage.indexedChunkBytes, 0)

        let verification = try await service.verifySnapshot(
            projectID: project.id,
            snapshotID: outcome.snapshot.id
        )
        XCTAssertEqual(verification.outcome, .passed, verification.details)
    }

    /// A fresh install with a working cloud target starts on v3, while an install
    /// that already has snapshots keeps the legacy engine until migration.
    func testCT165_OnboardingStartsFreshInstallOnV3() async throws {
        _ = try await service.bootstrap()
        let mirror = workspace.appendingPathComponent("mirror", isDirectory: true)
        var settings = try await service.currentSettings()
        settings.engineMode = .kopia
        settings.hasCompletedOnboarding = false
        settings.iCloudEnabled = false
        settings.localMirrorPath = mirror.path
        _ = try await service.saveSettings(settings)

        try await service.completeOnboarding()
        let after = try await service.currentSettings()
        XCTAssertEqual(after.engineMode, .cloudFirst, "全新安装没有旧历史时应直接使用 v3")
        XCTAssertTrue(after.hasCompletedOnboarding)
    }

    /// CT-166: cancellation must travel Service → Adapter → Engine. The backup is
    /// stopped only after the engine has actually started uploading, so this test
    /// cannot pass by cancelling before the work task ran.
    func testCT168_ServiceCancellationStopsEngineBeforeCommit() async throws {
        let (project, mirror) = try await configureV3()
        let big = URL(fileURLWithPath: project.rootPath, isDirectory: true)
            .appendingPathComponent("src/big.bin")
        try writeRandomFile(big, bytes: 48 * 1024 * 1024)

        let task = Task {
            try await service.createSnapshot(projectID: project.id, trigger: .manual)
        }

        // Wait until the engine has written at least one object. That proves the
        // cancellation reaches a run that is already publishing data.
        var observedObject = false
        for _ in 0..<5_000 {
            if containsRegularFile(
                under: mirror.appendingPathComponent("v3", isDirectory: true),
                suffix: nil
            ) {
                observedObject = true
                break
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(observedObject, "备份未开始写入云端对象，取消测试无效")
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("取消后的备份不得成功返回")
        } catch {
            XCTAssertTrue(
                Self.isCancellationError(error),
                "取消必须以取消错误结束，而不是失败重试：\(error)"
            )
        }

        let snapshots = try await service.snapshots(projectID: project.id)
        XCTAssertTrue(snapshots.isEmpty, "取消的备份不得发布可见快照")
        let interrupted = try await service.database.jobs(
            projectID: project.id,
            states: [.interrupted],
            limit: 10
        )
        XCTAssertFalse(interrupted.isEmpty, "取消的备份任务必须标记为 interrupted")
        let after = try await service.currentSettings()
        XCTAssertEqual(after.engineMode, .cloudFirst)
    }

    private func writeRandomFile(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/urandom"))
        defer { try? input.close() }
        var remaining = bytes
        while remaining > 0 {
            let block = input.readData(ofLength: min(1024 * 1024, remaining))
            guard !block.isEmpty else { break }
            try output.write(contentsOf: block)
            remaining -= block.count
        }
    }

    private func containsRegularFile(under root: URL, suffix: String?) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in enumerator {
            guard url.path.contains("/objects/") || url.path.contains("/packs/") else {
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                continue
            }
            if let suffix, !url.lastPathComponent.hasSuffix(suffix) { continue }
            return true
        }
        return false
    }

    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let code = error as? CodeTimeError, case .cancelled = code { return true }
        if let engine = error as? CloudFirstEngineError, case .cancelled = engine { return true }
        return false
    }
}
