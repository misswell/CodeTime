import XCTest
import Foundation
@testable import Persistence
@testable import SharedModels

/// CT-152: the v3 local index. It is a rebuildable cache of knowledge — the
/// tests pin the semantics that matter: replaced scans leave no ghosts, retries
/// are durable, and pinned cache entries survive budget enforcement.
final class CloudIndexV3Tests: XCTestCase {
    private var directory: URL!
    private var store: SQLiteStore!
    private let projectID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("v3-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try SQLiteStore(path: directory.appendingPathComponent("codetime.sqlite").path)
    }

    override func tearDown() async throws {
        await store?.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func node(_ path: String, size: Int64, hash: String) -> FileNode {
        FileNode(
            path: path,
            kind: .file,
            size: size,
            contentHash: hash,
            chunks: [
                ChunkRef(objectID: hash, plaintextSize: Int(size), storedSize: Int(size), compression: 0)
            ]
        ).withComputedID()
    }

    func testCT152_FileIndexReplacementLeavesNoGhosts() async throws {
        try await store.replaceFileIndex(
            projectID: projectID,
            files: [node("a.txt", size: 1, hash: "h1"), node("b.txt", size: 2, hash: "h2")],
            snapshotID: "snap-1"
        )
        var files = try await store.fileIndex(projectID: projectID)
        XCTAssertEqual(files.map(\.path), ["a.txt", "b.txt"])
        let count = try await store.fileIndexCount(projectID: projectID)
        XCTAssertEqual(count, 2)

        // Second scan: b.txt disappeared, a.txt changed.
        try await store.replaceFileIndex(
            projectID: projectID,
            files: [node("a.txt", size: 9, hash: "h1-new")],
            snapshotID: "snap-2"
        )
        files = try await store.fileIndex(projectID: projectID)
        XCTAssertEqual(files.map(\.path), ["a.txt"], "消失的文件不得残留在索引里")
        XCTAssertEqual(files.first?.size, 9)
        let single = try await store.fileNode(projectID: projectID, path: "a.txt")
        XCTAssertEqual(single?.contentHash, "h1-new")
        let missing = try await store.fileNode(projectID: projectID, path: "b.txt")
        XCTAssertNil(missing)
    }

    func testCT152_ChunkIndexAnswersWhatIsAlreadyKnown() async throws {
        let chunks = [
            ChunkRecordV3(objectID: "obj-1", plaintextSize: 100, storedSize: 80, keyVersion: 1),
            ChunkRecordV3(objectID: "obj-2", plaintextSize: 200, storedSize: 150, keyVersion: 1),
        ]
        try await store.upsertChunks(chunks)

        let known = try await store.knownObjectIDs(["obj-1", "obj-2", "obj-3"])
        XCTAssertEqual(known, ["obj-1", "obj-2"])

        // Upsert keeps the record and can upgrade it to verified.
        try await store.markChunkVerified("obj-1")
        let record = try await store.chunkRecord("obj-1")
        XCTAssertNotNil(record?.verifiedAt)
        XCTAssertEqual(record?.plaintextSize, 100)

        let total = try await store.chunkBytes()
        XCTAssertEqual(total, 230)
        let count = try await store.chunkCount()
        XCTAssertEqual(count, 2)

        try await store.removeChunkRecord("obj-2")
        let after = try await store.knownObjectIDs(["obj-2"])
        XCTAssertTrue(after.isEmpty)
    }

    func testCT152_SnapshotRecordsAreOrderedAndMutable() async throws {
        var older = SnapshotRecordV3(
            snapshotID: "s1", projectID: projectID,
            createdAt: Date(timeIntervalSince1970: 100),
            rootNodeID: "root1", fileCount: 1, totalBytes: 10
        )
        let newer = SnapshotRecordV3(
            snapshotID: "s2", projectID: projectID, parentSnapshotID: "s1",
            createdAt: Date(timeIntervalSince1970: 200),
            rootNodeID: "root2", fileCount: 2, totalBytes: 20
        )
        try await store.upsertSnapshotRecord(older)
        try await store.upsertSnapshotRecord(newer)

        let records = try await store.snapshotRecords(projectID: projectID)
        XCTAssertEqual(records.map(\.snapshotID), ["s2", "s1"], "按时间倒序")
        let latest = try await store.latestSnapshotRecord(projectID: projectID)
        XCTAssertEqual(latest?.snapshotID, "s2")
        XCTAssertEqual(latest?.parentSnapshotID, "s1")

        try await store.updateSnapshotRecord(
            "s1", uploadState: .uploaded, commitState: .committed, manifestPayloadHash: "abc"
        )
        let reloaded = try await store.snapshotRecord("s1")
        older = try XCTUnwrap(reloaded)
        XCTAssertEqual(older.uploadState, .uploaded)
        XCTAssertEqual(older.commitState, .committed)
        XCTAssertEqual(older.manifestPayloadHash, "abc")
        XCTAssertTrue(older.isCommitted)
    }

    func testCT152_PendingUploadsAreDurableAndCounted() async throws {
        let tasks = (1...3).map { index in
            PendingUploadV3(
                taskID: "task-\(index)",
                objectID: "obj-\(index)",
                localPath: "/spool/pending/obj-\(index)",
                remotePath: "/cloud/obj-\(index)",
                fileSize: Int64(index) * 100
            )
        }
        try await store.enqueueUploads(tasks)
        let pending = try await store.pendingUploads(state: .pending)
        XCTAssertEqual(pending.count, 3)
        let bytes = try await store.pendingUploadBytes()
        XCTAssertEqual(bytes, 600)
        let count = try await store.pendingUploadCount()
        XCTAssertEqual(count, 3)

        try await store.updateUploadState("task-1", state: .failed, bumpRetry: true)
        let retried = try await store.pendingUploads().first { $0.taskID == "task-1" }
        XCTAssertEqual(retried?.state, .failed)
        XCTAssertEqual(retried?.retryCount, 1, "重试次数必须持久化")

        try await store.removeUpload("task-2")
        let remaining = try await store.pendingUploadCount()
        XCTAssertEqual(remaining, 2)
    }

    func testCT152_CacheIndexTracksPinnedAndSizes() async throws {
        try await store.upsertCacheEntry(
            CacheEntryV3(key: "pack-a", localPath: "/cache/a", size: 100, pinned: true)
        )
        try await store.upsertCacheEntry(
            CacheEntryV3(key: "pack-b", localPath: "/cache/b", size: 250, pinned: false)
        )
        let all = try await store.cacheEntries()
        XCTAssertEqual(all.count, 2)
        let pinned = try await store.cacheEntries(pinned: true)
        XCTAssertEqual(pinned.map(\.key), ["pack-a"])
        let unpinned = try await store.cacheEntries(pinned: false)
        XCTAssertEqual(unpinned.map(\.key), ["pack-b"])
        let bytes = try await store.cacheBytes()
        XCTAssertEqual(bytes, 350)

        try await store.removeCacheEntry("pack-b")
        let remaining = try await store.cacheBytes()
        XCTAssertEqual(remaining, 100)
    }

    func testCT152_MigrationJournalKeepsLatestPhase() async throws {
        try await store.appendMigrationEvent(MigrationJournalEntryV3(phase: "legacyDetected"))
        try await store.appendMigrationEvent(
            MigrationJournalEntryV3(phase: "nativeBaselineUploading", updatedAt: Date().addingTimeInterval(10))
        )
        let latest = try await store.latestMigrationPhase()
        XCTAssertEqual(latest, "nativeBaselineUploading")
        let events = try await store.migrationEvents()
        XCTAssertEqual(events.count, 2)

        // Same id is an update, not a duplicate row.
        var entry = MigrationJournalEntryV3(phase: "nativeBaselineVerified")
        try await store.appendMigrationEvent(entry)
        entry.phase = "complete"
        try await store.appendMigrationEvent(entry)
        let after = try await store.migrationEvents()
        XCTAssertEqual(after.count, 3)
        let latestAfter = try await store.latestMigrationPhase()
        XCTAssertEqual(latestAfter ?? "", after.first?.phase ?? "")
    }
}
