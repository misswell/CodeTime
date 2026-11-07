import XCTest
import Foundation
@testable import SharedModels
@testable import CloudMirrorStore
@testable import Persistence

/// Permanent regressions CT-013 … CT-020 (cloud restore and recovery).
final class RecoveryRegressionTests: XCTestCase {
    private func makeCloud(_ name: String) throws -> RegressionCloud {
        try RegressionCloud(name: name)
    }

    private func seedRepository(_ workspace: RegressionWorkspace) throws {
        try workspace.writeFile("a.txt", "alpha")
        try workspace.writeFile("b.txt", "bravo")
        try workspace.writeFile("c.txt", "charlie")
    }

    // CT-013: 中断的恢复必须复用已校验文件，只补齐缺失部分。
    func testCT013_InterruptedRestoreResumesVerifiedObjects() async throws {
        let cloud = try makeCloud("ct013")
        defer { cloud.cleanup() }
        let device = UUID()
        let store = cloud.store(deviceID: device)
        try seedRepository(cloud.workspace)
        let generation = try await cloud.publish(store, deviceID: device)

        let complete = cloud.workspace.root.appendingPathComponent("complete", isDirectory: true)
        try await store.restoreRepository(generationId: generation, destination: complete)

        let partial = cloud.workspace.root.appendingPathComponent("partial", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: complete.appendingPathComponent("a.txt"),
            to: partial.appendingPathComponent("a.txt")
        )
        // Simulate an interrupted write that left a damaged file behind.
        try "wrong".write(to: partial.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        // A damaged target file must be replaced automatically; the user must not
        // have to delete internal staging files by hand.
        let recorder = ProgressRecorder()
        try await store.restoreRepository(
            generationId: generation,
            destination: partial,
            allowResume: true,
            progress: { progress in await recorder.record(progress) }
        )

        XCTAssertEqual(try String(contentsOf: partial.appendingPathComponent("a.txt"), encoding: .utf8), "alpha")
        XCTAssertEqual(try String(contentsOf: partial.appendingPathComponent("b.txt"), encoding: .utf8), "bravo")
        XCTAssertEqual(try String(contentsOf: partial.appendingPathComponent("c.txt"), encoding: .utf8), "charlie")
        let counts = await recorder.values()
        XCTAssertTrue(counts.contains(1), "恢复应从已校验的 a.txt 继续：\(counts)")
        let maximum = await recorder.maximum()
        XCTAssertEqual(maximum, 3)
    }

    // CT-014: 恢复过程中拷贝失败时，正式仓库必须保持原样。
    func testCT014_RestoreCopyFailureLeavesRepositoryUntouched() async throws {
        let cloud = try makeCloud("ct014")
        defer { cloud.cleanup() }
        let device = UUID()
        let store = cloud.store(deviceID: device)
        try cloud.workspace.writeFile("a.txt", "alpha")
        try cloud.workspace.writeFile("sub/c.txt", "nested")
        let generation = try await cloud.publish(store, deviceID: device)

        let destination = cloud.workspace.root.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        // A regular file where the manifest needs a directory forces the copy to fail.
        try "blocker".write(to: destination.appendingPathComponent("sub"), atomically: true, encoding: .utf8)

        await assertThrowsAsync(
            try await store.restoreRepository(generationId: generation, destination: destination, allowResume: true)
        )

        XCTAssertEqual(
            try String(contentsOf: cloud.workspace.repositoryURL.appendingPathComponent("a.txt"), encoding: .utf8),
            "alpha",
            "失败的恢复不得改写本地仓库"
        )
        let verification = try await store.verifyGeneration(generation)
        XCTAssertEqual(verification.outcome, .passed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("sub/c.txt").path))
    }

    // CT-015: 对象哈希不匹配时必须让恢复失败，不能把损坏内容写进目标目录。
    func testCT015_RestoreFailsOnObjectHashMismatch() async throws {
        let cloud = try makeCloud("ct015")
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
        try Data("BBBB".utf8).write(to: object)

        let destination = cloud.workspace.root.appendingPathComponent("restored", isDirectory: true)
        await assertThrowsAsync(
            try await store.restoreRepository(generationId: generation, destination: destination)
        ) { error in
            guard let storeError = error as? CloudStoreError else {
                return XCTFail("应报告对象校验失败，实际：\(error)")
            }
            switch storeError {
            case .objectCorrupt, .objectMissing:
                break
            default:
                XCTFail("应报告对象损坏，实际：\(storeError)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("a.txt").path))
    }

    // CT-016: 多设备恢复候选必须逐个校验，密钥不匹配的设备要被明确标记。
    func testCT016_MultiDeviceCandidatesReportKeyMismatch() async throws {
        let cloud = try makeCloud("ct016")
        defer { cloud.cleanup() }
        let deviceA = UUID()
        let deviceB = UUID()
        let keyB = Data((0..<32).map { UInt8(200 - $0) })
        let storeA = cloud.store(deviceID: deviceA)
        let storeB = cloud.store(deviceID: deviceB, masterKey: keyB, password: "password-b")

        try cloud.workspace.writeFile("a.txt", "from-a")
        _ = try await cloud.publish(storeA, deviceID: deviceA)
        try cloud.workspace.writeFile("a.txt", "from-b")
        _ = try await cloud.publish(storeB, deviceID: deviceB)

        let candidates = try await CloudMirrorStore.recoverCandidates(
            storageRoot: cloud.workspace.storageRoot,
            recoveryKey: cloud.masterKey
        )
        XCTAssertEqual(candidates.count, 2)
        let restorable = candidates.filter(\.isRestorable)
        XCTAssertEqual(restorable.count, 1)
        XCTAssertEqual(restorable.first?.deviceID, deviceA)

        let blocked = candidates.first { $0.deviceID == deviceB }
        XCTAssertEqual(blocked?.blockedReason, "恢复密钥与该设备不匹配")
        XCTAssertFalse(blocked?.isRestorable ?? true)
    }

    // CT-017: 第一个凭据密钥不匹配时，恢复必须继续尝试后续设备。
    func testCT017_MismatchedFirstCandidateDoesNotAbortRecovery() async throws {
        let cloud = try makeCloud("ct017")
        defer { cloud.cleanup() }
        let deviceA = UUID()
        let deviceB = UUID()
        let keyA = cloud.masterKey
        let keyB = Data((0..<32).map { UInt8(200 - $0) })
        let storeA = cloud.store(deviceID: deviceA)
        let storeB = cloud.store(deviceID: deviceB, masterKey: keyB, password: "password-b")

        try cloud.workspace.writeFile("a.txt", "from-a")
        _ = try await cloud.publish(storeA, deviceID: deviceA)
        try cloud.workspace.writeFile("a.txt", "from-b")
        _ = try await cloud.publish(storeB, deviceID: deviceB)

        let recovered = try await CloudMirrorStore.recover(
            storageRoot: cloud.workspace.storageRoot,
            recoveryKey: keyB
        )
        XCTAssertEqual(recovered.repositoryPassword, "password-b")
        XCTAssertEqual(recovered.deviceID, deviceB)

        let recoveredA = try await CloudMirrorStore.recover(
            storageRoot: cloud.workspace.storageRoot,
            recoveryKey: keyA
        )
        XCTAssertEqual(recoveredA.repositoryPassword, cloud.password)
        XCTAssertEqual(recoveredA.deviceID, deviceA)
    }

    // CT-018: 恢复报告只有在仓库与快照检查都通过时才算成功。
    func testCT018_RestoreReportRequiresRepositoryAndSnapshotChecks() {
        let base = RestoreReport(
            repositoryID: UUID(),
            sourceGenerationID: UUID(),
            totalObjects: 3,
            verifiedObjects: 3,
            repositoryCheck: true,
            snapshotCheck: true,
            result: .passed
        )
        XCTAssertTrue(base.isSuccessful)

        var missingRepository = base
        missingRepository.repositoryCheck = false
        XCTAssertFalse(missingRepository.isSuccessful, "缺少 Kopia 仓库检查不能算成功")

        var missingSnapshot = base
        missingSnapshot.snapshotCheck = false
        XCTAssertFalse(missingSnapshot.isSuccessful, "缺少快照检查不能算成功")

        var failedObject = base
        failedObject.failedObjects = ["abc"]
        XCTAssertFalse(failedObject.isSuccessful)

        var empty = base
        empty.totalObjects = 0
        empty.verifiedObjects = 0
        XCTAssertFalse(empty.isSuccessful)
    }

    // CT-019: 崩溃后云端恢复任务必须可从数据库续传，完成状态则不得被再次拾取。
    func testCT019_CloudRestoreJobSurvivesRestart() async throws {
        let workspace = try RegressionWorkspace(name: "ct019")
        defer { workspace.cleanup() }
        let databaseURL = workspace.root.appendingPathComponent("database.sqlite")

        let repositoryID = UUID()
        let generationID = UUID()
        let job = CloudRestoreJob(
            repositoryID: repositoryID,
            generationID: generationID,
            sourceDeviceID: UUID(),
            state: .downloading,
            stagingPath: workspace.root.appendingPathComponent("staging").path,
            totalFiles: 5,
            completedFiles: 2,
            totalBytes: 500,
            completedBytes: 200,
            verifiedHashes: ["aaa", "bbb"]
        )

        let first = try SQLiteStore(path: databaseURL.path)
        try await first.upsertCloudRestoreJob(job)
        await first.close()

        let reopened = try SQLiteStore(path: databaseURL.path)
        let resumed = try await reopened.resumableCloudRestore(repositoryID: repositoryID, generationID: generationID)
        XCTAssertEqual(resumed?.id, job.id)
        XCTAssertEqual(resumed?.completedFiles, 2)
        XCTAssertEqual(resumed?.verifiedHashes, ["aaa", "bbb"])

        var completed = job
        completed.state = .completed
        try await reopened.upsertCloudRestoreJob(completed)
        let afterCompletion = try await reopened.resumableCloudRestore(
            repositoryID: repositoryID,
            generationID: generationID
        )
        XCTAssertNil(afterCompletion)
        var interrupted = completed
        interrupted.state = .interrupted
        try await reopened.upsertCloudRestoreJob(interrupted)
        let afterInterrupt = try await reopened.resumableCloudRestore(
            repositoryID: repositoryID,
            generationID: generationID
        )
        XCTAssertNotNil(afterInterrupt)
    }

    // CT-020: 对同一目标重复恢复必须安全；不允许静默覆盖已存在内容。
    func testCT020_DuplicateRestoreIsSafe() async throws {
        let cloud = try makeCloud("ct020")
        defer { cloud.cleanup() }
        let device = UUID()
        let store = cloud.store(deviceID: device)
        try seedRepository(cloud.workspace)
        let generation = try await cloud.publish(store, deviceID: device)

        let destination = cloud.workspace.root.appendingPathComponent("twice", isDirectory: true)
        try await store.restoreRepository(generationId: generation, destination: destination)

        await assertThrowsAsync(
            try await store.restoreRepository(generationId: generation, destination: destination)
        ) { error in
            guard let code = error as? CodeTimeError, case .destinationExists = code else {
                return XCTFail("重复恢复必须拒绝覆盖，实际：\(error)")
            }
        }
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("b.txt"), encoding: .utf8),
            "bravo"
        )

        try await store.restoreRepository(generationId: generation, destination: destination, allowResume: true)
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("c.txt"), encoding: .utf8),
            "charlie"
        )
    }
}
