import XCTest
import Foundation
@testable import CloudMirrorStore
@testable import SharedModels
@testable import BackupEngine

/// CT-151: Cloud Object Store v3 — publish order, idempotency and the rule that
/// only a committed snapshot is visible.
final class CloudEngineV3StoreTests: XCTestCase {
    private var root: URL!
    private var store: CloudObjectStoreV3!
    private let deviceID = "device-A"
    private let projectID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("v3-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = CloudObjectStoreV3(
            root: root,
            deviceID: deviceID,
            masterKey: Data("store-test-key".utf8)
        )
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func manifestPayload(_ snapshotID: String) -> Data {
        Data("manifest-\(snapshotID)".utf8)
    }

    private func commit(
        snapshotID: String,
        hash: String,
        parent: String? = nil
    ) -> SnapshotCommit {
        SnapshotCommit(
            snapshotID: snapshotID,
            projectID: projectID,
            deviceID: deviceID,
            parentSnapshotID: parent,
            committedAt: Date(timeIntervalSince1970: 1_700_000_000),
            manifestPayloadHash: hash,
            nodeCount: 1,
            fileCount: 1,
            totalBytes: 1
        )
    }

    func testCT151_PrepareIsIdempotentAndNeverReinitialises() async throws {
        let first = try await store.prepare(deviceName: "Mac A", createdAt: Date(timeIntervalSince1970: 100))
        let second = try await store.prepare(deviceName: "Mac B", createdAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(first, second, "已有 format.json 不得被覆盖")
        XCTAssertEqual(first.createdBy, "Mac A")
        let read = try await store.readFormat()
        XCTAssertEqual(read?.format, CloudFormatV3.version)
    }

    func testCT267_FailedObjectUploadIsRewrittenAndConfirmed() async throws {
        let objectID = String(repeating: "ef", count: 32)
        let payload = Data("retry-after-provider-failure".utf8)
        let failedStore = CloudObjectStoreV3(
            root: root,
            deviceID: deviceID,
            masterKey: Data("store-test-key".utf8),
            uploadDispositionOverride: { _ in .failed("provider upload error") }
        )
        let first = try await failedStore.putObject(payload, objectID: objectID)
        XCTAssertTrue(first)
        let location = try await failedStore.ensureObjectReady(
            objectID, payload: payload, storedSize: payload.count
        )
        XCTAssertEqual(location.storedSize, payload.count)
        let readBack = try await failedStore.readObject(objectID)
        XCTAssertEqual(readBack, payload)
    }

    func testCT151_ObjectsAreIdempotentAndReadable() async throws {
        let payload = Data("encrypted-object-bytes".utf8)
        let objectID = String(repeating: "ab", count: 32)

        let before = try await store.hasObject(objectID)
        XCTAssertFalse(before)
        let firstUpload = try await store.putObject(payload, objectID: objectID)
        XCTAssertTrue(firstUpload, "首次写入应真正上传")
        let after = try await store.hasObject(objectID)
        XCTAssertTrue(after)
        let secondUpload = try await store.putObject(payload, objectID: objectID)
        XCTAssertFalse(secondUpload, "重复写入必须幂等")
        let readBack = try await store.readObject(objectID)
        XCTAssertEqual(readBack, payload)

        // Sharded two-character prefix.
        let expected = root
            .appendingPathComponent("devices/\(deviceID)/objects/ab/\(objectID)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))

        do {
            _ = try await store.readObject(String(repeating: "cd", count: 32))
            XCTFail("缺失对象必须报错")
        } catch {
            XCTAssertEqual(error as? CloudObjectStoreV3Error, .objectMissing(String(repeating: "cd", count: 32)))
        }
    }

    func testCT151_NodesAreContentAddressedAndIdempotent() async throws {
        let node = DirectoryNode(
            path: "",
            files: [
                FileNode(path: "a.txt", kind: .file, size: 3, contentHash: "h", chunks: [])
                    .withComputedID()
            ],
            directories: []
        ).withComputedID()

        let first = try await store.putNode(node)
        let second = try await store.putNode(node)
        let read = try await store.readNode(node.nodeID)
        XCTAssertTrue(first)
        XCTAssertFalse(second, "同一节点重复上传必须跳过")
        XCTAssertEqual(read.nodeID, node.nodeID)
        XCTAssertEqual(read.files.count, 1)
        let exists = try await store.hasNode(node.nodeID)
        XCTAssertTrue(exists)
    }

    func testCT151_CommitRequiresManifestAndMatchingHash() async throws {
        let snapshotID = "snap-1"

        // No manifest yet → refuse.
        do {
            try await store.putCommit(commit(snapshotID: snapshotID, hash: "deadbeef"))
            XCTFail("Manifest 不存在时不得发布 Commit")
        } catch {
            XCTAssertEqual(error as? CloudObjectStoreV3Error, .manifestMissing(snapshotID))
        }

        // Publish the manifest, then publish a commit whose hash matches.
        let payload = manifestPayload(snapshotID)
        let hash = try await store.putManifest(payload, projectID: projectID, snapshotID: snapshotID)
        XCTAssertEqual(hash, CanonicalHashing.sha256Hex(payload))
        try await store.putCommit(commit(snapshotID: snapshotID, hash: hash))

        let commits = try await store.commits(projectID: projectID)
        XCTAssertEqual(commits.map(\.snapshotID), [snapshotID])

        // Wrong hash → refuse (the payload on disk is not what was hashed).
        _ = try await store.putManifest(
            manifestPayload("snap-2"), projectID: projectID, snapshotID: "snap-2"
        )
        do {
            try await store.putCommit(commit(snapshotID: "snap-2", hash: "not-the-hash"))
            XCTFail("Manifest 哈希不匹配时必须拒绝")
        } catch {
            XCTAssertEqual(error as? CloudObjectStoreV3Error, .manifestHashMismatch)
        }

        // Wrong device → refuse.
        var foreign = commit(snapshotID: snapshotID, hash: hash)
        foreign.deviceID = "device-B"
        do {
            try await store.putCommit(foreign)
            XCTFail("设备命名空间不匹配时必须拒绝")
        } catch {
            XCTAssertEqual(
                error as? CloudObjectStoreV3Error,
                .deviceMismatch(expected: deviceID, found: "device-B")
            )
        }
    }

    func testCT151_OnlyCommittedSnapshotsAreVisible() async throws {
        // A snapshot that uploaded objects + manifest but died before the commit
        // must be invisible to readers.
        let halfDone = "snap-incomplete"
        _ = try await store.putManifest(
            manifestPayload(halfDone), projectID: projectID, snapshotID: halfDone
        )
        let empty = try await store.commits(projectID: projectID)
        XCTAssertTrue(empty.isEmpty, "未发布 Commit 的版本不可见")

        // A complete one becomes visible.
        let done = "snap-complete"
        let hash = try await store.putManifest(
            manifestPayload(done), projectID: projectID, snapshotID: done
        )
        try await store.putCommit(commit(snapshotID: done, hash: hash))
        let visible = try await store.commits(projectID: projectID)
        XCTAssertEqual(visible.map(\.snapshotID), [done])
        let halfCommit = try await store.readCommit(projectID: projectID, snapshotID: halfDone)
        XCTAssertNil(halfCommit)
        let fullCommit = try await store.readCommit(projectID: projectID, snapshotID: done)
        XCTAssertNotNil(fullCommit)
    }

    func testCT151_PacksRoundTrip() async throws {
        let packID = "pack-0001"
        let payload = Data(repeating: 0x7F, count: 4096)
        let first = try await store.putPack(payload, packID: packID)
        let second = try await store.putPack(payload, packID: packID)
        let read = try await store.readPack(packID)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(read, payload)
    }

    func testCT215_SameObjectIDWithDifferentRandomNonceIsReusedByEncryptedIdentity() async throws {
        let encoder = ObjectEncoder(masterKey: Data("store-test-key".utf8))
        let plaintext = Data("same plaintext, two nonces".utf8)
        let objectID = encoder.objectID(for: plaintext)
        let first = try encoder.encode(chunk: plaintext).payload
        let second = try encoder.encode(chunk: plaintext).payload
        XCTAssertNotEqual(first, second, "随机 nonce 必须让同一明文的密文不同")

        let firstUpload = try await store.putObject(first, objectID: objectID)
        XCTAssertTrue(firstUpload)
        let secondUpload = try await store.putObject(second, objectID: objectID)
        XCTAssertFalse(secondUpload, "密文不同但 Object ID 相同时必须复用")
        let read = try await store.readObject(objectID)
        XCTAssertEqual(read, first, "不得用第二个随机密文覆盖已有对象")

        let validating = CloudObjectStoreV3(
            root: root.appendingPathComponent("validating", isDirectory: true),
            deviceID: deviceID,
            masterKey: Data("store-test-key".utf8),
            objectValidator: { payload, id in
                (try? encoder.decode(payload, objectID: id)) != nil
            }
        )
        try await validating.prepare(deviceName: "Mac A")
        let validatingUpload = try await validating.putObject(first, objectID: objectID)
        XCTAssertTrue(validatingUpload)
        let url = root.appendingPathComponent("validating/devices/\(deviceID)/objects/\(objectID.prefix(2))/\(objectID)")
        try Data("corrupted".utf8).write(to: url)
        do {
            _ = try await validating.putObject(second, objectID: objectID)
            XCTFail("损坏的已有对象必须被拒绝，不能静默覆盖")
        } catch let error as CloudObjectStoreV3Error {
            XCTAssertEqual(error, .objectCorrupted(objectID))
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("corrupted".utf8), "修复前不得覆盖损坏字节")
    }
}
