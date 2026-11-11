import XCTest
import Foundation
@testable import BackupEngine
@testable import SharedModels

/// CT-159: the durable upload queue. Un-uploaded encrypted data must survive a
/// failure, never be evicted to free space, and must resume without re-encoding.
final class UploadQueueTests: XCTestCase {

    enum GateError: Error, Equatable { case offline }

    /// Wraps the in-memory cloud with an on/off switch so an "offline" iCloud can
    /// be simulated without touching the network.
    final class GatedCloud: CloudObjectSink, @unchecked Sendable {
        let base: InMemoryCloud
        var offline = false
        var attempts = 0
        private let lock = NSLock()

        init(base: InMemoryCloud) { self.base = base }

        func hasObject(_ objectID: String) async throws -> Bool {
            try await base.hasObject(objectID)
        }

        func hasPack(_ packID: String) async throws -> Bool {
            try await base.hasPack(packID)
        }

        @discardableResult
        func putObject(_ payload: Data, objectID: String) async throws -> Bool {
            lock.lock(); attempts += 1; let down = offline; lock.unlock()
            if down { throw GateError.offline }
            return try await base.putObject(payload, objectID: objectID)
        }

        @discardableResult
        func putPack(_ payload: Data, packID: String) async throws -> Bool {
            lock.lock(); attempts += 1; let down = offline; lock.unlock()
            if down { throw GateError.offline }
            return try await base.putPack(payload, packID: packID)
        }

        @discardableResult
        func putNode(_ node: DirectoryNode) async throws -> Bool {
            if offline { throw GateError.offline }
            return try await base.putNode(node)
        }

        func putManifest(_ payload: Data, projectID: UUID, snapshotID: String) async throws -> String {
            if offline { throw GateError.offline }
            return try await base.putManifest(payload, projectID: projectID, snapshotID: snapshotID)
        }

        func putCommit(_ commit: SnapshotCommit) async throws {
            if offline { throw GateError.offline }
            try await base.putCommit(commit)
        }
    }

    private func spoolDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("spool-\(UUID().uuidString)", isDirectory: true)
    }

    private func spoolFiles(_ root: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        )) ?? []
    }

    private let objectID = String(repeating: "a", count: 64)

    func testCT159_FailedUploadKeepsSpooledBytesAndResumeCompletes() async throws {
        let spool = spoolDirectory()
        defer { try? FileManager.default.removeItem(at: spool) }
        let cloud = GatedCloud(base: InMemoryCloud())
        let index = InMemoryIndex()
        let queue = UploadQueue(
            base: cloud,
            index: index,
            configuration: .init(spoolRoot: spool, softLimitBytes: 1 << 20, uploadConcurrency: 2)
        )

        let payload = Data(repeating: 0xAB, count: 4096)
        cloud.offline = true
        do {
            _ = try await queue.putObject(payload, objectID: objectID)
            XCTFail("离线时上传必须失败")
        } catch {
            // expected
        }

        // The encrypted payload is still on disk and the journal still owes it.
        XCTAssertEqual(spoolFiles(spool).count, 1, "失败的上传必须保留加密数据")
        XCTAssertEqual(spoolFiles(spool).first.flatMap { try? Data(contentsOf: $0) }, payload)
        let pending = try await index.pendingUploads(state: nil, limit: 10)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.state, .failed)
        XCTAssertEqual(pending.first?.retryCount, 1)
        let pendingBytes = try await index.pendingUploadBytes()
        XCTAssertEqual(pendingBytes, Int64(payload.count))

        // Network returns: the queue uploads from the spool, no re-encode needed.
        cloud.offline = false
        let report = await queue.resumePending()
        XCTAssertEqual(report.uploaded, 1)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(report.bytesUploaded, Int64(payload.count))
        XCTAssertTrue(spoolFiles(spool).isEmpty, "确认上传后必须释放待上传副本")
        let remaining = try await index.pendingUploads(state: nil, limit: 10)
        XCTAssertEqual(remaining.count, 0)
        XCTAssertEqual(cloud.base.objects[objectID], payload)
    }

    func testCT159_SoftLimitPausesInsteadOfDeletingStagedData() async throws {
        let spool = spoolDirectory()
        defer { try? FileManager.default.removeItem(at: spool) }
        let cloud = GatedCloud(base: InMemoryCloud())
        let index = InMemoryIndex()
        let queue = UploadQueue(
            base: cloud,
            index: index,
            configuration: .init(spoolRoot: spool, softLimitBytes: 5000)
        )

        let first = Data(repeating: 1, count: 4000)
        cloud.offline = true
        _ = try? await queue.putObject(first, objectID: objectID)

        let secondID = String(repeating: "b", count: 64)
        do {
            _ = try await queue.putObject(Data(repeating: 2, count: 2000), objectID: secondID)
            XCTFail("超过待上传软上限时必须暂停，而不是继续写入")
        } catch let error as UploadQueueError {
            guard case .spoolFull(let pendingBytes, let limit) = error else {
                return XCTFail("期望 spoolFull，实际 \(error)")
            }
            XCTAssertEqual(pendingBytes, 4000)
            XCTAssertEqual(limit, 5000)
        }

        XCTAssertEqual(spoolFiles(spool).count, 1, "已暂存的数据不得因上限被删除")
        let kept = try await index.pendingUploads(state: nil, limit: 10)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(spoolFiles(spool).first.flatMap { try? Data(contentsOf: $0) }, first)
    }

    func testCT159_ResumeCleansOrphanWhoseUploadActuallySucceeded() async throws {
        let spool = spoolDirectory()
        defer { try? FileManager.default.removeItem(at: spool) }
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        let payload = Data("already-uploaded".utf8)
        let file = spool.appendingPathComponent("object-\(objectID)")
        try payload.write(to: file)
        // Simulate a task left behind by a crash an hour ago; a fresh .uploading
        // file may belong to another process that is still uploading.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3700)],
            ofItemAtPath: file.path
        )

        let cloud = GatedCloud(base: InMemoryCloud())
        try await cloud.base.putObject(payload, objectID: objectID)
        let index = InMemoryIndex()
        try await index.enqueueUploads([
            PendingUploadV3(
                taskID: "object:\(objectID)",
                objectID: objectID,
                localPath: file.path,
                remotePath: UploadQueue.objectKind,
                fileSize: Int64(payload.count),
                state: .uploading
            )
        ])

        let queue = UploadQueue(
            base: cloud,
            index: index,
            configuration: .init(spoolRoot: spool, softLimitBytes: 1 << 20)
        )
        let report = await queue.resumePending()
        XCTAssertEqual(report.alreadyPresent, 1)
        XCTAssertEqual(report.failed, 0)
        XCTAssertTrue(spoolFiles(spool).isEmpty)
        let remaining = try await index.pendingUploads(state: nil, limit: 10)
        XCTAssertEqual(remaining.count, 0)
    }

    func testCT159_EngineOfflineKeepsSpoolAndCommitsAfterResume() async throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-engine-\(UUID().uuidString)", isDirectory: true)
        let root = work.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        for index in 1...6 {
            try Data("offline-file-\(index)".utf8).write(to: root.appendingPathComponent("f\(index).txt"))
        }

        let spool = work.appendingPathComponent("spool", isDirectory: true)
        let cloud = GatedCloud(base: InMemoryCloud())
        let index = InMemoryIndex()
        let queue = UploadQueue(
            base: cloud,
            index: index,
            configuration: .init(spoolRoot: spool, softLimitBytes: 1 << 20)
        )
        let projectID = UUID()
        let masterKey = Data("queue-test-key".utf8)
        let engine = CloudFirstBackupEngine(
            masterKey: masterKey,
            deviceID: "device-A",
            index: index,
            sink: queue,
            options: BackupRunOptions(
                chunker: ChunkerConfig(minSize: 1024, avgSize: 4096, maxSize: 16 * 1024)
            )
        )
        let matcher = ExclusionMatcher(rules: ExclusionPresets.defaultRules())

        cloud.offline = true
        do {
            _ = try await engine.run(projectID: projectID, root: root, matcher: matcher)
            XCTFail("离线时不得发布快照")
        } catch {
            // expected: the pack upload failed
        }
        XCTAssertFalse(spoolFiles(spool).isEmpty, "离线时必须保留加密待上传数据")
        let snapshots = try await index.snapshotRecords(projectID: projectID, limit: 10)
        XCTAssertTrue(snapshots.isEmpty, "未上传完成不得写入可用的快照记录")

        cloud.offline = false
        let resumed = await queue.resumePending()
        XCTAssertEqual(resumed.failed, 0)
        XCTAssertGreaterThan(resumed.uploaded, 0)
        XCTAssertTrue(spoolFiles(spool).isEmpty)

        let report = try await engine.run(projectID: projectID, root: root, matcher: matcher)
        XCTAssertTrue(report.committed)

        let restore = CloudRestoreEngine(masterKey: masterKey, source: cloud.base)
        let destination = work.appendingPathComponent("restored", isDirectory: true)
        _ = try await restore.restore(
            projectID: projectID,
            snapshotID: report.snapshotID,
            target: .project,
            destination: destination
        )
        for index in 1...6 {
            XCTAssertEqual(
                try Data(contentsOf: destination.appendingPathComponent("f\(index).txt")),
                Data("offline-file-\(index)".utf8)
            )
        }
    }
}
