import XCTest
import Foundation
@testable import BackupEngine

/// Task-book CT-300…CT-309: staging and journal must be directory-FD safe, and
/// staging identity must respect the target volume's case semantics.
final class TaskBookFileSystemTests: XCTestCase {
    private var workspace: URL!
    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskbook-fs-\(UUID().uuidString)", isDirectory: true)
        root = workspace.appendingPathComponent("staging", isDirectory: true)
        outside = workspace.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        try super.tearDownWithError()
    }

    func testCT300_StagingRootSymlinkIsRejected() throws {
        let link = workspace.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try RestoreDirectoryFS(rootURL: link))
    }

    func testCT301_StagingMiddleDirectorySymlinkIsRejected() throws {
        let fs = try RestoreDirectoryFS(rootURL: root)
        let link = root.appendingPathComponent("sub")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try fs.openFile("sub/file", flags: O_WRONLY | O_CREAT))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("file").path))
    }

    func testCT302_JournalSymlinkIsRejected() throws {
        let fs = try RestoreDirectoryFS(rootURL: root)
        let target = outside.appendingPathComponent("journal")
        try Data("protected".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("journal"),
            withDestinationURL: target
        )
        XCTAssertThrowsError(try RestoreJournal(directory: fs, name: "journal", identity: "id"))
        XCTAssertEqual(try Data(contentsOf: target), Data("protected".utf8))
    }

    func testCT303_ParentDirectoryReplacementBeforeWriteIsRejected() throws {
        let fs = try RestoreDirectoryFS(rootURL: root)
        try fs.ensureDirectory("parent")
        try FileManager.default.removeItem(at: root.appendingPathComponent("parent"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("parent"),
            withDestinationURL: outside
        )
        XCTAssertThrowsError(try fs.openFile("parent/file", flags: O_WRONLY | O_CREAT))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("file").path))
    }

    func testCT304_ChildDirectoryReplacementBeforeWriteIsRejected() throws {
        let fs = try RestoreDirectoryFS(rootURL: root)
        try fs.ensureDirectory("parent/child")
        let child = root.appendingPathComponent("parent/child")
        try FileManager.default.removeItem(at: child)
        try FileManager.default.createSymbolicLink(at: child, withDestinationURL: outside)
        XCTAssertThrowsError(try fs.openFile("parent/child/file", flags: O_WRONLY | O_CREAT))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("file").path))
    }

    func testCT305_DirectoryFDCannotEscapeStaging() throws {
        let fs = try RestoreDirectoryFS(rootURL: root)
        XCTAssertThrowsError(try fs.openFile("../escape", flags: O_WRONLY | O_CREAT))
        XCTAssertThrowsError(try fs.ensureDirectory("a/../../escape"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("escape").path))
    }

    func testCT306_CaseSensitiveVolumeDoesNotCollideStaging() throws {
        let upper = CloudRestoreEngine.stagingURL(
            for: workspace.appendingPathComponent("Export"),
            snapshotID: "snapshot",
            target: .project,
            caseSensitive: true
        )
        let lower = CloudRestoreEngine.stagingURL(
            for: workspace.appendingPathComponent("export"),
            snapshotID: "snapshot",
            target: .project,
            caseSensitive: true
        )
        XCTAssertNotEqual(upper, lower)
    }

    func testCT307_CaseInsensitiveVolumeMapsCaseVariantsToSameStaging() throws {
        let upper = CloudRestoreEngine.stagingURL(
            for: workspace.appendingPathComponent("Export"),
            snapshotID: "snapshot",
            target: .project,
            caseSensitive: false
        )
        let lower = CloudRestoreEngine.stagingURL(
            for: workspace.appendingPathComponent("export"),
            snapshotID: "snapshot",
            target: .project,
            caseSensitive: false
        )
        XCTAssertEqual(upper, lower)
    }

    func testCT308_DifferentSnapshotsDoNotShareStaging() {
        let destination = workspace.appendingPathComponent("export")
        let a = CloudRestoreEngine.stagingURL(for: destination, snapshotID: "a", target: .project)
        let b = CloudRestoreEngine.stagingURL(for: destination, snapshotID: "b", target: .project)
        XCTAssertNotEqual(a, b)
    }

    func testCT309_DifferentTargetsDoNotShareStaging() {
        let destination = workspace.appendingPathComponent("export")
        let a = CloudRestoreEngine.stagingURL(for: destination, snapshotID: "snap", target: .project)
        let b = CloudRestoreEngine.stagingURL(
            for: destination,
            snapshotID: "snap",
            target: .directory(path: "src")
        )
        XCTAssertNotEqual(a, b)
    }
}
