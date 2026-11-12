import XCTest
import Foundation
@testable import BackupEngine
@testable import SharedModels

/// CT-160: the BackupEngine v3 adapter — the surface the service and UI use.
final class CloudFirstEngineAdapterTests: XCTestCase {
    private var root: URL!
    private let masterKey = Data("adapter-test-key".utf8)
    private let projectID = UUID()

    actor SnapshotProjects {
        private var map: [String: UUID] = [:]
        func set(_ snapshot: String, _ project: UUID) { map[snapshot] = project }
        func get(_ snapshot: String) -> UUID? { map[snapshot] }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src/util"),
            withIntermediateDirectories: true
        )
        try Data("readme".utf8).write(to: root.appendingPathComponent("README.md"))
        try Data(String(repeating: "x", count: 40_000).utf8)
            .write(to: root.appendingPathComponent("src/big.txt"))
        try Data("helper".utf8).write(to: root.appendingPathComponent("src/util/helper.swift"))
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func makeAdapter(
        cloud: InMemoryCloud,
        index: InMemoryIndex,
        projects: SnapshotProjects
    ) -> CloudFirstEngineAdapter {
        CloudFirstEngineAdapter(
            masterKey: masterKey,
            deviceID: "device-A",
            index: index,
            sink: cloud,
            source: cloud,
            options: BackupRunOptions(
                chunker: ChunkerConfig(minSize: 1024, avgSize: 4096, maxSize: 32 * 1024)
            ),
            snapshotProjectProvider: { await projects.get($0) },
            sourceRootsProvider: { [root] in root.map { [$0] } ?? [] }
        )
    }

    private func project() -> Project {
        Project(id: projectID, name: "adapter", rootPath: root.path)
    }

    private func policy() -> BackupPolicy {
        BackupPolicy(projectID: projectID, excludeRules: [])
    }

    func testCT160_BackupBrowseDiffRestoreAndVerifyThroughTheAdapter() async throws {
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let projects = SnapshotProjects()
        let adapter = makeAdapter(cloud: cloud, index: index, projects: projects)

        let first = try await adapter.createSnapshot(
            project: project(), policy: policy(), trigger: .manual
        )
        await projects.set(first.id, projectID)
        XCTAssertEqual(first.cloudState, .synced)
        XCTAssertTrue(first.fileCount >= 3)

        let snapshots = try await adapter.listSnapshots(project: project())
        XCTAssertEqual(snapshots.map(\.id), [first.id])

        let listing = try await adapter.listDirectory(snapshotID: first.id, path: "")
        XCTAssertTrue(listing.contains { $0.path == "README.md" && !$0.isDirectory })
        XCTAssertTrue(listing.contains { $0.path == "src" && $0.isDirectory })

        let read = try await adapter.readFile(snapshotID: first.id, path: "README.md", maxBytes: 1024)
        XCTAssertEqual(read, Data("readme".utf8))

        // Modify one file: the diff must report it without downloading the tree.
        try Data("readme-v2".utf8).write(to: root.appendingPathComponent("README.md"))
        try Data("new".utf8).write(to: root.appendingPathComponent("added.txt"))
        let second = try await adapter.createSnapshot(
            project: project(), policy: policy(), trigger: .scheduled
        )
        await projects.set(second.id, projectID)

        let diff = try await adapter.diff(from: first.id, to: second.id)
        XCTAssertGreaterThanOrEqual(diff.modified, 1)
        XCTAssertGreaterThanOrEqual(diff.added, 1)
        XCTAssertTrue(diff.files.contains { $0.path == "added.txt" && $0.kind == .added })

        // Single-file restore goes through the pack/cache path.
        let destination = root.deletingLastPathComponent()
            .appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        try await adapter.restore(
            snapshotID: second.id,
            path: "README.md",
            destination: destination,
            overwrite: false
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("README.md")),
            Data("readme-v2".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("src").path
        ), "单文件恢复不得下载整个项目")

        let verified = try await adapter.verify(snapshotID: second.id)
        XCTAssertEqual(verified.outcome, .passed, verified.details)
        XCTAssertGreaterThan(verified.bytesChecked, 0)

        // Any corrupt chunk must make verification fail, not pass partially.
        let nodes = try await index.fileNodes(projectID: projectID)
        let objectID = try XCTUnwrap(nodes.flatMap(\.chunks).first?.objectID)
        cloud.corruptObject(objectID)
        let corrupted = try await adapter.verify(snapshotID: second.id)
        XCTAssertEqual(corrupted.outcome, .failed, "损坏的数据块必须让校验失败")
    }

    func testCT258_SearchStopsBeforeLoadingTheWholeTree() async throws {
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let projects = SnapshotProjects()
        let adapter = makeAdapter(cloud: cloud, index: index, projects: projects)
        let snapshot = try await adapter.createSnapshot(
            project: project(), policy: policy(), trigger: .manual
        )
        await projects.set(snapshot.id, projectID)
        cloud.resetReadCounts()

        let result = try await adapter.searchFiles(
            snapshotID: snapshot.id,
            query: "",
            limits: SearchLimits(maxFiles: 1, maxResults: 10)
        )
        XCTAssertTrue(result.truncated)
        XCTAssertLessThanOrEqual(result.visitedFiles, 2)
        XCTAssertLessThanOrEqual(
            cloud.readNodeCount,
            2,
            "达到 maxFiles 后不得继续递归加载整个目录树"
        )
    }

    final class FailingNodeSource: CloudObjectSource, @unchecked Sendable {
        enum Failure: Error { case nodeUnavailable }
        let base: InMemoryCloud
        init(base: InMemoryCloud) { self.base = base }
        func readObject(_ objectID: String) async throws -> Data { try await base.readObject(objectID) }
        func readPack(_ packID: String) async throws -> Data { try await base.readPack(packID) }
        func readObjectIfPresent(_ objectID: String) async throws -> Data? { try await base.readObjectIfPresent(objectID) }
        func readPackIfPresent(_ packID: String) async throws -> Data? { try await base.readPackIfPresent(packID) }
        func readNode(_ nodeID: String) async throws -> DirectoryNode { throw Failure.nodeUnavailable }
        func readManifestPayload(projectID: UUID, snapshotID: String) async throws -> Data {
            try await base.readManifestPayload(projectID: projectID, snapshotID: snapshotID)
        }
        func readCommit(projectID: UUID, snapshotID: String) async throws -> SnapshotCommit? {
            try await base.readCommit(projectID: projectID, snapshotID: snapshotID)
        }
        func commits(projectID: UUID) async throws -> [SnapshotCommit] { try await base.commits(projectID: projectID) }
    }

    func testCT310_NormalFileRestore() async throws {
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let projects = SnapshotProjects()
        let adapter = makeAdapter(cloud: cloud, index: index, projects: projects)
        let snapshot = try await adapter.createSnapshot(project: project(), policy: policy(), trigger: .manual)
        await projects.set(snapshot.id, projectID)
        let destination = root.deletingLastPathComponent()
            .appendingPathComponent("tb-file-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        try await adapter.restore(snapshotID: snapshot.id, path: "README.md", destination: destination, overwrite: false)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("README.md")),
            Data("readme".utf8)
        )
    }

    func testCT311_NormalDirectoryRestore() async throws {
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let projects = SnapshotProjects()
        let adapter = makeAdapter(cloud: cloud, index: index, projects: projects)
        let snapshot = try await adapter.createSnapshot(project: project(), policy: policy(), trigger: .manual)
        await projects.set(snapshot.id, projectID)
        let destination = root.deletingLastPathComponent()
            .appendingPathComponent("tb-dir-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        try await adapter.restore(snapshotID: snapshot.id, path: "src", destination: destination, overwrite: false)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("src/util/helper.swift").path
        ))
    }

    func testCT312_PathNotFoundIsExplicit() async throws {
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let projects = SnapshotProjects()
        let adapter = makeAdapter(cloud: cloud, index: index, projects: projects)
        let snapshot = try await adapter.createSnapshot(project: project(), policy: policy(), trigger: .manual)
        await projects.set(snapshot.id, projectID)
        let destination = root.deletingLastPathComponent()
            .appendingPathComponent("tb-missing-\(UUID().uuidString)", isDirectory: true)
        do {
            try await adapter.restore(
                snapshotID: snapshot.id,
                path: "does-not-exist.txt",
                destination: destination,
                overwrite: false
            )
            XCTFail("不存在的路径必须返回明确错误")
        } catch let error as CloudRestoreError {
            guard case .pathNotFound = error else { return XCTFail("实际 \(error)") }
        }
    }

    func testCT313_CloudReadErrorIsNotMisclassifiedAsFile() async throws {
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let projects = SnapshotProjects()
        let adapter = makeAdapter(cloud: cloud, index: index, projects: projects)
        let snapshot = try await adapter.createSnapshot(project: project(), policy: policy(), trigger: .manual)
        await projects.set(snapshot.id, projectID)
        let failing = CloudFirstEngineAdapter(
            masterKey: masterKey,
            deviceID: "device-A",
            index: index,
            sink: cloud,
            source: FailingNodeSource(base: cloud),
            snapshotProjectProvider: { await projects.get($0) },
            sourceRootsProvider: { [root] in root.map { [$0] } ?? [] }
        )
        let destination = root.deletingLastPathComponent()
            .appendingPathComponent("tb-cloud-error-\(UUID().uuidString)", isDirectory: true)
        do {
            try await failing.restore(snapshotID: snapshot.id, path: "src", destination: destination, overwrite: false)
            XCTFail("云端读取错误不得被当作文件类型判断")
        } catch is FailingNodeSource.Failure {
            // expected
        }
    }

    func testCT314_CorruptManifestIsNotMisclassifiedAsFile() async throws {
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let projects = SnapshotProjects()
        let adapter = makeAdapter(cloud: cloud, index: index, projects: projects)
        let snapshot = try await adapter.createSnapshot(project: project(), policy: policy(), trigger: .manual)
        await projects.set(snapshot.id, projectID)
        cloud.tamperManifest(snapshotID: snapshot.id) { payload in
            if !payload.isEmpty { payload[0] ^= 0xFF }
        }
        let destination = root.deletingLastPathComponent()
            .appendingPathComponent("tb-manifest-\(UUID().uuidString)", isDirectory: true)
        do {
            try await adapter.restore(snapshotID: snapshot.id, path: "src", destination: destination, overwrite: false)
            XCTFail("Manifest 损坏必须传播")
        } catch let error as CloudRestoreError {
            guard case .manifestHashMismatch = error else { return XCTFail("实际 \(error)") }
        }
    }

    func testCT160_UnknownSnapshotIsRejected() async throws {
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let adapter = makeAdapter(cloud: cloud, index: index, projects: SnapshotProjects())
        do {
            _ = try await adapter.readFile(snapshotID: "missing", path: "README.md", maxBytes: 10)
            XCTFail("未知快照必须失败")
        } catch let error as CodeTimeError {
            guard case .snapshotNotFound = error else {
                return XCTFail("期望 snapshotNotFound，实际 \(error)")
            }
        }
    }
}
