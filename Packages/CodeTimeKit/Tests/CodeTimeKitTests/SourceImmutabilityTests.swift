import XCTest
import Foundation
import Darwin
import CryptoKit
@testable import BackupEngine
@testable import SharedModels
@testable import CodeTimeCore
@testable import CodeTimeSecurity

/// CT-234…CT-245: the original project is a permanently read-only input.
///
/// Every test takes a full filesystem snapshot (bytes, structure, modes,
/// mtimes, symlinks, xattrs and link counts), performs a backup/restore/GC
/// operation, and proves the original is bit-for-bit unchanged. Restore
/// destinations that overlap a source are rejected before a job is created.
final class SourceImmutabilityTests: XCTestCase {
    private var workspace: URL!
    private let masterKey = Data("source-immutability-key".utf8)
    private let projectID = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-immutability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        try super.tearDownWithError()
    }

    // MARK: - Filesystem snapshot

    private struct Item: Equatable {
        var kind: String
        var size: Int64
        var mode: UInt16
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
        var linkCount: UInt16
        var symlinkTarget: String?
        var sha256: String?
        var xattr: Data?
    }

    private struct Snapshot: Equatable {
        var items: [String: Item]
    }

    private static let xattrName = "com.codetime.test.readonly"

    private func snapshot(_ root: URL) throws -> Snapshot {
        var paths = [root]
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in true }
        ) {
            while let url = enumerator.nextObject() as? URL {
                paths.append(url)
            }
        }
        let rootPath = root.standardizedFileURL.path
        var items: [String: Item] = [:]
        for url in paths {
            let path = url.standardizedFileURL.path
            let relative = path == rootPath ? "." : String(path.dropFirst(rootPath.count + 1))
            var info = stat()
            guard lstat(path, &info) == 0 else {
                throw NSError(domain: "SourceImmutabilityTests", code: 1)
            }
            let format = info.st_mode & S_IFMT
            let kind: String
            var symlinkTarget: String?
            var sha256: String?
            var xattr: Data?
            switch format {
            case S_IFDIR:
                kind = "directory"
            case S_IFLNK:
                kind = "symlink"
                symlinkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: path)
            case S_IFREG:
                kind = "file"
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                xattr = Self.readXattr(path: path, name: Self.xattrName)
            default:
                kind = "other"
            }
            if kind == "directory" {
                xattr = Self.readXattr(path: path, name: Self.xattrName)
            }
            items[relative] = Item(
                kind: kind,
                size: info.st_size,
                mode: UInt16(info.st_mode & 0o7777),
                modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                linkCount: info.st_nlink,
                symlinkTarget: symlinkTarget,
                sha256: sha256,
                xattr: xattr
            )
        }
        return Snapshot(items: items)
    }

    private static func readXattr(path: String, name: String) -> Data? {
        let size = path.withCString { p in
            name.withCString { n in getxattr(p, n, nil, 0, 0, 0) }
        }
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { buffer -> Int in
            path.withCString { p in
                name.withCString { n in
                    getxattr(p, n, buffer.baseAddress, size, 0, 0)
                }
            }
        }
        return read == size ? data : nil
    }

    @discardableResult
    private func setXattr(path: String, value: String) -> Bool {
        let data = Data(value.utf8)
        let result = path.withCString { p in
            Self.xattrName.withCString { n in
                data.withUnsafeBytes { buffer in
                    setxattr(p, n, buffer.baseAddress, data.count, 0, 0)
                }
            }
        }
        return result == 0
    }

    // MARK: - Fixture

    @discardableResult
    private func makeProject() throws -> URL {
        let project = workspace.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("src/nested"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("empty"),
            withIntermediateDirectories: true
        )
        try Data("alpha-content".utf8).write(to: project.appendingPathComponent("a.txt"))
        try Data(String(repeating: "beta-", count: 4_000).utf8)
            .write(to: project.appendingPathComponent("src/nested/b.bin"))
        try FileManager.default.createSymbolicLink(
            atPath: project.appendingPathComponent("link").path,
            withDestinationPath: "a.txt"
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o640)],
            ofItemAtPath: project.appendingPathComponent("a.txt").path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o750)],
            ofItemAtPath: project.appendingPathComponent("src/nested").path
        )
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000.125)
        for relative in ["a.txt", "src/nested/b.bin", "empty", "src/nested", "src", "."] {
            try FileManager.default.setAttributes(
                [.modificationDate: fixedDate],
                ofItemAtPath: project.appendingPathComponent(relative).path
            )
        }
        XCTAssertTrue(setXattr(path: project.appendingPathComponent("a.txt").path, value: "keep-me"))
        XCTAssertTrue(setXattr(path: project.appendingPathComponent("src").path, value: "dir-xattr"))
        return project
    }

    private func makeEngine(
        cloud: InMemoryCloud,
        index: InMemoryIndex,
        sink: CloudObjectSink? = nil
    ) -> CloudFirstBackupEngine {
        CloudFirstBackupEngine(
            masterKey: masterKey,
            deviceID: "device-A",
            index: index,
            sink: sink ?? cloud,
            options: BackupRunOptions(
                chunker: ChunkerConfig(minSize: 1024, avgSize: 4096, maxSize: 16 * 1024),
                packObjectsUpTo: nil
            )
        )
    }

    private func backup(
        _ root: URL,
        cloud: InMemoryCloud,
        index: InMemoryIndex,
        snapshotID: String = UUID().uuidString
    ) async throws -> BackupRunReport {
        try await makeEngine(cloud: cloud, index: index).run(
            projectID: projectID,
            root: root,
            matcher: ExclusionMatcher(rules: []),
            snapshotID: snapshotID
        )
    }

    // MARK: - Backup is read-only

    func testCT234_BackupLeavesOriginalBytesAndStructureUnchanged() async throws {
        let project = try makeProject()
        let before = try snapshot(project)
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let report = try await backup(project, cloud: cloud, index: index)
        XCTAssertTrue(report.committed)
        XCTAssertEqual(try snapshot(project), before, "备份不得修改原始项目的字节或目录结构")
    }

    func testCT235_BackupLeavesModesMtimesXattrsAndSymlinksUnchanged() async throws {
        let project = try makeProject()
        let before = try snapshot(project)
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        _ = try await backup(project, cloud: cloud, index: index)
        let after = try snapshot(project)
        XCTAssertEqual(after.items["."]?.mode, before.items["."]?.mode)
        XCTAssertEqual(after.items["a.txt"]?.mode, 0o640)
        XCTAssertEqual(after.items["a.txt"]?.modifiedNanoseconds, before.items["a.txt"]?.modifiedNanoseconds)
        XCTAssertEqual(after.items["a.txt"]?.xattr, before.items["a.txt"]?.xattr)
        XCTAssertEqual(after.items["src"]?.xattr, before.items["src"]?.xattr)
        XCTAssertEqual(after.items["link"]?.symlinkTarget, "a.txt")
        XCTAssertEqual(after, before, "备份不得修改权限、mtime、xattr 或符号链接")
    }

    // MARK: - Failure / retry / cancellation

    private final class FailingSink: CloudObjectSink, @unchecked Sendable {
        enum Failure: Error { case injected }
        let base: InMemoryCloud
        private let lock = NSLock()
        var failObjectUploads = true
        var onObjectUpload: (@Sendable () -> Void)?

        init(base: InMemoryCloud) { self.base = base }

        func hasObject(_ objectID: String) async throws -> Bool {
            try await base.hasObject(objectID)
        }

        @discardableResult
        func putObject(_ payload: Data, objectID: String) async throws -> Bool {
            lock.lock()
            let shouldFail = failObjectUploads
            let hook = onObjectUpload
            lock.unlock()
            hook?()
            if shouldFail { throw Failure.injected }
            return try await base.putObject(payload, objectID: objectID)
        }

        @discardableResult
        func putNode(_ node: DirectoryNode) async throws -> Bool {
            try await base.putNode(node)
        }

        @discardableResult
        func putPack(_ payload: Data, packID: String) async throws -> Bool {
            try await base.putPack(payload, packID: packID)
        }

        func hasPack(_ packID: String) async throws -> Bool {
            try await base.hasPack(packID)
        }

        func objectState(_ objectID: String) async throws -> CloudObjectState {
            try await base.objectState(objectID)
        }

        func ensureObjectReady(
            _ objectID: String,
            payload: Data,
            storedSize: Int
        ) async throws -> StoredObjectLocation {
            lock.lock()
            let shouldFail = failObjectUploads
            let hook = onObjectUpload
            lock.unlock()
            hook?()
            if shouldFail { throw Failure.injected }
            return try await base.ensureObjectReady(
                objectID,
                payload: payload,
                storedSize: storedSize
            )
        }

        func packState(_ packID: String) async throws -> CloudObjectState {
            try await base.packState(packID)
        }

        func putManifest(_ payload: Data, projectID: UUID, snapshotID: String) async throws -> String {
            try await base.putManifest(payload, projectID: projectID, snapshotID: snapshotID)
        }

        func putCommit(_ commit: SnapshotCommit) async throws {
            try await base.putCommit(commit)
        }
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testCT236_UploadFailureDoesNotModifyOriginals() async throws {
        let project = try makeProject()
        let before = try snapshot(project)
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let sink = FailingSink(base: cloud)
        let engine = makeEngine(cloud: cloud, index: index, sink: sink)
        do {
            _ = try await engine.run(
                projectID: projectID,
                root: project,
                matcher: ExclusionMatcher(rules: [])
            )
            XCTFail("注入的上传失败必须中止备份")
        } catch {
            // expected
        }
        XCTAssertEqual(try snapshot(project), before, "上传失败不得回写或清理原始文件")
    }

    func testCT237_UploadRetryAfterFailureDoesNotModifyOriginals() async throws {
        let project = try makeProject()
        let before = try snapshot(project)
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let sink = FailingSink(base: cloud)
        do {
            _ = try await makeEngine(cloud: cloud, index: index, sink: sink).run(
                projectID: projectID,
                root: project,
                matcher: ExclusionMatcher(rules: [])
            )
            XCTFail("第一次上传应失败")
        } catch {
            // expected
        }
        sink.failObjectUploads = false
        let retry = try await makeEngine(cloud: cloud, index: index, sink: sink).run(
            projectID: projectID,
            root: project,
            matcher: ExclusionMatcher(rules: [])
        )
        XCTAssertTrue(retry.committed)
        XCTAssertEqual(try snapshot(project), before, "失败后的重试不得修改原始文件")
    }

    func testCT238_BackupCancellationDoesNotModifyOriginals() async throws {
        let project = try makeProject()
        let before = try snapshot(project)
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let sink = FailingSink(base: cloud)
        sink.failObjectUploads = false
        let flag = CancelFlag()
        sink.onObjectUpload = { flag.set() }
        let engine = makeEngine(cloud: cloud, index: index, sink: sink)
        do {
            _ = try await engine.run(
                projectID: projectID,
                root: project,
                matcher: ExclusionMatcher(rules: []),
                isCancelled: { flag.isSet }
            )
            XCTFail("取消后备份不得发布成功")
        } catch {
            // expected: cancellation aborts before commit
        }
        XCTAssertEqual(try snapshot(project), before, "取消备份不得修改原始文件")
        XCTAssertTrue(cloud.commits.isEmpty, "取消的备份不得提交云端版本")
    }

    // MARK: - Restore is an independent export

    func testCT239_RestoreCopyDoesNotOverwriteOrHardLinkOriginals() async throws {
        let project = try makeProject()
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let report = try await backup(project, cloud: cloud, index: index)
        let before = try snapshot(project)
        let destination = workspace.appendingPathComponent("restored", isDirectory: true)
        let reader = CloudRestoreEngine(masterKey: masterKey, source: cloud)
        let restored = try await reader.restore(
            projectID: projectID,
            snapshotID: report.snapshotID,
            target: .project,
            destination: destination
        )
        XCTAssertTrue(restored.commited)
        XCTAssertEqual(try snapshot(project), before, "恢复不得修改原始项目")

        let restoredFile = destination.appendingPathComponent("a.txt")
        var info = stat()
        XCTAssertEqual(lstat(restoredFile.path, &info), 0)
        XCTAssertEqual(info.st_nlink, 1, "恢复文件不得与原始项目共享可写 inode")

        // Mutating the export must not leak back into the source, including via a
        // copy-on-write/hardlink shortcut.
        try Data("mutated-export".utf8).write(to: restoredFile)
        XCTAssertEqual(
            try Data(contentsOf: project.appendingPathComponent("a.txt")),
            Data("alpha-content".utf8)
        )
        XCTAssertEqual(try snapshot(project), before)
    }

    func testCT240_RestoreDestinationOverlappingProjectIsRejected() async throws {
        let project = try makeProject()
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let report = try await backup(project, cloud: cloud, index: index)
        let before = try snapshot(project)
        let reader = CloudRestoreEngine(masterKey: masterKey, source: cloud)

        let projectLink = workspace.appendingPathComponent("project-link")
        try FileManager.default.createSymbolicLink(at: projectLink, withDestinationURL: project)
        let candidates: [URL] = [
            project,
            project.appendingPathComponent("restored-inside", isDirectory: true),
            workspace,
            projectLink,
            URL(fileURLWithPath: workspace.appendingPathComponent("PROJECT").path, isDirectory: true),
        ]
        for destination in candidates {
            XCTAssertThrowsError(
                try SafePath.validateRestoreDestination(
                    destination,
                    protectedRoots: [workspace.appendingPathComponent("data", isDirectory: true)],
                    sourceRoots: [project]
                ),
                "恢复目标 \(destination.path) 与原始项目重叠，必须拒绝"
            )
        }

        // Direct engine use is not a bypass: the destination still cannot be the
        // source tree, even if a caller skips the service.
        do {
            _ = try await reader.restore(
                projectID: projectID,
                snapshotID: report.snapshotID,
                target: .project,
                destination: project
            )
            XCTFail("引擎不得写入原始项目")
        } catch {
            // expected: destination exists / policy refusal
        }
        XCTAssertEqual(try snapshot(project), before)
    }

    func testCT241_OverwriteRestoreModeIsRejected() async throws {
        let project = try makeProject()
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let report = try await backup(project, cloud: cloud, index: index)
        let before = try snapshot(project)
        let target = project.appendingPathComponent("a.txt")
        let reader = CloudRestoreEngine(masterKey: masterKey, source: cloud)
        let overwriting = CloudRestoreEngine(
            masterKey: masterKey,
            source: cloud,
            options: RestoreOptions(overwriteDestination: true, sourceRoots: [project])
        )
        do {
            _ = try await overwriting.restore(
                projectID: projectID,
                snapshotID: report.snapshotID,
                target: .file(path: "a.txt"),
                destination: target
            )
            XCTFail("引擎绝不能覆盖原始项目中的文件")
        } catch {
            // expected
        }
        XCTAssertEqual(try snapshot(project), before)
        // The normal reader is unaffected and still exports to a new directory.
        _ = reader
    }

    // MARK: - Local deletion and cloud deletion are one-way

    func testCT242_DeletingLocalSourceKeepsCloudHistoryRestorable() async throws {
        let project = try makeProject()
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let report = try await backup(project, cloud: cloud, index: index)
        let commitCount = cloud.commits.count
        try FileManager.default.removeItem(at: project)
        XCTAssertEqual(cloud.commits.count, commitCount, "删除本地源不得删除云端历史")
        XCTAssertNotNil(cloud.commits[report.snapshotID])

        let destination = workspace.appendingPathComponent("recovered", isDirectory: true)
        let reader = CloudRestoreEngine(masterKey: masterKey, source: cloud)
        _ = try await reader.restore(
            projectID: projectID,
            snapshotID: report.snapshotID,
            target: .project,
            destination: destination
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("a.txt")),
            Data("alpha-content".utf8)
        )
    }

    func testCT243_DeletingCloudObjectsDoesNotModifyOriginals() async throws {
        let project = try makeProject()
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        _ = try await backup(project, cloud: cloud, index: index)
        let before = try snapshot(project)
        for objectID in Array(cloud.objects.keys) { try await cloud.deleteObject(objectID) }
        for packID in Array(cloud.packs.keys) { try await cloud.deletePack(packID) }
        for nodeID in Array(cloud.nodes.keys) { try await cloud.deleteNode(nodeID) }
        for snapshotID in Array(cloud.commits.keys) {
            try await cloud.deleteCommit(projectID: projectID, snapshotID: snapshotID)
            try await cloud.deleteManifest(projectID: projectID, snapshotID: snapshotID)
        }
        XCTAssertEqual(try snapshot(project), before, "云端删除不得通过任何反向同步修改原始项目")
    }

    func testCT244_GarbageCollectionNeverTouchesSourceDirectory() async throws {
        let project = try makeProject()
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for version in 0..<3 {
            try Data("version-\(version)-\(String(repeating: "x", count: 2_000))".utf8)
                .write(to: project.appendingPathComponent("a.txt"))
            try FileManager.default.setAttributes(
                [.modificationDate: start.addingTimeInterval(Double(version) * 86_400)],
                ofItemAtPath: project.appendingPathComponent("a.txt").path
            )
            _ = try await makeEngine(cloud: cloud, index: index).run(
                projectID: projectID,
                root: project,
                matcher: ExclusionMatcher(rules: []),
                snapshotID: "gc-\(version)"
            )
        }
        let before = try snapshot(project)
        let now = start.addingTimeInterval(4 * 86_400)
        let policy = RetentionPolicy(keepLatest: 1, keepDaily: 0, keepWeekly: 0, keepMonthly: 0)
        let collector = CloudGarbageCollector(
            store: cloud,
            masterKey: masterKey,
            deviceID: "device-A",
            index: index,
            gracePeriod: 0,
            clock: { now }
        )
        _ = try await collector.createTombstones(policies: [projectID: policy], now: now)
        _ = try await collector.sweep(policies: [projectID: policy], now: now)
        _ = try await collector.sweep(
            policies: [projectID: policy],
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(try snapshot(project), before, "GC 只能操作云端仓库，绝不能触碰源目录")
    }

    // MARK: - Interrupted restore

    private final class FlakySource: CloudObjectSource, @unchecked Sendable {
        enum Failure: Error { case injected }
        let base: InMemoryCloud
        private let lock = NSLock()
        private var failingObjectID: String?

        init(base: InMemoryCloud) { self.base = base }

        func fail(on objectID: String?) {
            lock.lock(); failingObjectID = objectID; lock.unlock()
        }

        private func shouldFail(_ objectID: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return failingObjectID == objectID
        }

        func readObject(_ objectID: String) async throws -> Data {
            if shouldFail(objectID) { throw Failure.injected }
            return try await base.readObject(objectID)
        }

        func readPack(_ packID: String) async throws -> Data {
            try await base.readPack(packID)
        }

        func readObjectIfPresent(_ objectID: String) async throws -> Data? {
            if shouldFail(objectID) { throw Failure.injected }
            return try await base.readObjectIfPresent(objectID)
        }

        func readPackIfPresent(_ packID: String) async throws -> Data? {
            try await base.readPackIfPresent(packID)
        }

        func readNode(_ nodeID: String) async throws -> DirectoryNode {
            try await base.readNode(nodeID)
        }

        func readManifestPayload(projectID: UUID, snapshotID: String) async throws -> Data {
            try await base.readManifestPayload(projectID: projectID, snapshotID: snapshotID)
        }

        func readCommit(projectID: UUID, snapshotID: String) async throws -> SnapshotCommit? {
            try await base.readCommit(projectID: projectID, snapshotID: snapshotID)
        }

        func commits(projectID: UUID) async throws -> [SnapshotCommit] {
            try await base.commits(projectID: projectID)
        }
    }

    func testCT245_InterruptedRestoreDoesNotDamageOriginals() async throws {
        let project = try makeProject()
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let report = try await backup(project, cloud: cloud, index: index)
        let before = try snapshot(project)
        let nodes = try await index.fileNodes(projectID: projectID)
        let failingID = try XCTUnwrap(nodes.first { $0.path == "src/nested/b.bin" }?.chunks.first?.objectID)
        let source = FlakySource(base: cloud)
        source.fail(on: failingID)
        let destination = workspace.appendingPathComponent("interrupted", isDirectory: true)
        let reader = CloudRestoreEngine(masterKey: masterKey, source: source)
        do {
            _ = try await reader.restore(
                projectID: projectID,
                snapshotID: report.snapshotID,
                target: .project,
                destination: destination
            )
            XCTFail("注入失败后恢复应中断")
        } catch {
            // expected
        }
        XCTAssertEqual(try snapshot(project), before, "中断恢复不得修改原始项目")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        source.fail(on: nil)
        _ = try await reader.restore(
            projectID: projectID,
            snapshotID: report.snapshotID,
            target: .project,
            destination: destination
        )
        XCTAssertEqual(try snapshot(project), before, "恢复重试也不得修改原始项目")
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("a.txt")),
            Data("alpha-content".utf8)
        )
    }
}

/// Service-level destination policy: the service must reject before creating a
/// restore job, and normal whole-project exports must leave the source untouched.
final class RestoreDestinationPolicyTests: XCTestCase {
    private var workspace: URL!
    private var paths: AppPaths!
    private var keychain: KeychainStore!
    private var service: CodeTimeService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-destination-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        paths = AppPaths(root: workspace.appendingPathComponent("data", isDirectory: true))
        keychain = KeychainStore(service: "com.codetime.test.source-readonly.\(UUID().uuidString)")
        service = try CodeTimeService(paths: paths, keychain: keychain)
    }

    override func tearDownWithError() throws {
        if let keychain { keychain.deleteAllSecrets() }
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        service = nil
        try super.tearDownWithError()
    }

    private func configureV3() async throws -> (Project, URL) {
        let mirror = workspace.appendingPathComponent("mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        // Choose v3 before bootstrap so the test does not depend on a local
        // Kopia binary being installed on the test machine.
        var settings = try await service.currentSettings()
        settings.engineMode = .cloudFirst
        settings.iCloudEnabled = false
        settings.localMirrorPath = mirror.path
        settings.cachePreset = .minimal
        settings.spoolSoftLimitBytes = 64 * 1024 * 1024
        _ = try await service.saveSettings(settings)
        _ = try await service.bootstrap()

        let projectRoot = workspace.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent("src"),
            withIntermediateDirectories: true
        )
        try Data("service-alpha".utf8).write(to: projectRoot.appendingPathComponent("a.txt"))
        try Data(String(repeating: "z", count: 20_000).utf8)
            .write(to: projectRoot.appendingPathComponent("src/data.txt"))
        let project = try await service.addProject(url: projectRoot, name: "readonly")
        return (project, projectRoot)
    }

    private func sourceState(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let rootPath = root.standardizedFileURL.path
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in true }
        ) {
            while let url = enumerator.nextObject() as? URL {
                let path = url.standardizedFileURL.path
                let relative = String(path.dropFirst(rootPath.count + 1))
                var info = stat()
                lstat(path, &info)
                let kind = (info.st_mode & S_IFMT) == S_IFDIR ? "d" : "f"
                let data = kind == "f" ? (try? Data(contentsOf: url)) : nil
                let hash = data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "-"
                result[relative] = "\(kind):\(info.st_mode & 0o7777):\(hash)"
            }
        }
        return result
    }

    private func snapshotID(_ project: Project) async throws -> String {
        let outcome = try await service.createSnapshot(projectID: project.id, trigger: .manual)
        XCTAssertNil(outcome.cloudError)
        return outcome.snapshot.id
    }

    func testCT246_ServiceRestoreWritesOnlyToIndependentDestination() async throws {
        let (project, root) = try await configureV3()
        let before = try sourceState(root)
        let snapshot = try await snapshotID(project)
        let destination = workspace.appendingPathComponent("export", isDirectory: true)
        let job = try await service.restore(RestoreRequest(
            projectID: project.id,
            snapshotID: snapshot,
            relativePath: nil,
            mode: .wholeProject,
            destination: destination
        ))
        XCTAssertEqual(job.status, .completed)
        XCTAssertEqual(try sourceState(root), before, "正常恢复也不得修改原始项目")
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("a.txt")),
            Data("service-alpha".utf8)
        )
    }

    func testCT247_ServiceRejectsEqualChildAndAncestorDestinations() async throws {
        let (project, root) = try await configureV3()
        let before = try sourceState(root)
        let snapshot = try await snapshotID(project)
        let destinations: [URL] = [
            root,
            root.appendingPathComponent("inside", isDirectory: true),
            workspace,
        ]
        for destination in destinations {
            do {
                _ = try await service.restore(RestoreRequest(
                    projectID: project.id,
                    snapshotID: snapshot,
                    relativePath: nil,
                    mode: .wholeProject,
                    destination: destination
                ))
                XCTFail("重叠目标必须被拒绝：\(destination.path)")
            } catch let error as CodeTimeError {
                switch error {
                case .pathOverlap, .pathOutsideProject:
                    break
                default:
                    XCTFail("错误类型不符合预期：\(error)")
                }
            }
            XCTAssertEqual(try sourceState(root), before, "拒绝恢复不得触碰原始项目")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("inside").path),
            "拒绝恢复不得在原始项目中创建目录"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(".codetime-restore").path)
        )
    }

    func testCT248_ServiceRejectsOverwriteMode() async throws {
        let (project, root) = try await configureV3()
        let before = try sourceState(root)
        let snapshot = try await snapshotID(project)
        do {
            _ = try await service.restore(RestoreRequest(
                projectID: project.id,
                snapshotID: snapshot,
                relativePath: "a.txt",
                mode: .overwrite,
                destination: root.appendingPathComponent("a.txt")
            ))
            XCTFail("覆盖模式必须被拒绝")
        } catch let error as CodeTimeError {
            guard case .unsupported(let message) = error else {
                XCTFail("错误类型不符合预期：\(error)")
                return
            }
            XCTAssertTrue(message.contains("只读"), message)
        }
        XCTAssertEqual(try sourceState(root), before)
    }

    func testCT249_MirrorInsideSourceIsRejectedBeforeBackup() async throws {
        let (project, root) = try await configureV3()
        let before = try sourceState(root)
        var settings = try await service.currentSettings()
        settings.localMirrorPath = root.appendingPathComponent("mirror-inside").path
        _ = try await service.saveSettings(settings)
        do {
            _ = try await service.createSnapshot(projectID: project.id, trigger: .manual)
            XCTFail("镜像目录位于原始项目内时备份必须拒绝")
        } catch let error as CodeTimeError {
            guard case .pathOverlap = error else {
                XCTFail("错误类型不符合预期：\(error)")
                return
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("mirror-inside").path),
            "拒绝备份不得在原始项目中创建镜像目录"
        )
        XCTAssertEqual(try sourceState(root), before)
    }
}
