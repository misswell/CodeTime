import Foundation
import CryptoKit

/// Cloud Format v3 — immutable snapshot model.
///
/// Everything here is content addressed: a node's identity is the SHA-256 of its
/// own canonical JSON, so an unchanged directory keeps its node ID across
/// snapshots and never needs re-uploading. A changed file changes exactly the
/// file node, its directory node(s) and the manifest/commit — nothing else.
///
/// These structures are always encrypted before they reach iCloud; the plaintext
/// form exists only in memory and in the local index.
public enum CloudFormatV3 {
    public static let version = 3
    /// Directory under `iCloud Drive/CodeTime/` that holds v3 data.
    public static let folderName = "v3"
    public static let formatFile = "format.json"
}

/// Stable file identity as reported by `lstat`. ctime is included because a
/// preserved mtime (or an atomic replacement) must still be detected; size+mtime
/// alone is never sufficient to declare a file unchanged.
public struct FileIdentity: Codable, Hashable, Sendable {
    public var device: UInt64
    public var inode: UInt64
    public var size: Int64
    /// Nanoseconds since 1970. Kept alongside `modified` for old call sites.
    public var modifiedNanos: Int64
    public var changedNanos: Int64
    public var modified: Double
    public var resourceIdentifier: String?

    public init(
        device: UInt64,
        inode: UInt64,
        size: Int64,
        modified: Double,
        changed: Double = 0,
        resourceIdentifier: String? = nil
    ) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modified = modified
        self.modifiedNanos = Int64(modified * 1_000_000_000)
        self.changedNanos = Int64(changed * 1_000_000_000)
        self.resourceIdentifier = resourceIdentifier
    }

    public init(
        device: UInt64,
        inode: UInt64,
        size: Int64,
        modifiedNanos: Int64,
        changedNanos: Int64,
        resourceIdentifier: String?
    ) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modifiedNanos = modifiedNanos
        self.changedNanos = changedNanos
        self.modified = Double(modifiedNanos) / 1_000_000_000
        self.resourceIdentifier = resourceIdentifier
    }

    /// Whether two observations describe the same unchanged file.
    ///
    /// `resourceIdentifier` is only available from URL resource values; an
    /// identity taken from an open descriptor or another API may legitimately
    /// omit it. Compare it only when both sides provide one — inode, ctime, size
    /// and mtime are the authoritative fields.
    public func matches(
        _ other: FileIdentity,
        modifiedToleranceNanos: Int64 = 1_000_000_000
    ) -> Bool {
        guard device == other.device,
              inode == other.inode,
              size == other.size,
              changedNanos == other.changedNanos,
              abs(modifiedNanos - other.modifiedNanos) <= modifiedToleranceNanos else {
            return false
        }
        if let mine = resourceIdentifier, let theirs = other.resourceIdentifier,
           mine != theirs {
            return false
        }
        return true
    }

    public var isZero: Bool { device == 0 && inode == 0 && size == 0 && modifiedNanos == 0 }
}

public enum NodeKind: String, Codable, Sendable, Hashable {
    case file
    case directory
    case symlink
}

/// A reference to one data block. `packID` is nil for a standalone object.
public struct ChunkRef: Codable, Hashable, Sendable {
    public var objectID: String
    public var plaintextSize: Int32
    public var storedSize: Int32
    public var compression: UInt8
    public var packID: String?
    public var packOffset: Int64?

    public init(
        objectID: String,
        plaintextSize: Int,
        storedSize: Int,
        compression: UInt8,
        packID: String? = nil,
        packOffset: Int64? = nil
    ) {
        self.objectID = objectID
        self.plaintextSize = Int32(clamping: plaintextSize)
        self.storedSize = Int32(clamping: storedSize)
        self.compression = compression
        self.packID = packID
        self.packOffset = packOffset
    }
}

public struct FileNode: Codable, Hashable, Sendable {
    public var path: String
    public var kind: NodeKind
    public var size: Int64
    public var modifiedAt: Date?
    /// POSIX permission bits (0o755 etc.), restored bit-for-bit.
    public var mode: UInt16?
    /// Only for `.symlink`.
    public var linkTarget: String?
    /// SHA-256 of the whole file (plaintext), for end-to-end verification.
    public var contentHash: String?
    public var chunks: [ChunkRef]
    /// Stable identity (dev/inode/size/mtime/ctime) used for incremental reuse.
    public var identity: FileIdentity?
    public var nodeID: String

    public init(
        path: String,
        kind: NodeKind,
        size: Int64,
        modifiedAt: Date? = nil,
        mode: UInt16? = nil,
        linkTarget: String? = nil,
        contentHash: String? = nil,
        chunks: [ChunkRef] = [],
        identity: FileIdentity? = nil,
        nodeID: String = ""
    ) {
        self.path = path
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.mode = mode
        self.linkTarget = linkTarget
        self.contentHash = contentHash
        self.chunks = chunks
        self.identity = identity
        self.nodeID = nodeID
    }

    /// Deterministic identity: the payload WITHOUT `nodeID`, canonical JSON.
    public var computedNodeID: String {
        var copy = self
        copy.nodeID = ""
        return CanonicalHashing.hex(of: copy)
    }

    public func withComputedID() -> FileNode {
        var copy = self
        copy.nodeID = computedNodeID
        return copy
    }
}

/// Pointer from a directory to one of its subdirectories.
public struct DirectoryEntry: Codable, Hashable, Sendable {
    public var name: String
    public var nodeID: String
    public var fileCount: Int
    public var totalBytes: Int64

    public init(name: String, nodeID: String, fileCount: Int, totalBytes: Int64) {
        self.name = name
        self.nodeID = nodeID
        self.fileCount = fileCount
        self.totalBytes = totalBytes
    }
}

public struct DirectoryNode: Codable, Hashable, Sendable {
    /// "" is the project root.
    public var path: String
    public var files: [FileNode]
    public var directories: [DirectoryEntry]
    /// POSIX permission bits. Optional so existing nodes remain decodable.
    public var mode: UInt16?
    public var modifiedAt: Date?
    public var nodeID: String

    public init(
        path: String,
        files: [FileNode],
        directories: [DirectoryEntry],
        mode: UInt16? = nil,
        modifiedAt: Date? = nil,
        nodeID: String = ""
    ) {
        self.path = path
        self.files = files
        self.directories = directories
        self.mode = mode
        self.modifiedAt = modifiedAt
        self.nodeID = nodeID
    }

    public var fileCount: Int {
        files.count + directories.reduce(0) { $0 + $1.fileCount }
    }

    public var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.size } + directories.reduce(0) { $0 + $1.totalBytes }
    }

    public var computedNodeID: String {
        var copy = self
        copy.nodeID = ""
        return CanonicalHashing.hex(of: copy)
    }

    public func withComputedID() -> DirectoryNode {
        var copy = self
        copy.nodeID = computedNodeID
        return copy
    }
}

/// Encrypted, uploaded as an object; referenced by its commit marker.
/// Directory permissions/timestamps captured by the scanner and carried by the
/// Merkle node so restore can reproduce Xcode-required modes.
public struct DirectoryMetadata: Codable, Hashable, Sendable {
    public var path: String
    public var mode: UInt16?
    public var modifiedAt: Date?

    public init(path: String, mode: UInt16? = nil, modifiedAt: Date? = nil) {
        self.path = path
        self.mode = mode
        self.modifiedAt = modifiedAt
    }
}

public struct SnapshotManifest: Codable, Hashable, Sendable {
    public var snapshotID: String
    public var projectID: UUID
    public var deviceID: String
    public var createdAt: Date
    public var parentSnapshotID: String?
    public var rootNodeID: String
    public var fileCount: Int
    public var totalBytes: Int64
    /// Number of distinct chunks referenced (post-dedup) — informational.
    public var chunkCount: Int
    public var formatVersion: Int
    public var keyVersion: UInt16
    /// Hash over (rootNodeID, fileCount, totalBytes, chunkCount) so a manifest
    /// cannot be edited to describe a different tree.
    public var integrityDigest: String

    public init(
        snapshotID: String,
        projectID: UUID,
        deviceID: String,
        createdAt: Date,
        parentSnapshotID: String?,
        rootNodeID: String,
        fileCount: Int,
        totalBytes: Int64,
        chunkCount: Int,
        formatVersion: Int = CloudFormatV3.version,
        keyVersion: UInt16 = 1
    ) {
        self.snapshotID = snapshotID
        self.projectID = projectID
        self.deviceID = deviceID
        self.createdAt = createdAt
        self.parentSnapshotID = parentSnapshotID
        self.rootNodeID = rootNodeID
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.chunkCount = chunkCount
        self.formatVersion = formatVersion
        self.keyVersion = keyVersion
        self.integrityDigest = Self.digest(
            rootNodeID: rootNodeID,
            fileCount: fileCount,
            totalBytes: totalBytes,
            chunkCount: chunkCount
        )
    }

    public static func digest(
        rootNodeID: String,
        fileCount: Int,
        totalBytes: Int64,
        chunkCount: Int
    ) -> String {
        CanonicalHashing.sha256Hex(
            Data("\(rootNodeID)|\(fileCount)|\(totalBytes)|\(chunkCount)".utf8)
        )
    }

    public var digestMatches: Bool {
        integrityDigest == Self.digest(
            rootNodeID: rootNodeID,
            fileCount: fileCount,
            totalBytes: totalBytes,
            chunkCount: chunkCount
        )
    }
}

/// The last thing published for a snapshot. Until this marker is confirmed
/// uploaded the version MUST NOT be shown as complete — that is what makes a
/// half-published snapshot impossible to mistake for a good one.
public struct SnapshotCommit: Codable, Hashable, Sendable {
    public var snapshotID: String
    public var projectID: UUID
    public var deviceID: String
    public var parentSnapshotID: String?
    public var committedAt: Date
    /// SHA-256 of the encrypted manifest payload as stored in iCloud.
    public var manifestPayloadHash: String
    /// Number of node objects the manifest depends on (root + descendants).
    public var nodeCount: Int
    public var fileCount: Int
    public var totalBytes: Int64
    public var formatVersion: Int

    public init(
        snapshotID: String,
        projectID: UUID,
        deviceID: String,
        parentSnapshotID: String?,
        committedAt: Date,
        manifestPayloadHash: String,
        nodeCount: Int,
        fileCount: Int,
        totalBytes: Int64,
        formatVersion: Int = CloudFormatV3.version
    ) {
        self.snapshotID = snapshotID
        self.projectID = projectID
        self.deviceID = deviceID
        self.parentSnapshotID = parentSnapshotID
        self.committedAt = committedAt
        self.manifestPayloadHash = manifestPayloadHash
        self.nodeCount = nodeCount
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.formatVersion = formatVersion
    }
}

public enum CanonicalHashing {
    /// Canonical JSON → SHA-256. Sorted keys and fixed date encoding, so the same
    /// logical node always hashes to the same ID on every machine.
    public static func hex<T: Encodable>(of value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data: Data
        do {
            data = try encoder.encode(CanonicalBox(value))
        } catch {
            // Encoding a plain Codable struct cannot fail in practice; falling back
            // to a hash of the type name keeps the failure visible but safe.
            return sha256Hex(Data("unencodable:\(T.self)".utf8))
        }
        return sha256Hex(data)
    }

    /// Local SHA-256 helper: SharedModels must not depend on CodeTimeSecurity.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct CanonicalBox<T: Encodable>: Encodable {
        let value: T
        init(_ value: T) { self.value = value }
        func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
    }
}

// MARK: - Local index records (Cloud Format v3)

public enum UploadTaskState: String, Codable, Sendable, Hashable {
    case pending
    case uploading
    /// Cloud confirmed the upload, but the staged file or journal row could not
    /// be removed yet. A reconciler retries; it is not reported as complete.
    case uploadedPendingCleanup
    /// Cloud confirmed and local cleanup finished; the row is normally deleted.
    case uploaded
    case completed
    case failed
}

public enum SnapshotUploadState: String, Codable, Sendable, Hashable {
    case pending
    case uploading
    case uploaded
    case failed
}

public enum SnapshotCommitState: String, Codable, Sendable, Hashable {
    /// Objects/manifest not finished; the version is not visible in the cloud.
    case pending
    /// Commit marker confirmed uploaded: the version is complete.
    case committed
    /// Publishing stopped on an error that needs user action (quota, account).
    case blocked
}

/// What the local database knows about one cloud version. Rebuildable from the
/// cloud (commits + manifest + nodes) — it is an index, never the only copy.
public struct SnapshotRecordV3: Codable, Hashable, Sendable {
    public var snapshotID: String
    public var projectID: UUID
    public var parentSnapshotID: String?
    public var createdAt: Date
    public var rootNodeID: String
    public var fileCount: Int
    public var totalBytes: Int64
    public var uploadState: SnapshotUploadState
    public var commitState: SnapshotCommitState
    public var manifestPayloadHash: String?

    public init(
        snapshotID: String,
        projectID: UUID,
        parentSnapshotID: String? = nil,
        createdAt: Date,
        rootNodeID: String,
        fileCount: Int,
        totalBytes: Int64,
        uploadState: SnapshotUploadState = .pending,
        commitState: SnapshotCommitState = .pending,
        manifestPayloadHash: String? = nil
    ) {
        self.snapshotID = snapshotID
        self.projectID = projectID
        self.parentSnapshotID = parentSnapshotID
        self.createdAt = createdAt
        self.rootNodeID = rootNodeID
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.uploadState = uploadState
        self.commitState = commitState
        self.manifestPayloadHash = manifestPayloadHash
    }

    public var isCommitted: Bool { commitState == .committed }
}

/// One remote chunk we know about. `verifiedAt` is nil until we have actually
/// downloaded and decrypted it; a local index row alone never counts as proof.
public struct ChunkRecordV3: Codable, Hashable, Sendable {
    public var objectID: String
    public var plaintextSize: Int
    public var storedSize: Int
    public var keyVersion: UInt16
    public var packID: String?
    public var packOffset: Int64?
    public var verifiedAt: Date?

    public init(
        objectID: String,
        plaintextSize: Int,
        storedSize: Int,
        keyVersion: UInt16,
        packID: String? = nil,
        packOffset: Int64? = nil,
        verifiedAt: Date? = nil
    ) {
        self.objectID = objectID
        self.plaintextSize = plaintextSize
        self.storedSize = storedSize
        self.keyVersion = keyVersion
        self.packID = packID
        self.packOffset = packOffset
        self.verifiedAt = verifiedAt
    }
}

/// A durable upload task. Lives in `spool/`: never LRU-evicted, never deleted
/// because a cache budget was reached — un-uploaded data is the only copy.
public struct PendingUploadV3: Codable, Hashable, Sendable {
    public var taskID: String
    public var objectID: String
    public var localPath: String
    public var remotePath: String
    public var fileSize: Int64
    public var state: UploadTaskState
    public var retryCount: Int
    public var createdAt: Date
    /// Earliest time a failed task may be retried. Persisted in the journal so a
    /// relaunch cannot turn exponential backoff into a tight retry loop.
    public var nextAttemptAt: Date?

    public init(
        taskID: String,
        objectID: String,
        localPath: String,
        remotePath: String,
        fileSize: Int64,
        state: UploadTaskState = .pending,
        retryCount: Int = 0,
        createdAt: Date = Date(),
        nextAttemptAt: Date? = nil
    ) {
        self.taskID = taskID
        self.objectID = objectID
        self.localPath = localPath
        self.remotePath = remotePath
        self.fileSize = fileSize
        self.state = state
        self.retryCount = retryCount
        self.createdAt = createdAt
        self.nextAttemptAt = nextAttemptAt
    }
}

public struct CacheEntryV3: Codable, Hashable, Sendable {
    public var key: String
    public var localPath: String
    public var size: Int64
    public var lastAccessedAt: Date
    /// Pinned entries (active restore, pending upload) are never evicted.
    public var pinned: Bool

    public init(key: String, localPath: String, size: Int64, lastAccessedAt: Date = Date(), pinned: Bool = false) {
        self.key = key
        self.localPath = localPath
        self.size = size
        self.lastAccessedAt = lastAccessedAt
        self.pinned = pinned
    }
}

public struct MigrationJournalEntryV3: Codable, Hashable, Sendable {
    public var id: String
    public var phase: String
    public var updatedAt: Date
    public var detail: String

    public init(id: String = UUID().uuidString, phase: String, updatedAt: Date = Date(), detail: String = "") {
        self.id = id
        self.phase = phase
        self.updatedAt = updatedAt
        self.detail = detail
    }
}
