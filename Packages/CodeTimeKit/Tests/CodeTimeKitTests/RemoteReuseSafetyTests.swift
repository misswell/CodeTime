import XCTest
import Foundation
@testable import BackupEngine
@testable import SharedModels

/// CT-253…CT-254: a local SQLite chunk row is not proof that the cloud still
/// has the object. Incremental reuse must probe remote lifecycle state, re-read
/// missing data, and stop when the state is unknown.
final class RemoteReuseSafetyTests: XCTestCase {
    private var workspace: URL!
    private let masterKey = Data("remote-reuse-key".utf8)
    private let projectID = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-reuse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        try super.tearDownWithError()
    }

    private func makeProject() throws -> URL {
        let root = workspace.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("reuse-content".utf8).write(to: root.appendingPathComponent("a.txt"))
        return root
    }

    private func engine(
        sink: CloudObjectSink,
        index: InMemoryIndex
    ) -> CloudFirstBackupEngine {
        CloudFirstBackupEngine(
            masterKey: masterKey,
            deviceID: "device-A",
            index: index,
            sink: sink,
            options: BackupRunOptions(
                chunker: ChunkerConfig(minSize: 1024, avgSize: 4096, maxSize: 16 * 1024),
                packObjectsUpTo: nil
            )
        )
    }

    final class InaccessibleSink: CloudObjectSink, @unchecked Sendable {
        let base: InMemoryCloud
        let inaccessibleID: String

        init(base: InMemoryCloud, inaccessibleID: String) {
            self.base = base
            self.inaccessibleID = inaccessibleID
        }

        func hasObject(_ objectID: String) async throws -> Bool {
            try await base.hasObject(objectID)
        }

        @discardableResult
        func putObject(_ payload: Data, objectID: String) async throws -> Bool {
            try await base.putObject(payload, objectID: objectID)
        }

        @discardableResult
        func putNode(_ node: DirectoryNode) async throws -> Bool {
            try await base.putNode(node)
        }

        @discardableResult
        func putPack(_ payload: Data, packID: String) async throws -> Bool {
            try await base.putPack(payload, packID: packID)
        }

        func hasPack(_ packID: String) async throws -> Bool {
            try await base.hasPack(packID)
        }

        func objectState(_ objectID: String) async throws -> CloudObjectState {
            if objectID == inaccessibleID {
                return .inaccessible("metadata unavailable")
            }
            return try await base.objectState(objectID)
        }

        func ensureObjectReady(
            _ objectID: String,
            payload: Data,
            storedSize: Int
        ) async throws -> StoredObjectLocation {
            try await base.ensureObjectReady(
                objectID,
                payload: payload,
                storedSize: storedSize
            )
        }

        func packState(_ packID: String) async throws -> CloudObjectState {
            try await base.packState(packID)
        }

        func putManifest(_ payload: Data, projectID: UUID, snapshotID: String) async throws -> String {
            try await base.putManifest(payload, projectID: projectID, snapshotID: snapshotID)
        }

        func putCommit(_ commit: SnapshotCommit) async throws {
            try await base.putCommit(commit)
        }
    }

    func testCT253_MissingCloudObjectIsReuploadedInsteadOfReusedFromIndex() async throws {
        let project = try makeProject()
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let first = try await engine(sink: cloud, index: index).run(
            projectID: projectID,
            root: project,
            matcher: ExclusionMatcher(rules: []),
            snapshotID: "first"
        )
        XCTAssertTrue(first.committed)
        let known = try await index.fileNodes(projectID: projectID)
        let objectID = try XCTUnwrap(known.first?.chunks.first?.objectID)
        try await cloud.deleteObject(objectID)
        let stillPresent = try await cloud.hasObject(objectID)
        XCTAssertFalse(stillPresent)

        // The source is untouched, so size+mtime would normally reuse the file
        // node. Remote verification must force a re-read and re-upload.
        let second = try await engine(sink: cloud, index: index).run(
            projectID: projectID,
            root: project,
            matcher: ExclusionMatcher(rules: []),
            snapshotID: "second"
        )
        XCTAssertTrue(second.committed)
        XCTAssertGreaterThan(second.objectsUploaded, 0)
        let reuploaded = try await cloud.hasObject(objectID)
        XCTAssertTrue(reuploaded, "缺失对象必须重新上传")

        let destination = workspace.appendingPathComponent("restored", isDirectory: true)
        let reader = CloudRestoreEngine(masterKey: masterKey, source: cloud, options: RestoreOptions(sourceRoots: [project]))
        _ = try await reader.restore(
            projectID: projectID,
            snapshotID: "second",
            target: .project,
            destination: destination
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("a.txt")),
            Data("reuse-content".utf8)
        )
    }

    func testCT266_UploadQueueTerminalJournalDoesNotHideDeletedObject() async throws {
        let project = try makeProject()
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let spool = workspace.appendingPathComponent("spool/pending", isDirectory: true)
        let queue = UploadQueue(
            base: cloud,
            index: index,
            configuration: .init(spoolRoot: spool, retryBaseDelay: 0)
        )
        let engine = CloudFirstBackupEngine(
            masterKey: masterKey,
            deviceID: "device-A",
            index: index,
            sink: queue,
            options: BackupRunOptions(
                chunker: ChunkerConfig(minSize: 1024, avgSize: 4096, maxSize: 16 * 1024),
                packObjectsUpTo: nil
            )
        )
        _ = try await engine.run(
            projectID: projectID,
            root: project,
            matcher: ExclusionMatcher(rules: []),
            snapshotID: "first"
        )
        let known = try await index.fileNodes(projectID: projectID)
        let objectID = try XCTUnwrap(known.first?.chunks.first?.objectID)
        try await cloud.deleteObject(objectID)
        // Simulate the dangerous production state: journal says uploaded, but
        // the local spool was already cleaned and the cloud object is gone.
        try await index.enqueueUploads([
            PendingUploadV3(
                taskID: "object:\(objectID)",
                objectID: objectID,
                localPath: spool.appendingPathComponent("object-\(objectID)").path,
                remotePath: UploadQueue.objectKind,
                fileSize: 1,
                state: .uploadedPendingCleanup,
                retryCount: 0
            )
        ])
        let second = try await engine.run(
            projectID: projectID,
            root: project,
            matcher: ExclusionMatcher(rules: []),
            snapshotID: "second"
        )
        XCTAssertTrue(second.committed)
        let reuploaded = try await cloud.hasObject(objectID)
        XCTAssertTrue(reuploaded, "终态 journal 不得掩盖已删除的云端对象")
    }

    func testCT254_InaccessibleRemoteStateAbortsBeforeCommit() async throws {
        let project = try makeProject()
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        _ = try await engine(sink: cloud, index: index).run(
            projectID: projectID,
            root: project,
            matcher: ExclusionMatcher(rules: []),
            snapshotID: "first"
        )
        let known = try await index.fileNodes(projectID: projectID)
        let objectID = try XCTUnwrap(known.first?.chunks.first?.objectID)
        let sink = InaccessibleSink(base: cloud, inaccessibleID: objectID)
        do {
            _ = try await engine(sink: sink, index: index).run(
                projectID: projectID,
                root: project,
                matcher: ExclusionMatcher(rules: []),
                snapshotID: "second"
            )
            XCTFail("远端状态不可读时必须中止，而不是当作缺失或存在")
        } catch {
            // expected: fail closed
        }
        XCTAssertNil(cloud.commits["second"])
    }
}
