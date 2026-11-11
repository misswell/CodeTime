import XCTest
import Foundation
@testable import CloudMirrorStore
@testable import SharedModels
@testable import CodeTimeSecurity
@testable import BackupEngine

/// CT-172: every metadata write uses the same confirm → verify → evict path.
final class CloudAccessCoordinatorTests: XCTestCase {
    private var workspace: URL!
    private let masterKey = Data("coordinator-key".utf8)
    private let projectID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        try super.tearDownWithError()
    }

    final class RecordingProbe: UbiquitousItemProbing, @unchecked Sendable {
        var evicted: [URL] = []
        var uploaded = true
        private let lock = NSLock()

        func isUploaded(_ url: URL) async -> Bool {
            lock.lock(); defer { lock.unlock() }
            return uploaded
        }

        func evict(_ url: URL) async throws {
            lock.lock(); defer { lock.unlock() }
            evicted.append(url)
        }

        func isUbiquitous(_ url: URL) async -> Bool { true }

        func snapshot() -> [URL] {
            lock.lock(); defer { lock.unlock() }
            return evicted
        }
    }

    func testCT175_HashMismatchPreventsEviction() async throws {
        let probe = RecordingProbe()
        let coordinator = CloudAccessCoordinator(
            access: LocalFileAccess(),
            tracker: NoopUploadTracker(),
            eviction: ICloudEvictionManager(probe: probe)
        )
        let url = workspace.appendingPathComponent("metadata.bin")
        let bytes = Data("confirmed bytes".utf8)
        try bytes.write(to: url)

        do {
            try await coordinator.confirmAndRelease(
                url: url,
                expectedHash: CanonicalHashing.sha256Hex(Data("different".utf8))
            )
            XCTFail("哈希不一致时不得释放本地副本")
        } catch {
            // expected
        }
        XCTAssertTrue(probe.snapshot().isEmpty)

        try await coordinator.confirmAndRelease(
            url: url,
            expectedHash: CanonicalHashing.sha256Hex(bytes)
        )
        XCTAssertEqual(probe.snapshot(), [url])
    }

    func testCT176_NodesManifestsAndCommitsAllEvictAfterConfirmation() async throws {
        let probe = RecordingProbe()
        let eviction = ICloudEvictionManager(probe: probe)
        let store = CloudObjectStoreV3(
            root: workspace.appendingPathComponent("v3", isDirectory: true),
            deviceID: "device-A",
            masterKey: masterKey,
            eviction: eviction
        )
        try await store.prepare(deviceName: "Mac A")

        let tree = MerkleTreeBuilder().build(files: [])
        _ = try await store.putNode(tree.root)

        let snapshotID = "snap-evict"
        let manifest = Data("sealed-manifest".utf8)
        let manifestHash = try await store.putManifest(
            manifest, projectID: projectID, snapshotID: snapshotID
        )
        let commit = SnapshotCommit(
            snapshotID: snapshotID,
            projectID: projectID,
            deviceID: "device-A",
            parentSnapshotID: nil,
            committedAt: Date(),
            manifestPayloadHash: manifestHash,
            nodeCount: 1,
            fileCount: 0,
            totalBytes: 0,
            formatVersion: CloudFormatV3.version
        )
        try await store.putCommit(commit)

        let evictedPaths = Set(probe.snapshot().map(\.path))
        XCTAssertTrue(
            evictedPaths.contains(store.layout.nodeURL(tree.root.nodeID).path),
            "节点上传确认后必须释放本地副本"
        )
        XCTAssertTrue(
            evictedPaths.contains(
                store.layout.manifestURL(projectID: projectID, snapshotID: snapshotID).path
            ),
            "Manifest 上传确认后必须释放本地副本"
        )
        XCTAssertTrue(
            evictedPaths.contains(
                store.layout.commitURL(projectID: projectID, snapshotID: snapshotID).path
            ),
            "Commit 上传确认后必须释放本地副本"
        )
    }
}
