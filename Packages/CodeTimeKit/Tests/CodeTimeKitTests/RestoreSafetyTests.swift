import XCTest
import Foundation
@testable import BackupEngine
@testable import SharedModels

/// CT-169: restore must not accept partial files, must preserve directory
/// metadata, and must create symlinks only after all regular content.
final class RestoreSafetyTests: XCTestCase {
    private var work: URL!
    private var project: URL!
    private let masterKey = Data("restore-safety-key".utf8)
    private let projectID = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-safety-\(UUID().uuidString)", isDirectory: true)
        project = work.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("nested"),
            withIntermediateDirectories: true
        )
        try Data("correct-content".utf8).write(to: project.appendingPathComponent("a.txt"))
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o750)],
            ofItemAtPath: project.appendingPathComponent("nested").path
        )
        let outside = work.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: project.appendingPathComponent("link").path,
            withDestinationPath: outside.path
        )
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
        try super.tearDownWithError()
    }

    private func backup() async throws -> (InMemoryCloud, BackupRunReport) {
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let engine = CloudFirstBackupEngine(
            masterKey: masterKey, deviceID: "device-A", index: index, sink: cloud
        )
        let report = try await engine.run(
            projectID: projectID, root: project, matcher: ExclusionMatcher(rules: [])
        )
        return (cloud, report)
    }

    func testCT186_TruncatedStagingFileIsNeverAcceptedWhenVerifyHashesIsFalse() async throws {
        let (cloud, report) = try await backup()
        let destination = work.appendingPathComponent("restored", isDirectory: true)
        let staging = CloudRestoreEngine.stagingURL(for: destination, snapshotID: report.snapshotID, target: .project)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        // Same size, wrong content: the old resume shortcut would accept it.
        try Data("inCORRECT!!".utf8.prefix(15)).write(to: staging.appendingPathComponent("a.txt"))
        XCTAssertEqual(
            (try? Data(contentsOf: staging.appendingPathComponent("a.txt")))?.count,
            11
        )
        let engine = CloudRestoreEngine(
            masterKey: masterKey,
            source: cloud,
            options: RestoreOptions(verifyHashes: false)
        )
        _ = try await engine.restore(
            projectID: projectID, snapshotID: report.snapshotID,
            target: .project, destination: destination
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("a.txt")),
            Data("correct-content".utf8),
            "verifyHashes=false 也不能接受内容不一致的 staging 文件"
        )
    }

    func testCT187_DirectoryModeAndSymlinksAreRestoredWithoutEscaping() async throws {
        let (cloud, report) = try await backup()
        let destination = work.appendingPathComponent("restored", isDirectory: true)
        let engine = CloudRestoreEngine(masterKey: masterKey, source: cloud)
        _ = try await engine.restore(
            projectID: projectID, snapshotID: report.snapshotID,
            target: .project, destination: destination
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: destination.appendingPathComponent("nested").path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.uint16Value, 0o750)
        let link = destination.appendingPathComponent("link")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
            try FileManager.default.destinationOfSymbolicLink(atPath: project.appendingPathComponent("link").path)
        )
        // Content written through the original symlink must not appear in staging.
        let outside = try FileManager.default.destinationOfSymbolicLink(
            atPath: project.appendingPathComponent("link").path
        )
        let outsideContents = try FileManager.default.contentsOfDirectory(atPath: outside)
        XCTAssertTrue(outsideContents.isEmpty, "恢复不得通过符号链接向项目外写入")
    }
}
