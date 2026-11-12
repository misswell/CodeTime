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
    /// Commits are hidden; every required device must now observe that state
    /// before any irreversible deletion starts.
    case awaitsHiddenAcks
    case manifestsCleaned
    case nodesCleaned
    case packsCleaned
    case objectsCleaned
    case completed
    case failed
}

public enum GCBarrierPhase: String, Codable, Sendable, Hashable {
    case prepared
    case commitsHiddenObserved
    case released
}

/// Durable proof that this device has drained readers and will refuse restores
/// of the candidate snapshots for the lifetime of the epoch.
public struct GCDeviceBarrier: Codable, Hashable, Sendable {
    public var epochID: String
    public var planDigest: String
    public var deviceID: String
    public var candidateSnapshotIDs: [String]
    public var createdAt: Date
    public var phase: GCBarrierPhase

    public init(
        epochID: String,
        planDigest: String,
        deviceID: String,
        candidateSnapshotIDs: [String],
        createdAt: Date,
        phase: GCBarrierPhase = .prepared
    ) {
        self.epochID = epochID
        self.planDigest = planDigest
        self.deviceID = deviceID
        self.candidateSnapshotIDs = candidateSnapshotIDs
        self.createdAt = createdAt
        self.phase = phase
    }
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
    /// Hidden-commit acknowledgements, written only after a device observed that
    /// every candidate commit is no longer visible.
    public var hiddenAcknowledgedBy: [String: Date]
    /// 1 = legacy epoch without device barriers; 2 = barrier protocol.
    public var protocolVersion: Int?
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
        hiddenAcknowledgedBy: [String: Date] = [:],
        protocolVersion: Int? = 2,
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
        self.hiddenAcknowledgedBy = hiddenAcknowledgedBy
        self.protocolVersion = protocolVersion
        self.lastError = lastError
    }

    public func missingAcknowledgements() -> [String] {
        requiredDeviceIDs.filter { acknowledgedBy[$0] == nil }
    }

    public func missingHiddenAcknowledgements() -> [String] {
        requiredDeviceIDs.filter { hiddenAcknowledgedBy[$0] == nil }
    }

    public var supportsDeviceBarriers: Bool { (protocolVersion ?? 1) >= 2 }

    /// `failed` is retryable: a deletion that failed must be resumed later, not
    /// silently abandoned.
    public var isTerminal: Bool { state == .completed }

    private enum CodingKeys: String, CodingKey {
        case id, initiatorDeviceID, createdAt, graceUntil, state, candidates
        case retainedSnapshots, planDigest, requiredDeviceIDs, acknowledgedBy
        case hiddenAcknowledgedBy, protocolVersion, lastError
    }

    /// Explicit decoding keeps old epochs readable: fields added with the device
    /// barrier protocol default to "legacy" instead of failing the whole GC scan.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        initiatorDeviceID = try container.decode(String.self, forKey: .initiatorDeviceID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        graceUntil = try container.decode(Date.self, forKey: .graceUntil)
        state = try container.decode(GCOperationState.self, forKey: .state)
        candidates = try container.decode(GCCandidateSet.self, forKey: .candidates)
        retainedSnapshots = try container.decode([GCSnapshotCandidate].self, forKey: .retainedSnapshots)
        planDigest = try container.decode(String.self, forKey: .planDigest)
        requiredDeviceIDs = try container.decode([String].self, forKey: .requiredDeviceIDs)
        acknowledgedBy = try container.decodeIfPresent([String: Date].self, forKey: .acknowledgedBy) ?? [:]
        hiddenAcknowledgedBy = try container.decodeIfPresent(
            [String: Date].self, forKey: .hiddenAcknowledgedBy
        ) ?? [:]
        protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }
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
