import XCTest
import Foundation
@testable import SharedModels
@testable import BackupEngine
@testable import CloudMirrorStore
@testable import Persistence
@testable import CodeTimeSecurity
@testable import CodeTimeCore

private struct TestPassword: RepositoryPasswordProviding {
    let value: String
    func repositoryPassword() throws -> String { value }
}

private struct TestMasterKey: MasterKeyProviding {
    let value: Data
    func masterKey() throws -> Data { value }
}

final class ExclusionMatcherTests: XCTestCase {
    func testDefaultDeveloperRules() {
        let rules = ExclusionPresets.defaultRules()
        let matcher = ExclusionMatcher(rules: rules, includeEnvFiles: false)
        XCTAssertTrue(matcher.isExcluded(relativePath: "node_modules/react/index.js", isDirectory: false))
        XCTAssertTrue(matcher.isExcluded(relativePath: "app/build/out.bin", isDirectory: false))
        XCTAssertTrue(matcher.isExcluded(relativePath: "logs/debug.log", isDirectory: false))
        XCTAssertTrue(matcher.isExcluded(relativePath: ".env", isDirectory: false))
        XCTAssertFalse(matcher.isExcluded(relativePath: ".env.example", isDirectory: false))
        XCTAssertFalse(matcher.isExcluded(relativePath: "package-lock.json", isDirectory: false))
        XCTAssertFalse(matcher.isExcluded(relativePath: ".git/config", isDirectory: false))
    }

    func testGitDirectoryCanBeExcluded() {
        let matcher = ExclusionMatcher(
            rules: [ExclusionRule(pattern: ".git/")],
            includeGitDirectory: false
        )
        XCTAssertTrue(matcher.isExcluded(relativePath: ".git/config", isDirectory: false))
    }

    func testNegationIsNotSupportedToMatchKopia() {
        let matcher = ExclusionMatcher(rules: [ExclusionRule(pattern: "*.log"), ExclusionRule(pattern: "!keep.log")])
        XCTAssertTrue(matcher.isExcluded(relativePath: "keep.log", isDirectory: false))
    }
}

final class SQLiteStoreTests: XCTestCase {
    func testProjectAndSnapshotRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codetime-db-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStore(path: url.path)
        let project = Project(name: "Demo", rootPath: "/tmp/demo")
        try await store.upsertProject(project)
        let projects = try await store.projects()
        XCTAssertEqual(projects.count, 1)

        let snapshot = Snapshot(id: "abc", projectID: project.id, createdAt: Date())
        try await store.upsertSnapshot(snapshot)
        let snapshots = try await store.snapshots(projectID: project.id)
        XCTAssertEqual(snapshots.first?.id, "abc")
        let count = try await store.snapshotCount()
        XCTAssertEqual(count, 1)

        let job = BackupJob(projectID: project.id, type: .backup, state: .running)
        try await store.upsertJob(job)
        let recovered = try await store.recoverInterruptedJobs()
        XCTAssertEqual(recovered.count, 1)
        let interrupted = try await store.jobs(state: .interrupted)
        XCTAssertEqual(interrupted.count, 1)
        let failed = try await store.jobs(state: .failed)
        XCTAssertEqual(failed.count, 0)
    }
}

final class KopiaEngineIntegrationTests: XCTestCase {
    private var root: URL!
    private var engine: KopiaBackupEngine!

    override func setUpWithError() throws {
        guard let binary = KopiaBinary.locate() else {
            throw XCTSkip("KOPIA_PATH 未设置，跳过 Kopia 集成测试")
        }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("codetime-kopia-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        engine = KopiaBackupEngine(configuration: .init(
            repositoryID: UUID(),
            repositoriesRoot: root.appendingPathComponent("repositories"),
            cacheURL: root.appendingPathComponent("cache"),
            logsURL: root.appendingPathComponent("logs"),
            binaryURL: binary,
            passwordProvider: TestPassword(value: "test-password-123"),
            gitProvider: nil,
            defaultParallelism: 1
        ))
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testSnapshotBrowseRestoreAndVerify() async throws {
        let source = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "hello v1\n".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "nested\n".write(to: source.appendingPathComponent("sub/b.md"), atomically: true, encoding: .utf8)
        try "ignored\n".write(to: source.appendingPathComponent("debug.log"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try "dep\n".write(to: source.appendingPathComponent("node_modules/dep.js"), atomically: true, encoding: .utf8)
        try "secret\n".write(to: source.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try "root-only\n".write(to: source.appendingPathComponent("root-only.txt"), atomically: true, encoding: .utf8)
        try "nested-root-only\n".write(to: source.appendingPathComponent("sub/root-only.txt"), atomically: true, encoding: .utf8)
        try "secret.txt\n".write(to: source.appendingPathComponent(".kopiaignore"), atomically: true, encoding: .utf8)

        let project = Project(name: "Fixture", rootPath: source.path)
        let policy = BackupPolicy(
            projectID: project.id,
            excludeRules: ExclusionPresets.defaultRules() + [
                ExclusionRule(pattern: "/root-only.txt"),
            ]
        )
        try await engine.ensureRepository()
        let first = try await engine.createSnapshot(project: project, policy: policy, trigger: .manual)
        XCTAssertEqual(first.status, .complete)
        XCTAssertGreaterThanOrEqual(first.fileCount, 2)
        let listed = try await engine.listSnapshots(project: project)
        XCTAssertEqual(listed.first?.id, first.id)

        let entries = try await engine.listDirectory(snapshotID: first.id, path: "")
        XCTAssertTrue(entries.contains { $0.name == "a.txt" })
        XCTAssertFalse(entries.contains { $0.name == "node_modules" })
        XCTAssertFalse(entries.contains { $0.name == "debug.log" })
        XCTAssertFalse(entries.contains { $0.name == "secret.txt" })
        XCTAssertFalse(entries.contains { $0.name == "root-only.txt" })
        let subEntries = try await engine.listDirectory(snapshotID: first.id, path: "sub")
        XCTAssertTrue(subEntries.contains { $0.name == "root-only.txt" })

        let data = try await engine.readFile(snapshotID: first.id, path: "a.txt", maxBytes: 1024)
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello v1\n")

        let search = try await engine.searchFiles(snapshotID: first.id, query: "b.md")
        XCTAssertFalse(search.truncated)
        XCTAssertEqual(search.entries.first?.path, "sub/b.md")

        try "hello v2\n".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let second = try await engine.createSnapshot(project: project, policy: policy, trigger: .scheduled)
        let ordered = try await engine.listSnapshots(project: project)
        XCTAssertEqual(ordered.map(\.id), [second.id, first.id], "快照必须按最新在前排序")
        let diff = try await engine.diff(from: first.id, to: second.id)
        XCTAssertEqual(diff.modified, 1)
        XCTAssertEqual(diff.files.first?.path, "a.txt")

        let restoredFile = root.appendingPathComponent("restored-a.txt")
        try await engine.restore(snapshotID: second.id, path: "a.txt", destination: restoredFile, overwrite: false)
        let restoredText = try String(contentsOf: restoredFile, encoding: .utf8)
        XCTAssertEqual(restoredText, "hello v2\n")

        let whole = root.appendingPathComponent("whole")
        try await engine.restore(snapshotID: first.id, path: nil, destination: whole, overwrite: false)
        let wholeText = try String(contentsOf: whole.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(wholeText, "hello v1\n")

        let verification = try await engine.verify(snapshotID: second.id)
        XCTAssertEqual(verification.outcome, .passed)
        XCTAssertEqual(verification.details.isEmpty, false)

        let sourcePaths = try await engine.snapshotSourcePaths()
        XCTAssertEqual(sourcePaths, [source.path])
    }

    func testRestoreRefusesOverwriteByDefault() async throws {
        let source = root.appendingPathComponent("src2")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "new\n".write(to: source.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        let project = Project(name: "Fixture2", rootPath: source.path)
        let policy = BackupPolicy(projectID: project.id)
        let snapshot = try await engine.createSnapshot(project: project, policy: policy, trigger: .manual)

        let target = root.appendingPathComponent("existing.txt")
        try "old\n".write(to: target, atomically: true, encoding: .utf8)
        do {
            try await engine.restore(snapshotID: snapshot.id, path: "x.txt", destination: target, overwrite: false)
            XCTFail("应当拒绝覆盖")
        } catch {
            let text = try String(contentsOf: target, encoding: .utf8)
            XCTAssertEqual(text, "old\n")
        }
    }
}

final class CloudMirrorStoreTests: XCTestCase {
    private var root: URL!
    private var repoURL: URL!
    private var storageRoot: URL!
    private var repositoryID: UUID!
    private var deviceID: UUID!
    private var store: CloudMirrorStore!
    private let masterKey = Data((0..<32).map { UInt8($0) })

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("codetime-cloud-\(UUID().uuidString)")
        repoURL = root.appendingPathComponent("repository")
        storageRoot = root.appendingPathComponent("iCloud/CodeTime")
        repositoryID = UUID()
        deviceID = UUID()
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try writeRepoFile("kopia.repository", "format-block")
        try writeRepoFile("packs/p1", "content-one")
        try writeRepoFile("indexes/i1", "index-one")
        store = makeStore()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func makeStore(sweepGrace: TimeInterval = 3_600) -> CloudMirrorStore {
        CloudMirrorStore(configuration: .init(
            storageRoot: storageRoot,
            repositoryID: repositoryID,
            repositoryURL: repoURL,
            deviceID: deviceID,
            masterKeyProvider: TestMasterKey(value: masterKey),
            passwordProvider: TestPassword(value: "repo-password"),
            sweepGrace: sweepGrace
        ))
    }

    private func writeRepoFile(_ relative: String, _ content: String) throws {
        let url = repoURL.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func objectFilePaths() throws -> Set<String> {
        let devices = storageRoot.appendingPathComponent("devices")
        var result = Set<String>()
        guard let enumerator = FileManager.default.enumerator(at: devices, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return result
        }
        while let url = enumerator.nextObject() as? URL {
            guard url.path.contains("/objects/"), !url.path.contains(".tmp-") else { continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if !isDirectory { result.insert(url.path) }
        }
        return result
    }

    func testPublishRestoreVerifyAndRecovery() async throws {
        let empty = try await store.listGenerations(repositoryId: repositoryID)
        XCTAssertTrue(empty.isEmpty)

        let generation = CloudGeneration(repositoryID: repositoryID, deviceID: UUID(), snapshotIDs: ["snap-1"])
        try await store.publish(repositoryId: repositoryID, generation: generation)

        let generations = try await store.listGenerations(repositoryId: repositoryID)
        XCTAssertEqual(generations.count, 1)
        XCTAssertEqual(generations.first?.id, generation.id)

        let restored = root.appendingPathComponent("restored-repo")
        try await store.restoreRepository(generationId: generation.id, destination: restored)
        let restoredContent = try String(contentsOf: restored.appendingPathComponent("packs/p1"), encoding: .utf8)
        XCTAssertEqual(restoredContent, "content-one")

        let verification = try await store.verifyGeneration(generation.id)
        XCTAssertEqual(verification.outcome, .passed)

        let summary = try await store.storageSummary(repositoryId: repositoryID)
        XCTAssertEqual(summary.objectCount, 3)
        XCTAssertEqual(summary.generationCount, 1)

        let recovered = try await CloudMirrorStore.recover(storageRoot: storageRoot, recoveryKey: masterKey)
        XCTAssertEqual(recovered.repositoryPassword, "repo-password")
        XCTAssertEqual(recovered.repositoryID, repositoryID)
    }

    func testMissingObjectIsDetected() async throws {
        let generation = CloudGeneration(repositoryID: repositoryID, deviceID: UUID(), snapshotIDs: ["s1"])
        try await store.publish(repositoryId: repositoryID, generation: generation)
        let objects = try objectFilePaths()
        let victim = try XCTUnwrap(objects.first)
        try FileManager.default.removeItem(atPath: victim)

        let verification = try await store.verifyGeneration(generation.id)
        XCTAssertEqual(verification.outcome, .failed)

        let destination = root.appendingPathComponent("restore-missing")
        do {
            try await store.restoreRepository(generationId: generation.id, destination: destination)
            XCTFail("对象缺失时必须拒绝恢复")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("packs/p1").path))
        }
    }

    func testObjectsRemainImmutableAcrossGenerations() async throws {
        let first = CloudGeneration(repositoryID: repositoryID, deviceID: UUID(), snapshotIDs: ["s1"])
        try await store.publish(repositoryId: repositoryID, generation: first)
        let firstObjects = try objectFilePaths()
        XCTAssertEqual(firstObjects.count, 3)

        try writeRepoFile("packs/p1", "content-two")
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let second = CloudGeneration(repositoryID: repositoryID, deviceID: UUID(), snapshotIDs: ["s2"])
        try await store.publish(repositoryId: repositoryID, generation: second)

        let after = try objectFilePaths()
        XCTAssertTrue(firstObjects.isSubset(of: after), "旧对象不应被覆盖或删除")

        let restored = root.appendingPathComponent("restored-old")
        try await store.restoreRepository(generationId: first.id, destination: restored)
        let text = try String(contentsOf: restored.appendingPathComponent("packs/p1"), encoding: .utf8)
        XCTAssertEqual(text, "content-one")
    }

    func testCleanupRetainsReferencedObjects() async throws {
        var generations: [CloudGeneration] = []
        for index in 0..<3 {
            try writeRepoFile("packs/p1", "content-\(index)")
            try await Task.sleep(nanoseconds: 50_000_000)
            let gen = CloudGeneration(repositoryID: repositoryID, deviceID: UUID(), snapshotIDs: ["s\(index)"])
            try await store.publish(repositoryId: repositoryID, generation: gen)
            generations.append(gen)
        }

        // Retention assertions run with the synchronization grace disabled; the
        // grace phase itself is covered by CT-002/CT-003.
        let report = try await makeStore(sweepGrace: 0).cleanup(
            repositoryId: repositoryID,
            gracePeriod: 0,
            minimumGenerations: 2
        )
        XCTAssertEqual(report.retainedGenerations, 2)
        XCTAssertNil(report.skippedReason)

        let newest = try await store.listGenerations(repositoryId: repositoryID)
        XCTAssertEqual(newest.count, 2)
        XCTAssertTrue(newest.contains { $0.id == generations[2].id }, "最新版本必须被保留")
        let restored = root.appendingPathComponent("restored-newest")
        try await store.restoreRepository(generationId: newest[0].id, destination: restored)
        let text = try String(contentsOf: restored.appendingPathComponent("packs/p1"), encoding: .utf8)
        XCTAssertEqual(text, "content-2")
    }
}

final class ProcessRunnerTests: XCTestCase {
    func testVersionCommand() async throws {
        guard let binary = KopiaBinary.locate() else { throw XCTSkip("no kopia") }
        let result = try await ProcessRunner().run(executable: binary, arguments: ["--version"], timeout: 30)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdoutText.contains("0.23.1"))
    }
}

final class ServiceEndToEndTests: XCTestCase {
    func testBackupPublishVerifyRestore() async throws {
        guard KopiaBinary.locate() != nil else { throw XCTSkip("KOPIA_PATH 未设置") }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codetime-service-\(UUID().uuidString)")
        let paths = AppPaths(root: root.appendingPathComponent("app"))
        let keychain = KeychainStore(service: "com.codetime.test.\(UUID().uuidString)")
        defer {
            keychain.deleteAllSecrets()
            try? FileManager.default.removeItem(at: root)
        }

        let source = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "func main() {}\n".write(to: source.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

        let service = try CodeTimeService(paths: paths, keychain: keychain)
        let report = try await service.bootstrap()
        XCTAssertGreaterThanOrEqual(report.recoveredInterruptedJobs, 0)

        let project = try await service.addProject(url: source)
        var settings = try await service.currentSettings()
        let mirror = root.appendingPathComponent("mirror")
        settings.localMirrorPath = mirror.path
        settings.iCloudEnabled = false
        try await service.saveSettings(settings)

        let outcome = try await service.createSnapshot(projectID: project.id, trigger: .manual)
        XCTAssertNil(outcome.cloudError)
        XCTAssertEqual(outcome.snapshot.status, .complete)
        let snapshots = try await service.refreshSnapshots(projectID: project.id)
        XCTAssertEqual(snapshots.count, 1)
        let snapshotID = try XCTUnwrap(snapshots.first?.id)

        let entries = try await service.listDirectory(snapshotID: snapshotID, path: "")
        XCTAssertTrue(entries.contains { $0.name == "main.swift" })

        let content = try await service.readFile(snapshotID: snapshotID, path: "main.swift", maxBytes: 1024)
        XCTAssertEqual(String(data: content, encoding: .utf8), "func main() {}\n")

        let secondSource = root.appendingPathComponent("project2")
        try FileManager.default.createDirectory(at: secondSource, withIntermediateDirectories: true)
        try "second\n".write(to: secondSource.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
        let secondProject = try await service.addProject(url: secondSource)
        _ = try await service.createSnapshot(projectID: secondProject.id, trigger: .manual)
        let wrongTarget = root.appendingPathComponent("wrong-target.txt")
        do {
            _ = try await service.restore(RestoreRequest(
                projectID: secondProject.id,
                snapshotID: snapshotID,
                relativePath: "main.swift",
                mode: .copy,
                destination: wrongTarget
            ))
            XCTFail("跨项目恢复必须被拒绝")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: wrongTarget.path))
        }

        let verification = try await service.verifySnapshot(projectID: project.id, snapshotID: snapshotID)
        XCTAssertEqual(verification.outcome, .passed)

        let summary = try await service.cloudSummary()
        let cloudSummary = try XCTUnwrap(summary)
        XCTAssertGreaterThan(cloudSummary.objectCount, 0)

        let cloudVerification = try await service.verifyCloud()
        XCTAssertEqual(cloudVerification?.outcome, .passed)

        let restoreTarget = root.appendingPathComponent("restored")
        let job = try await service.restore(RestoreRequest(
            projectID: project.id,
            snapshotID: snapshotID,
            relativePath: nil,
            mode: .wholeProject,
            destination: restoreTarget
        ))
        XCTAssertEqual(job.status, .completed)
        let restored = try String(contentsOf: restoreTarget.appendingPathComponent("main.swift"), encoding: .utf8)
        XCTAssertEqual(restored, "func main() {}\n")

        _ = try keychain.repositoryPassword()

        // Simulate a fresh Mac: new application data directory, same recovery key.
        let freshPaths = AppPaths(root: root.appendingPathComponent("fresh"))
        let freshService = try CodeTimeService(paths: freshPaths, keychain: keychain)
        _ = try await freshService.bootstrap()
        let recovered = try await freshService.recoverFromCloud(
            storageRoot: mirror,
            recoveryKeyText: keychain.recoveryKeyText()
        )
        XCTAssertTrue(recovered.sourcePaths.contains(source.path))
        XCTAssertNotEqual(recovered.repositoryID, UUID())

        // A recovered project whose original directory no longer exists must still
        // be browsable from the repository.
        let recoveredProject = try await freshService.addRecoveredProject(sourcePath: source.path)
        try FileManager.default.removeItem(at: source)
        let recoveredSnapshots = try await freshService.refreshSnapshots(projectID: recoveredProject.id)
        XCTAssertEqual(recoveredSnapshots.count, 1)

        let cleanup = try await service.cleanupCloud()
        XCTAssertNotNil(cleanup)
    }
}

final class RepositoryReplicationTests: XCTestCase {
    func testRepositoryRoundTripsThroughCloudStore() async throws {
        guard let binary = KopiaBinary.locate() else { throw XCTSkip("no kopia") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codetime-repl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let repoID = UUID()
        let deviceID = UUID()
        let reposRoot = root.appendingPathComponent("repos")
        let password = "replication-password"
        let master = Data((0..<32).map { UInt8($0) })

        let engine = KopiaBackupEngine(configuration: .init(
            repositoryID: repoID,
            repositoriesRoot: reposRoot,
            cacheURL: root.appendingPathComponent("cache"),
            logsURL: root.appendingPathComponent("logs"),
            binaryURL: binary,
            passwordProvider: TestPassword(value: password),
            gitProvider: nil,
            defaultParallelism: 1
        ))
        let source = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "hello\n".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "nested\n".write(to: source.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try await engine.ensureRepository()
        let project = Project(name: "R", rootPath: source.path)
        _ = try await engine.createSnapshot(project: project, policy: BackupPolicy(projectID: project.id), trigger: .manual)

        let cloudRoot = root.appendingPathComponent("cloud/CodeTime")
        let store = CloudMirrorStore(configuration: .init(
            storageRoot: cloudRoot,
            repositoryID: repoID,
            repositoryURL: engine.repositoryURL,
            deviceID: deviceID,
            masterKeyProvider: TestMasterKey(value: master),
            passwordProvider: TestPassword(value: password)
        ))
        let generation = CloudGeneration(repositoryID: repoID, deviceID: deviceID, snapshotIDs: ["s1"])
        try await store.publish(repositoryId: repoID, generation: generation)

        let restoredRepo = root.appendingPathComponent("restored/\(repoID.uuidString)/repo")
        try await store.restoreRepository(generationId: generation.id, destination: restoredRepo)

        let sourceFiles = try fileHashes(engine.repositoryURL)
        let restoredFiles = try fileHashes(restoredRepo)
        XCTAssertEqual(sourceFiles, restoredFiles, "恢复出的仓库文件必须与原仓库完全一致")

        let second = KopiaBackupEngine(configuration: .init(
            repositoryID: repoID,
            repositoriesRoot: root.appendingPathComponent("restored"),
            cacheURL: root.appendingPathComponent("cache2"),
            logsURL: root.appendingPathComponent("logs2"),
            binaryURL: binary,
            passwordProvider: TestPassword(value: password),
            gitProvider: nil,
            defaultParallelism: 1
        ))
        try await second.ensureRepository()
        let sources = try await second.snapshotSourcePaths()
        XCTAssertEqual(sources, [source.path])
    }

    private func hashDirectory(_ root: URL) throws -> [String: String] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [:] }
        var result: [String: String] = [:]
        let rootPath = root.standardizedFileURL.path
        while let url = enumerator.nextObject() as? URL {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory { continue }
            var relative = url.standardizedFileURL.path
            relative = String(relative.dropFirst(rootPath.count))
            if relative.hasPrefix("/") { relative.removeFirst() }
            result[relative] = try Hashing.sha256Hex(fileURL: url)
        }
        return result
    }

    private func fileHashes(_ root: URL) throws -> [String: String] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [:] }
        var result: [String: String] = [:]
        let rootPath = root.standardizedFileURL.path
        while let url = enumerator.nextObject() as? URL {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory { continue }
            var relative = url.standardizedFileURL.path
            relative = String(relative.dropFirst(rootPath.count))
            if relative.hasPrefix("/") { relative.removeFirst() }
            result[relative] = try Hashing.sha256Hex(fileURL: url)
        }
        return result
    }
}


private func hashDirectoryTree(_ root: URL) throws -> [String: String] {
    let keys: [URLResourceKey] = [.isDirectoryKey]
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [:] }
    var result: [String: String] = [:]
    let rootPath = root.standardizedFileURL.path
    while let url = enumerator.nextObject() as? URL {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDirectory { continue }
        var relative = url.standardizedFileURL.path
        relative = String(relative.dropFirst(rootPath.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        result[relative] = try Hashing.sha256Hex(fileURL: url)
    }
    return result
}
