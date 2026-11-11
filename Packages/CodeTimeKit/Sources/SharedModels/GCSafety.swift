import Foundation

/// Result of listing a directory where "missing" and "failed" must never be
/// confused. GC treats `.notFound` as an empty namespace and any thrown error as
/// a reason to abort without deleting anything.
public enum DirectoryEnumerationResult: Sendable, Equatable {
    case exists([URL])
    case notFound
}

public enum GCDeviceState: String, Codable, Sendable, Hashable {
    case active
    case retired
}

/// Durable device registration. A device without a record (legacy install) is
/// treated as active if its namespace directory exists, which is the conservative
/// choice: an unknown device blocks destructive cleanup.
public struct GCDeviceRecord: Codable, Hashable, Sendable {
    public var deviceID: String
    public var name: String
    public var createdAt: Date
    public var lastSeenAt: Date
    public var state: GCDeviceState

    public init(
        deviceID: String,
        name: String,
        createdAt: Date,
        lastSeenAt: Date,
        state: GCDeviceState = .active
    ) {
        self.deviceID = deviceID
        self.name = name
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.state = state
    }
}

public struct GCSnapshotCandidate: Codable, Hashable, Sendable {
    public var projectID: UUID
    public var snapshotID: String

    public init(projectID: UUID, snapshotID: String) {
        self.projectID = projectID
        self.snapshotID = snapshotID
    }
}

/// The exact set of objects a GC Epoch was planned against. The digest binds the
/// plan so a sweep cannot delete a different set after a crash or a concurrent
/// backup changed the reference graph.
public struct GCCandidateSet: Codable, Hashable, Sendable {
    public var snapshots: [GCSnapshotCandidate]
    public var nodes: [String]
    public var packs: [String]
    public var objects: [String]

    public init(
        snapshots: [GCSnapshotCandidate] = [],
        nodes: [String] = [],
        packs: [String] = [],
        objects: [String] = []
    ) {
        self.snapshots = snapshots
        self.nodes = nodes
        self.packs = packs
        self.objects = objects
    }

    public var isEmpty: Bool {
        snapshots.isEmpty && nodes.isEmpty && packs.isEmpty && objects.isEmpty
    }

    public var planDigest: String {
        let snapshots = snapshots
            .map { "\($0.projectID.uuidString):\($0.snapshotID)" }
            .sorted()
        let payload: [String: [String]] = [
            "snapshots": snapshots,
            "nodes": nodes.sorted(),
            "packs": packs.sorted(),
            "objects": objects.sorted(),
        ]
        let data = (try? JSONEncoder.canonical.encode(payload)) ?? Data()
        return CanonicalHashing.sha256Hex(data)
    }
}

public enum GCOperationState: String, Codable, Sendable, CaseIterable {
    case planned
    case awaitsDeviceAcks
    case gracePeriod
    case commitsHidden
    case manifestsCleaned
    case nodesCleaned
    case packsCleaned
    case objectsCleaned
    case completed
    case failed
}

public struct GCEpochAck: Codable, Hashable, Sendable {
    public var epochID: String
    public var deviceID: String
    public var acknowledgedAt: Date

    public init(epochID: String, deviceID: String, acknowledgedAt: Date) {
        self.epochID = epochID
        self.deviceID = deviceID
        self.acknowledgedAt = acknowledgedAt
    }
}

/// A persistent GC plan/progress record. It lives under `v3/gc/epochs/<id>.json`
/// so it survives a crash and is visible to the other devices that must confirm
/// the epoch before any deletion happens.
public struct GCEpoch: Codable, Hashable, Sendable {
    public var id: String
    public var initiatorDeviceID: String
    public var createdAt: Date
    public var graceUntil: Date
    public var state: GCOperationState
    public var candidates: GCCandidateSet
    /// Frozen retention decision: the sweep rebuilds references from exactly
    /// these versions, so a later clock cannot silently change the plan.
    public var retainedSnapshots: [GCSnapshotCandidate]
    public var planDigest: String
    public var requiredDeviceIDs: [String]
    public var acknowledgedBy: [String: Date]
    public var lastError: String?

    public init(
        id: String,
        initiatorDeviceID: String,
        createdAt: Date,
        graceUntil: Date,
        state: GCOperationState,
        candidates: GCCandidateSet,
        retainedSnapshots: [GCSnapshotCandidate],
        planDigest: String,
        requiredDeviceIDs: [String],
        acknowledgedBy: [String: Date] = [:],
        lastError: String? = nil
    ) {
        self.id = id
        self.initiatorDeviceID = initiatorDeviceID
        self.createdAt = createdAt
        self.graceUntil = graceUntil
        self.state = state
        self.candidates = candidates
        self.retainedSnapshots = retainedSnapshots
        self.planDigest = planDigest
        self.requiredDeviceIDs = requiredDeviceIDs
        self.acknowledgedBy = acknowledgedBy
        self.lastError = lastError
    }

    public func missingAcknowledgements() -> [String] {
        requiredDeviceIDs.filter { acknowledgedBy[$0] == nil }
    }

    /// `failed` is retryable: a deletion that failed must be resumed later, not
    /// silently abandoned.
    public var isTerminal: Bool { state == .completed }
}

public extension JSONEncoder {
    /// Stable JSON for plan digests (sorted keys, millisecond dates).
    static var canonical: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}
