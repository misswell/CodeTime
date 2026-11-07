import XCTest
import Foundation
import CryptoKit
@testable import SharedModels
@testable import CloudMirrorStore
@testable import BackupEngine
@testable import Persistence
@testable import CodeTimeSecurity
@testable import CodeTimeCore
@testable import Diagnostics

/// Permanent regressions CT-029 … CT-040 and CT-042 … CT-044
/// (migration, sandbox, large data and capacity limits).
final class SandboxMigrationRegressionTests: XCTestCase {
    private func makeRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codetime-reg-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // CT-029: Beta 数据目录必须可无损迁移；目标已有数据时拒绝合并。
    func testCT029_BetaToReleaseMigrationIsLosslessAndNonDestructive() async throws {
        let root = try makeRoot("ct029")
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("beta", isDirectory: true)
        let target = root.appendingPathComponent("stable", isDirectory: true)
        let database = source.appendingPathComponent("database/codetime.sqlite")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourceStore = try SQLiteStore(path: database.path)
        try await sourceStore.upsertProject(Project(name: "Migrated", rootPath: root.path))
        await sourceStore.close()
        let repositoryID = UUID()
        let repository = source.appendingPathComponent("repositories/\(repositoryID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let blob = Data(repeating: 0x42, count: 4_096)
        try blob.write(to: repository.appendingPathComponent("blob"))
        // Kopia may keep hidden shard directories; they are part of the repository.
        let hidden = repository.appendingPathComponent(".shards", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data("hidden-shard".utf8).write(to: hidden.appendingPathComponent("s1"))

        let plan = try DataMigrator.inspect(source: source, target: target)
        XCTAssertEqual(plan.repositoryCount, 1)
        XCTAssertTrue(plan.hasDatabase)
        XCTAssertTrue(plan.conflicts.isEmpty)
        XCTAssertTrue(plan.isSafeToProceed)

        let result = try DataMigrator.migrate(source: source, target: target)
        XCTAssertEqual(result.fileCount, plan.fileCount)
        let migratedStore = try SQLiteStore(path: target.appendingPathComponent("database/codetime.sqlite").path)
        let migratedProjects = try await migratedStore.projects()
        XCTAssertEqual(migratedProjects.map(\.name), ["Migrated"])
        await migratedStore.close()
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathComponent("repositories/\(repositoryID.uuidString)/blob")),
            blob
        )
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathComponent("repositories/\(repositoryID.uuidString)/.shards/s1")),
            Data("hidden-shard".utf8),
            "隐藏目录必须完整迁移"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: database.path),
            "迁移绝不能删除或改写 Beta 源目录"
        )

        await assertThrowsAsync(
            try DataMigrator.migrate(source: source, target: target)
        ) { error in
            guard let migration = error as? MigrationError, case .targetNotEmpty = migration else {
                return XCTFail("重复迁移必须被拒绝，实际：\(error)")
            }
        }
    }

    // CT-030: 外部项目目录必须可用，而 CodeTime 数据目录及项目嵌套必须被拒绝。
    func testCT030_ExternalProjectAllowedButRecursiveRootsRejected() throws {
        let root = try makeRoot("ct030")
        defer { try? FileManager.default.removeItem(at: root) }
        let appRoot = root.appendingPathComponent("appsupport", isDirectory: true)
        let mirror = root.appendingPathComponent("mirror", isDirectory: true)
        let external = root.appendingPathComponent("external-project", isDirectory: true)
        let nested = appRoot.appendingPathComponent("repositories/inner", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let accepted = ProjectPathValidator.validate(
            url: external,
            existingProjects: [],
            appRoot: appRoot,
            mirrorPath: mirror.path
        )
        XCTAssertTrue(accepted.isAcceptable, "外部项目不应被拒绝：\(accepted.issues)")

        let insideApp = ProjectPathValidator.validate(
            url: nested,
            existingProjects: [],
            appRoot: appRoot,
            mirrorPath: mirror.path
        )
        XCTAssertFalse(insideApp.isAcceptable)
        XCTAssertTrue(insideApp.issues.contains { $0.reason.contains("递归备份") })

        let mirrorInside = ProjectPathValidator.validate(
            url: mirror.appendingPathComponent("inside"),
            existingProjects: [],
            appRoot: appRoot,
            mirrorPath: mirror.path
        )
        XCTAssertFalse(mirrorInside.isAcceptable)

        let existing = Project(name: "Existing", rootPath: external.path)
        let child = external.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let overlap = ProjectPathValidator.validate(
            url: child,
            existingProjects: [existing],
            appRoot: appRoot,
            mirrorPath: nil
        )
        XCTAssertFalse(overlap.isAcceptable)
    }

    // CT-031: 外部镜像书签必须可持久化并跨重启解析到同一路径。
    func testCT031_ExternalMirrorBookmarkSurvivesEncoding() throws {
        let root = try makeRoot("ct031")
        defer { try? FileManager.default.removeItem(at: root) }
        let mirror = root.appendingPathComponent("external-mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)

        let bookmark = try SecurityScopedBookmarks.makeBookmark(for: mirror)
        var settings = AppSettings(iCloudEnabled: false)
        settings.localMirrorPath = mirror.path
        settings.localMirrorBookmark = bookmark
        settings.localMirrorAccessState = .granted

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.localMirrorPath, mirror.path)
        XCTAssertEqual(decoded.localMirrorBookmark, bookmark)
        XCTAssertEqual(decoded.localMirrorAccessState, .granted)

        let resolved = try SecurityScopedBookmarks.resolve(decoded.localMirrorBookmark ?? Data())
        XCTAssertEqual(
            resolved.url.standardizedFileURL.resolvingSymlinksInPath().path,
            mirror.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    // CT-032: 失效书签必须显式失败，让 UI 提示重新授权而不是静默降级。
    func testCT032_StaleBookmarkFailsExplicitly() {
        let garbage = Data("not-a-bookmark".utf8)
        XCTAssertThrowsError(try SecurityScopedBookmarks.resolve(garbage)) { error in
            XCTAssertNotNil(error as? SecurityError, "书签解析失败必须是显式错误：\(error)")
        }
        XCTAssertEqual(SecurityAccessState.stale.displayName, "授权已过期")
    }

    // CT-033: Agent 与 UI 共用数据库时，项目书签必须完整保留。
    func testCT033_ProjectBookmarkIsSharedWithAgentConnection() async throws {
        let root = try makeRoot("ct033")
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let bookmark = try SecurityScopedBookmarks.makeBookmark(for: external)
        let databaseURL = root.appendingPathComponent("database.sqlite")

        let uiStore = try SQLiteStore(path: databaseURL.path)
        let project = Project(
            name: "External",
            rootPath: external.path,
            bookmark: bookmark,
            accessState: .granted
        )
        try await uiStore.upsertProject(project)
        await uiStore.close()

        let agentStore = try SQLiteStore(path: databaseURL.path)
        let loaded = try await agentStore.project(id: project.id)
        XCTAssertEqual(loaded?.bookmark, bookmark)
        XCTAssertEqual(loaded?.accessState, .granted)
        let resolved = try SecurityScopedBookmarks.resolve(loaded?.bookmark ?? Data())
        XCTAssertEqual(
            resolved.url.standardizedFileURL.resolvingSymlinksInPath().path,
            external.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    // CT-034: 首次启动必须能创建数据库、设置与项目，且不允许把数据目录当项目。
    func testCT034_FreshSandboxBootstrap() async throws {
        let root = try makeRoot("ct034")
        defer { try? FileManager.default.removeItem(at: root) }
        let appRoot = root.appendingPathComponent("appsupport", isDirectory: true)
        let databaseURL = appRoot.appendingPathComponent("database/codetime.sqlite")

        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
        let store = try SQLiteStore(path: databaseURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path), "首次打开必须创建数据库")

        let settings = try await store.saveSettingsCAS(
            AppSettings(hasCompletedOnboarding: false),
            expectedRevision: nil
        )
        XCTAssertEqual(settings.configRevision, 1)
        let storedSettings = try await store.codable(AppSettings.self, forKey: "app.settings")
        XCTAssertEqual(storedSettings?.hasCompletedOnboarding, false)

        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = Project(name: "First", rootPath: projectDir.path)
        try await store.upsertProject(project)
        let projects = try await store.projects()
        XCTAssertEqual(projects.map(\.id), [project.id])

        let selfBackup = ProjectPathValidator.validate(
            url: appRoot,
            existingProjects: [],
            appRoot: appRoot,
            mirrorPath: nil
        )
        XCTAssertFalse(selfBackup.isAcceptable, "数据目录本身不可作为项目")
    }

    // CT-035: 丢失的仓库不能被自动重建为空仓库。
    func testCT035_MissingRepositoryIsNotAutoCreated() async throws {
        let root = try makeRoot("ct035")
        defer { try? FileManager.default.removeItem(at: root) }
        let repositoryID = UUID()
        let repositoriesRoot = root.appendingPathComponent("repositories", isDirectory: true)
        let engine = KopiaBackupEngine(configuration: .init(
            repositoryID: repositoryID,
            repositoriesRoot: repositoriesRoot,
            cacheURL: root.appendingPathComponent("cache", isDirectory: true),
            logsURL: root.appendingPathComponent("logs", isDirectory: true),
            binaryURL: URL(fileURLWithPath: "/nonexistent/kopia"),
            passwordProvider: RegressionPassword(value: "p"),
            gitProvider: nil,
            defaultParallelism: 1
        ))

        let metadataURL = engine.repositoryRootURL.appendingPathComponent("repository.json")
        try FileManager.default.createDirectory(
            at: metadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let metadata = RepositoryMetadata(repositoryID: repositoryID, state: .missing)
        try JSONEncoder().encode(metadata).write(to: metadataURL)

        let state = await engine.repositoryState()
        XCTAssertEqual(state, .missing)
        await assertThrowsAsync(try await engine.ensureRepository()) { error in
            guard let code = error as? CodeTimeError else {
                return XCTFail("应为仓库错误，实际：\(error)")
            }
            if case .repositoryMissing = code { return }
            XCTFail("丢失仓库必须报 repositoryMissing，实际：\(code)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: engine.repositoryURL.path),
            "丢失仓库不得被自动创建"
        )
    }

    // CT-036: 十万文件目录的排除预览必须完整且受上限保护（默认不跑，需显式开启）。
    func testCT036_HundredThousandFilesPreview() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CODETIME_SCALE_TESTS"] == "1",
            "NOT RUN: 规模测试需设置 CODETIME_SCALE_TESTS=1"
        )
        let root = try makeRoot("ct036")
        defer { try? FileManager.default.removeItem(at: root) }
        try createFiles(at: root, count: 100_000)

        let matcher = ExclusionMatcher(rules: ExclusionPresets.defaultRules())
        let preview = ExclusionScanner.preview(root: root, matcher: matcher, maxFiles: 200_000)
        XCTAssertTrue(preview.isComplete)
        XCTAssertNil(preview.truncatedReason)
        XCTAssertGreaterThanOrEqual(preview.scannedFiles, 100_000)
        XCTAssertEqual(preview.permissionErrors, 0)
    }

    // CT-037: 百万文件扫描必须在上限处截断，而不是无限增长（默认不跑）。
    func testCT037_MillionFilesBoundedByLimit() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CODETIME_SCALE_TESTS"] == "1",
            "NOT RUN: 规模测试需设置 CODETIME_SCALE_TESTS=1"
        )
        let root = try makeRoot("ct037")
        defer { try? FileManager.default.removeItem(at: root) }
        try createFiles(at: root, count: 1_000_000)

        let matcher = ExclusionMatcher(rules: ExclusionPresets.defaultRules())
        let preview = ExclusionScanner.preview(root: root, matcher: matcher, maxFiles: 50_000)
        XCTAssertFalse(preview.isComplete)
        XCTAssertNotNil(preview.truncatedReason)
        XCTAssertEqual(preview.scannedFiles, 50_000, "扫描必须在 maxFiles 处停止")
    }

    // CT-038: 大文件哈希必须流式分块，结果与一次性哈希一致。
    func testCT038_LargeFileHashStreamsInChunks() throws {
        let root = try makeRoot("ct038")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.bin")
        var data = Data(count: 8 * 1024 * 1024)
        for index in stride(from: 0, to: data.count, by: 4_096) {
            data[index] = UInt8(truncatingIfNeeded: index)
        }
        try data.write(to: file)

        var hasher = SHA256()
        hasher.update(data: data)
        let expected = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        let chunked = try Hashing.sha256Hex(fileURL: file, chunkSize: 64 * 1024)
        XCTAssertEqual(chunked, expected)
        XCTAssertEqual(chunked.count, 64)
    }

    // CT-039: 搜索结果超过上限时必须报告截断，而不是返回不完整的“成功”结果。
    func testCT039_SearchTruncationIsExplicit() async throws {
        guard let binary = KopiaBinary.locate() else {
            throw XCTSkip("KOPIA_PATH 未设置，跳过搜索截断测试")
        }
        let root = try makeRoot("ct039")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for index in 0..<50 {
            try "content-\(index)".write(
                to: source.appendingPathComponent(String(format: "file-%02d.txt", index)),
                atomically: true,
                encoding: .utf8
            )
        }
        let engine = makeEngine(root: root, binary: binary)
        let project = Project(name: "Search", rootPath: source.path)
        let snapshot = try await engine.createSnapshot(
            project: project,
            policy: BackupPolicy(projectID: project.id),
            trigger: .manual
        )

        let result = try await engine.searchFiles(
            snapshotID: snapshot.id,
            query: "file-",
            limits: SearchLimits(
                maxDirectories: 100,
                maxFiles: 10_000,
                maxDepth: 16,
                maxDuration: 30,
                maxResults: 5
            )
        )
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.entries.count, 5)
        XCTAssertEqual(result.truncationReason, "结果超过 5 条")
    }

    // CT-040: 超过预览上限的大文件必须降级为显式错误，而不是截断内容。
    func testCT040_LargeFilePreviewDegradesExplicitly() async throws {
        guard let binary = KopiaBinary.locate() else {
            throw XCTSkip("KOPIA_PATH 未设置，跳过文件预览上限测试")
        }
        let root = try makeRoot("ct040")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x5a, count: 2 * 1024 * 1024)
        try payload.write(to: source.appendingPathComponent("big.bin"))
        let engine = makeEngine(root: root, binary: binary)
        let project = Project(name: "Large", rootPath: source.path)
        let snapshot = try await engine.createSnapshot(
            project: project,
            policy: BackupPolicy(projectID: project.id),
            trigger: .manual
        )

        await assertThrowsAsync(
            try await engine.readFile(snapshotID: snapshot.id, path: "big.bin", maxBytes: 1_024)
        ) { error in
            guard let code = error as? CodeTimeError, case .fileTooLarge = code else {
                return XCTFail("应报告文件过大，实际：\(error)")
            }
        }
    }

    // CT-042: 日志文件达到上限必须轮转，归档数量受 maxArchives 约束。
    func testCT042_LogRotationIsBounded() async throws {
        let root = try makeRoot("ct042")
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = root.appendingPathComponent("logs/codetime.log")
        let logger = FileLogger(fileURL: logURL, maxBytes: 256 * 1024, maxArchives: 2, maxAge: 3_600)
        let line = String(repeating: "x", count: 1_024)
        for index in 0..<600 {
            await logger.info("line-\(index)-\(line)")
        }

        let directory = logURL.deletingLastPathComponent()
        let archives = ((try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )).filter { $0.lastPathComponent != logURL.lastPathComponent })
        XCTAssertGreaterThanOrEqual(archives.count, 1, "写入应触发至少一次轮转")
        XCTAssertLessThanOrEqual(archives.count, 2, "归档数量必须受 maxArchives 限制")

        let currentSize = (try FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertLessThanOrEqual(currentSize, 256 * 1024 + 2_048, "单个日志文件必须有界")

        let totalBytes = archives.reduce(Int64(0)) { partial, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return partial + size
        } + currentSize
        XCTAssertLessThan(totalBytes, 1_024 * 1_024, "日志总量必须有界")
    }

    // CT-043: 哈希缓存与活动日志必须可按保留集合裁剪，内存/数据库不会无限增长。
    func testCT043_CacheAndActivityTablesArePruned() async throws {
        let root = try makeRoot("ct043")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(path: root.appendingPathComponent("database.sqlite").path)
        let repositoryID = UUID()

        var keep: Set<String> = []
        for index in 0..<100 {
            let path = "file-\(index).txt"
            if index < 10 { keep.insert(path) }
            let entry = ObjectHashCacheEntry(
                relativePath: path,
                fileIdentity: "1:\(index)",
                size: 4,
                modifiedAt: Date(),
                contentHash: String(format: "%064d", index)
            )
            try await store.saveHashCacheEntry(entry, repositoryID: repositoryID)
        }
        try await store.pruneObjectHashCache(repositoryID: repositoryID, keepPaths: keep)
        for index in 0..<100 {
            let entry = try await store.hashCacheEntry(
                repositoryID: repositoryID,
                relativePath: "file-\(index).txt"
            )
            if index < 10 {
                XCTAssertNotNil(entry, "保留集合内的缓存必须存在")
            } else {
                XCTAssertNil(entry, "保留集合外的缓存必须被删除")
            }
        }

        for index in 0..<200 {
            try await store.appendActivity(ActivityEvent(
                kind: .backup,
                message: "event-\(index)"
            ))
        }
        try await store.trimActivities(keep: 50)
        let activities = try await store.activities(limit: 500)
        XCTAssertEqual(activities.count, 50)
        XCTAssertEqual(activities.first?.message, "event-199", "裁剪必须保留最新活动")
    }

    // CT-044: 磁盘写满时不得破坏正式仓库（当前环境无法可靠注入 ENOSPC）。
    func testCT044_DiskFullLeavesRepositoryUntouched() throws {
        throw XCTSkip("NOT RUN: 需要可控的小容量卷注入 ENOSPC；由 §16.6 真机验收覆盖")
    }

    // MARK: - Helpers

    private func makeEngine(root: URL, binary: URL) -> KopiaBackupEngine {
        KopiaBackupEngine(configuration: .init(
            repositoryID: UUID(),
            repositoriesRoot: root.appendingPathComponent("repositories", isDirectory: true),
            cacheURL: root.appendingPathComponent("cache", isDirectory: true),
            logsURL: root.appendingPathComponent("logs", isDirectory: true),
            binaryURL: binary,
            passwordProvider: RegressionPassword(value: "regression-kopia-password"),
            gitProvider: nil,
            defaultParallelism: 1
        ))
    }

    private func createFiles(at root: URL, count: Int) throws {
        let directory = root.appendingPathComponent("scale", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<count {
            let url = directory.appendingPathComponent("f-\(index).txt")
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
    }
}

/// §16.6 requires two real Macs, a signed Release build and a real iCloud
/// container. The automated part below is a single-Mac iCloud round trip; the
/// two-Mac matrix remains a manual acceptance report required by
/// `Scripts/require_icloud_acceptance.sh` for stable releases.
final class ICloudAcceptanceTests: XCTestCase {
    func testSingleMacICloudRoundTrip() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["CODETIME_ICLOUD_TESTS"] == "1",
            "NOT RUN: 设置 CODETIME_ICLOUD_TESTS=1 和 CODETIME_ICLOUD_CONTAINER 后执行单机 iCloud 往返"
        )
        guard let containerPath = environment["CODETIME_ICLOUD_CONTAINER"],
              !containerPath.isEmpty else {
            throw XCTSkip("NOT RUN: 未提供真实 iCloud 容器路径")
        }
        let container = URL(fileURLWithPath: containerPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: container.path) else {
            throw XCTSkip("NOT RUN: iCloud 容器不存在：\(container.path)")
        }

        let root = container.appendingPathComponent("CodeTimeAcceptance-\(UUID().uuidString)", isDirectory: true)
        let repositoryRoot = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryRoot, withIntermediateDirectories: true)
        try "icloud-round-trip".write(
            to: repositoryRoot.appendingPathComponent("payload.txt"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let repositoryID = UUID()
        let deviceID = UUID()
        let key = Data((0..<32).map { UInt8(($0 * 19 + 7) % 251) })
        let store = CloudMirrorStore(configuration: .init(
            storageRoot: root,
            repositoryID: repositoryID,
            repositoryURL: repositoryRoot,
            deviceID: deviceID,
            deviceName: "Acceptance-\(deviceID.uuidString.prefix(4))",
            masterKeyProvider: RegressionMasterKey(value: key),
            passwordProvider: RegressionPassword(value: "acceptance-password"),
            uploadTracker: UbiquitousUploadTracker(containerURL: container),
            coordinatedIO: true,
            uploadTimeout: 300
        ))
        let generationID = UUID()
        try await store.publish(
            repositoryId: repositoryID,
            generation: CloudGeneration(id: generationID, repositoryID: repositoryID, deviceID: deviceID)
        )
        let persisted = await store.confirmPublished(generationId: generationID)
        XCTAssertTrue(persisted, "真实 iCloud 未确认上传，不能报告发布成功")

        let restored = FileManager.default.temporaryDirectory
            .appendingPathComponent("codetime-icloud-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: restored) }
        try await store.restoreRepository(generationId: generationID, destination: restored)
        XCTAssertEqual(
            try String(contentsOf: restored.appendingPathComponent("payload.txt"), encoding: .utf8),
            "icloud-round-trip"
        )
    }
}
