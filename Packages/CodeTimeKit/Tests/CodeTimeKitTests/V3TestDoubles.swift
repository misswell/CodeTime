import Foundation
import SharedModels
@testable import BackupEngine

/// In-memory cloud used by the v3 restore tests. Implements both sides of the
/// seam so a backup can be produced and then restored without any filesystem
/// pretending to be iCloud.
final class InMemoryCloud: CloudObjectSink, CloudObjectSource, @unchecked Sendable {
    enum Failure: Error { case manifestHashMismatch, objectMissing(String), nodeMissing(String), commitMissing(String) }

    private let lock = NSLock()
    private(set) var objects: [String: Data] = [:]
    private(set) var nodes: [String: DirectoryNode] = [:]
    private(set) var manifests: [String: Data] = [:]
    private(set) var commits: [String: SnapshotCommit] = [:]
    private(set) var readObjectCount = 0
    /// Optional corruption hook: objectID → replacement payload.
    var corruptObjects: [String: Data] = [:]

    func hasObject(_ objectID: String) async throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return objects[objectID] != nil
    }

    @discardableResult
    func putObject(_ payload: Data, objectID: String) async throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if objects[objectID] != nil { return false }
        objects[objectID] = payload
        return true
    }

    func readObject(_ objectID: String) async throws -> Data {
        lock.lock(); defer { lock.unlock() }
        readObjectCount += 1
        if let corrupt = corruptObjects[objectID] { return corrupt }
        guard let data = objects[objectID] else { throw Failure.objectMissing(objectID) }
        return data
    }

    @discardableResult
    func putNode(_ node: DirectoryNode) async throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if nodes[node.nodeID] != nil { return false }
        nodes[node.nodeID] = node
        return true
    }

    func readNode(_ nodeID: String) async throws -> DirectoryNode {
        lock.lock(); defer { lock.unlock() }
        guard let node = nodes[nodeID] else { throw Failure.nodeMissing(nodeID) }
        return node
    }

    func putManifest(_ payload: Data, projectID: UUID, snapshotID: String) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        manifests[snapshotID] = payload
        return CanonicalHashing.sha256Hex(payload)
    }

    func readManifestPayload(projectID: UUID, snapshotID: String) async throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let payload = manifests[snapshotID] else { throw Failure.commitMissing(snapshotID) }
        return payload
    }

    func putCommit(_ commit: SnapshotCommit) async throws {
        lock.lock(); defer { lock.unlock() }
        guard let payload = manifests[commit.snapshotID],
              CanonicalHashing.sha256Hex(payload) == commit.manifestPayloadHash else {
            throw Failure.manifestHashMismatch
        }
        commits[commit.snapshotID] = commit
    }

    func readCommit(projectID: UUID, snapshotID: String) async throws -> SnapshotCommit? {
        lock.lock(); defer { lock.unlock() }
        return commits[snapshotID]
    }

    func commits(projectID: UUID) async throws -> [SnapshotCommit] {
        lock.lock(); defer { lock.unlock() }
        return commits.values.filter { $0.projectID == projectID }.sorted { $0.committedAt < $1.committedAt }
    }

    func tamperManifest(snapshotID: String, mutate: (inout Data) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard var payload = manifests[snapshotID] else { return }
        mutate(&payload)
        manifests[snapshotID] = payload
    }

    func totalObjectCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return objects.count
    }
}

/// In-memory index with the same semantics as the SQLite one for the fields the
/// engine reads.
final class InMemoryIndex: CloudSnapshotIndex, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [UUID: [FileNode]] = [:]
    private(set) var chunks: [String: ChunkRecordV3] = [:]
    private(set) var snapshots: [SnapshotRecordV3] = []
    private(set) var uploads: [PendingUploadV3] = []
    private(set) var cache: [String: CacheEntryV3] = [:]

    func fileNodes(projectID: UUID) async throws -> [FileNode] {
        lock.lock(); defer { lock.unlock() }
        return files[projectID] ?? []
    }

    func replaceFileIndex(projectID: UUID, files: [FileNode], snapshotID: String) async throws {
        lock.lock(); defer { lock.unlock() }
        self.files[projectID] = files
    }

    func knownObjectIDs(_ objectIDs: [String]) async throws -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(objectIDs.filter { chunks[$0] != nil })
    }

    func upsertChunks(_ newChunks: [ChunkRecordV3]) async throws {
        lock.lock(); defer { lock.unlock() }
        for chunk in newChunks { chunks[chunk.objectID] = chunk }
    }

    func upsertSnapshot(_ record: SnapshotRecordV3) async throws {
        lock.lock(); defer { lock.unlock() }
        if let index = snapshots.firstIndex(where: { $0.snapshotID == record.snapshotID }) {
            snapshots[index] = record
        } else {
            snapshots.append(record)
        }
    }

    func updateSnapshot(
        _ snapshotID: String,
        uploadState: SnapshotUploadState?,
        commitState: SnapshotCommitState?,
        manifestPayloadHash: String?
    ) async throws {
        lock.lock(); defer { lock.unlock() }
        guard let index = snapshots.firstIndex(where: { $0.snapshotID == snapshotID }) else { return }
        if let uploadState { snapshots[index].uploadState = uploadState }
        if let commitState { snapshots[index].commitState = commitState }
        if let manifestPayloadHash { snapshots[index].manifestPayloadHash = manifestPayloadHash }
    }

    func snapshotRecords(projectID: UUID, limit: Int) async throws -> [SnapshotRecordV3] {
        lock.lock(); defer { lock.unlock() }
        return Array(
            snapshots.filter { $0.projectID == projectID }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(limit)
        )
    }

    func enqueueUploads(_ uploads: [PendingUploadV3]) async throws {
        lock.lock(); defer { lock.unlock() }
        self.uploads.append(contentsOf: uploads)
    }

    func removeUpload(_ taskID: String) async throws {
        lock.lock(); defer { lock.unlock() }
        uploads.removeAll { $0.taskID == taskID }
    }
}

extension InMemoryIndex: ChunkCacheIndex {
    func cacheEntry(_ key: String) async throws -> CacheEntryV3? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    func upsertCacheEntry(_ entry: CacheEntryV3) async throws {
        lock.lock(); defer { lock.unlock() }
        cache[entry.key] = entry
    }

    func cacheEntries(pinned: Bool?, limit: Int) async throws -> [CacheEntryV3] {
        lock.lock(); defer { lock.unlock() }
        let values = cache.values.filter { pinned == nil || $0.pinned == pinned }
        return Array(values.sorted { $0.lastAccessedAt < $1.lastAccessedAt }.prefix(limit))
    }

    func removeCacheEntry(_ key: String) async throws {
        lock.lock(); defer { lock.unlock() }
        cache.removeValue(forKey: key)
    }

    func cacheBytes() async throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return cache.values.reduce(0) { $0 + $1.size }
    }
}
