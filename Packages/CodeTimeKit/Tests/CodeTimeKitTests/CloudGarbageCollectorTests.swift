import XCTest
import Foundation
@testable import BackupEngine
@testable import SharedModels

/// CT-163: Cloud Format v3 garbage collection. Two phases, reference analysis
/// from retained commits only, and hard refusal whenever the graph is uncertain.
final class CloudGarbageCollectorTests: XCTestCase {
    private var root: URL!
    private let masterKey = Data("gc-test-key".utf8)
    private let projectID = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func write(_ version: Int, at date: Date) throws {
        // A unique payload per version, so expired versions own private chunks.
        let url = root.appendingPathComponent("data.txt")
        try Data("version-\(version)-\(String(repeating: "q", count: 5000))".utf8).write(to: url)
        // Distinct mtimes: the reuse heuristic compares size and mtime, and these
        // snapshots are created back to back in the test.
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }

    private func makeEngine(
        cloud: InMemoryCloud,
        index: InMemoryIndex,
        snapshotID: String,
        at date: Date
    ) -> CloudFirstBackupEngine {
        CloudFirstBackupEngine(
            masterKey: masterKey,
            deviceID: "device-A",
            index: index,
            sink: cloud,
            options: BackupRunOptions(
                chunker: ChunkerConfig(minSize: 1024, avgSize: 4096, maxSize: 16 * 1024),
                uploadConcurrency: 2,
                packObjectsUpTo: nil
            ),
            clock: { date }
        )
    }

    private func makeSnapshots(
        count: Int,
        cloud: InMemoryCloud,
        index: InMemoryIndex
    ) async throws -> [(id: String, date: Date)] {
        var result: [(String, Date)] = []
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for version in 0..<count {
            let date = start.addingTimeInterval(Double(version) * 86_400)
            try write(version, at: date)
            let id = "snapshot-\(version)"
            let engine = makeEngine(cloud: cloud, index: index, snapshotID: id, at: date)
            let report = try await engine.run(
                projectID: projectID,
                root: root,
                matcher: ExclusionMatcher(rules: []),
                snapshotID: id
            )
            XCTAssertTrue(report.committed)
            result.append((id, date))
        }
        return result
    }

    func testCT163_TombstonesFirstThenSweepsOnlyExpiredUnreferencedData() async throws {
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let snapshots = try await makeSnapshots(count: 5, cloud: cloud, index: index)
        let latestDate = snapshots.last!.date
        let policy = RetentionPolicy(keepLatest: 2, keepDaily: 0, keepWeekly: 0, keepMonthly: 0)
        let collector = CloudGarbageCollector(
            store: cloud,
            masterKey: masterKey,
            deviceID: "device-A",
            index: index,
            gracePeriod: 30 * 86_400,
            clock: { latestDate }
        )

        let objectsBefore = cloud.objects.count
        let nodesBefore = cloud.nodes.count
        let commitsBefore = cloud.commits.count

        let tombstoned = try await collector.createTombstones(
            policies: [projectID: policy],
            now: latestDate
        )
        XCTAssertEqual(tombstoned.retainedSnapshots, 2)
        XCTAssertEqual(tombstoned.expiredSnapshots, 3)
        XCTAssertGreaterThan(tombstoned.orphanObjects, 0)
        XCTAssertGreaterThan(tombstoned.tombstonesPending, 0)
        XCTAssertEqual(cloud.objects.count, objectsBefore, "墓碑阶段不得删除任何对象")
        XCTAssertEqual(cloud.nodes.count, nodesBefore)
        XCTAssertEqual(cloud.commits.count, commitsBefore)

        // Before the grace period expires nothing is deleted.
        let early = try await collector.sweep(policies: [projectID: policy], now: latestDate)
        XCTAssertEqual(early.deletedObjects, 0)
        XCTAssertGreaterThan(early.tombstonesPending, 0)

        // After 31 days the expired versions and their exclusive data are gone.
        let later = latestDate.addingTimeInterval(31 * 86_400)
        let hidden = try await collector.sweep(policies: [projectID: policy], now: later)
        XCTAssertEqual(hidden.epochState, .awaitsHiddenAcks)
        XCTAssertEqual(hidden.deletedSnapshots, 0)
        let swept = try await collector.sweep(policies: [projectID: policy], now: later)
        XCTAssertEqual(swept.deletedSnapshots, 3)
        XCTAssertGreaterThan(swept.deletedObjects, 0)
        XCTAssertEqual(cloud.commits.count, 2, "只保留策略内的提交标记")
        XCTAssertEqual(
            Set(cloud.commits.keys),
            Set(["snapshot-3", "snapshot-4"]),
            "保留的必须是最新两个版本，实际 \(cloud.commits.keys.sorted())"
        )

        // The newest snapshot must still restore bit-for-bit.
        let restore = CloudRestoreEngine(masterKey: masterKey, source: cloud)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("gc-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        _ = try await restore.restore(
            projectID: projectID,
            snapshotID: snapshots.last!.id,
            target: .project,
            destination: destination
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("data.txt")),
            try Data(contentsOf: root.appendingPathComponent("data.txt"))
        )
    }

    func testCT194_SweepRefusesWhileDataIsStagedOrPublishing() async throws {
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        _ = try await makeSnapshots(count: 3, cloud: cloud, index: index)
        try await index.enqueueUploads([
            PendingUploadV3(
                taskID: "object:\(String(repeating: "c", count: 64))",
                objectID: String(repeating: "c", count: 64),
                localPath: "/tmp/pending",
                remotePath: UploadQueue.objectKind,
                fileSize: 128,
                state: .failed
            )
        ])
        let collector = CloudGarbageCollector(
            store: cloud,
            masterKey: masterKey,
            deviceID: "device-A",
            index: index
        )
        do {
            _ = try await collector.sweep(policies: [projectID: .default])
            XCTFail("存在未上传数据时必须拒绝清理")
        } catch let error as V3GCError {
            guard case .unsafe = error else { return XCTFail("期望 unsafe，实际 \(error)") }
        }
    }

    func testCT195_MissingReferencedObjectAbortsBeforeAnyTombstone() async throws {
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        _ = try await makeSnapshots(count: 2, cloud: cloud, index: index)
        let fileNodes = try await index.fileNodes(projectID: projectID)
        let objectID = try XCTUnwrap(fileNodes.flatMap(\.chunks).first?.objectID)
        try await cloud.deleteObject(objectID)

        let collector = CloudGarbageCollector(
            store: cloud,
            masterKey: masterKey,
            deviceID: "device-A",
            index: index
        )
        do {
            _ = try await collector.createTombstones(policies: [projectID: .default])
            XCTFail("引用对象缺失时必须中止")
        } catch let error as V3GCError {
            guard case .unsafe(let reason) = error else { return XCTFail("期望 unsafe") }
            XCTAssertTrue(reason.contains("缺失"), reason)
        }
        XCTAssertTrue(cloud.tombstones.isEmpty, "中止时不得留下墓碑")
    }

    func testCT196_RetentionPlannerKeepsNewestAndBuckets() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let commits = (0..<40).map { index in
            SnapshotCommit(
                snapshotID: "s\(index)",
                projectID: projectID,
                deviceID: "d",
                parentSnapshotID: nil,
                committedAt: now.addingTimeInterval(-Double(index) * 3 * 3600),
                manifestPayloadHash: "hash",
                nodeCount: 1,
                fileCount: 1,
                totalBytes: 1
            )
        }
        let retained = SnapshotRetentionPlanner.retained(
            commits: commits,
            policy: RetentionPolicy(keepLatest: 3, keepDaily: 2, keepWeekly: 1, keepMonthly: 1),
            now: now
        )
        XCTAssertTrue(retained.contains("s0"))
        XCTAssertTrue(retained.contains("s1"))
        XCTAssertTrue(retained.contains("s2"))
        XCTAssertFalse(retained.contains("s39"), "超过窗口的旧版本应被淘汰")
        XCTAssertGreaterThan(retained.count, 3)
    }
}

// MARK: - P0 GC safety (epochs, device acks, fail-closed enumeration)

extension CloudGarbageCollectorTests {
    private func makeCollector(
        _ cloud: InMemoryCloud,
        _ index: InMemoryIndex,
        at date: Date,
        graceDays: Double = 30
    ) -> CloudGarbageCollector {
        CloudGarbageCollector(
            store: cloud,
            masterKey: masterKey,
            deviceID: "device-A",
            index: index,
            gracePeriod: graceDays * 86_400,
            clock: { date }
        )
    }

    func testGCEnumerationFailureAbortsWithoutTombstonesOrDeletion() async throws {
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let snapshots = try await makeSnapshots(count: 4, cloud: cloud, index: index)
        let policy = RetentionPolicy(keepLatest: 2, keepDaily: 0, keepWeekly: 0, keepMonthly: 0)
        let collector = makeCollector(cloud, index, at: snapshots.last!.date)
        cloud.failEnumeration = true
        do {
            _ = try await collector.createTombstones(policies: [projectID: policy])
            XCTFail("枚举失败必须中止 GC")
        } catch {
            // expected
        }
        XCTAssertTrue(cloud.tombstones.isEmpty, "枚举失败不得写墓碑")
        XCTAssertEqual(cloud.commits.count, 4)
        XCTAssertEqual(cloud.objects.count > 0, true)
    }

    func testGCWaitsForEveryActiveDeviceAndOfflineDeviceBlocksDeletion() async throws {
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let snapshots = try await makeSnapshots(count: 4, cloud: cloud, index: index)
        let policy = RetentionPolicy(keepLatest: 2, keepDaily: 0, keepWeekly: 0, keepMonthly: 0)
        let now = snapshots.last!.date
        try await cloud.writeDeviceRecord(GCDeviceRecord(
            deviceID: "device-B", name: "Mac B", createdAt: now, lastSeenAt: now
        ))
        let collector = makeCollector(cloud, index, at: now)
        let planned = try await collector.createTombstones(policies: [projectID: policy])
        XCTAssertEqual(planned.epochState, .awaitsDeviceAcks)
        XCTAssertEqual(planned.awaitingDevices, ["device-B"])

        let later = now.addingTimeInterval(31 * 86_400)
        let blocked = try await collector.sweep(policies: [projectID: policy], now: later)
        XCTAssertEqual(blocked.epochState, .awaitsDeviceAcks)
        XCTAssertEqual(blocked.deletedObjects, 0)
        XCTAssertEqual(blocked.hiddenSnapshots, 0)
        XCTAssertEqual(cloud.commits.count, 4, "未知设备未确认时不得删除任何版本")

        // The other device confirms (barrier + prepared ack); it is not enough to
        // write a bare ack file.
        let collectorB = CloudGarbageCollector(
            store: cloud,
            masterKey: masterKey,
            deviceID: "device-B",
            index: index,
            gracePeriod: 30 * 86_400,
            clock: { later }
        )
        _ = try await collectorB.acknowledgePendingEpochs(now: later)
        let hidden = try await collector.sweep(policies: [projectID: policy], now: later)
        XCTAssertEqual(hidden.epochState, .awaitsHiddenAcks)
        XCTAssertEqual(hidden.awaitingDevices, ["device-B"])
        XCTAssertEqual(cloud.commits.count, 2, "删除前必须等待隐藏确认")

        _ = try await collectorB.acknowledgePendingEpochs(now: later)
        let swept = try await collector.sweep(policies: [projectID: policy], now: later)
        XCTAssertEqual(swept.epochState, .completed)
        XCTAssertEqual(swept.deletedSnapshots, 2)
        XCTAssertEqual(cloud.commits.count, 2)
    }

    func testGCSweepProtectsObjectsReferencedByASnapshotCreatedAfterPlanning() async throws {
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let snapshots = try await makeSnapshots(count: 4, cloud: cloud, index: index)
        let policy = RetentionPolicy(keepLatest: 2, keepDaily: 0, keepWeekly: 0, keepMonthly: 0)
        let now = snapshots.last!.date
        let collector = makeCollector(cloud, index, at: now)
        _ = try await collector.createTombstones(policies: [projectID: policy])

        // Revive the content of the oldest snapshot after the plan was frozen.
        try write(0, at: now.addingTimeInterval(-3 * 86_400))
        let revivedEngine = makeEngine(
            cloud: cloud, index: index, snapshotID: "revived", at: now
        )
        let revived = try await revivedEngine.run(
            projectID: projectID, root: root,
            matcher: ExclusionMatcher(rules: []), snapshotID: "revived"
        )
        XCTAssertTrue(revived.committed)

        let later = now.addingTimeInterval(31 * 86_400)
        _ = try await collector.sweep(policies: [projectID: policy], now: later)

        // The revived snapshot must still restore after GC.
        let restore = CloudRestoreEngine(masterKey: masterKey, source: cloud)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("gc-revive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        _ = try await restore.restore(
            projectID: projectID, snapshotID: "revived",
            target: .project, destination: destination
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("data.txt")),
            try Data(contentsOf: root.appendingPathComponent("data.txt"))
        )
    }

    func testGCDepletionFailureKeepsEpochRetryableAndDataOnDisk() async throws {
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let snapshots = try await makeSnapshots(count: 4, cloud: cloud, index: index)
        let policy = RetentionPolicy(keepLatest: 2, keepDaily: 0, keepWeekly: 0, keepMonthly: 0)
        let now = snapshots.last!.date
        let collector = makeCollector(cloud, index, at: now)
        _ = try await collector.createTombstones(policies: [projectID: policy])
        cloud.failDeletes = true
        let later = now.addingTimeInterval(31 * 86_400)
        let hidden = try await collector.sweep(policies: [projectID: policy], now: later)
        XCTAssertEqual(hidden.epochState, .awaitsHiddenAcks)
        let report = try await collector.sweep(policies: [projectID: policy], now: later)
        XCTAssertEqual(report.epochState, .failed)
        XCTAssertFalse(report.failures.isEmpty)
        XCTAssertEqual(cloud.commits.count, 2, "提交已隐藏，但数据删除失败时 epoch 必须可重试")
        XCTAssertGreaterThan(cloud.objects.count, 0)

        cloud.failDeletes = false
        let retried = try await collector.sweep(policies: [projectID: policy], now: later)
        XCTAssertEqual(retried.epochState, .completed)
    }

    func testGCResumesFromPersistedEpochAfterCrash() async throws {
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let snapshots = try await makeSnapshots(count: 4, cloud: cloud, index: index)
        let policy = RetentionPolicy(keepLatest: 2, keepDaily: 0, keepWeekly: 0, keepMonthly: 0)
        let now = snapshots.last!.date
        let collector = makeCollector(cloud, index, at: now)
        let planned = try await collector.createTombstones(policies: [projectID: policy])
        let epochID = try XCTUnwrap(planned.epochID)

        // Simulate a crash after hiding commits: persist that exact phase.
        var epoch = try XCTUnwrap(cloud.epochs[epochID])
        for snapshot in epoch.candidates.snapshots {
            try await cloud.hideCommit(
                projectID: snapshot.projectID,
                snapshotID: snapshot.snapshotID,
                epochID: epochID
            )
        }
        epoch.state = .commitsHidden
        try await cloud.writeEpoch(epoch)

        let later = now.addingTimeInterval(31 * 86_400)
        _ = try await collector.acknowledgePendingEpochs(now: later)
        let resumed = try await collector.sweep(policies: [projectID: policy], now: later)
        XCTAssertEqual(resumed.epochState, .completed)
        XCTAssertEqual(resumed.deletedSnapshots, 2)
        XCTAssertEqual(cloud.commits.count, 2)
        XCTAssertTrue(cloud.hiddenCommits[epochID]?.isEmpty ?? true)
    }

    func testGCBarrierCreatedWithPreparedAckAndReleasedOnlyAfterCompletion() async throws {
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let snapshots = try await makeSnapshots(count: 4, cloud: cloud, index: index)
        let policy = RetentionPolicy(keepLatest: 2, keepDaily: 0, keepWeekly: 0, keepMonthly: 0)
        let now = snapshots.last!.date
        let collector = makeCollector(cloud, index, at: now)
        let planned = try await collector.createTombstones(policies: [projectID: policy])
        let epochID = try XCTUnwrap(planned.epochID)
        let storedBarrier = try await cloud.deviceBarrier(epochID: epochID, deviceID: "device-A")
        let barrier = try XCTUnwrap(storedBarrier)
        XCTAssertEqual(barrier.phase, .prepared)
        let plannedEpoch = try XCTUnwrap(cloud.epochs[epochID])
        let expiredIDs = plannedEpoch.candidates.snapshots.map(\.snapshotID)
        XCTAssertEqual(Set(barrier.candidateSnapshotIDs), Set(expiredIDs))
        let blockedBefore = try await cloud.blockedSnapshotIDs()
        XCTAssertTrue(blockedBefore.contains(try XCTUnwrap(expiredIDs.first)))

        let later = now.addingTimeInterval(31 * 86_400)
        _ = try await collector.sweep(policies: [projectID: policy], now: later)
        _ = try await collector.sweep(policies: [projectID: policy], now: later)
        let releasedBarrier = try await cloud.deviceBarrier(epochID: epochID, deviceID: "device-A")
        XCTAssertNil(releasedBarrier)
        let blockedAfter = try await cloud.blockedSnapshotIDs()
        XCTAssertTrue(blockedAfter.isEmpty)
    }

    func testGCLegacyEpochWithoutBarrierCannotDelete() async throws {
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        _ = try await makeSnapshots(count: 3, cloud: cloud, index: index)
        let legacy = GCEpoch(
            id: "legacy-epoch",
            initiatorDeviceID: "device-A",
            createdAt: Date(timeIntervalSince1970: 0),
            graceUntil: Date(timeIntervalSince1970: 0),
            state: .gracePeriod,
            candidates: GCCandidateSet(snapshots: [GCSnapshotCandidate(projectID: projectID, snapshotID: "snapshot-0")]),
            retainedSnapshots: [],
            planDigest: "",
            requiredDeviceIDs: ["device-A"],
            acknowledgedBy: ["device-A": Date(timeIntervalSince1970: 0)],
            protocolVersion: 1
        )
        try await cloud.writeEpoch(legacy)
        let collector = makeCollector(cloud, index, at: Date())
        let report = try await collector.sweep(
            policies: [projectID: RetentionPolicy(keepLatest: 2)],
            now: Date(timeIntervalSince1970: 100 * 86_400)
        )
        XCTAssertEqual(report.epochState, .failed)
        XCTAssertEqual(report.deletedSnapshots, 0)
        XCTAssertEqual(cloud.commits.count, 3)
        let legacyBarriers = try await cloud.deviceBarriers(epochID: "legacy-epoch")
        XCTAssertEqual(legacyBarriers.count, 0)
    }

    func testGCAckRefusedWhileLocalWorkIsActive() async throws {
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let snapshots = try await makeSnapshots(count: 4, cloud: cloud, index: index)
        try await cloud.writeDeviceRecord(GCDeviceRecord(
            deviceID: "device-B", name: "Mac B", createdAt: snapshots.last!.date, lastSeenAt: snapshots.last!.date
        ))
        let initiator = makeCollector(cloud, index, at: snapshots.last!.date)
        let planned = try await initiator.createTombstones(
            policies: [projectID: RetentionPolicy(keepLatest: 2)]
        )
        let busy = CloudGarbageCollector(
            store: cloud,
            masterKey: masterKey,
            deviceID: "device-B",
            index: index,
            isSafeToCollect: { false },
            clock: { snapshots.last!.date }
        )
        do {
            _ = try await busy.acknowledgePendingEpochs(now: snapshots.last!.date)
            XCTFail("本机有活动任务时不得写 GC ACK")
        } catch {
            // expected
        }
        let acks = try await cloud.epochAcks(epochID: try XCTUnwrap(planned.epochID))
        XCTAssertNil(acks["device-B"])
        let epochID = try XCTUnwrap(planned.epochID)
        let busyBarrier = try await cloud.deviceBarrier(epochID: epochID, deviceID: "device-B")
        XCTAssertNil(busyBarrier)
    }

}
