import XCTest
import Foundation
@testable import BackupEngine
@testable import SharedModels
@testable import CodeTimeSecurity

/// CT-155: on-demand restore — staging, per-file verification, path safety and
/// the promise that a failure never touches the user's existing tree.
final class CloudRestoreEngineTests: XCTestCase {
    private var source: URL!
    private var work: URL!
    private let masterKey = Data("restore-test-master-key".utf8)
    private let projectID = UUID(uuidString: "0F0F0F0F-1111-2222-3333-444444444444")!

    private var cloud: InMemoryCloud!
    private var index: InMemoryIndex!
    private var backupEngine: CloudFirstBackupEngine!
    private var snapshotID: String!

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        work = fm.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        source = work.appendingPathComponent("project", isDirectory: true)
        try fm.createDirectory(at: source.appendingPathComponent("src/util"), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("readme-content".utf8).write(to: source.appendingPathComponent("README.md"))
        try Data(String(repeating: "x", count: 40_000).utf8)
            .write(to: source.appendingPathComponent("src/util/data.txt"))
        try Data("main".utf8).write(to: source.appendingPathComponent("src/main.swift"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appendingPathComponent("src/main.swift").path)
        try? fm.createSymbolicLink(
            atPath: source.appendingPathComponent("link.md").path,
            withDestinationPath: "README.md"
        )

        cloud = InMemoryCloud()
        index = InMemoryIndex()
        backupEngine = CloudFirstBackupEngine(
            masterKey: masterKey,
            deviceID: "device-A",
            index: index,
            sink: cloud,
            options: BackupRunOptions(
                chunker: ChunkerConfig(minSize: 1024, avgSize: 4096, maxSize: 16 * 1024)
            )
        )
        let report = try await backupEngine.run(
            projectID: projectID,
            root: source,
            matcher: ExclusionMatcher(rules: ExclusionPresets.defaultRules())
        )
        snapshotID = report.snapshotID
    }

    override func tearDown() async throws {
        if let work { try? FileManager.default.removeItem(at: work) }
        try await super.tearDown()
    }

    private func destination(_ name: String) -> URL {
        work.appendingPathComponent(name, isDirectory: true)
    }

    func testCT155_FullProjectRestoreIsBitForBit() async throws {
        let engine = CloudRestoreEngine(masterKey: masterKey, source: cloud)
        let target = destination("restored")

        let report: CloudRestoreReport = try await engine.restore(
            projectID: projectID, snapshotID: snapshotID, target: .project, destination: target
        )

        XCTAssertTrue(report.commited)
        XCTAssertEqual(report.filesRestored, 3)
        XCTAssertEqual(report.symlinksRestored, 1)
        XCTAssertGreaterThanOrEqual(report.directoriesCreated, 2, "空目录必须被恢复")
        XCTAssertGreaterThan(report.bytesWritten, 40_000)

        let fm = FileManager.default
        let readme = try Data(contentsOf: target.appendingPathComponent("README.md"))
        XCTAssertEqual(readme, Data("readme-content".utf8))
        let data = try Data(contentsOf: target.appendingPathComponent("src/util/data.txt"))
        XCTAssertEqual(data.count, 40_000)
        XCTAssertEqual(
            CanonicalHashing.sha256Hex(data),
            CanonicalHashing.sha256Hex(Data(String(repeating: "x", count: 40_000).utf8))
        )
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("empty").path), "空目录结构必须恢复")

        // Permissions and symlinks survive.
        let attributes = try fm.attributesOfItem(atPath: target.appendingPathComponent("src/main.swift").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.uint16Value, 0o755)
        let linkTarget = try fm.destinationOfSymbolicLink(atPath: target.appendingPathComponent("link.md").path)
        XCTAssertEqual(linkTarget, "README.md")

        // Restore never follows the link into the original tree.
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("link.md/..").path))
    }

    func testCT155_SingleFileRestoreDownloadsOnlyItsChunks() async throws {
        let engine = CloudRestoreEngine(masterKey: masterKey, source: cloud)
        let target = destination("one-file")
        let before = cloud.readObjectCount

        let report: CloudRestoreReport = try await engine.restore(
            projectID: projectID,
            snapshotID: snapshotID,
            target: .file(path: "README.md"),
            destination: target
        )

        XCTAssertEqual(report.filesRestored, 1)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("README.md")), Data("readme-content".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: target.appendingPathComponent("src").path),
            "单文件恢复不得恢复其他文件"
        )
        let downloaded = cloud.readObjectCount - before
        XCTAssertEqual(downloaded, 1, "只应下载该文件需要的块（实际 \(downloaded)）")
    }

    func testCT155_DirectoryRestoreSkipsSiblings() async throws {
        let engine = CloudRestoreEngine(masterKey: masterKey, source: cloud)
        let target = destination("subtree")

        let report: CloudRestoreReport = try await engine.restore(
            projectID: projectID,
            snapshotID: snapshotID,
            target: .directory(path: "src/util"),
            destination: target
        )

        XCTAssertEqual(report.filesRestored, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: target.appendingPathComponent("src/util/data.txt").path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: target.appendingPathComponent("README.md").path)
        )
    }

    func testCT155_ExistingDestinationIsNeverClobbered() async throws {
        let engine = CloudRestoreEngine(masterKey: masterKey, source: cloud)
        let target = destination("occupied")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let marker = target.appendingPathComponent("user-file.txt")
        try Data("do-not-touch".utf8).write(to: marker)

        do {
            _ = try await engine.restore(
                projectID: projectID, snapshotID: snapshotID, target: .project, destination: target
            )
            XCTFail("目标已存在时不得覆盖")
        } catch let error as CloudRestoreError {
            XCTAssertEqual(error, .destinationExists(target.path))
        }

        XCTAssertEqual(try Data(contentsOf: marker), Data("do-not-touch".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("README.md").path))
    }

    func testCT155_CorruptedObjectAbortsWithoutTouchingDestination() async throws {
        let engine = CloudRestoreEngine(masterKey: masterKey, source: cloud)
        let target = destination("corrupt")
        // Corrupt whichever object backs data.txt.
        let fileNodes = try await index.fileNodes(projectID: projectID)
        let node = try XCTUnwrap(fileNodes.first { $0.path == "src/util/data.txt" })
        let objectID = try XCTUnwrap(node.chunks.first?.objectID)
        cloud.corruptObjects[objectID] = Data("garbage".utf8)

        do {
            _ = try await engine.restore(
                projectID: projectID, snapshotID: snapshotID, target: .project, destination: target
            )
            XCTFail("对象损坏必须中止恢复")
        } catch {
            // Any decode/hash failure is acceptable; silently succeeding is not.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "失败不得留下目标目录")
    }

    func testCT155_TamperedManifestIsRejected() async throws {
        cloud.tamperManifest(snapshotID: snapshotID) { payload in
            guard payload.count > 40 else { return }
            payload[30] ^= 0xFF
        }
        let engine = CloudRestoreEngine(masterKey: masterKey, source: cloud)
        do {
            _ = try await engine.restore(
                projectID: projectID, snapshotID: snapshotID, target: .project,
                destination: destination("tampered")
            )
            XCTFail("Manifest 被篡改必须拒绝")
        } catch let error as CloudRestoreError {
            XCTAssertEqual(error, .manifestHashMismatch)
        }
    }

    func testCT155_PathTraversalIsRejected() async throws {
        let staging = destination("staging-root")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let engine = CloudRestoreEngine(masterKey: masterKey, source: cloud)

        for bad in ["../escape.txt", "/etc/passwd", "a/../../escape.txt", "a//b", "./hidden"] {
            XCTAssertThrowsError(try engine.safeURL(for: bad, in: staging), "必须拒绝：\(bad)")
        }
        XCTAssertNoThrow(try engine.safeURL(for: "src/ok.txt", in: staging))
        XCTAssertEqual(
            try engine.safeURL(for: "src/ok.txt", in: staging).lastPathComponent,
            "ok.txt"
        )
    }

    func testCT155_MissingCommitMeansVersionDoesNotExist() async throws {
        let engine = CloudRestoreEngine(masterKey: masterKey, source: cloud)
        do {
            _ = try await engine.loadManifest(projectID: projectID, snapshotID: "no-such-snapshot")
            XCTFail("未提交的版本必须不可读")
        } catch let error as CloudRestoreError {
            XCTAssertEqual(error, .commitMissing("no-such-snapshot"))
        }
    }
}
