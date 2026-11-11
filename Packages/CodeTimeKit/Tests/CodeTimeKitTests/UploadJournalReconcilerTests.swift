import XCTest
import Foundation
@testable import BackupEngine
@testable import SharedModels

/// Journal/spool reconciliation and the per-object cross-process upload lease.
final class UploadJournalReconcilerTests: XCTestCase {
    private let id = String(repeating: "a", count: 64)

    private func spool() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconciler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func file(_ spool: URL, kind: String = "object", id: String? = nil) -> URL {
        spool.appendingPathComponent("\(kind)-\(id ?? self.id)")
    }

    func testCT190_ReconcilerAdoptsValidOrphansAndQuarantinesUnknown() async throws {
        let spool = try spool()
        defer { try? FileManager.default.removeItem(at: spool) }
        try Data("valid-object".utf8).write(to: file(spool))
        try Data("partial".utf8).write(to: spool.appendingPathComponent(".tmp-\(UUID().uuidString)"))
        let index = InMemoryIndex()
        let cloud = InMemoryCloud()
        let reconciler = UploadJournalReconciler(
            spoolRoot: spool,
            index: index,
            cloud: cloud,
            validate: { payload, _, _ in payload == Data("valid-object".utf8) }
        )
        let report = await reconciler.reconcile()
        XCTAssertEqual(report.adoptedFiles, 1)
        XCTAssertEqual(report.quarantined.count, 1)
        let tasks = try await index.pendingUploads(state: .pending, limit: 10)
        XCTAssertEqual(tasks.map(\.taskID), ["object:\(id)"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.appendingPathComponent(".tmp-\(UUID().uuidString)").path))
    }

    func testCT191_ReconcilerResolvesMissingFilesAgainstTheCloud() async throws {
        let spool = try spool()
        defer { try? FileManager.default.removeItem(at: spool) }
        let index = InMemoryIndex()
        let cloud = InMemoryCloud()
        try await cloud.putObject(Data("uploaded".utf8), objectID: id)
        try await index.enqueueUploads([
            PendingUploadV3(
                taskID: "object:\(id)", objectID: id,
                localPath: file(spool).path, remotePath: "object", fileSize: 8
            )
        ])
        let missing = String(repeating: "b", count: 64)
        try await index.enqueueUploads([
            PendingUploadV3(
                taskID: "object:\(missing)", objectID: missing,
                localPath: file(spool, id: missing).path, remotePath: "object", fileSize: 8
            )
        ])
        let report = await UploadJournalReconciler(
            spoolRoot: spool, index: index, cloud: cloud
        ).reconcile()
        XCTAssertEqual(report.removedConfirmedTasks, 1)
        XCTAssertEqual(report.failedTasks, 1)
        let remaining = try await index.pendingUploads(state: nil, limit: 10)
        XCTAssertEqual(remaining.map(\.taskID), ["object:\(missing)"])
        XCTAssertEqual(remaining.first?.state, .failed)
    }

    func testCT192_ReconcilerCleansUploadedPendingCleanup() async throws {
        let spool = try spool()
        defer { try? FileManager.default.removeItem(at: spool) }
        try Data("confirmed".utf8).write(to: file(spool))
        let index = InMemoryIndex()
        try await index.enqueueUploads([
            PendingUploadV3(
                taskID: "object:\(id)", objectID: id,
                localPath: file(spool).path, remotePath: "object", fileSize: 9,
                state: .uploadedPendingCleanup
            )
        ])
        let report = await UploadJournalReconciler(
            spoolRoot: spool, index: index, cloud: InMemoryCloud()
        ).reconcile()
        XCTAssertEqual(report.removedConfirmedTasks, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(spool).path))
        let remaining = try await index.pendingUploads(state: nil, limit: 10)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testCT193_UploadQueueRefusesConcurrentWriterForSameObject() async throws {
        let spool = try spool()
        defer { try? FileManager.default.removeItem(at: spool) }
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let first = UploadQueue(
            base: cloud, index: index,
            configuration: .init(spoolRoot: spool, leaseTimeout: 0, retryBaseDelay: 0)
        )
        let second = UploadQueue(
            base: cloud, index: index,
            configuration: .init(spoolRoot: spool, leaseTimeout: 0.1, retryBaseDelay: 0)
        )
        // Simulate another process holding the same object lease.
        let held = try await first.acquireUploadLease(kind: "object", id: id, timeout: 0)
        defer { held.release() }
        do {
            _ = try await second.putObject(Data("payload".utf8), objectID: id)
            XCTFail("同一 Object ID 不允许第二个写入者")
        } catch let error as UploadQueueError {
            guard case .leaseUnavailable = error else {
                return XCTFail("期望 leaseUnavailable，实际 \(error)")
            }
        }
    }
}
