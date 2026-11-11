import XCTest
import Foundation
@testable import BackupEngine
@testable import SharedModels
@testable import CodeTimeSecurity

/// CT-154: the cloud-first engine end to end against an in-memory cloud.
final class CloudFirstBackupEngineTests: XCTestCase {
    private var root: URL!
    private let masterKey = Data("engine-test-master-key".utf8)
    private let projectID = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!

    // MARK: - Doubles

    final class FakeSink: CloudObjectSink, @unchecked Sendable {
        var objects: [String: Data] = [:]
        var nodes: [String: DirectoryNode] = [:]
        var manifests: [String: Data] = [:]
        var commits: [SnapshotCommit] = []
        var events: [String] = []
        private let lock = NSLock()

        var packedObjectIDs: Set<String> = []

        func hasObject(_ objectID: String) async throws -> Bool {
            lock.lock(); defer { lock.unlock() }
            return objects[objectID] != nil || packedObjectIDs.contains(objectID)
        }

        func containsObject(_ objectID: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return objects[objectID] != nil || packedObjectIDs.contains(objectID)
        }

        @discardableResult
        func putObject(_ payload: Data, objectID: String) async throws -> Bool {
            lock.lock(); defer { lock.unlock() }
            if objects[objectID] != nil { return false }
            objects[objectID] = payload
            events.append("object:\(objectID)")
            return true
        }

        @discardableResult
        func putNode(_ node: DirectoryNode) async throws -> Bool {
            lock.lock(); defer { lock.unlock() }
            if nodes[node.nodeID] != nil { return false }
            nodes[node.nodeID] = node
            events.append("node:\(node.nodeID)")
            return true
        }

        var packs: [String: Data] = [:]

        @discardableResult
        func putPack(_ payload: Data, packID: String) async throws -> Bool {
            lock.lock(); defer { lock.unlock() }
            if packs[packID] != nil { return false }
            packs[packID] = payload
            if let entries = try? ObjectPackReader().entries(in: payload) {
                packedObjectIDs.formUnion(entries.map(\.objectID))
            }
            events.append("pack:\(packID)")
            return true
        }

        func hasPack(_ packID: String) async throws -> Bool {
            lock.lock(); defer { lock.unlock() }
            return packs[packID] != nil
        }

        func putManifest(_ payload: Data, projectID: UUID, snapshotID: String) async throws -> String {
            lock.lock(); defer { lock.unlock() }
            manifests[snapshotID] = payload
            events.append("manifest:\(snapshotID)")
            return CanonicalHashing.sha256Hex(payload)
        }

        func putCommit(_ commit: SnapshotCommit) async throws {
            lock.lock(); defer { lock.unlock() }
            guard let payload = manifests[commit.snapshotID],
                  CanonicalHashing.sha256Hex(payload) == commit.manifestPayloadHash else {
                throw CloudObjectStoreV3ErrorShim.manifestHashMismatch
            }
            commits.append(commit)
            events.append("commit:\(commit.snapshotID)")
        }

        func snapshot(_ id: String) -> SnapshotCommit? {
            lock.lock(); defer { lock.unlock() }
            return commits.first { $0.snapshotID == id }
        }
    }

    enum CloudObjectStoreV3ErrorShim: Error { case manifestHashMismatch }

    final class FakeIndex: CloudSnapshotIndex, @unchecked Sendable {
        var files: [UUID: [FileNode]] = [:]
        var chunks: [String: ChunkRecordV3] = [:]
        var snapshots: [SnapshotRecordV3] = []
        var uploads: [PendingUploadV3] = []
        private let lock = NSLock()

        func fileNodes(projectID: UUID) async throws -> [FileNode] {
            lock.lock(); defer { lock.unlock() }
            return files[projectID] ?? []
        }

        func replaceFileIndex(projectID: UUID, files: [FileNode], snapshotID: String) async throws {
            lock.lock(); defer { lock.unlock() }
            self.files[projectID] = files
        }

        func knownObjectIDs(_ objectIDs: [String]) async throws -> Set<String> {
            lock.lock(); defer { lock.unlock() }
            return Set(objectIDs.filter { chunks[$0] != nil })
        }

        func knownChunks(_ objectIDs: [String]) async throws -> [String: ChunkRecordV3] {
            lock.lock(); defer { lock.unlock() }
            var result: [String: ChunkRecordV3] = [:]
            for id in objectIDs {
                if let record = chunks[id] { result[id] = record }
            }
            return result
        }

        func upsertChunks(_ newChunks: [ChunkRecordV3]) async throws {
            lock.lock(); defer { lock.unlock() }
            for chunk in newChunks { chunks[chunk.objectID] = chunk }
        }

        func upsertSnapshot(_ record: SnapshotRecordV3) async throws {
            lock.lock(); defer { lock.unlock() }
            if let index = snapshots.firstIndex(where: { $0.snapshotID == record.snapshotID }) {
                snapshots[index] = record
            } else {
                snapshots.append(record)
            }
        }

        func updateSnapshot(
            _ snapshotID: String,
            uploadState: SnapshotUploadState?,
            commitState: SnapshotCommitState?,
            manifestPayloadHash: String?
        ) async throws {
            lock.lock(); defer { lock.unlock() }
            guard let index = snapshots.firstIndex(where: { $0.snapshotID == snapshotID }) else { return }
            if let uploadState { snapshots[index].uploadState = uploadState }
            if let commitState { snapshots[index].commitState = commitState }
            if let manifestPayloadHash { snapshots[index].manifestPayloadHash = manifestPayloadHash }
        }

        func snapshotRecords(projectID: UUID, limit: Int) async throws -> [SnapshotRecordV3] {
            lock.lock(); defer { lock.unlock() }
            return Array(
                snapshots
                    .filter { $0.projectID == projectID }
                    .sorted { $0.createdAt > $1.createdAt }
                    .prefix(limit)
            )
        }

        func enqueueUploads(_ uploads: [PendingUploadV3]) async throws {
            lock.lock(); defer { lock.unlock() }
            self.uploads.append(contentsOf: uploads)
        }

        func removeUpload(_ taskID: String) async throws {
            lock.lock(); defer { lock.unlock() }
            uploads.removeAll { $0.taskID == taskID }
        }

        func pendingUploads(state: UploadTaskState?, limit: Int) async throws -> [PendingUploadV3] {
            lock.lock(); defer { lock.unlock() }
            return Array(
                uploads
                    .filter { state == nil || $0.state == state }
                    .sorted { $0.createdAt < $1.createdAt }
                    .prefix(limit)
            )
        }

        func updateUploadState(_ taskID: String, state: UploadTaskState, bumpRetry: Bool) async throws {
            lock.lock(); defer { lock.unlock() }
            guard let index = uploads.firstIndex(where: { $0.taskID == taskID }) else { return }
            uploads[index].state = state
            if bumpRetry { uploads[index].retryCount += 1 }
        }

        func pendingUploadBytes() async throws -> Int64 {
            lock.lock(); defer { lock.unlock() }
            return uploads.reduce(0) { $0 + $1.fileSize }
        }

        func inFlightSnapshotCount() async throws -> Int {
            lock.lock(); defer { lock.unlock() }
            return snapshots.filter { !$0.isCommitted }.count
        }
    }

    // MARK: - Setup

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data(String(repeating: "a", count: 3_000_000).utf8).write(to: root.appendingPathComponent("src/big.txt"))
        try Data("hello".utf8).write(to: root.appendingPathComponent("README.md"))
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func makeEngine(
        sink: FakeSink,
        index: FakeIndex,
        options: BackupRunOptions = BackupRunOptions(
            chunker: ChunkerConfig(minSize: 1024, avgSize: 4096, maxSize: 16 * 1024),
            uploadConcurrency: 2
        )
    ) -> CloudFirstBackupEngine {
        CloudFirstBackupEngine(
            masterKey: masterKey,
            deviceID: "device-A",
            index: index,
            sink: sink,
            options: options
        )
    }

    private func matcher() -> ExclusionMatcher {
        ExclusionMatcher(rules: ExclusionPresets.defaultRules())
    }

    private func decryptManifest(_ sink: FakeSink, snapshotID: String) throws -> SnapshotManifest {
        let payload = try XCTUnwrap(sink.manifests[snapshotID])
        let plaintext = try CryptoBox.open(
            payload,
            masterKey: masterKey,
            context: "v3:manifest:\(projectID.uuidString):\(snapshotID)"
        )
        return try JSONDecoder().decode(SnapshotManifest.self, from: plaintext)
    }

    private func treeFiles(_ sink: FakeSink, rootNodeID: String) throws -> [FileNode] {
        var result: [FileNode] = []
        func walk(_ nodeID: String) throws {
            let node = try XCTUnwrap(sink.nodes[nodeID], "节点 \(nodeID) 未上传")
            result.append(contentsOf: node.files)
            for directory in node.directories {
                try walk(directory.nodeID)
            }
        }
        try walk(rootNodeID)
        return result
    }

    // MARK: - CT-154

    func testCT154_FirstBackupPublishesInOrderAndIsReadable() async throws {
        let sink = FakeSink()
        let index = FakeIndex()
        let engine = makeEngine(sink: sink, index: index)

        let report = try await engine.run(projectID: projectID, root: root, matcher: matcher())

        XCTAssertTrue(report.committed)
        XCTAssertEqual(report.filesScanned, 2)
        XCTAssertEqual(report.filesChanged, 2)
        XCTAssertGreaterThan(report.objectsUploaded, 1, "大文件应被切成多块")
        XCTAssertEqual(sink.commits.count, 1)

        // Publication order: every object, then nodes, then manifest, then commit.
        let commitIndex = try XCTUnwrap(sink.events.firstIndex { $0.hasPrefix("commit:") })
        let manifestIndex = try XCTUnwrap(sink.events.firstIndex { $0.hasPrefix("manifest:") })
        let nodeIndices = sink.events.indices.filter { sink.events[$0].hasPrefix("node:") }
        let objectIndices = sink.events.indices.filter { sink.events[$0].hasPrefix("object:") }
        XCTAssertLessThan(objectIndices.max() ?? -1, manifestIndex, "Manifest 必须在所有对象之后")
        XCTAssertLessThan(nodeIndices.max() ?? -1, manifestIndex, "Manifest 必须在目录节点之后")
        XCTAssertLessThan(manifestIndex, commitIndex, "Commit 必须最后发布")

        // Manifest decrypts and describes the tree we actually uploaded.
        let manifest = try decryptManifest(sink, snapshotID: report.snapshotID)
        XCTAssertEqual(manifest.rootNodeID, try XCTUnwrap(index.files[projectID]).isEmpty ? "" : manifest.rootNodeID)
        XCTAssertEqual(manifest.fileCount, 2)
        XCTAssertTrue(manifest.digestMatches)

        let files = try treeFiles(sink, rootNodeID: manifest.rootNodeID)
        XCTAssertEqual(files.map(\.path).sorted(), ["README.md", "src/big.txt"])
        let big = try XCTUnwrap(files.first { $0.path == "src/big.txt" })
        XCTAssertEqual(big.size, 3_000_000)
        XCTAssertGreaterThan(big.chunks.count, 1)
        XCTAssertEqual(
            big.chunks.reduce(0) { $0 + Int($1.plaintextSize) },
            3_000_000,
            "所有块的大小之和必须等于文件大小"
        )
        XCTAssertNotNil(big.contentHash)

        // The index now knows the tree and the chunks.
        XCTAssertEqual(index.files[projectID]?.count, 2)
        XCTAssertEqual(index.snapshots.first?.commitState, .committed)
        XCTAssertEqual(index.snapshots.first?.uploadState, .uploaded)
    }

    func testCT154_SecondRunReusesEverythingWhenNothingChanged() async throws {
        let sink = FakeSink()
        let index = FakeIndex()
        let engine = makeEngine(sink: sink, index: index)

        let first = try await engine.run(projectID: projectID, root: root, matcher: matcher())
        let objectCountAfterFirst = sink.objects.count
        let second = try await engine.run(projectID: projectID, root: root, matcher: matcher())

        XCTAssertEqual(second.filesReused, 2, "未修改文件必须复用，不重新读取")
        XCTAssertEqual(second.filesChanged, 0)
        XCTAssertEqual(second.objectsUploaded, 0, "未变化时不得重新上传任何对象")
        XCTAssertEqual(sink.objects.count, objectCountAfterFirst)
        XCTAssertEqual(second.parentSnapshotID, first.snapshotID, "父版本必须指向最后一个已提交版本")
        XCTAssertEqual(second.nodesUploaded, 0, "未变化的目录节点不得重传")

        // The tree is identical, so the root node is identical too.
        let firstManifest = try decryptManifest(sink, snapshotID: first.snapshotID)
        let secondManifest = try decryptManifest(sink, snapshotID: second.snapshotID)
        XCTAssertEqual(firstManifest.rootNodeID, secondManifest.rootNodeID)

        // §7.2: once per day every file is re-read even when size+mtime match.
        // Re-chunking finds the same objects, so nothing is uploaded again.
        let nextDay = Date().addingTimeInterval(86_400)
        let daily = CloudFirstBackupEngine(
            masterKey: masterKey,
            deviceID: "device-A",
            index: index,
            sink: sink,
            options: BackupRunOptions(
                chunker: ChunkerConfig(minSize: 1024, avgSize: 4096, maxSize: 16 * 1024),
                uploadConcurrency: 2
            ),
            clock: { nextDay }
        )
        let third = try await daily.run(projectID: projectID, root: root, matcher: matcher())
        XCTAssertEqual(third.filesReused, 0, "跨天后必须重新读取文件内容")
        XCTAssertEqual(third.filesChanged, 2)
        XCTAssertEqual(third.objectsUploaded, 0, "内容未变时重新分块不得产生新对象")
    }

    func testCT154_EditingOneFileUploadsOnlyNewChunks() async throws {
        let sink = FakeSink()
        let index = FakeIndex()
        let engine = makeEngine(sink: sink, index: index)

        let first = try await engine.run(projectID: projectID, root: root, matcher: matcher())
        let firstObjects = Set(sink.objects.keys)

        // Append 10 KB to the big file: content-defined chunking must reuse the
        // existing chunks and upload only the tail.
        let bigURL = root.appendingPathComponent("src/big.txt")
        let handle = try FileHandle(forWritingTo: bigURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(String(repeating: "b", count: 10_000).utf8))
        try handle.close()

        let second = try await engine.run(projectID: projectID, root: root, matcher: matcher())
        XCTAssertEqual(second.filesChanged, 1)
        XCTAssertEqual(second.filesReused, 1, "README 未变化必须复用")
        XCTAssertGreaterThan(second.objectsUploaded, 0)
        XCTAssertGreaterThan(second.bytesDeduped, 0, "未变化的数据块必须被去重")

        let newObjects = Set(sink.objects.keys).subtracting(firstObjects)
        XCTAssertLessThan(
            newObjects.count,
            second.objectsUploaded + 1,
            "新增对象数应与实际上传数一致"
        )
        // Old snapshot still fully present (immutable history).
        let firstManifest = try decryptManifest(sink, snapshotID: first.snapshotID)
        let oldFiles = try treeFiles(sink, rootNodeID: firstManifest.rootNodeID)
        XCTAssertEqual(oldFiles.first { $0.path == "src/big.txt" }?.size, 3_000_000, "旧版本不可被改写")
    }

    func testCT154_DeletingAFileKeepsHistoryAndUpdatesTree() async throws {
        let sink = FakeSink()
        let index = FakeIndex()
        let engine = makeEngine(sink: sink, index: index)

        let first = try await engine.run(projectID: projectID, root: root, matcher: matcher())
        try FileManager.default.removeItem(at: root.appendingPathComponent("README.md"))
        let second = try await engine.run(projectID: projectID, root: root, matcher: matcher())

        XCTAssertEqual(second.filesRemoved, 1)
        let secondManifest = try decryptManifest(sink, snapshotID: second.snapshotID)
        let files = try treeFiles(sink, rootNodeID: secondManifest.rootNodeID)
        XCTAssertEqual(files.map(\.path), ["src/big.txt"])

        // The deleted file's content is still referenced by the first snapshot.
        let firstManifest = try decryptManifest(sink, snapshotID: first.snapshotID)
        let oldFiles = try treeFiles(sink, rootNodeID: firstManifest.rootNodeID)
        XCTAssertEqual(oldFiles.map(\.path).sorted(), ["README.md", "src/big.txt"])
        for chunk in oldFiles.flatMap(\.chunks) {
            XCTAssertTrue(sink.containsObject(chunk.objectID), "历史版本引用的对象不得丢失（独立对象或包内）")
        }
    }

    func testCT154_IdenticalContentAcrossFilesIsStoredOnce() async throws {
        let sink = FakeSink()
        let index = FakeIndex()
        let engine = makeEngine(sink: sink, index: index)

        let copy = Data(String(repeating: "a", count: 3_000_000).utf8)
        try copy.write(to: root.appendingPathComponent("src/copy.txt"))
        let report = try await engine.run(projectID: projectID, root: root, matcher: matcher())

        XCTAssertEqual(report.filesChanged, 3)
        XCTAssertGreaterThan(report.objectsReused, 0, "相同内容的块必须跨文件复用")
        // Both files reference the same object IDs.
        let manifest = try decryptManifest(sink, snapshotID: report.snapshotID)
        let files = try treeFiles(sink, rootNodeID: manifest.rootNodeID)
        let big = try XCTUnwrap(files.first { $0.path == "src/big.txt" })
        let duplicate = try XCTUnwrap(files.first { $0.path == "src/copy.txt" })
        XCTAssertEqual(
            Set(big.chunks.map(\.objectID)).subtracting(Set(duplicate.chunks.map(\.objectID))),
            [],
            "相同内容必须共享同一批对象"
        )
    }

    func testCT154_IncompleteScanRefusesToPublish() async throws {
        let sink = FakeSink()
        let index = FakeIndex()
        let engine = makeEngine(sink: sink, index: index)

        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appendingPathComponent("hidden.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        if getuid() == 0 { throw XCTSkip("root 不受权限限制") }

        do {
            _ = try await engine.run(projectID: projectID, root: root, matcher: matcher())
            XCTFail("扫描不完整时不得发布快照")
        } catch let error as CloudFirstEngineError {
            guard case .scanIncomplete = error else {
                return XCTFail("错误类型应为 scanIncomplete，实际 \(error)")
            }
        }
        XCTAssertTrue(sink.commits.isEmpty, "失败路径不得留下 Commit")
        XCTAssertTrue(sink.manifests.isEmpty)
    }

    func testCT154_CancellationStopsBeforePublishing() async throws {
        let sink = FakeSink()
        let index = FakeIndex()
        let engine = makeEngine(sink: sink, index: index)

        do {
            _ = try await engine.run(
                projectID: projectID, root: root, matcher: matcher(), isCancelled: { true }
            )
            XCTFail("已取消的任务必须中止")
        } catch let error as CloudFirstEngineError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertTrue(sink.commits.isEmpty)
    }
}
