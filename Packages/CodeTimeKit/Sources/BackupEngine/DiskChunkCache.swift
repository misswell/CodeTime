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
    public var failedKeys: [String]
    public var skippedReason: String?

    public init(
        evictedKeys: [String] = [],
        freedBytes: Int64 = 0,
        retainedPinned: Int = 0,
        failedKeys: [String] = [],
        skippedReason: String? = nil
    ) {
        self.evictedKeys = evictedKeys
        self.freedBytes = freedBytes
        self.retainedPinned = retainedPinned
        self.failedKeys = failedKeys
        self.skippedReason = skippedReason
    }
}

public enum ChunkCacheError: Error, Sendable, Equatable {
    case writeFailed(String)
    case readFailed(String)
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
/// Deliverable name for the bounded download-cache manager.
public typealias CacheManager = DiskChunkCache

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
        guard isInsideRoot(url) else {
            throw ChunkCacheError.outsideCacheRoot(entry.localPath)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError {
            if Self.isFileMissing(error) {
                // The index outlived the file. Removing a stale row is safe; a
                // failed read must not be remembered as "not cached" silently.
                try? await index.removeCacheEntry(objectID)
                return nil
            }
            throw ChunkCacheError.readFailed(error.localizedDescription)
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
                report.failedKeys.append(entry.key)
                continue
            }
            do {
                // Delete the file first; only then update the index. If the file
                // cannot be removed, its row must stay so a later pass retries.
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try await index.removeCacheEntry(entry.key)
                total -= entry.size
                report.evictedKeys.append(entry.key)
                report.freedBytes += entry.size
            } catch {
                report.failedKeys.append(entry.key)
                report.skippedReason = "缓存文件删除失败：\(entry.localPath)"
            }
        }
        if total > budgetBytes, report.skippedReason == nil {
            report.skippedReason = "固定条目占用 \(total - budgetBytes) 字节，未强制驱逐"
        }
        return report
    }

    /// Reconciles the index with the directory after a crash. Index rows whose
    /// file is gone are dropped; files with no row are orphans and are removed
    /// (this is the cache root only — never the spool).
    @discardableResult
    public func reconcile() async throws -> EvictionReport {
        var report = EvictionReport()
        let all = try await index.cacheEntries(pinned: nil, limit: 100_000)
        var known = Set<String>()
        for entry in all {
            let url = URL(fileURLWithPath: entry.localPath)
            guard isInsideRoot(url) else {
                report.skippedReason = "缓存索引指向目录之外：\(entry.localPath)"
                report.failedKeys.append(entry.key)
                continue
            }
            if FileManager.default.fileExists(atPath: url.path) {
                known.insert(url.standardizedFileURL.path)
            } else {
                try? await index.removeCacheEntry(entry.key)
                report.evictedKeys.append(entry.key)
            }
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return report }
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                continue
            }
            let path = url.standardizedFileURL.path
            guard !known.contains(path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                report.evictedKeys.append(url.lastPathComponent)
            } catch {
                report.failedKeys.append(url.lastPathComponent)
                report.skippedReason = "缓存孤儿文件删除失败：\(path)"
            }
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
            guard isInsideRoot(url) else {
                report.failedKeys.append(entry.key)
                continue
            }
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try await index.removeCacheEntry(entry.key)
                report.evictedKeys.append(entry.key)
                report.freedBytes += entry.size
            } catch {
                report.failedKeys.append(entry.key)
                report.skippedReason = "缓存文件删除失败：\(entry.localPath)"
            }
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

    private static func isFileMissing(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain,
           error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError {
            return true
        }
        return error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
    }
}
