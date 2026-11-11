import XCTest
import Foundation
@testable import BackupEngine
@testable import SharedModels
@testable import CodeTimeSecurity
@testable import Persistence
@testable import CloudMirrorStore

/// CT-167…CT-169: remote metadata, not local SQLite rows, decides snapshot format.
final class SnapshotFormatResolverTests: XCTestCase {
    private var workspace: URL!
    private let masterKey = Data("resolver-master-key".utf8)
    private let deviceID = "device-A"
    private let projectID = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        try super.tearDownWithError()
    }

    private func makeStack() async throws -> (
        CloudObjectStoreV3,
        SQLiteStore,
        CloudObjectStoreV3.Layout,
        URL
    ) {
        let root = workspace.appendingPathComponent("v3", isDirectory: true)
        let store = CloudObjectStoreV3(root: root, deviceID: deviceID, masterKey: masterKey)
        try await store.prepare(deviceName: "Mac A")
        let database = try SQLiteStore(path: workspace.appendingPathComponent("meta.sqlite").path)
        let projectRoot = workspace.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent("src"),
            withIntermediateDirectories: true
        )
        try Data("hello resolver".utf8).write(to: projectRoot.appendingPathComponent("README.md"))
        try Data(String(repeating: "x", count: 40_000).utf8)
            .write(to: projectRoot.appendingPathComponent("src/data.txt"))
        return (store, database, store.layout, projectRoot)
    }

    private func runBackup(
        store: CloudObjectStoreV3,
        database: SQLiteStore,
        projectRoot: URL,
        snapshotID: String
    ) async throws -> SnapshotCommit {
        let engine = CloudFirstBackupEngine(
            masterKey: masterKey,
            deviceID: deviceID,
            index: database,
            sink: store,
            options: BackupRunOptions(packObjectsUpTo: nil)
        )
        _ = try await engine.run(
            projectID: projectID,
            root: projectRoot,
            matcher: ExclusionMatcher(rules: ExclusionPresets.defaultRules()),
            snapshotID: snapshotID
        )
        let commit = try await store.readCommit(projectID: projectID, snapshotID: snapshotID)
        return try XCTUnwrap(commit, "备份必须发布提交标记")
    }

    func testCT169_ResolverTrustsRemoteCommitAndNeverDowngradesLocalV3() async throws {
        let (store, database, layout, projectRoot) = try await makeStack()
        let snapshotID = "snap-v3-1"
        let commit = try await runBackup(
            store: store, database: database, projectRoot: projectRoot, snapshotID: snapshotID
        )

        let resolver = SnapshotFormatResolver(
            masterKey: masterKey,
            source: store,
            localSnapshotProbe: { _ in nil }
        )
        let resolved = try await resolver.resolve(snapshotID: snapshotID, projectID: projectID)
        XCTAssertEqual(resolved.format, .v3)
        XCTAssertEqual(resolved.deviceID, deviceID)
        XCTAssertEqual(resolved.formatVersion, CloudFormatV3.version)
        XCTAssertEqual(resolved.discoveryStatus, .verified)
        XCTAssertEqual(resolved.manifestHash, commit.manifestPayloadHash)
        XCTAssertNotNil(resolved.rootNodeID)
        XCTAssertNotNil(resolved.lastVerifiedAt)

        // A locally recorded v3 publication without a remote commit must fail; it
        // must never be handed to the Kopia engine.
        var legacyProbeCalled = false
        let halfPublished = SnapshotFormatResolver(
            masterKey: masterKey,
            source: store,
            localSnapshotProbe: { id in
                id == "snap-half" ? SnapshotRecordV3(
                    snapshotID: "snap-half",
                    projectID: self.projectID,
                    parentSnapshotID: nil,
                    createdAt: Date(),
                    rootNodeID: "root",
                    fileCount: 1,
                    totalBytes: 1,
                    uploadState: .uploading,
                    commitState: .pending
                ) : nil
            },
            legacyProbe: { _, _ in
                legacyProbeCalled = true
                return ResolvedSnapshot(
                    snapshotID: "snap-half",
                    projectID: self.projectID,
                    deviceID: "",
                    formatVersion: 1,
                    rootNodeID: nil,
                    createdAt: Date(),
                    format: .kopia,
                    discoveryStatus: .discovered
                )
            }
        )
        do {
            _ = try await halfPublished.resolve(snapshotID: "snap-half", projectID: projectID)
            XCTFail("本地有 v3 发布记录但云端无 commit 时必须失败")
        } catch let error as SnapshotFormatError {
            guard case .commitMissing = error else {
                return XCTFail("期望 commitMissing，实际 \(error)")
            }
        }
        XCTAssertFalse(legacyProbeCalled, "缺少 v3 commit 时不得降级为 Kopia")

        // A commit whose manifest disappeared is corruption, not a different format.
        try FileManager.default.removeItem(
            at: layout.manifestURL(projectID: projectID, snapshotID: snapshotID)
        )
        let corrupted = try await resolver.resolve(snapshotID: snapshotID, projectID: projectID)
        XCTAssertEqual(corrupted.format, .v3)
        XCTAssertEqual(corrupted.discoveryStatus, .corrupted)
    }

    func testCT170_RemoteSnapshotIndexIsPersistentAndRebuildable() async throws {
        let (store, database, _, projectRoot) = try await makeStack()
        _ = try await runBackup(
            store: store, database: database, projectRoot: projectRoot, snapshotID: "snap-a"
        )
        try Data("changed".utf8).write(to: projectRoot.appendingPathComponent("README.md"))
        _ = try await runBackup(
            store: store, database: database, projectRoot: projectRoot, snapshotID: "snap-b"
        )

        let resolver = SnapshotFormatResolver(masterKey: masterKey, source: store)
        let records = try await resolver.refreshRemoteIndex(projectID: projectID, index: database)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.snapshotID)), ["snap-a", "snap-b"])
        XCTAssertTrue(records.allSatisfy { $0.discoveryStatus == .verified })
        XCTAssertTrue(records.allSatisfy { $0.deviceID == deviceID })
        XCTAssertTrue(records.allSatisfy { !$0.rootNodeID.isEmpty })

        let cached = try await database.remoteSnapshots(projectID: projectID)
        XCTAssertEqual(Set(cached.map(\.snapshotID)), ["snap-a", "snap-b"])

        // The cache is not the authority: removing a commit must not leave the
        // snapshot resolvable just because its row still says "verified".
        try FileManager.default.removeItem(
            at: store.layout.commitURL(projectID: projectID, snapshotID: "snap-a")
        )
        do {
            _ = try await resolver.resolve(snapshotID: "snap-a", projectID: projectID)
            XCTFail("云端 commit 已不存在时必须报告，而不是信任本地索引")
        } catch let error as SnapshotFormatError {
            guard case .snapshotNotFound = error else {
                return XCTFail("期望 snapshotNotFound，实际 \(error)")
            }
        }

        // Rebuilding the cache from the remaining commit keeps the surviving row
        // and drops nothing else silently.
        let rebuilt = try await resolver.refreshRemoteIndex(projectID: projectID, index: database)
        XCTAssertEqual(rebuilt.map(\.snapshotID), ["snap-b"])
    }

    func testCT171_DeviceListHasTTLAndFailedRefreshKeepsLastKnownList() async throws {
        let root = workspace.appendingPathComponent("v3", isDirectory: true)
        let devices = root.appendingPathComponent("devices", isDirectory: true)
        for id in ["device-A", "device-B"] {
            try FileManager.default.createDirectory(
                at: devices.appendingPathComponent(id, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let source = CloudMultiDeviceStoreV3(
            root: root,
            localDeviceID: "device-A",
            masterKey: masterKey,
            deviceListTTL: 0.05
        )
        try await source.refreshDeviceList(force: true)
        var cached = await source.cachedDeviceIDs()
        XCTAssertEqual(Set(cached), ["device-A", "device-B"])

        // A new Mac appears; without a TTL this list would stay stale for the rest
        // of the process lifetime.
        try FileManager.default.createDirectory(
            at: devices.appendingPathComponent("device-C", isDirectory: true),
            withIntermediateDirectories: true
        )
        try await Task.sleep(nanoseconds: 80_000_000)
        try await source.refreshDeviceList(force: false)
        cached = await source.cachedDeviceIDs()
        XCTAssertTrue(cached.contains("device-C"), "TTL 到期后必须重新读取设备列表")

        // An unreadable device directory must not silently replace the cache with
        // an empty list.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: devices.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: devices.path
            )
        }
        do {
            try await source.refreshDeviceList(force: true)
            XCTFail("无法枚举设备时刷新必须抛错")
        } catch {
            // expected
        }
        cached = await source.cachedDeviceIDs()
        XCTAssertTrue(cached.contains("device-C"), "刷新失败不得清空上次成功的设备列表")

        await source.invalidateDeviceList()
        let afterInvalidate = await source.cachedDeviceIDs()
        XCTAssertTrue(afterInvalidate.isEmpty)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: devices.path
        )
        try await source.refreshDeviceList(force: true)
        let refreshed = await source.cachedDeviceIDs()
        XCTAssertTrue(refreshed.contains("device-C"))
    }
}
