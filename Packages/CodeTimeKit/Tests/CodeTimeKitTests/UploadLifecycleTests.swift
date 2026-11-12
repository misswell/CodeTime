import XCTest
import Foundation
@testable import BackupEngine
@testable import SharedModels

/// CT-211…CT-214: upload state is not inferred from a file name; locks are
/// bounded; retry exhaustion keeps the only encrypted copy.
final class UploadLifecycleTests: XCTestCase {
    enum Failure: Error { case shouldNotUpload }

    final class StateSink: CloudObjectSink, @unchecked Sendable {
        var state: CloudObjectState
        private(set) var ensureCalls = 0
        private(set) var putCalls = 0

        init(state: CloudObjectState) { self.state = state }

        func hasObject(_ objectID: String) async throws -> Bool { state.isDurablyPresent }
        func objectState(_ objectID: String) async throws -> CloudObjectState { state }
        func ensureObjectReady(_ objectID: String, payload: Data, storedSize: Int) async throws -> StoredObjectLocation {
            ensureCalls += 1
            return StoredObjectLocation(storedSize: storedSize)
        }
        func putObject(_ payload: Data, objectID: String) async throws -> Bool {
            putCalls += 1
            throw Failure.shouldNotUpload
        }
        func putNode(_ node: DirectoryNode) async throws -> Bool { true }
        func putPack(_ payload: Data, packID: String) async throws -> Bool { true }
        func hasPack(_ packID: String) async throws -> Bool { false }
        func putManifest(_ payload: Data, projectID: UUID, snapshotID: String) async throws -> String {
            CanonicalHashing.sha256Hex(payload)
        }
        func putCommit(_ commit: SnapshotCommit) async throws {}
    }

    private func spool() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-lifecycle-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("spool/pending", isDirectory: true)
    }

    func testCT211_UploadingObjectIsWaitedForNotOverwritten() async throws {
        let root = spool()
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = StateSink(state: .uploading)
        let index = InMemoryIndex()
        let queue = UploadQueue(
            base: sink,
            index: index,
            configuration: .init(spoolRoot: root, retryBaseDelay: 0)
        )
        let id = String(repeating: "a", count: 64)
        let location = try await queue.ensureObjectReady(id, payload: Data("x".utf8), storedSize: 1)
        XCTAssertEqual(location.storedSize, 1)
        XCTAssertEqual(sink.ensureCalls, 1, "uploading 状态必须交给底层等待/确认")
        XCTAssertEqual(sink.putCalls, 0, "不得绕过 writer 直接写第二个密文")
        let tasks = try await index.pendingUploads(state: nil, limit: 10)
        XCTAssertTrue(tasks.isEmpty, "已有 writer 时不得创建新 spool 任务")
    }

    func testCT212_UploadingIsNotReportedAsReusable() async throws {
        let sink = StateSink(state: .uploading)
        let index = InMemoryIndex()
        let root = spool()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = UploadQueue(
            base: sink,
            index: index,
            configuration: .init(spoolRoot: root, retryBaseDelay: 0)
        )
        let id = String(repeating: "b", count: 64)
        let reusable = try await queue.hasObject(id)
        XCTAssertFalse(reusable)
        let state = try await queue.objectState(id)
        XCTAssertEqual(state, .uploading)
    }

    func testCT213_UploadLockFilesRemainBounded() async throws {
        let root = spool()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = InMemoryIndex()
        let queue = UploadQueue(
            base: InMemoryCloud(),
            index: index,
            configuration: .init(
                spoolRoot: root,
                retryBaseDelay: 0,
                lockStripeCount: 4
            )
        )
        for indexValue in 0..<32 {
            let id = String(format: "%064x", indexValue + 1)
            _ = try await queue.putObject(Data("payload-\(indexValue)".utf8), objectID: id)
        }
        let lockDir = root.deletingLastPathComponent().appendingPathComponent("upload-locks")
        let locks = (try? FileManager.default.contentsOfDirectory(
            at: lockDir,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertLessThanOrEqual(locks.count, 4, "锁文件必须固定为分片数量，不得按对象增长")
        let status = await queue.status()
        XCTAssertEqual(status.lockFileCount, locks.count)
    }

    func testCT214_RetryExhaustionKeepsSpoolAndJournal() async throws {
        let root = spool()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = InMemoryIndex()
        let offline = OfflineSink()
        let queue = UploadQueue(
            base: offline,
            index: index,
            configuration: .init(
                spoolRoot: root,
                softLimitBytes: 1 << 20,
                maxRetries: 0,
                retryBaseDelay: 0
            )
        )
        let id = String(repeating: "c", count: 64)
        do {
            _ = try await queue.putObject(Data("must-survive".utf8), objectID: id)
            XCTFail("离线上传必须失败")
        } catch {
            // expected
        }
        let tasks = try await index.pendingUploads(state: .failed, limit: 10)
        XCTAssertEqual(tasks.count, 1)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertEqual(files.count, 1, "重试耗尽后 spool 必须保留")
        let report = await queue.resumePending()
        XCTAssertEqual(report.skippedRetryExhausted, 1)
        XCTAssertEqual(report.uploaded, 0)
        let remaining = try await index.pendingUploads(state: nil, limit: 10)
        XCTAssertEqual(remaining.count, 1)
    }

    final class OfflineSink: CloudObjectSink, @unchecked Sendable {
        func hasObject(_ objectID: String) async throws -> Bool { false }
        func putObject(_ payload: Data, objectID: String) async throws -> Bool {
            throw Failure.shouldNotUpload
        }
        func putNode(_ node: DirectoryNode) async throws -> Bool { true }
        func putPack(_ payload: Data, packID: String) async throws -> Bool { true }
        func hasPack(_ packID: String) async throws -> Bool { false }
        func putManifest(_ payload: Data, projectID: UUID, snapshotID: String) async throws -> String {
            CanonicalHashing.sha256Hex(payload)
        }
        func putCommit(_ commit: SnapshotCommit) async throws {}
    }
}
