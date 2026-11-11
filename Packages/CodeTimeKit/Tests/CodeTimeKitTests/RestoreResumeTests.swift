import XCTest
import Foundation
@testable import BackupEngine
@testable import SharedModels

/// CT-166: an interrupted v3 restore resumes from its deterministic staging
/// directory instead of re-downloading files that already verified.
final class RestoreResumeTests: XCTestCase {
    final class FlakySource: CloudObjectSource, @unchecked Sendable {
        let base: InMemoryCloud
        var failingObjectID: String?
        private let lock = NSLock()

        init(base: InMemoryCloud) { self.base = base }

        func readObject(_ objectID: String) async throws -> Data {
            lock.lock(); let failing = failingObjectID; lock.unlock()
            if failing == objectID { throw Failure.injected }
            return try await base.readObject(objectID)
        }

        func readPack(_ packID: String) async throws -> Data {
            try await base.readPack(packID)
        }

        func readNode(_ nodeID: String) async throws -> DirectoryNode {
            try await base.readNode(nodeID)
        }

        func readManifestPayload(projectID: UUID, snapshotID: String) async throws -> Data {
            try await base.readManifestPayload(projectID: projectID, snapshotID: snapshotID)
        }

        func readCommit(projectID: UUID, snapshotID: String) async throws -> SnapshotCommit? {
            try await base.readCommit(projectID: projectID, snapshotID: snapshotID)
        }

        func commits(projectID: UUID) async throws -> [SnapshotCommit] {
            try await base.commits(projectID: projectID)
        }

        enum Failure: Error { case injected }
    }

    func testCT166_InterruptedRestoreResumesStagedFiles() async throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = work.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try Data("first-file".utf8).write(to: projectRoot.appendingPathComponent("a.txt"))
        try Data(String(repeating: "b", count: 20_000).utf8)
            .write(to: projectRoot.appendingPathComponent("b.txt"))

        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let projectID = UUID()
        let masterKey = Data("resume-test-key".utf8)
        let snapshotID = "resume-snapshot"
        let engine = CloudFirstBackupEngine(
            masterKey: masterKey,
            deviceID: "device-A",
            index: index,
            sink: cloud,
            options: BackupRunOptions(
                chunker: ChunkerConfig(minSize: 1024, avgSize: 4096, maxSize: 16 * 1024),
                packObjectsUpTo: nil
            )
        )
        _ = try await engine.run(
            projectID: projectID,
            root: projectRoot,
            matcher: ExclusionMatcher(rules: []),
            snapshotID: snapshotID
        )
        let nodes = try await index.fileNodes(projectID: projectID)
        let failing = try XCTUnwrap(nodes.first { $0.path == "b.txt" }?.chunks.first?.objectID)

        let source = FlakySource(base: cloud)
        source.failingObjectID = failing
        let destination = work.appendingPathComponent("restored", isDirectory: true)
        let reader = CloudRestoreEngine(masterKey: masterKey, source: source)
        do {
            _ = try await reader.restore(
                projectID: projectID, snapshotID: snapshotID,
                target: .project, destination: destination
            )
            XCTFail("第一次恢复应因注入失败而中断")
        } catch {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let staging = CloudRestoreEngine.stagingURL(for: destination, snapshotID: snapshotID)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: staging.appendingPathComponent("a.txt").path
        ), "已校验的文件必须留在 staging 供续传")

        source.failingObjectID = nil
        let resumed = try await reader.restore(
            projectID: projectID, snapshotID: snapshotID,
            target: .project, destination: destination
        )
        XCTAssertGreaterThanOrEqual(resumed.filesSkippedExisting, 1, "续传必须复用已校验文件")
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("b.txt")),
            Data(String(repeating: "b", count: 20_000).utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "成功后 staging 必须原子移走")
    }
}
