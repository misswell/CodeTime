import XCTest
import Foundation
@testable import SharedModels
@testable import CloudMirrorStore

/// Permanent regressions CT-001 … CT-012 from the reliability task book.
/// Each test fails loudly if the corresponding safety invariant is weakened.
final class CloudMirrorRegressionTests: XCTestCase {
    private func makeCloud(_ name: String) throws -> RegressionCloud {
        try RegressionCloud(name: name)
    }

    // CT-001: 一个无法读取的清单必须中止整个 GC，不能按“可见清单”继续删除。
    func testCT001_UnreadableManifestAbortsCleanup() async throws {
        let cloud = try makeCloud("ct001")
        defer { cloud.cleanup() }
        let device = UUID()
        let store = cloud.store(deviceID: device, sweepGrace: 0)

        try cloud.workspace.writeFile("a.txt", "v1")
        _ = try await cloud.publish(store, deviceID: device, createdAt: Date().addingTimeInterval(-300))
        try cloud.workspace.writeFile("a.txt", "v2")
        _ = try await cloud.publish(store, deviceID: device, createdAt: Date().addingTimeInterval(-200))
        try cloud.workspace.writeFile("a.txt", "v3")
        _ = try await cloud.publish(store, deviceID: device, createdAt: Date().addingTimeInterval(-100))

        let corrupt = cloud.workspace.commitsDirectory(deviceID: device, repositoryID: cloud.repositoryID)
            .appendingPathComponent("\(UUID().uuidString).ctm")
        try Data("this-is-not-a-sealed-manifest".utf8).write(to: corrupt)

        let objectsBefore = try cloud.workspace.objectFiles(deviceID: device, repositoryID: cloud.repositoryID)
            .map(\.lastPathComponent)
        let report = try await store.cleanup(
            repositoryId: cloud.repositoryID,
            gracePeriod: 0,
            minimumGenerations: 1
        )

        XCTAssertNotNil(report.skippedReason, "存在不可读清单时清理必须暂停")
        XCTAssertEqual(report.deletedObjects, 0)
        XCTAssertEqual(
            try cloud.workspace.objectFiles(deviceID: device, repositoryID: cloud.repositoryID).map(\.lastPathComponent),
            objectsBefore,
            "中止的清理不得删除任何对象"
        )
        XCTAssertEqual(
            try cloud.workspace.commitFiles(deviceID: device, repositoryID: cloud.repositoryID).count,
            4,
            "所有原清单都必须保留"
        )
    }

    // CT-002: GC 在 tombstone 与 sweep 之间被终止后，下一次运行必须能继续并完成。
    func testCT002_InterruptedGarbageCollectionResumes() async throws {
        let cloud = try makeCloud("ct002")
        defer { cloud.cleanup() }
        let device = UUID()
        let journals = MemoryJournalStore()
        let first = cloud.store(deviceID: device, journalStore: journals, sweepGrace: 3_600)

        try cloud.workspace.writeFile("a.txt", "v1")
        let g1 = try await cloud.publish(first, deviceID: device, createdAt: Date().addingTimeInterval(-300))
        try cloud.workspace.writeFile("a.txt", "v2")
        _ = try await cloud.publish(first, deviceID: device, createdAt: Date().addingTimeInterval(-200))
        try cloud.workspace.writeFile("a.txt", "v3")
        _ = try await cloud.publish(first, deviceID: device, createdAt: Date().addingTimeInterval(-100))

        let v1Object = cloud.workspace.objectURL(
            deviceID: device,
            repositoryID: cloud.repositoryID,
            hash: sha256Hex("v1")
        )
        let v2Object = cloud.workspace.objectURL(
            deviceID: device,
            repositoryID: cloud.repositoryID,
            hash: sha256Hex("v2")
        )
        let v3Object = cloud.workspace.objectURL(
            deviceID: device,
            repositoryID: cloud.repositoryID,
            hash: sha256Hex("v3")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: v1Object.path))

        let paused = try await first.cleanup(
            repositoryId: cloud.repositoryID,
            gracePeriod: 0,
            minimumGenerations: 1
        )
        XCTAssertNotNil(paused.skippedReason)
        XCTAssertEqual(journals.latest(repositoryID: cloud.repositoryID)?.phase, .gracePeriod)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: cloud.workspace.commitURL(
                    deviceID: device,
                    repositoryID: cloud.repositoryID,
                    generationID: g1
                ).path
            ),
            "旧清单必须已进入 tombstone"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: v1Object.path), "宽限期内对象必须保留")

        // Simulated restart with an elapsed grace period.
        journals.fastForwardGraceDeadline = true
        let second = cloud.store(deviceID: device, journalStore: journals, sweepGrace: 0)
        let resumed = try await second.cleanup(
            repositoryId: cloud.repositoryID,
            gracePeriod: 0,
            minimumGenerations: 1
        )

        XCTAssertNil(resumed.skippedReason)
        XCTAssertGreaterThanOrEqual(resumed.deletedObjects, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: v1Object.path), "旧对象应在宽限后清扫")
        XCTAssertTrue(FileManager.default.fileExists(atPath: v2Object.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: v3Object.path))
        XCTAssertEqual(journals.latest(repositoryID: cloud.repositoryID)?.phase, .completed)
    }

    // CT-003: 清单删除必须等待同步与宽限期，不能与删除动作同时发生。
    func testCT003_ManifestDeletionWaitsForGrace() async throws {
        let cloud = try makeCloud("ct003")
        defer { cloud.cleanup() }
        let device = UUID()
        let journals = MemoryJournalStore()
        let store = cloud.store(deviceID: device, journalStore: journals, sweepGrace: 3_600)

        try cloud.workspace.writeFile("a.txt", "old")
        let oldGeneration = try await cloud.publish(store, deviceID: device, createdAt: Date().addingTimeInterval(-300))
        try cloud.workspace.writeFile("a.txt", "mid")
        _ = try await cloud.publish(store, deviceID: device, createdAt: Date().addingTimeInterval(-200))
        try cloud.workspace.writeFile("a.txt", "new")
        _ = try await cloud.publish(store, deviceID: device, createdAt: Date().addingTimeInterval(-100))

        let oldObject = cloud.workspace.objectURL(
            deviceID: device,
            repositoryID: cloud.repositoryID,
            hash: sha256Hex("old")
        )
        let report = try await store.cleanup(
            repositoryId: cloud.repositoryID,
            gracePeriod: 0,
            minimumGenerations: 1
        )

        XCTAssertTrue(report.skippedReason?.contains("宽限期") ?? false, "首次清理必须停在宽限期")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: cloud.workspace.commitURL(
                    deviceID: device,
                    repositoryID: cloud.repositoryID,
                    generationID: oldGeneration
                ).path
            )
        )
        XCTAssertEqual(
            try cloud.workspace.tombstoneURLs(deviceID: device, repositoryID: cloud.repositoryID).count,
            1,
            "旧清单必须以 tombstone 形式保留删除意图"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: oldObject.path),
            "宽限期内对象不可删除，避免其他设备上传中被截断"
        )
    }

    // CT-004: 同大小、不同内容的对象必须在 SHA-256 校验中失败，而不是按大小通过。
    func testCT004_SameSizeDifferentContentFailsVerification() async throws {
        let cloud = try makeCloud("ct004")
        defer { cloud.cleanup() }
        let device = UUID()
        let store = cloud.store(deviceID: device)

        try cloud.workspace.writeFile("a.txt", "AAAA")
        let generation = try await cloud.publish(store, deviceID: device)

        let object = cloud.workspace.objectURL(
            deviceID: device,
            repositoryID: cloud.repositoryID,
            hash: sha256Hex("AAAA")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: object.path))
        // Same byte count, different content.
        try Data("BBBB".utf8).write(to: object)

        let result = try await store.verifyGeneration(generation)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.details.contains("校验失败"))

        let entries = try await store.listGenerationEntries(repositoryId: cloud.repositoryID)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(
            entries.first?.readState,
            .valid,
            "清单本身仍可读；损坏的是对象，必须如实报告在对象校验里"
        )
    }

    // CT-005: 上传未确认时禁止产生 generation 提交点。
    func testCT005_UnconfirmedUploadProducesNoGeneration() async throws {
        let cloud = try makeCloud("ct005")
        defer { cloud.cleanup() }
        let device = UUID()
        let tracker = SwitchableUploadTracker(failEverything: true)
        let store = cloud.store(deviceID: device, tracker: tracker)

        try cloud.workspace.writeFile("a.txt", "offline")
        await assertThrowsAsync(try await cloud.publish(store, deviceID: device)) { error in
            guard let storeError = error as? CloudStoreError, case .uploadNotConfirmed = storeError else {
                return XCTFail("应报告上传未确认，实际：\(error)")
            }
        }

        XCTAssertTrue(
            try cloud.workspace.commitFiles(deviceID: device, repositoryID: cloud.repositoryID).isEmpty,
            "失败的发布不能留下清单"
        )
        let generations = try await store.listGenerations(repositoryId: cloud.repositoryID)
        XCTAssertTrue(generations.isEmpty)
    }

    // CT-006: iCloud 元数据读取失败必须 fail-closed，不能被当成“已上传”。
    func testCT006_MetadataFailureIsNotTreatedAsUploaded() async throws {
        let directory = try makeEnvironmentFile("local.txt", contents: "local")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tracker = UbiquitousUploadTracker()

        await assertThrowsAsync(
            try await tracker.waitForUpload(directory.appendingPathComponent("local.txt"), timeout: 0.5)
        ) { error in
            guard let storeError = error as? CloudStoreError, case .notICloudItem = storeError else {
                return XCTFail("本地文件必须被明确拒绝，实际：\(error)")
            }
        }

        await assertThrowsAsync(
            try await tracker.waitForUpload(directory.appendingPathComponent("missing.txt"), timeout: 0.5)
        ) { error in
            guard let storeError = error as? CloudStoreError, case .metadataUnavailable = storeError else {
                return XCTFail("元数据读取失败必须显式报错，实际：\(error)")
            }
        }
    }

    // CT-007: 不可读取的 iCloud 文件不能被视为“不存在”，恢复必须报错。
    func testCT007_UnreadableCloudFileFailsClosed() async throws {
        let directory = try makeEnvironmentFile("placeholder", contents: "x")
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("not-downloaded.ctm")

        switch UbiquitousFiles.state(of: missing) {
        case .unavailable:
            break
        default:
            XCTFail("缺失文件的元数据读取必须落到 unavailable")
        }

        await assertThrowsAsync(
            try await UbiquitousFiles.ensureDownloaded(missing, timeout: 0.1)
        ) { error in
            guard let storeError = error as? CloudStoreError, case .metadataUnavailable = storeError else {
                return XCTFail("不可读文件必须显式报错，实际：\(error)")
            }
        }
    }

    // CT-008: 两个进程并发上传同一对象时，对象只保留一份且两份清单都有效。
    func testCT008_ConcurrentPublisherOfSameObjectKeepsOneVerifiedCopy() async throws {
        let cloud = try makeCloud("ct008")
        defer { cloud.cleanup() }
        let device = UUID()
        let lockURL = cloud.workspace.root.appendingPathComponent("cloud.lock")
        let first = cloud.store(deviceID: device, lockURL: lockURL)
        let second = cloud.store(deviceID: device, lockURL: lockURL)

        try cloud.workspace.writeFile("a.txt", "shared-body")

        async let a = cloud.publish(first, deviceID: device)
        async let b = cloud.publish(second, deviceID: device)
        let generations = try await [a, b]

        XCTAssertEqual(Set(generations).count, 2)
        let objects = try cloud.workspace.objectFiles(deviceID: device, repositoryID: cloud.repositoryID)
        XCTAssertEqual(objects.count, 1, "相同内容只应有一个对象")
        XCTAssertEqual(
            try cloud.workspace.commitFiles(deviceID: device, repositoryID: cloud.repositoryID).count,
            2
        )
        for generation in generations {
            let verification = try await first.verifyGeneration(generation)
            XCTAssertEqual(verification.outcome, .passed)
        }
    }

    // CT-009: 新版本清单发布失败时，旧版本必须保持可读、可校验。
    func testCT009_FailedManifestPublishLeavesOldGenerationIntact() async throws {
        let cloud = try makeCloud("ct009")
        defer { cloud.cleanup() }
        let device = UUID()
        let tracker = SwitchableUploadTracker()
        let store = cloud.store(deviceID: device, tracker: tracker)

        try cloud.workspace.writeFile("a.txt", "v1")
        let first = try await cloud.publish(store, deviceID: device)

        try cloud.workspace.writeFile("a.txt", "v2")
        await tracker.block("/commits/")
        await assertThrowsAsync(try await cloud.publish(store, deviceID: device)) { error in
            guard let storeError = error as? CloudStoreError, case .uploadNotConfirmed = storeError else {
                return XCTFail("应报告清单上传未确认，实际：\(error)")
            }
        }

        let commitFiles = try cloud.workspace.commitFiles(deviceID: device, repositoryID: cloud.repositoryID)
        XCTAssertEqual(commitFiles.count, 1)
        let listed = try await store.listGenerations(repositoryId: cloud.repositoryID)
        XCTAssertEqual(listed.map(\.id), [first])
        let verification = try await store.verifyGeneration(first)
        XCTAssertEqual(verification.outcome, .passed)
    }

    // CT-010: 失效的哈希缓存必须重新计算，不能把旧哈希写进新清单。
    func testCT010_InvalidHashCacheIsRecomputed() async throws {
        let cloud = try makeCloud("ct010")
        defer { cloud.cleanup() }
        let device = UUID()
        let cache = MemoryHashCacheStore()
        let store = cloud.store(deviceID: device, hashCacheStore: cache)
        let body = "cache-body-\(UUID().uuidString)"
        let realHash = sha256Hex(body)

        try cloud.workspace.writeFile("a.txt", body)
        cache.seed(ObjectHashCacheEntry(
            relativePath: "a.txt",
            fileIdentity: "0:0",
            size: Int64(body.utf8.count),
            modifiedAt: .distantPast,
            contentHash: String(repeating: "0", count: 64)
        ))

        let generation = try await cloud.publish(store, deviceID: device)

        let object = cloud.workspace.objectURL(deviceID: device, repositoryID: cloud.repositoryID, hash: realHash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: object.path), "必须按真实内容写入对象")
        XCTAssertEqual(cache.entry("a.txt")?.contentHash, realHash, "缓存必须被正确结果替换")
        let verification = try await store.verifyGeneration(generation)
        XCTAssertEqual(verification.outcome, .passed)
    }

    // CT-011: 多设备同时上传时，两台设备都必须出现在恢复候选中。
    func testCT011_TwoDevicesPublishIndependentGenerations() async throws {
        let cloud = try makeCloud("ct011")
        defer { cloud.cleanup() }
        let deviceA = UUID()
        let deviceB = UUID()
        let storeA = cloud.store(deviceID: deviceA)
        let storeB = cloud.store(deviceID: deviceB)

        try cloud.workspace.writeFile("a.txt", "from-a")
        let generationA = try await cloud.publish(storeA, deviceID: deviceA)
        try cloud.workspace.writeFile("a.txt", "from-b")
        let generationB = try await cloud.publish(storeB, deviceID: deviceB)

        let candidates = try await CloudMirrorStore.recoverCandidates(
            storageRoot: cloud.workspace.storageRoot,
            recoveryKey: cloud.masterKey
        )
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(Set(candidates.map(\.deviceID)), [deviceA, deviceB])
        XCTAssertTrue(candidates.allSatisfy(\.isRestorable))
        XCTAssertEqual(
            Set(candidates.compactMap(\.latestGenerationID)),
            [generationA, generationB]
        )
    }

    // CT-012: GC 宽限期内产生的新版本必须被重新验证并保留。
    func testCT012_NewGenerationDuringCleanupIsPreserved() async throws {
        let cloud = try makeCloud("ct012")
        defer { cloud.cleanup() }
        let device = UUID()
        let journals = MemoryJournalStore()
        let store = cloud.store(deviceID: device, journalStore: journals, sweepGrace: 3_600)

        try cloud.workspace.writeFile("a.txt", "v1")
        _ = try await cloud.publish(store, deviceID: device, createdAt: Date().addingTimeInterval(-300))
        try cloud.workspace.writeFile("a.txt", "v2")
        _ = try await cloud.publish(store, deviceID: device, createdAt: Date().addingTimeInterval(-200))
        try cloud.workspace.writeFile("a.txt", "v3")
        _ = try await cloud.publish(store, deviceID: device, createdAt: Date().addingTimeInterval(-100))

        _ = try await store.cleanup(repositoryId: cloud.repositoryID, gracePeriod: 0, minimumGenerations: 1)

        // A new snapshot arrives while GC is in its grace period.
        try cloud.workspace.writeFile("a.txt", "v4")
        let latest = try await cloud.publish(store, deviceID: device, createdAt: Date())

        journals.fastForwardGraceDeadline = true
        let resumer = cloud.store(deviceID: device, journalStore: journals, sweepGrace: 0)
        _ = try await resumer.cleanup(repositoryId: cloud.repositoryID, gracePeriod: 0, minimumGenerations: 1)

        let verification = try await resumer.verifyGeneration(latest)
        XCTAssertEqual(verification.outcome, .passed, "清理期间产生的新版本不能被清扫")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloud.workspace.objectURL(
            deviceID: device,
            repositoryID: cloud.repositoryID,
            hash: sha256Hex("v4")
        ).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloud.workspace.objectURL(
            deviceID: device,
            repositoryID: cloud.repositoryID,
            hash: sha256Hex("v1")
        ).path))
    }
}
