import XCTest
import Foundation
@testable import BackupEngine
@testable import SharedModels

/// CT-175: cache deletion must confirm the file is gone before dropping its row.
final class DiskChunkCacheSafetyTests: XCTestCase {
    private var root: URL!
    private var index: InMemoryIndex!
    private var cache: DiskChunkCache!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        index = InMemoryIndex()
        cache = DiskChunkCache(
            root: root,
            index: index,
            budget: CacheBudget(bytes: 10)
        )
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: root.path
            )
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    func testCT179_FailedDeleteKeepsIndexAndReportsFailure() async throws {
        let key = String(repeating: "a", count: 64)
        try await cache.storeChunk(objectID: key, data: Data(repeating: 1, count: 20))
        let file = cache.url(for: key)
        // Removing a file needs write permission on its parent directory.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: file.deletingLastPathComponent().path
        )
        let report = try await cache.enforceBudget()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: file.deletingLastPathComponent().path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(report.failedKeys, [key])
        XCTAssertFalse(report.evictedKeys.contains(key))
        let retained = try await index.cacheEntry(key)
        XCTAssertNotNil(retained, "删除失败时索引不得提前删除")
    }

    func testCT180_ReconcileDropsMissingRowsAndRemovesOrphans() async throws {
        let staleKey = String(repeating: "b", count: 64)
        let staleURL = root.appendingPathComponent("aa").appendingPathComponent(staleKey)
        try FileManager.default.createDirectory(
            at: staleURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await index.upsertCacheEntry(CacheEntryV3(
            key: staleKey,
            localPath: staleURL.path,
            size: 10
        ))
        let orphan = root.appendingPathComponent("cc/orphan-file")
        try FileManager.default.createDirectory(
            at: orphan.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("orphan".utf8).write(to: orphan)

        let report = try await cache.reconcile()
        let stale = try await index.cacheEntry(staleKey)
        XCTAssertNil(stale)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(report.evictedKeys.contains(staleKey))
        XCTAssertTrue(report.evictedKeys.contains("orphan-file"))
    }

    func testCT181_OutsideRootEntryIsNeverDeleted() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-cache-\(UUID().uuidString).bin")
        try Data("must survive".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try await index.upsertCacheEntry(CacheEntryV3(
            key: "outside",
            localPath: outside.path,
            size: 100
        ))
        let report = try await cache.enforceBudget()
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(report.failedKeys, ["outside"])
    }

    func testCT182_InaccessibleCacheFileIsReportedNotTreatedAsMiss() async throws {
        let key = String(repeating: "c", count: 64)
        try await cache.storeChunk(objectID: key, data: Data(repeating: 7, count: 16))
        let file = cache.url(for: key)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: file.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: file.path
            )
        }
        do {
            _ = try await cache.cachedChunk(objectID: key)
            XCTFail("不可读的缓存必须报错")
        } catch let error as ChunkCacheError {
            guard case .readFailed = error else {
                return XCTFail("期望 readFailed，实际 \(error)")
            }
        }
        let inaccessible = try await index.cacheEntry(key)
        XCTAssertNotNil(inaccessible, "不可访问不等于不存在，索引必须保留")
    }
}
