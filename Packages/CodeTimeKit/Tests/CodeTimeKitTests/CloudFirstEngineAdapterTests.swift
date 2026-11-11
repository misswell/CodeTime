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
            snapshotProjectProvider: { await projects.get($0) }
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
