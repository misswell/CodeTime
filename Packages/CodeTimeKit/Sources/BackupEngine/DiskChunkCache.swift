import Foundation
import SharedModels

public struct CacheBudget: Sendable, Equatable {
    public var bytes: Int64
    public init(bytes: Int64) { self.bytes = bytes }

    /// §13.2 presets.
    public static let minimal = CacheBudget(bytes: 128 * 1024 * 1024)
    public static let balanced = CacheBudget(bytes: 256 * 1024 * 1024)
    public static let fastRestore = CacheBudget(bytes: 512 * 1024 * 1024)
}

public struct EvictionReport: Sendable, Equatable {
    public var evictedKeys: [String]
    public var freedBytes: Int64
    public var retainedPinned: Int
    public var skippedReason: String?

    public init(
        evictedKeys: [String] = [],
        freedBytes: Int64 = 0,
        retainedPinned: Int = 0,
        skippedReason: String? = nil
    ) {
        self.evictedKeys = evictedKeys
        self.freedBytes = freedBytes
        self.retainedPinned = retainedPinned
        self.skippedReason = skippedReason
    }
}

public enum ChunkCacheError: Error, Sendable, Equatable {
    case writeFailed(String)
    case outsideCacheRoot(String)
}

/// Bounded on-disk cache for decrypted chunks.
///
/// Two rules matter more than the LRU policy:
/// 1. The cache only ever deletes files inside its own root — the spool (data that
///    has not been uploaded) is a different directory and is never touched here.
/// 2. Pinned entries (an active restore, an upload in flight) are never evicted,
///    so the budget can be exceeded rather than destroying something in use. The
///    report says so instead of pretending the limit was met.
public actor DiskChunkCache: RestoreObjectCache {
    public let root: URL
    private let index: ChunkCacheIndex
    private var budgetBytes: Int64

    public init(root: URL, index: ChunkCacheIndex, budget: CacheBudget = .balanced) {
        self.root = root
        self.index = index
        self.budgetBytes = budget.bytes
    }

    public func setBudget(_ budget: CacheBudget) async {
        budgetBytes = budget.bytes
    }

    public func currentBudget() -> Int64 { budgetBytes }

    // MARK: - RestoreObjectCache

    public func cachedChunk(objectID: String) async throws -> Data? {
        guard let entry = try await index.cacheEntry(objectID) else { return nil }
        let url = URL(fileURLWithPath: entry.localPath)
        guard let data = try? Data(contentsOf: url) else {
            try? await index.removeCacheEntry(objectID)
            return nil
        }
        var touched = entry
        touched.lastAccessedAt = Date()
        try? await index.upsertCacheEntry(touched)
        return data
    }

    public func storeChunk(objectID: String, data: Data) async throws {
        let url = url(for: objectID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ChunkCacheError.writeFailed(error.localizedDescription)
        }
        try await index.upsertCacheEntry(
            CacheEntryV3(
                key: objectID,
                localPath: url.path,
                size: Int64(data.count),
                lastAccessedAt: Date(),
                pinned: false
            )
        )
    }

    // MARK: - Pinning

    public func pin(_ objectID: String) async throws {
        guard var entry = try await index.cacheEntry(objectID) else { return }
        entry.pinned = true
        try await index.upsertCacheEntry(entry)
    }

    public func unpin(_ objectID: String) async throws {
        guard var entry = try await index.cacheEntry(objectID) else { return }
        entry.pinned = false
        try await index.upsertCacheEntry(entry)
    }

    // MARK: - Budget

    /// Evicts least-recently-used unpinned entries until the cache fits the
    /// budget. Returns what happened, including when it could not get under the
    /// budget because too much is pinned.
    @discardableResult
    public func enforceBudget() async throws -> EvictionReport {
        var report = EvictionReport()
        var total = try await index.cacheBytes()
        if total <= budgetBytes { return report }

        let candidates = try await index.cacheEntries(pinned: false, limit: 10_000)
        let pinned = try await index.cacheEntries(pinned: true, limit: 10_000)
        report.retainedPinned = pinned.count

        for entry in candidates.sorted(by: { $0.lastAccessedAt < $1.lastAccessedAt }) {
            if total <= budgetBytes { break }
            let url = URL(fileURLWithPath: entry.localPath)
            guard isInsideRoot(url) else {
                report.skippedReason = "拒绝删除缓存目录之外的文件：\(entry.localPath)"
                continue
            }
            try? FileManager.default.removeItem(at: url)
            try await index.removeCacheEntry(entry.key)
            total -= entry.size
            report.evictedKeys.append(entry.key)
            report.freedBytes += entry.size
        }
        if total > budgetBytes {
            report.skippedReason = "固定条目占用 \(total - budgetBytes) 字节，未强制驱逐"
        }
        return report
    }

    public func totalBytes() async throws -> Int64 {
        try await index.cacheBytes()
    }

    public func removeAllUnpinned() async throws -> EvictionReport {
        var report = EvictionReport()
        let candidates = try await index.cacheEntries(pinned: false, limit: 10_000)
        let pinned = try await index.cacheEntries(pinned: true, limit: 10_000)
        report.retainedPinned = pinned.count
        for entry in candidates {
            let url = URL(fileURLWithPath: entry.localPath)
            guard isInsideRoot(url) else { continue }
            try? FileManager.default.removeItem(at: url)
            try await index.removeCacheEntry(entry.key)
            report.evictedKeys.append(entry.key)
            report.freedBytes += entry.size
        }
        return report
    }

    // MARK: - Paths

    public nonisolated func url(for objectID: String) -> URL {
        let prefix = String(objectID.prefix(2))
        return root.appendingPathComponent(prefix, isDirectory: true)
            .appendingPathComponent(objectID)
    }

    /// The cache must never delete outside its own root (in particular never in
    /// the spool, which holds the only copy of un-uploaded data).
    nonisolated func isInsideRoot(_ url: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        return candidate.hasPrefix(rootPath + "/")
    }
}
