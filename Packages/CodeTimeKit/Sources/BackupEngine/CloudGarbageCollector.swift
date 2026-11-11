import Foundation
import SharedModels

public enum V3GCTombstoneKind: String, Codable, Sendable {
    case object
    case pack
    case node
    case snapshot
}

/// §11.2 phase one. Nothing is deleted while a tombstone is young.
public struct V3Tombstone: Codable, Hashable, Sendable {
    public var id: String
    public var kind: V3GCTombstoneKind
    public var targetID: String
    public var projectID: UUID?
    public var reason: String
    public var deviceID: String
    public var createdAt: Date
    public var graceUntil: Date

    public init(
        id: String,
        kind: V3GCTombstoneKind,
        targetID: String,
        projectID: UUID? = nil,
        reason: String,
        deviceID: String,
        createdAt: Date,
        graceUntil: Date
    ) {
        self.id = id
        self.kind = kind
        self.targetID = targetID
        self.projectID = projectID
        self.reason = reason
        self.deviceID = deviceID
        self.createdAt = createdAt
        self.graceUntil = graceUntil
    }
}

public struct V3GCReport: Sendable, Equatable {
    public var phase: String
    public var retainedSnapshots: Int
    public var expiredSnapshots: Int
    public var orphanObjects: Int
    public var orphanPacks: Int
    public var orphanNodes: Int
    public var tombstonesPending: Int
    public var deletedObjects: Int
    public var deletedPacks: Int
    public var deletedNodes: Int
    public var deletedSnapshots: Int
    public var warnings: [String]
    public var skippedReason: String?

    public init(
        phase: String = "",
        retainedSnapshots: Int = 0,
        expiredSnapshots: Int = 0,
        orphanObjects: Int = 0,
        orphanPacks: Int = 0,
        orphanNodes: Int = 0,
        tombstonesPending: Int = 0,
        deletedObjects: Int = 0,
        deletedPacks: Int = 0,
        deletedNodes: Int = 0,
        deletedSnapshots: Int = 0,
        warnings: [String] = [],
        skippedReason: String? = nil
    ) {
        self.phase = phase
        self.retainedSnapshots = retainedSnapshots
        self.expiredSnapshots = expiredSnapshots
        self.orphanObjects = orphanObjects
        self.orphanPacks = orphanPacks
        self.orphanNodes = orphanNodes
        self.tombstonesPending = tombstonesPending
        self.deletedObjects = deletedObjects
        self.deletedPacks = deletedPacks
        self.deletedNodes = deletedNodes
        self.deletedSnapshots = deletedSnapshots
        self.warnings = warnings
        self.skippedReason = skippedReason
    }
}

public enum V3GCError: Error, Sendable, Equatable {
    /// A condition where deleting anything could destroy a live version.
    case unsafe(String)

    public var diagnosticCode: String { "ICLOUD_MANIFEST_UNREADABLE" }
}

/// Time-Machine-style retention over cloud commits: keep the newest N, plus one
/// version per day/week/month inside the configured windows. The newest two are
/// always kept regardless of policy, because GC must never erase the last
/// recoverable version.
public enum SnapshotRetentionPlanner {
    public static func retained(
        commits: [SnapshotCommit],
        policy: RetentionPolicy,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Set<String> {
        let ordered = commits.sorted { $0.committedAt > $1.committedAt }
        guard !ordered.isEmpty else { return [] }
        var keep = Set(ordered.prefix(max(2, policy.keepLatest)).map(\.snapshotID))

        func age(_ date: Date, in component: Calendar.Component) -> Int? {
            calendar.dateComponents([component], from: date, to: now).value(for: component)
        }

        var seenDays = Set<String>()
        for commit in ordered {
            guard let days = age(commit.committedAt, in: .day), days <= policy.keepDaily else { continue }
            let key = dayKey(commit.committedAt, calendar: calendar)
            if seenDays.insert(key).inserted { keep.insert(commit.snapshotID) }
        }

        var seenWeeks = Set<String>()
        for commit in ordered {
            guard let weeks = age(commit.committedAt, in: .weekOfYear), weeks <= policy.keepWeekly else { continue }
            let key = weekKey(commit.committedAt, calendar: calendar)
            if seenWeeks.insert(key).inserted { keep.insert(commit.snapshotID) }
        }

        var seenMonths = Set<String>()
        for commit in ordered {
            guard let months = age(commit.committedAt, in: .month), months <= policy.keepMonthly else { continue }
            let key = monthKey(commit.committedAt, calendar: calendar)
            if seenMonths.insert(key).inserted { keep.insert(commit.snapshotID) }
        }
        return keep
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    private static func weekKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return "\(c.yearForWeekOfYear ?? 0)-\(c.weekOfYear ?? 0)"
    }

    private static func monthKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)"
    }
}

/// §11: two-phase cloud garbage collection for Cloud Format v3.
///
/// Phase one only writes tombstones. Phase two recomputes every reference from
/// the retained commit markers, refuses to run while anything is publishing or
/// staged, and deletes only tombstones whose grace period has elapsed and which
/// are still unreferenced. Any unreadable manifest, missing referenced object or
/// unparseable tombstone aborts the whole run — a partial reference graph is
/// exactly the situation where deletion becomes data loss.
public struct CloudGarbageCollector: Sendable {
    private let store: CloudGarbageCollectible
    private let masterKey: Data
    private let deviceID: String
    private let index: CloudSnapshotIndex
    private let gracePeriod: TimeInterval
    private let isSafeToCollect: @Sendable () async -> Bool
    private let clock: @Sendable () -> Date

    public init(
        store: CloudGarbageCollectible,
        masterKey: Data,
        deviceID: String,
        index: CloudSnapshotIndex,
        gracePeriod: TimeInterval = 30 * 24 * 3600,
        isSafeToCollect: @escaping @Sendable () async -> Bool = { true },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.masterKey = masterKey
        self.deviceID = deviceID
        self.index = index
        self.gracePeriod = max(0, gracePeriod)
        self.isSafeToCollect = isSafeToCollect
        self.clock = clock
    }

    // MARK: - Phase one

    public func createTombstones(
        policies: [UUID: RetentionPolicy],
        now: Date? = nil
    ) async throws -> V3GCReport {
        let at = now ?? clock()
        let plan = try await buildPlan(policies: policies, now: at)
        let existing = try await loadTombstones()
        var report = V3GCReport(
            phase: "tombstone",
            retainedSnapshots: plan.retainedSnapshotCount,
            expiredSnapshots: plan.expiredSnapshots.count,
            orphanObjects: plan.orphanObjects.count,
            orphanPacks: plan.orphanPacks.count,
            orphanNodes: plan.orphanNodes.count
        )

        for objectID in plan.orphanObjects {
            try await tombstoneIfNeeded(
                kind: .object, target: objectID, projectID: nil,
                reason: "不再被任何保留版本引用的数据块",
                existing: existing, now: at
            )
            report.tombstonesPending += 1
        }
        for packID in plan.orphanPacks {
            try await tombstoneIfNeeded(
                kind: .pack, target: packID, projectID: nil,
                reason: "不再被任何保留版本引用的对象包",
                existing: existing, now: at
            )
            report.tombstonesPending += 1
        }
        for nodeID in plan.orphanNodes {
            try await tombstoneIfNeeded(
                kind: .node, target: nodeID, projectID: nil,
                reason: "不再被任何保留版本引用的目录节点",
                existing: existing, now: at
            )
            report.tombstonesPending += 1
        }
        for expired in plan.expiredSnapshots {
            try await tombstoneIfNeeded(
                kind: .snapshot, target: expired.snapshotID, projectID: expired.projectID,
                reason: "超出保留策略的历史版本",
                existing: existing, now: at
            )
            report.tombstonesPending += 1
        }
        return report
    }

    // MARK: - Phase two

    public func sweep(
        policies: [UUID: RetentionPolicy],
        now: Date? = nil
    ) async throws -> V3GCReport {
        let at = now ?? clock()
        guard await isSafeToCollect() else {
            throw V3GCError.unsafe("备份/发布/恢复任务正在运行")
        }
        let pendingBytes = try await index.pendingUploadBytes()
        guard pendingBytes == 0 else {
            throw V3GCError.unsafe("存在 \(pendingBytes) 字节未确认上传的数据，禁止清理")
        }
        let inFlight = try await index.inFlightSnapshotCount()
        guard inFlight == 0 else {
            throw V3GCError.unsafe("有 \(inFlight) 个快照仍在发布，禁止清理")
        }

        let plan = try await buildPlan(policies: policies, now: at)
        let tombstones = try await loadTombstones()
        var report = V3GCReport(
            phase: "sweep",
            retainedSnapshots: plan.retainedSnapshotCount,
            expiredSnapshots: plan.expiredSnapshots.count,
            orphanObjects: plan.orphanObjects.count,
            orphanPacks: plan.orphanPacks.count,
            orphanNodes: plan.orphanNodes.count
        )

        for tombstone in tombstones.values.sorted(by: { $0.graceUntil < $1.graceUntil }) {
            guard tombstone.graceUntil <= at else {
                report.tombstonesPending += 1
                continue
            }
            do {
                switch tombstone.kind {
                case .object:
                    if plan.orphanObjects.contains(tombstone.targetID) {
                        try await store.deleteObject(tombstone.targetID)
                        report.deletedObjects += 1
                    }
                case .pack:
                    if plan.orphanPacks.contains(tombstone.targetID) {
                        try await store.deletePack(tombstone.targetID)
                        report.deletedPacks += 1
                    }
                case .node:
                    if plan.orphanNodes.contains(tombstone.targetID) {
                        try await store.deleteNode(tombstone.targetID)
                        report.deletedNodes += 1
                    }
                case .snapshot:
                    guard let projectID = tombstone.projectID,
                          plan.expiredSnapshots.contains(where: {
                              $0.projectID == projectID && $0.snapshotID == tombstone.targetID
                          }) else {
                        break
                    }
                    // Removing the commit marker first makes the version
                    // invisible; its manifest is then no longer referenced.
                    try await store.deleteCommit(projectID: projectID, snapshotID: tombstone.targetID)
                    try await store.deleteManifest(projectID: projectID, snapshotID: tombstone.targetID)
                    report.deletedSnapshots += 1
                }
                try await store.deleteTombstone(id: tombstone.id)
            } catch {
                // Keep the tombstone: the object is still there, so retrying later
                // is safe and the error stays visible.
                report.warnings.append("\(tombstone.kind.rawValue) \(tombstone.targetID)：\(error)")
            }
        }
        return report
    }

    // MARK: - Reference analysis

    struct Plan {
        var retainedSnapshotCount: Int
        var expiredSnapshots: [(projectID: UUID, snapshotID: String)]
        var referencedObjects: Set<String>
        var referencedPacks: Set<String>
        var referencedNodes: Set<String>
        var orphanObjects: Set<String>
        var orphanPacks: Set<String>
        var orphanNodes: Set<String>
    }

    func buildPlan(
        policies: [UUID: RetentionPolicy],
        now: Date
    ) async throws -> Plan {
        let projects = try await store.projectIDs()
        let allObjects = Set(try await store.standaloneObjectIDs())
        let allPacks = Set(try await store.packIDs())
        let allNodes = Set(try await store.nodeIDs())

        var packMembers: [String: Set<String>] = [:]
        for packID in allPacks {
            guard let payload = try? await store.readPack(packID) else {
                // An unreadable pack may hold referenced data; its members are
                // unknown, so it is protected and later reported, never deleted.
                packMembers[packID] = nil
                continue
            }
            if let entries = try? ObjectPackReader().entries(in: payload) {
                packMembers[packID] = Set(entries.map(\.objectID))
            }
        }

        var referencedObjects = Set<String>()
        var referencedPacks = Set<String>()
        var referencedNodes = Set<String>()
        var retainedCount = 0
        var expired: [(UUID, String)] = []
        let reader = CloudRestoreEngine(masterKey: masterKey, source: store)

        for projectID in projects {
            let commits = try await store.strictCommits(projectID: projectID)
            let policy = policies[projectID] ?? .default
            let retained = SnapshotRetentionPlanner.retained(
                commits: commits, policy: policy, now: now
            )
            retainedCount += retained.count
            for commit in commits where !retained.contains(commit.snapshotID) {
                expired.append((projectID, commit.snapshotID))
            }

            for commit in commits where retained.contains(commit.snapshotID) {
                let manifest: SnapshotManifest
                do {
                    manifest = try await reader.loadManifest(
                        projectID: projectID,
                        snapshotID: commit.snapshotID
                    )
                } catch {
                    throw V3GCError.unsafe(
                        "保留版本 \(commit.snapshotID) 的清单不可读：\(error)"
                    )
                }
                guard allNodes.contains(manifest.rootNodeID) else {
                    throw V3GCError.unsafe("保留版本 \(commit.snapshotID) 缺少根节点")
                }
                var stack = [manifest.rootNodeID]
                while let nodeID = stack.popLast() {
                    guard referencedNodes.insert(nodeID).inserted else { continue }
                    let node: DirectoryNode
                    do {
                        node = try await store.readNode(nodeID)
                    } catch {
                        throw V3GCError.unsafe("目录节点 \(nodeID) 不可读：\(error)")
                    }
                    for file in node.files {
                        for chunk in file.chunks {
                            referencedObjects.insert(chunk.objectID)
                            if let packID = chunk.packID {
                                referencedPacks.insert(packID)
                                guard let members = packMembers[packID],
                                      members.contains(chunk.objectID) else {
                                    throw V3GCError.unsafe(
                                        "数据块 \(chunk.objectID) 声称位于包 \(packID)，但包内找不到它"
                                    )
                                }
                            } else {
                                guard allObjects.contains(chunk.objectID) else {
                                    throw V3GCError.unsafe("独立对象 \(chunk.objectID) 缺失")
                                }
                            }
                        }
                    }
                    for directory in node.directories {
                        guard allNodes.contains(directory.nodeID) else {
                            throw V3GCError.unsafe("目录节点 \(directory.nodeID) 缺失")
                        }
                        stack.append(directory.nodeID)
                    }
                }
            }
        }

        // A pack is never split: if any member is still referenced, the whole
        // pack stays. A pack whose members cannot be parsed is also kept.
        let orphanPacks = allPacks.filter { packID in
            if referencedPacks.contains(packID) { return false }
            guard let members = packMembers[packID] else { return false }
            return members.isDisjoint(with: referencedObjects)
        }
        return Plan(
            retainedSnapshotCount: retainedCount,
            expiredSnapshots: expired,
            referencedObjects: referencedObjects,
            referencedPacks: referencedPacks,
            referencedNodes: referencedNodes,
            orphanObjects: allObjects.subtracting(referencedObjects),
            orphanPacks: Set(orphanPacks),
            orphanNodes: allNodes.subtracting(referencedNodes)
        )
    }

    // MARK: - Tombstone IO

    private func loadTombstones() async throws -> [String: V3Tombstone] {
        var result: [String: V3Tombstone] = [:]
        for payload in try await store.tombstonePayloads() {
            guard let tombstone = try? JSONDecoder().decode(V3Tombstone.self, from: payload) else {
                throw V3GCError.unsafe("存在无法解析的墓碑记录，已停止清理")
            }
            result[tombstone.id] = tombstone
        }
        return result
    }

    private func tombstoneIfNeeded(
        kind: V3GCTombstoneKind,
        target: String,
        projectID: UUID?,
        reason: String,
        existing: [String: V3Tombstone],
        now: Date
    ) async throws {
        let id = Self.tombstoneID(kind: kind, target: target, projectID: projectID)
        if existing[id] != nil { return }
        let tombstone = V3Tombstone(
            id: id,
            kind: kind,
            targetID: target,
            projectID: projectID,
            reason: reason,
            deviceID: deviceID,
            createdAt: now,
            graceUntil: now.addingTimeInterval(gracePeriod)
        )
        try await store.putTombstone(try JSONEncoder().encode(tombstone), id: id)
    }

    static func tombstoneID(kind: V3GCTombstoneKind, target: String, projectID: UUID?) -> String {
        switch kind {
        case .snapshot:
            return "snapshot-\(projectID?.uuidString ?? "unknown")-\(target)"
        default:
            return "\(kind.rawValue)-\(target)"
        }
    }
}
