import XCTest
import Foundation
@testable import BackupEngine
@testable import CloudMirrorStore
@testable import SharedModels

/// CT-156: bounded cache and iCloud local-copy eviction. Both are places where a
/// "space saving" shortcut would destroy data, so the tests pin the refusals:
/// pinned entries are not evicted, nothing outside the cache root is deleted, and
/// nothing that is not confirmed uploaded is evicted.
final class SpaceManagementTests: XCTestCase {
    private var work: URL!
    private var cacheRoot: URL!
    private var spool: URL!
    private var index: InMemoryIndex!

    override func setUpWithError() throws {
        try super.setUpWithError()
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("space-\(UUID().uuidString)", isDirectory: true)
        cacheRoot = work.appendingPathComponent("cache", isDirectory: true)
        spool = work.appendingPathComponent("spool/pending", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        index = InMemoryIndex()
    }

    override func tearDownWithError() throws {
        if let work { try? FileManager.default.removeItem(at: work) }
        try super.tearDownWithError()
    }

    private func cache(budget: CacheBudget) -> DiskChunkCache {
        DiskChunkCache(root: cacheRoot, index: index, budget: budget)
    }

    func testCT156_CacheStoresReadsAndEvictsLRUWithinBudget() async throws {
        let cache = self.cache(budget: CacheBudget(bytes: 1_000))
        try await cache.storeChunk(objectID: "aaaa-1", data: Data(repeating: 1, count: 400))
        try await cache.storeChunk(objectID: "bbbb-2", data: Data(repeating: 2, count: 400))
        try await cache.storeChunk(objectID: "cccc-3", data: Data(repeating: 3, count: 400))

        let total = try await cache.totalBytes()
        XCTAssertEqual(total, 1_200)

        let report = try await cache.enforceBudget()
        XCTAssertFalse(report.evictedKeys.isEmpty, "超预算必须驱逐")
        let after = try await cache.totalBytes()
        XCTAssertLessThanOrEqual(after, 1_000)
        // The oldest entry goes first.
        XCTAssertEqual(report.evictedKeys.first, "aaaa-1")
        let gone = try await cache.cachedChunk(objectID: "aaaa-1")
        XCTAssertNil(gone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent("aa/aaaa-1").path))
    }

    func testCT156_PinnedEntriesSurviveBudgetPressure() async throws {
        let cache = self.cache(budget: CacheBudget(bytes: 1))
        try await cache.storeChunk(objectID: "pinned-object", data: Data(repeating: 9, count: 500))
        try await cache.pin("pinned-object")
        try await cache.storeChunk(objectID: "loose-object", data: Data(repeating: 8, count: 500))

        let report = try await cache.enforceBudget()
        XCTAssertEqual(report.retainedPinned, 1)
        XCTAssertEqual(report.evictedKeys, ["loose-object"], "只应驱逐未固定的条目")
        let pinned = try await cache.cachedChunk(objectID: "pinned-object")
        XCTAssertNotNil(pinned)
        XCTAssertNotNil(report.skippedReason, "未达到预算时必须说明原因，而不是假装成功")
    }

    func testCT156_CacheNeverTouchesFilesOutsideItsRoot() async throws {
        let spoolFile = spool.appendingPathComponent("only-copy.enc")
        let payload = Data("un-uploaded-data".utf8)
        try payload.write(to: spoolFile)

        // A malicious/stale index row pointing into the spool must be refused.
        try await index.upsertCacheEntry(
            CacheEntryV3(key: "evil", localPath: spoolFile.path, size: 15, pinned: false)
        )
        let cache = self.cache(budget: CacheBudget(bytes: 0))
        let report = try await cache.enforceBudget()

        XCTAssertFalse(report.evictedKeys.contains("evil"), "缓存不得删除 spool 中的唯一副本")
        XCTAssertNotNil(report.skippedReason)
        XCTAssertEqual(try Data(contentsOf: spoolFile), payload)
    }

    func testCT156_MissingFileIsForgottenNotReportedAsCached() async throws {
        let cache = self.cache(budget: .balanced)
        try await cache.storeChunk(objectID: "vanishing", data: Data("x".utf8))
        try FileManager.default.removeItem(at: cacheRoot.appendingPathComponent("va/vanishing"))
        let data = try await cache.cachedChunk(objectID: "vanishing")
        XCTAssertNil(data)
        let entry = try await index.cacheEntry("vanishing")
        XCTAssertNil(entry, "文件消失后索引必须清理，不能继续声称已缓存")
    }

    // MARK: - Eviction

    final class FakeProbe: UbiquitousItemProbing, @unchecked Sendable {
        var ubiquitous: Set<String> = []
        var uploaded: Set<String> = []
        var evicted: [String] = []
        var failing: Set<String> = []

        func isUbiquitous(_ url: URL) async -> Bool { ubiquitous.contains(url.path) }

        func isUploaded(_ url: URL) async -> Bool { uploaded.contains(url.path) }

        func evict(_ url: URL) async throws {
            if failing.contains(url.path) { throw NSError(domain: "probe", code: 1) }
            evicted.append(url.path)
        }
    }

    func testCT156_EvictionRequiresConfirmedUpload() async throws {
        let probe = FakeProbe()
        let uploaded = cacheRoot.appendingPathComponent("uploaded.bin")
        let pending = cacheRoot.appendingPathComponent("pending.bin")
        let localOnly = cacheRoot.appendingPathComponent("local.bin")
        for url in [uploaded, pending, localOnly] {
            try Data("x".utf8).write(to: url)
        }
        probe.ubiquitous = [uploaded.path, pending.path]
        probe.uploaded = [uploaded.path]   // pending is still uploading

        let manager = ICloudEvictionManager(probe: probe)
        let outcome = await manager.evictLocalCopies(of: [uploaded, pending, localOnly])

        XCTAssertEqual(outcome.evicted, 1)
        XCTAssertEqual(probe.evicted, [uploaded.path])
        XCTAssertEqual(Set(outcome.skippedNotUploaded.map(\.path)), [pending.path, localOnly.path])
        XCTAssertFalse(outcome.isComplete, "有跳过项时不得声称全部释放")
    }

    func testCT156_EvictionFailureIsReportedNotSwallowed() async throws {
        let probe = FakeProbe()
        let first = cacheRoot.appendingPathComponent("a.bin")
        let second = cacheRoot.appendingPathComponent("b.bin")
        probe.ubiquitous = [first.path, second.path]
        probe.uploaded = [first.path, second.path]
        probe.failing = [second.path]

        let manager = ICloudEvictionManager(probe: probe)
        let outcome = await manager.evictLocalCopies(of: [first, second])

        XCTAssertEqual(outcome.evicted, 1)
        XCTAssertEqual(outcome.failed.map(\.path), [second.path])
        XCTAssertFalse(outcome.isComplete)
    }
}
