import XCTest
import Foundation
@testable import CodeTimeCore
@testable import SharedModels
@testable import CodeTimeSecurity
@testable import BackupEngine

/// CT-170: two independent service instances (two Macs) sharing one cloud root.
/// This is a local-mirror simulation, not a claim about real iCloud; the real
/// dual-Mac acceptance remains a separate external gate.
final class CrossDeviceV3Tests: XCTestCase {
    private var workspace: URL!
    private var keychain: KeychainStore!
    private var serviceA: CodeTimeService!
    private var serviceB: CodeTimeService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("cross-device-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        keychain = KeychainStore(service: "com.codetime.test.ct170.\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        keychain.deleteAllSecrets()
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        serviceA = nil
        serviceB = nil
        try super.tearDownWithError()
    }

    func testCT172_TwoServiceInstancesDiscoverEachOthersVersions() async throws {
        let mirror = workspace.appendingPathComponent("mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        let projectRoot = workspace.appendingPathComponent("project-a", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent("src"),
            withIntermediateDirectories: true
        )
        try Data("from Mac A".utf8).write(to: projectRoot.appendingPathComponent("README.md"))
        try Data(String(repeating: "a", count: 80_000).utf8)
            .write(to: projectRoot.appendingPathComponent("src/a.txt"))

        serviceA = try CodeTimeService(
            paths: AppPaths(root: workspace.appendingPathComponent("data-a", isDirectory: true)),
            keychain: keychain,
            hardwareUUIDProvider: { "hw-mac-a" }
        )
        serviceB = try CodeTimeService(
            paths: AppPaths(root: workspace.appendingPathComponent("data-b", isDirectory: true)),
            keychain: keychain,
            hardwareUUIDProvider: { "hw-mac-b" }
        )
        _ = try await serviceA.bootstrap()
        _ = try await serviceB.bootstrap()
        try await configure(serviceA, mirror: mirror)
        try await configure(serviceB, mirror: mirror)

        let project = try await serviceA.addProject(url: projectRoot, name: "shared")
        let first = try await serviceA.createSnapshot(projectID: project.id, trigger: .manual)
        XCTAssertTrue(first.snapshot.id.count > 0)

        let recoveryKeyText = try keychain.recoveryKeyText()
        let candidates = try await serviceB.v3RecoveryCandidates(
            storageRoot: mirror,
            recoveryKeyText: recoveryKeyText
        )
        let candidate = try XCTUnwrap(candidates.first { $0.projectID == project.id })
        XCTAssertTrue(candidate.restorable, candidate.detail)

        let restored = workspace.appendingPathComponent("restored-b", isDirectory: true)
        let recoveredProjectID = try await serviceB.recoverV3Project(
            storageRoot: mirror,
            recoveryKeyText: recoveryKeyText,
            candidate: candidate,
            destination: restored
        )
        XCTAssertEqual(recoveredProjectID, project.id)
        XCTAssertEqual(
            try Data(contentsOf: restored.appendingPathComponent("README.md")),
            Data("from Mac A".utf8)
        )

        // Mac B writes a new version into its own device namespace.
        try Data("from Mac B".utf8).write(to: restored.appendingPathComponent("README.md"))
        let second = try await serviceB.createSnapshot(projectID: project.id, trigger: .manual)

        // Mac A must discover the new version without a restart.
        let listed = try await serviceA.refreshSnapshots(projectID: project.id)
        XCTAssertTrue(
            listed.contains { $0.id == second.snapshot.id },
            "Mac A 未发现 Mac B 的新版本：\(listed.map(\.id))"
        )
        let readBack = try await serviceA.readFile(
            snapshotID: second.snapshot.id,
            path: "README.md",
            maxBytes: 1024
        )
        XCTAssertEqual(readBack, Data("from Mac B".utf8))

        // The remote discovery cache records both devices, but each version still
        // resolves through its remote commit.
        let remote = try await serviceA.database.remoteSnapshots(projectID: project.id)
        XCTAssertEqual(Set(remote.map(\.snapshotID)), [first.snapshot.id, second.snapshot.id])
        XCTAssertEqual(Set(remote.map(\.deviceID)).count, 2)
        XCTAssertTrue(remote.allSatisfy { $0.discoveryStatus == .verified })
    }

    private func configure(_ service: CodeTimeService, mirror: URL) async throws {
        var settings = try await service.currentSettings()
        settings.engineMode = .cloudFirst
        settings.iCloudEnabled = false
        settings.localMirrorPath = mirror.path
        settings.cachePreset = .minimal
        settings.spoolSoftLimitBytes = 64 * 1024 * 1024
        _ = try await service.saveSettings(settings)
    }
}
