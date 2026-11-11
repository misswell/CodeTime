import Foundation

/// The storage format a snapshot was written with. The format is derived from
/// the remote commit marker, never from whether a local SQLite row happens to
/// exist: a SQLite index is rebuildable cache, not the authority for what the
/// cloud contains.
public enum SnapshotFormat: String, Codable, Sendable, Hashable {
    case v3
    case v2
    case kopia
    case unknown
}

public enum RemoteSnapshotDiscoveryStatus: String, Codable, Sendable, Hashable {
    /// The commit was seen and its manifest has not been validated yet.
    case discovered
    /// The commit and manifest were read from the remote store and their hashes
    /// matched. This is a point-in-time observation, not a permanent guarantee.
    case verified
    /// The commit was found but the manifest is missing, unreadable, or does not
    /// match the commit hash.
    case corrupted
    /// The remote namespace could not be enumerated. Never treat this as absent.
    case inaccessible
}

/// A committed version as resolved from remote metadata.
public struct ResolvedSnapshot: Codable, Hashable, Sendable {
    public var snapshotID: String
    public var projectID: UUID
    public var deviceID: String
    public var formatVersion: Int
    /// `nil` when the format has no single manifest URL (for example a legacy
    /// Kopia snapshot). v3 manifests live under the device namespace.
    public var manifestLocation: URL?
    public var rootNodeID: String?
    public var createdAt: Date
    public var format: SnapshotFormat
    public var commitHash: String?
    public var manifestHash: String?
    public var discoveryStatus: RemoteSnapshotDiscoveryStatus
    public var lastVerifiedAt: Date?

    public init(
        snapshotID: String,
        projectID: UUID,
        deviceID: String,
        formatVersion: Int,
        manifestLocation: URL? = nil,
        rootNodeID: String?,
        createdAt: Date,
        format: SnapshotFormat,
        commitHash: String? = nil,
        manifestHash: String? = nil,
        discoveryStatus: RemoteSnapshotDiscoveryStatus = .discovered,
        lastVerifiedAt: Date? = nil
    ) {
        self.snapshotID = snapshotID
        self.projectID = projectID
        self.deviceID = deviceID
        self.formatVersion = formatVersion
        self.manifestLocation = manifestLocation
        self.rootNodeID = rootNodeID
        self.createdAt = createdAt
        self.format = format
        self.commitHash = commitHash
        self.manifestHash = manifestHash
        self.discoveryStatus = discoveryStatus
        self.lastVerifiedAt = lastVerifiedAt
    }
}

/// Persistent cache of remote snapshot discovery. It is deliberately separate
/// from `v3_snapshot_index` (which records this device's own publication state)
/// because another Mac's versions may never have a local publication row.
public struct RemoteSnapshotRecord: Codable, Hashable, Sendable {
    public var projectID: UUID
    public var snapshotID: String
    public var deviceID: String
    public var formatVersion: Int
    public var commitHash: String
    public var manifestHash: String
    public var rootNodeID: String
    public var createdAt: Date
    public var discoveryStatus: RemoteSnapshotDiscoveryStatus
    public var lastVerifiedAt: Date?

    public init(
        projectID: UUID,
        snapshotID: String,
        deviceID: String,
        formatVersion: Int,
        commitHash: String,
        manifestHash: String,
        rootNodeID: String,
        createdAt: Date,
        discoveryStatus: RemoteSnapshotDiscoveryStatus = .discovered,
        lastVerifiedAt: Date? = nil
    ) {
        self.projectID = projectID
        self.snapshotID = snapshotID
        self.deviceID = deviceID
        self.formatVersion = formatVersion
        self.commitHash = commitHash
        self.manifestHash = manifestHash
        self.rootNodeID = rootNodeID
        self.createdAt = createdAt
        self.discoveryStatus = discoveryStatus
        self.lastVerifiedAt = lastVerifiedAt
    }

    public var resolved: ResolvedSnapshot {
        ResolvedSnapshot(
            snapshotID: snapshotID,
            projectID: projectID,
            deviceID: deviceID,
            formatVersion: formatVersion,
            rootNodeID: rootNodeID,
            createdAt: createdAt,
            format: formatVersion == CloudFormatV3.version ? .v3 : .unknown,
            commitHash: commitHash,
            manifestHash: manifestHash,
            discoveryStatus: discoveryStatus,
            lastVerifiedAt: lastVerifiedAt
        )
    }
}

/// Stable hash of a commit marker's canonical JSON. Used to tell a re-read
/// commit apart from one that was updated (which is a protocol violation).
public enum SnapshotCommitHashing {
    public static func hash(_ commit: SnapshotCommit) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = (try? encoder.encode(commit)) ?? Data()
        return CanonicalHashing.sha256Hex(data)
    }
}

/// One project's migration from legacy Kopia/v2 history to a native v3 baseline.
/// The stable `migrationID` is derived from the legacy source and the project, so
/// a retry resumes the same record instead of creating a second baseline.
public struct MigrationRecordV3: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable, CaseIterable {
        case pending
        case baselineCreated
        case baselineVerified
        case committed
        case completed
        case blocked

        public var rank: Int {
            switch self {
            case .pending: return 0
            case .baselineCreated: return 1
            case .baselineVerified: return 2
            case .committed: return 3
            case .completed: return 4
            case .blocked: return -1
            }
        }
    }

    public var migrationID: String
    public var projectID: UUID
    public var sourceRepositoryID: String
    public var baselineSnapshotID: String?
    public var state: State
    public var startedAt: Date
    public var updatedAt: Date
    public var lastError: String?

    public init(
        migrationID: String,
        projectID: UUID,
        sourceRepositoryID: String,
        baselineSnapshotID: String? = nil,
        state: State = .pending,
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        lastError: String? = nil
    ) {
        self.migrationID = migrationID
        self.projectID = projectID
        self.sourceRepositoryID = sourceRepositoryID
        self.baselineSnapshotID = baselineSnapshotID
        self.state = state
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.lastError = lastError
    }

    /// Stable identity: one migration per (project, legacy source).
    public static func identifier(projectID: UUID, sourceRepositoryID: String) -> String {
        CanonicalHashing.sha256Hex(
            Data("v3:migration:\(projectID.uuidString):\(sourceRepositoryID)".utf8)
        )
    }
}

public enum SnapshotFormatError: Error, Sendable, Equatable {    /// A local v3 publication row exists but the cloud has no commit marker.
    /// This must never be downgraded to a legacy snapshot.
    case commitMissing(snapshotID: String)
    case unsupportedFormat(snapshotID: String, version: Int)
    case manifestInvalid(snapshotID: String, reason: String)
    case remoteNamespaceInaccessible(snapshotID: String, reason: String)
    case snapshotNotFound(snapshotID: String)

    public var diagnosticCode: String {
        switch self {
        case .commitMissing: return "commit_missing"
        case .unsupportedFormat: return "snapshot_format_unsupported"
        case .manifestInvalid: return "manifest_invalid"
        case .remoteNamespaceInaccessible: return "icloud_unavailable"
        case .snapshotNotFound: return "commit_missing"
        }
    }
}
