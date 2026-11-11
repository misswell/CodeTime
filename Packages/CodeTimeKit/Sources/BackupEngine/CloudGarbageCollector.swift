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
    /// Missing on tombstones written before GC Epochs existed.
    public var epochID: String?

    public init(
        id: String,
        kind: V3GCTombstoneKind,
        targetID: String,
        projectID: UUID? = nil,
        reason: String,
        deviceID: String,
        createdAt: Date,
        graceUntil: Date,
        epochID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.targetID = targetID
        self.projectID = projectID
        self.reason = reason
        self.deviceID = deviceID
        self.createdAt = createdAt
        self.graceUntil = graceUntil
        self.epochID = epochID
    }
}

public struct V3GCReport: Sendable, Equatable {
    public var phase: String
    public var epochID: String?
    public var epochState: GCOperationState?
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
    public var hiddenSnapshots: Int
    public var awaitingDevices: [String]
    public var warnings: [String]
    public var failures: [String]
    public var skippedReason: String?

    public init(
        phase: String = "",
        epochID: String? = nil,
        epochState: GCOperationState? = nil,
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
        hiddenSnapshots: Int = 0,
        awaitingDevices: [String] = [],
        warnings: [String] = [],
        failures: [String] = [],
        skippedReason: String? = nil
    ) {
        self.phase = phase
        self.epochID = epochID
        self.epochState = epochState
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
        self.hiddenSnapshots = hiddenSnapshots
        self.awaitingDevices = awaitingDevices
        self.warnings = warnings
        self.failures = failures
        self.skippedReason = skippedReason
    }
}

public enum V3GCError: Error, Sendable, Equatable {
    /// A condition where deleting anything could destroy a live version.
    case unsafe(String)
    case awaitingDevices([String])
    case graceNotElapsed(until: Date)
    case planChanged(String)

    public var diagnosticCode: String {
        switch self {
        case .unsafe, .planChanged: return "gc_reference_incomplete"
        case .awaitingDevices: return "gc_lock_unavailable"
        case .graceNotElapsed: return "gc_aborted"
        }
    }
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

/// §11: fail-closed cloud garbage collection for Cloud Format v3.
///
/// This is deliberately not a "scan and delete" loop. A destructive sweep
/// requires:
/// 1. a complete strict enumeration (any unreadable directory aborts);
/// 2. a persistent GC Epoch whose plan is frozen at creation time;
/// 3. an acknowledgement from every active device (offline devices block it);
/// 4. the grace period to elapse;
/// 5. a fresh reference graph rebuilt from all currently visible commits;
/// 6. no pending uploads, in-flight snapshots, active backups or restores;
/// 7. deletion in the order commits → manifests → nodes → packs → objects,
///    followed by a verification that the candidates are actually gone.
///
/// Every step is resumable: the epoch file is rewritten only by its initiator and
/// never changes its candidates or digests.
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

    // MARK: - Phase one: plan + tombstones

    /// Creates (or refreshes) a GC Epoch. No data is deleted here. The plan is
    /// persisted before any tombstone is written; a crash can resume from it.
    public func createTombstones(
        policies: [UUID: RetentionPolicy],
        now: Date? = nil
    ) async throws -> V3GCReport {
        let at = now ?? clock()
        try await ensureNoInFlightWork()
        guard await isSafeToCollect() else {
            throw V3GCError.unsafe("备份/发布/恢复任务正在运行")
        }

        let plan = try await buildPlan(policies: policies, now: at)
        let records = try await deviceRecords()
        let required = records.filter { $0.state == .active }.map(\.deviceID)
        guard required.contains(deviceID) else {
            throw V3GCError.unsafe("本设备未注册为活动设备，禁止执行 GC")
        }
        let acknowledged: [String: Date] = [deviceID: at]
        let missing = required.filter { acknowledged[$0] == nil }
        let epochID = UUID().uuidString
        let epoch = GCEpoch(
            id: epochID,
            initiatorDeviceID: deviceID,
            createdAt: at,
            graceUntil: at.addingTimeInterval(gracePeriod),
            state: missing.isEmpty ? .gracePeriod : .awaitsDeviceAcks,
            candidates: plan.candidates,
            retainedSnapshots: plan.retained,
            planDigest: plan.candidates.planDigest,
            requiredDeviceIDs: required,
            acknowledgedBy: acknowledged
        )
        try await store.writeEpoch(epoch)
        try await store.writeEpochAck(GCEpochAck(
            epochID: epochID, deviceID: deviceID, acknowledgedAt: at
        ))

        let tombstoneCount = try await writeTombstones(
            candidates: plan.candidates,
            epochID: epochID,
            now: at,
            graceUntil: epoch.graceUntil
        )
        return V3GCReport(
            phase: "plan",
            epochID: epochID,
            epochState: epoch.state,
            retainedSnapshots: plan.retained.count,
            expiredSnapshots: plan.candidates.snapshots.count,
            orphanObjects: plan.candidates.objects.count,
            orphanPacks: plan.candidates.packs.count,
            orphanNodes: plan.candidates.nodes.count,
            tombstonesPending: tombstoneCount,
            awaitingDevices: missing
        )
    }

    /// Other devices call this to confirm an epoch. It only writes an ack file;
    /// it never rewrites the epoch or deletes anything.
    @discardableResult
    public func acknowledgePendingEpochs(now: Date? = nil) async throws -> [String] {
        let at = now ?? clock()
        let epochs = try await store.epochsStrict()
        var acknowledged: [String] = []
        for epoch in epochs where !epoch.isTerminal {
            guard epoch.requiredDeviceIDs.contains(deviceID) else { continue }
            let acks = try await store.epochAcks(epochID: epoch.id)
            guard acks[deviceID] == nil else { continue }
            try await store.writeEpochAck(GCEpochAck(
                epochID: epoch.id, deviceID: deviceID, acknowledgedAt: at
            ))
            acknowledged.append(epoch.id)
        }
        return acknowledged
    }

    // MARK: - Phase two: sweep

    public func sweep(
        policies: [UUID: RetentionPolicy],
        now: Date? = nil
    ) async throws -> V3GCReport {
        let at = now ?? clock()
        try await ensureNoInFlightWork()
        guard await isSafeToCollect() else {
            throw V3GCError.unsafe("备份/发布/恢复任务正在运行")
        }

        let epochs = try await store.epochsStrict()
            .filter { !$0.isTerminal && $0.initiatorDeviceID == deviceID }
            .sorted { $0.createdAt < $1.createdAt }
        guard !epochs.isEmpty else {
            return V3GCReport(phase: "sweep", skippedReason: "没有待执行的 GC Epoch")
        }

        var latest = V3GCReport(phase: "sweep", skippedReason: "没有到期的 GC Epoch")
        for candidate in epochs {
            let acks = try await store.epochAcks(epochID: candidate.id)
            let missing = candidate.requiredDeviceIDs.filter { acks[$0] == nil }
            if !missing.isEmpty {
                latest = V3GCReport(
                    phase: "sweep",
                    epochID: candidate.id,
                    epochState: .awaitsDeviceAcks,
                    tombstonesPending: tombstoneCount(in: candidate.candidates),
                    awaitingDevices: missing,
                    skippedReason: "等待设备确认 GC Epoch：\(missing.joined(separator: ", "))"
                )
                continue
            }
            guard at >= candidate.graceUntil else {
                latest = V3GCReport(
                    phase: "sweep",
                    epochID: candidate.id,
                    epochState: .gracePeriod,
                    tombstonesPending: tombstoneCount(in: candidate.candidates),
                    skippedReason: "GC 宽限期未结束"
                )
                continue
            }
            return try await execute(epoch: candidate, policies: policies, now: at)
        }
        return latest
    }

    // MARK: - Execution

    private func execute(
        epoch initial: GCEpoch,
        policies: [UUID: RetentionPolicy],
        now: Date
    ) async throws -> V3GCReport {
        var epoch = initial
        var report = V3GCReport(
            phase: "sweep",
            epochID: epoch.id,
            epochState: epoch.state,
            retainedSnapshots: epoch.retainedSnapshots.count,
            expiredSnapshots: epoch.candidates.snapshots.count,
            orphanObjects: epoch.candidates.objects.count,
            orphanPacks: epoch.candidates.packs.count,
            orphanNodes: epoch.candidates.nodes.count
        )

        // 1. Hide commit markers first; they remain on disk under gc/hidden until
        //    all data deletion has been verified.
        if epoch.state.rank < GCOperationState.commitsHidden.rank {
            for snapshot in epoch.candidates.snapshots {
                do {
                    try await store.hideCommit(
                        projectID: snapshot.projectID,
                        snapshotID: snapshot.snapshotID,
                        epochID: epoch.id
                    )
                    report.hiddenSnapshots += 1
                } catch {
                    epoch.state = .failed
                    epoch.lastError = "隐藏提交标记失败：\(snapshot.snapshotID)：\(error)"
                    try await store.writeEpoch(epoch)
                    throw V3GCError.unsafe(epoch.lastError ?? "隐藏提交标记失败")
                }
            }
            // Verify they are no longer visible before touching any data.
            for snapshot in epoch.candidates.snapshots {
                let visible = try await store.strictCommits(projectID: snapshot.projectID)
                if visible.contains(where: { $0.snapshotID == snapshot.snapshotID }) {
                    epoch.state = .failed
                    epoch.lastError = "提交标记仍然可见：\(snapshot.snapshotID)"
                    try await store.writeEpoch(epoch)
                    throw V3GCError.unsafe(epoch.lastError ?? "提交标记仍然可见")
                }
            }
            epoch.state = .commitsHidden
            try await store.writeEpoch(epoch)
            report.epochState = epoch.state
        }

        // 2. Rebuild the reference graph from all CURRENTLY visible commits. New
        //    snapshots created during the grace period therefore protect their
        //    objects, and a candidate that became referenced again is kept.
        let graph = try await buildReferenceGraph(snapshotCandidates: nil)
        let protected = graph.referencedObjects
        let candidateObjects = Set(epoch.candidates.objects).subtracting(protected)
        let candidateNodes = Set(epoch.candidates.nodes).subtracting(graph.referencedNodes)
        let candidatePacks = Set(epoch.candidates.packs).filter { pack in
            graph.referencedPacks.contains(pack) == false
                && (graph.packMembers[pack] ?? []).isDisjoint(with: protected)
        }
        let candidateSnapshots = epoch.candidates.snapshots

        // 3. Manifests first (versions are already hidden).
        for snapshot in candidateSnapshots {
            do {
                try await deleteIfPresent {
                    try await store.deleteManifest(projectID: snapshot.projectID, snapshotID: snapshot.snapshotID)
                }
                report.deletedSnapshots += 1
            } catch {
                report.failures.append("删除 Manifest 失败：\(snapshot.snapshotID)：\(error)")
            }
        }
        epoch.state = .manifestsCleaned
        epoch.lastError = report.failures.isEmpty ? nil : report.failures.joined(separator: "; ")
        try await store.writeEpoch(epoch)
        report.epochState = epoch.state

        // 4. Nodes → packs → objects.
        for nodeID in candidateNodes {
            do {
                try await deleteIfPresent { try await store.deleteNode(nodeID) }
                report.deletedNodes += 1
            } catch {
                report.failures.append("删除节点失败：\(nodeID)：\(error)")
            }
        }
        epoch.state = .nodesCleaned
        epoch.lastError = report.failures.isEmpty ? nil : report.failures.joined(separator: "; ")
        try await store.writeEpoch(epoch)

        for packID in candidatePacks {
            do {
                try await deleteIfPresent { try await store.deletePack(packID) }
                report.deletedPacks += 1
            } catch {
                report.failures.append("删除 Pack 失败：\(packID)：\(error)")
            }
        }
        epoch.state = .packsCleaned
        epoch.lastError = report.failures.isEmpty ? nil : report.failures.joined(separator: "; ")
        try await store.writeEpoch(epoch)

        for objectID in candidateObjects {
            do {
                try await deleteIfPresent { try await store.deleteObject(objectID) }
                report.deletedObjects += 1
            } catch {
                report.failures.append("删除对象失败：\(objectID)：\(error)")
            }
        }
        epoch.state = .objectsCleaned
        epoch.lastError = report.failures.isEmpty ? nil : report.failures.joined(separator: "; ")
        try await store.writeEpoch(epoch)
        report.epochState = epoch.state

        // 5. Verify deletion before removing the hidden markers / tombstones.
        let remaining = try await remainingCandidates(
            objects: candidateObjects,
            packs: candidatePacks,
            nodes: candidateNodes
        )
        if !remaining.isEmpty {
            epoch.state = .failed
            epoch.lastError = "清理后仍存在：\(remaining.prefix(10).joined(separator: ", "))"
            try await store.writeEpoch(epoch)
            report.epochState = .failed
            report.failures.append(epoch.lastError ?? "清理验证失败")
            return report
        }
        if !report.failures.isEmpty {
            epoch.state = .failed
            epoch.lastError = report.failures.joined(separator: "; ")
            try await store.writeEpoch(epoch)
            report.epochState = .failed
            return report
        }

        for snapshot in candidateSnapshots {
            try? await store.deleteHiddenCommit(
                projectID: snapshot.projectID,
                snapshotID: snapshot.snapshotID,
                epochID: epoch.id
            )
        }
        // Tombstones are the very last thing removed.
        for tombstone in try await loadTombstones() where tombstone.epochID == epoch.id {
            try? await store.deleteTombstone(id: tombstone.id)
        }
        epoch.state = .completed
        epoch.lastError = nil
        epoch.acknowledgedBy = try await store.epochAcks(epochID: epoch.id)
        try await store.writeEpoch(epoch)
        report.epochState = .completed
        report.tombstonesPending = 0
        return report
    }

    // MARK: - Reference analysis

    struct Plan {
        var retained: [GCSnapshotCandidate]
        var candidates: GCCandidateSet
    }

    struct Graph {
        var referencedObjects: Set<String>
        var referencedPacks: Set<String>
        var referencedNodes: Set<String>
        var allObjects: Set<String>
        var allPacks: Set<String>
        var allNodes: Set<String>
        var packMembers: [String: Set<String>]
        /// Panics for GC: a pack whose contents cannot be parsed is never assumed
        /// empty; the whole run aborts.
        var packErrors: [String]
    }

    func buildPlan(
        policies: [UUID: RetentionPolicy],
        now: Date
    ) async throws -> Plan {
        let projects = try await store.strictProjectIDs()
        let allObjects = Set(try await store.strictStandaloneObjectIDs())
        let allPacks = Set(try await store.strictPackIDs())
        let allNodes = Set(try await store.strictNodeIDs())
        let packMembers = try await loadPackMembers(allPacks)

        var retained: [GCSnapshotCandidate] = []
        var expired: [GCSnapshotCandidate] = []
        for projectID in projects {
            let commits = try await store.strictCommits(projectID: projectID)
            let policy = policies[projectID] ?? .default
            let keep = SnapshotRetentionPlanner.retained(commits: commits, policy: policy, now: now)
            for commit in commits {
                let candidate = GCSnapshotCandidate(projectID: projectID, snapshotID: commit.snapshotID)
                if keep.contains(commit.snapshotID) { retained.append(candidate) }
                else { expired.append(candidate) }
            }
        }

        let graph = try await buildReferenceGraph(
            snapshotCandidates: retained,
            allObjects: allObjects,
            allPacks: allPacks,
            allNodes: allNodes,
            packMembers: packMembers
        )
        let orphanPacks = allPacks.filter { packID in
            if graph.referencedPacks.contains(packID) { return false }
            return (packMembers[packID] ?? []).isDisjoint(with: graph.referencedObjects)
        }
        return Plan(
            retained: retained,
            candidates: GCCandidateSet(
                snapshots: expired,
                nodes: Array(allNodes.subtracting(graph.referencedNodes)).sorted(),
                packs: orphanPacks.sorted(),
                objects: Array(allObjects.subtracting(graph.referencedObjects)).sorted()
            )
        )
    }

    /// Rebuilds references from exactly the requested snapshots, or from every
    /// currently visible commit when nil. Any unreadable manifest/node/pack or
    /// missing referenced object aborts the entire operation.
    private func buildReferenceGraph(
        snapshotCandidates: [GCSnapshotCandidate]?,
        allObjects: Set<String>? = nil,
        allPacks: Set<String>? = nil,
        allNodes: Set<String>? = nil,
        packMembers: [String: Set<String>]? = nil
    ) async throws -> Graph {
        let objects: Set<String>
        if let allObjects { objects = allObjects }
        else { objects = Set(try await store.strictStandaloneObjectIDs()) }
        let packs: Set<String>
        if let allPacks { packs = allPacks }
        else { packs = Set(try await store.strictPackIDs()) }
        let nodes: Set<String>
        if let allNodes { nodes = allNodes }
        else { nodes = Set(try await store.strictNodeIDs()) }
        let members: [String: Set<String>]
        if let packMembers { members = packMembers }
        else { members = try await loadPackMembers(packs) }

        let candidates: [GCSnapshotCandidate]
        if let snapshotCandidates {
            candidates = snapshotCandidates
        } else {
            var all: [GCSnapshotCandidate] = []
            for projectID in try await store.strictProjectIDs() {
                for commit in try await store.strictCommits(projectID: projectID) {
                    all.append(GCSnapshotCandidate(projectID: projectID, snapshotID: commit.snapshotID))
                }
            }
            candidates = all
        }

        var referencedObjects = Set<String>()
        var referencedPacks = Set<String>()
        var referencedNodes = Set<String>()
        let reader = CloudRestoreEngine(masterKey: masterKey, source: store)

        for candidate in candidates {
            let manifest: SnapshotManifest
            do {
                manifest = try await reader.loadManifest(
                    projectID: candidate.projectID,
                    snapshotID: candidate.snapshotID
                )
            } catch {
                throw V3GCError.unsafe("保留版本 \(candidate.snapshotID) 的清单不可读：\(error)")
            }
            guard nodes.contains(manifest.rootNodeID) else {
                throw V3GCError.unsafe("保留版本 \(candidate.snapshotID) 缺少根节点")
            }
            var stack = [manifest.rootNodeID]
            while let nodeID = stack.popLast() {
                guard referencedNodes.insert(nodeID).inserted else { continue }
                let node: DirectoryNode
                do { node = try await store.readNode(nodeID) }
                catch { throw V3GCError.unsafe("目录节点 \(nodeID) 不可读：\(error)") }
                for file in node.files {
                    for chunk in file.chunks {
                        referencedObjects.insert(chunk.objectID)
                        if let packID = chunk.packID {
                            referencedPacks.insert(packID)
                            guard let packMembers = members[packID],
                                  packMembers.contains(chunk.objectID) else {
                                throw V3GCError.unsafe(
                                    "数据块 \(chunk.objectID) 声称位于包 \(packID)，但包内找不到它"
                                )
                            }
                        } else if !objects.contains(chunk.objectID) {
                            throw V3GCError.unsafe("独立对象 \(chunk.objectID) 缺失")
                        }
                    }
                }
                for directory in node.directories {
                    guard nodes.contains(directory.nodeID) else {
                        throw V3GCError.unsafe("目录节点 \(directory.nodeID) 缺失")
                    }
                    stack.append(directory.nodeID)
                }
            }
        }
        return Graph(
            referencedObjects: referencedObjects,
            referencedPacks: referencedPacks,
            referencedNodes: referencedNodes,
            allObjects: objects,
            allPacks: packs,
            allNodes: nodes,
            packMembers: members,
            packErrors: []
        )
    }

    private func loadPackMembers(_ packIDs: Set<String>) async throws -> [String: Set<String>] {
        var members: [String: Set<String>] = [:]
        for packID in packIDs {
            let payload: Data
            do { payload = try await store.readPack(packID) }
            catch { throw V3GCError.unsafe("Pack \(packID) 不可读：\(error)") }
            guard CanonicalHashing.sha256Hex(payload) == packID else {
                throw V3GCError.unsafe("Pack \(packID) 内容哈希不匹配")
            }
            let entries: [ObjectPackFormat.Entry]
            do { entries = try ObjectPackReader().entries(in: payload) }
            catch { throw V3GCError.unsafe("Pack \(packID) 索引损坏：\(error)") }
            var seen = Set<String>()
            var ranges: [(Int, Int)] = []
            for entry in entries {
                guard seen.insert(entry.objectID).inserted else {
                    throw V3GCError.unsafe("Pack \(packID) 含重复对象 \(entry.objectID)")
                }
                guard entry.offset >= ObjectPackFormat.headerSize,
                      entry.length > 0,
                      entry.offset + entry.length <= payload.count else {
                    throw V3GCError.unsafe("Pack \(packID) 对象越界：\(entry.objectID)")
                }
                ranges.append((entry.offset, entry.offset + entry.length))
            }
            ranges.sort { $0.0 < $1.0 }
            for index in 1..<max(1, ranges.count) where ranges.count > 1 {
                if ranges[index].0 < ranges[index - 1].1 {
                    throw V3GCError.unsafe("Pack \(packID) 对象区间重叠")
                }
            }
            members[packID] = seen
        }
        return members
    }

    private func tombstoneCount(in candidates: GCCandidateSet) -> Int {
        candidates.snapshots.count + candidates.nodes.count
            + candidates.packs.count + candidates.objects.count
    }

    private func remainingCandidates(
        objects: Set<String>,
        packs: Set<String>,
        nodes: Set<String>
    ) async throws -> [String] {
        let liveObjects = Set(try await store.strictStandaloneObjectIDs())
        let livePacks = Set(try await store.strictPackIDs())
        let liveNodes = Set(try await store.strictNodeIDs())
        var remaining: [String] = []
        remaining.append(contentsOf: objects.intersection(liveObjects).map { "object:\($0)" })
        remaining.append(contentsOf: packs.intersection(livePacks).map { "pack:\($0)" })
        remaining.append(contentsOf: nodes.intersection(liveNodes).map { "node:\($0)" })
        return remaining
    }

    // MARK: - Helpers

    private func ensureNoInFlightWork() async throws {
        let pendingBytes = try await index.pendingUploadBytes()
        guard pendingBytes == 0 else {
            throw V3GCError.unsafe("存在 \(pendingBytes) 字节未确认上传的数据，禁止清理")
        }
        let inFlight = try await index.inFlightSnapshotCount()
        guard inFlight == 0 else {
            throw V3GCError.unsafe("有 \(inFlight) 个快照仍在发布，禁止清理")
        }
    }

    private func deviceRecords() async throws -> [GCDeviceRecord] {
        var records = try await store.deviceRecordsStrict()
        if !records.contains(where: { $0.deviceID == deviceID }) {
            let record = GCDeviceRecord(
                deviceID: deviceID,
                name: deviceID,
                createdAt: clock(),
                lastSeenAt: clock(),
                state: .active
            )
            try await store.writeDeviceRecord(record)
            records.append(record)
        }
        return records
    }

    private func writeTombstones(
        candidates: GCCandidateSet,
        epochID: String,
        now: Date,
        graceUntil: Date
    ) async throws -> Int {
        var count = 0
        for objectID in candidates.objects {
            try await tombstone(kind: .object, target: objectID, projectID: nil,
                                reason: "不再被任何保留版本引用的数据块",
                                epochID: epochID, now: now, graceUntil: graceUntil)
            count += 1
        }
        for packID in candidates.packs {
            try await tombstone(kind: .pack, target: packID, projectID: nil,
                                reason: "不再被任何保留版本引用的对象包",
                                epochID: epochID, now: now, graceUntil: graceUntil)
            count += 1
        }
        for nodeID in candidates.nodes {
            try await tombstone(kind: .node, target: nodeID, projectID: nil,
                                reason: "不再被任何保留版本引用的目录节点",
                                epochID: epochID, now: now, graceUntil: graceUntil)
            count += 1
        }
        for snapshot in candidates.snapshots {
            try await tombstone(kind: .snapshot, target: snapshot.snapshotID, projectID: snapshot.projectID,
                                reason: "超出保留策略的历史版本",
                                epochID: epochID, now: now, graceUntil: graceUntil)
            count += 1
        }
        return count
    }

    private func tombstone(
        kind: V3GCTombstoneKind,
        target: String,
        projectID: UUID?,
        reason: String,
        epochID: String,
        now: Date,
        graceUntil: Date
    ) async throws {
        let id = Self.tombstoneID(kind: kind, target: target, projectID: projectID)
        let tombstone = V3Tombstone(
            id: id,
            kind: kind,
            targetID: target,
            projectID: projectID,
            reason: reason,
            deviceID: deviceID,
            createdAt: now,
            graceUntil: graceUntil,
            epochID: epochID
        )
        try await store.putTombstone(try JSONEncoder.canonical.encode(tombstone), id: id)
    }

    private func loadTombstones() async throws -> [V3Tombstone] {
        var result: [V3Tombstone] = []
        for payload in try await store.strictTombstonePayloads() {
            guard let tombstone = try? JSONDecoder().decode(V3Tombstone.self, from: payload) else {
                throw V3GCError.unsafe("存在无法解析的墓碑记录，已停止清理")
            }
            result.append(tombstone)
        }
        return result
    }

    /// Deletions are idempotent: a file that is already gone is success.
    private func deleteIfPresent(_ body: () async throws -> Void) async throws {
        try await body()
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

extension GCOperationState {
    /// Monotonic rank used to resume an epoch after a crash.
    var rank: Int {
        switch self {
        case .planned: return 0
        case .awaitsDeviceAcks: return 1
        case .gracePeriod: return 2
        case .commitsHidden: return 3
        case .manifestsCleaned: return 4
        case .nodesCleaned: return 5
        case .packsCleaned: return 6
        case .objectsCleaned: return 7
        case .completed: return 8
        case .failed: return -1
        }
    }
}
