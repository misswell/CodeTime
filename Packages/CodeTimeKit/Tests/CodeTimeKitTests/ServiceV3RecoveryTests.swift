import XCTest
import Foundation
@testable import CodeTimeCore
@testable import SharedModels
@testable import CodeTimeSecurity

/// CT-164: new-Mac recovery. A second service instance with the same recovery
/// key discovers the v3 projects, restores one version, and can browse the
/// history afterwards — without downloading a Kopia repository.
final class ServiceV3RecoveryTests: XCTestCase {
    private var workspace: URL!
    private var mirror: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("service-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        mirror = workspace.appendingPathComponent("mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        try super.tearDownWithError()
    }

    private func makeService(_ name: String, keychain: KeychainStore) throws -> CodeTimeService {
        let paths = AppPaths(root: workspace.appendingPathComponent(name, isDirectory: true))
        let service = try CodeTimeService(paths: paths, keychain: keychain)
        return service
    }

    private func configureV3(_ service: CodeTimeService) async throws -> (Project, URL) {
        _ = try await service.bootstrap()
        var settings = try await service.currentSettings()
        settings.engineMode = .cloudFirst
        settings.iCloudEnabled = false
        settings.localMirrorPath = mirror.path
        _ = try await service.saveSettings(settings)

        let projectRoot = workspace.appendingPathComponent("source-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try Data("new-mac-file".utf8).write(to: projectRoot.appendingPathComponent("hello.txt"))
        return (try await service.addProject(url: projectRoot, name: "source"), projectRoot)
    }

    func testCT164_NewMacDiscoversAndRestoresV3Project() async throws {
        let keychain = KeychainStore(service: "com.codetime.test.ct164.\(UUID().uuidString)")
        defer { keychain.deleteAllSecrets() }

        let macA = try makeService("mac-a", keychain: keychain)
        let (project, _) = try await configureV3(macA)
        let outcome = try await macA.createSnapshot(projectID: project.id, trigger: .manual)
        let recoveryKey = try keychain.recoveryKeyText()

        // Mac B: fresh database, same Apple account/recovery key, different device.
        let macB = try makeService("mac-b", keychain: keychain)
        _ = try await macB.bootstrap()
        var settingsB = try await macB.currentSettings()
        settingsB.localMirrorPath = mirror.path
        settingsB.iCloudEnabled = false
        _ = try await macB.saveSettings(settingsB)
        let candidates = try await macB.v3RecoveryCandidates(
            storageRoot: mirror,
            recoveryKeyText: recoveryKey
        )
        let candidate = try XCTUnwrap(candidates.first { $0.projectID == project.id })
        XCTAssertTrue(candidate.restorable, candidate.detail)
        XCTAssertEqual(candidate.snapshotCount, 1)

        let destination = workspace.appendingPathComponent("restored-on-b", isDirectory: true)
        let recoveredID = try await macB.recoverV3Project(
            storageRoot: mirror,
            recoveryKeyText: recoveryKey,
            candidate: candidate,
            destination: destination
        )
        XCTAssertEqual(recoveredID, project.id)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("hello.txt")),
            Data("new-mac-file".utf8)
        )

        let finalSettings = try await macB.currentSettings()
        XCTAssertEqual(finalSettings.engineMode, .cloudFirst)
        let history = try await macB.refreshSnapshots(projectID: recoveredID)
        XCTAssertTrue(history.contains { $0.id == outcome.snapshot.id })
        let listing = try await macB.listDirectory(snapshotID: outcome.snapshot.id, path: "")
        XCTAssertTrue(listing.contains { $0.path == "hello.txt" })
    }
}
