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
    private(set) var packs: [String: Data] = [:]
    /// objectID → (packID, offset, length) for objects stored inside packs, so a
    /// read through either API behaves like one logical object store.
    private(set) var packedLocations: [String: (packID: String, offset: Int, length: Int)] = [:]
    private(set) var readPackCount = 0
    private(set) var readObjectCount = 0
    /// Optional corruption hook: objectID → replacement payload.
    var corruptObjects: [String: Data] = [:]

    func hasObject(_ objectID: String) async throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return objects[objectID] != nil || packedLocations[objectID] != nil
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
        if let data = objects[objectID] { return data }
        if let location = packedLocations[objectID],
           let pack = packs[location.packID] {
            return pack.subdata(in: location.offset..<(location.offset + location.length))
        }
        throw Failure.objectMissing(objectID)
    }

    @discardableResult
    func putNode(_ node: DirectoryNode) async throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if nodes[node.nodeID] != nil { return false }
        nodes[node.nodeID] = node
        return true
    }

    @discardableResult
    func putPack(_ payload: Data, packID: String) async throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if packs[packID] != nil { return false }
        packs[packID] = payload
        if let entries = try? ObjectPackReader().entries(in: payload) {
            for entry in entries {
                packedLocations[entry.objectID] = (packID, entry.offset, entry.length)
            }
        }
        return true
    }

    func hasPack(_ packID: String) async throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return packs[packID] != nil
    }

    func readPack(_ packID: String) async throws -> Data {
        lock.lock(); defer { lock.unlock() }
        readPackCount += 1
        guard let data = packs[packID] else { throw Failure.objectMissing(packID) }
        return data
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

    /// Corrupts the stored bytes behind an object, whether it is standalone or
    /// inside a pack. Used by restore tests to prove AEAD/hash failures abort.
    func corruptObject(_ objectID: String) {
        lock.lock(); defer { lock.unlock() }
        if objects[objectID] != nil {
            corruptObjects[objectID] = Data("garbage".utf8)
            return
        }
        guard let location = packedLocations[objectID],
              var pack = packs[location.packID],
              location.length > 0 else { return }
        let target = pack.startIndex + location.offset + location.length / 2
        pack[target] ^= 0xFF
        packs[location.packID] = pack
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

    func knownChunks(_ objectIDs: [String]) async throws -> [String: ChunkRecordV3] {
        lock.lock(); defer { lock.unlock() }
        var result: [String: ChunkRecordV3] = [:]
        for id in objectIDs {
            if let record = chunks[id] { result[id] = record }
        }
        return result
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

    func pendingUploads(state: UploadTaskState?, limit: Int) async throws -> [PendingUploadV3] {
        lock.lock(); defer { lock.unlock() }
        return Array(
            uploads
                .filter { state == nil || $0.state == state }
                .sorted { $0.createdAt < $1.createdAt }
                .prefix(limit)
        )
    }

    func updateUploadState(_ taskID: String, state: UploadTaskState, bumpRetry: Bool) async throws {
        lock.lock(); defer { lock.unlock() }
        guard let index = uploads.firstIndex(where: { $0.taskID == taskID }) else { return }
        uploads[index].state = state
        if bumpRetry { uploads[index].retryCount += 1 }
    }

    func pendingUploadBytes() async throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return uploads.reduce(0) { $0 + $1.fileSize }
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
