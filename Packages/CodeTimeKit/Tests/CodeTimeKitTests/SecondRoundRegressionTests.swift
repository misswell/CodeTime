import XCTest
import Foundation
@testable import SharedModels
@testable import CloudMirrorStore
@testable import CodeTimeCore
@testable import Persistence
@testable import BackupEngine
@testable import CodeTimeSecurity

/// Second-round regressions CT-045 … CT-057. These encode the failure modes
/// found in the c81fda5 review rather than the happy path.
final class SecondRoundRegressionTests: XCTestCase {
    private func makeRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codetime-second-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDatabase(at directory: URL, projectName: String) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteStore(path: directory.appendingPathComponent("codetime.sqlite").path)
        try await store.upsertProject(Project(name: projectName, rootPath: directory.path))
        await store.close()
    }

    private func scaffoldReleaseTarget(_ root: URL) async throws -> URL {
        let target = root.appendingPathComponent("release", isDirectory: true)
        try await makeDatabase(at: target.appendingPathComponent("database"), projectName: "Release")
        let repositories = target.appendingPathComponent("repositories", isDirectory: true)
        try FileManager.default.createDirectory(at: repositories, withIntermediateDirectories: true)
        let repo = repositories.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data("kopia.repository".utf8).write(to: repo.appendingPathComponent("kopia.repository"))
        for name in ["cache", "spool", "logs", "recovery"] {
            try FileManager.default.createDirectory(
                at: target.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        return target
    }

    private func makeBetaSource(_ root: URL) async throws -> URL {
        let source = root.appendingPathComponent("beta", isDirectory: true)
        try await makeDatabase(at: source.appendingPathComponent("database"), projectName: "Beta")
        let repo = source.appendingPathComponent("repositories/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data("repo-data".utf8).write(to: repo.appendingPathComponent("blob"))
        return source
    }

    // CT-045: an initialized Release scaffold must not block a user-requested migration.
    func testCT045_InitializedReleaseCanRequestMigration() async throws {
        let root = try makeRoot("ct045")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try await scaffoldReleaseTarget(root)
        let source = try await makeBetaSource(root)

        let plan = try DataMigrator.inspect(
            source: source,
            target: target,
            ignoreTargetConflicts: true
        )
        XCTAssertTrue(plan.isSafeToProceed)
        try DataMigrator.requestMigration(source: source, target: target, allowReplaceRoot: true)
        XCTAssertNotNil(try DataMigrator.performPending(target: target))
        XCTAssertFalse(DataMigrator.hasPendingRequest(target: target))

        let migrated = try SQLiteStore(path: target.appendingPathComponent("database/codetime.sqlite").path)
        let projects = try await migrated.projects()
        XCTAssertEqual(projects.map(\.name), ["Beta"])
        await migrated.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("database/codetime.sqlite").path))
    }

    // CT-046: empty repositories/cache directories on the target are not a conflict.
    func testCT046_EmptyTargetDirectoriesDoNotBlockMigration() async throws {
        let root = try makeRoot("ct046")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try await scaffoldReleaseTarget(root)
        let source = try await makeBetaSource(root)
        try DataMigrator.requestMigration(source: source, target: target, allowReplaceRoot: true)
        let result = try DataMigrator.performPending(target: target)
        XCTAssertNotNil(result)
        let migrated = try SQLiteStore(path: target.appendingPathComponent("database/codetime.sqlite").path)
        let migratedProjects = try await migrated.projects()
        XCTAssertEqual(migratedProjects.map(\.name), ["Beta"])
        await migrated.close()
    }

    // CT-047: hidden repository content must be copied, not silently skipped.
    func testCT047_HiddenRepositoryFilesAreMigrated() async throws {
        let root = try makeRoot("ct047")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await makeBetaSource(root)
        let hidden = source.appendingPathComponent("repositories/hidden/.shards", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data("hidden".utf8).write(to: hidden.appendingPathComponent("p1"))
        let target = root.appendingPathComponent("target", isDirectory: true)
        _ = try DataMigrator.migrate(source: source, target: target)
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathComponent("repositories/hidden/.shards/p1")),
            Data("hidden".utf8)
        )
    }

    // CT-048: cancellation before the swap leaves the target untouched and retryable.
    func testCT048_InterruptedMigrationLeavesTargetRetryable() async throws {
        let root = try makeRoot("ct048")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await makeBetaSource(root)
        let target = try await scaffoldReleaseTarget(root)
        await assertThrowsAsync(
            try DataMigrator.migrate(source: source, target: target, replaceRoot: true, isCancelled: { true })
        ) { error in
            guard let migration = error as? MigrationError,
                  case .cancelled = migration else {
                return XCTFail("应为取消，实际：\(error)")
            }
        }
        let stillTarget = try SQLiteStore(path: target.appendingPathComponent("database/codetime.sqlite").path)
        let targetProjects = try await stillTarget.projects()
        XCTAssertEqual(targetProjects.map(\.name), ["Release"])
        await stillTarget.close()

        _ = try DataMigrator.migrate(source: source, target: target, replaceRoot: true)
        let migrated = try SQLiteStore(path: target.appendingPathComponent("database/codetime.sqlite").path)
        let migratedProjects = try await migrated.projects()
        XCTAssertEqual(migratedProjects.map(\.name), ["Beta"])
        await migrated.close()
    }

    // CT-049: a damaged target file and stale restore temp are repaired automatically.
    func testCT049_PartialRestoreFileIsReplaced() async throws {
        let cloud = try RegressionCloud(name: "ct049")
        defer { cloud.cleanup() }
        let device = UUID()
        let store = cloud.store(deviceID: device)
        try cloud.workspace.writeFile("a.txt", "alpha")
        try cloud.workspace.writeFile("b.txt", "bravo")
        try cloud.workspace.writeFile("c.txt", "charlie")
        let generation = try await cloud.publish(store, deviceID: device)

        let destination = cloud.workspace.root.appendingPathComponent("partial", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "broken".write(to: destination.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "stale".write(to: destination.appendingPathComponent(".ctrestore-stale"), atomically: true, encoding: .utf8)

        try await store.restoreRepository(generationId: generation, destination: destination, allowResume: true)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("b.txt"), encoding: .utf8), "bravo")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".ctrestore-stale").path))
    }

    // CT-050: a crash in the committing state is resumable, not terminal.
    func testCT050_CommittingRestoreIsResumable() async throws {
        XCTAssertTrue(RestoreJobState.committing.isResumable)
        let root = try makeRoot("ct050")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(path: root.appendingPathComponent("db.sqlite").path)
        let repositoryID = UUID()
        let generationID = UUID()
        let job = CloudRestoreJob(
            repositoryID: repositoryID,
            generationID: generationID,
            sourceDeviceID: UUID(),
            state: .committing,
            stagingPath: root.appendingPathComponent("staging").path
        )
        try await store.upsertCloudRestoreJob(job)
        let resumed = try await store.resumableCloudRestore(
            repositoryID: repositoryID,
            generationID: generationID
        )
        XCTAssertEqual(resumed?.id, job.id)
        await store.close()
    }

    // CT-051: the selected device must be the one used by recover().
    func testCT051_SelectedDeviceIsBoundToRecovery() async throws {
        let cloud = try RegressionCloud(name: "ct051")
        defer { cloud.cleanup() }
        let deviceA = UUID()
        let deviceB = UUID()
        let storeA = cloud.store(deviceID: deviceA)
        let storeB = cloud.store(deviceID: deviceB)
        try cloud.workspace.writeFile("a.txt", "from-a")
        _ = try await cloud.publish(storeA, deviceID: deviceA)
        try cloud.workspace.writeFile("a.txt", "from-b")
        _ = try await cloud.publish(storeB, deviceID: deviceB)

        let recovered = try await CloudMirrorStore.recover(
            storageRoot: cloud.workspace.storageRoot,
            recoveryKey: cloud.masterKey,
            repositoryID: cloud.repositoryID,
            deviceID: deviceB
        )
        XCTAssertEqual(recovered.deviceID, deviceB)
        XCTAssertEqual(recovered.repositoryID, cloud.repositoryID)
    }

    // CT-052: a missing object in the newest generation must make the candidate non-restorable.
    func testCT052_MissingObjectMakesCandidateNonRestorable() async throws {
        let cloud = try RegressionCloud(name: "ct052")
        defer { cloud.cleanup() }
        let device = UUID()
        let store = cloud.store(deviceID: device)
        try cloud.workspace.writeFile("a.txt", "object")
        _ = try await cloud.publish(store, deviceID: device)
        try FileManager.default.removeItem(
            at: cloud.workspace.objectURL(
                deviceID: device,
                repositoryID: cloud.repositoryID,
                hash: sha256Hex("object")
            )
        )

        let candidates = try await CloudMirrorStore.recoverCandidates(
            storageRoot: cloud.workspace.storageRoot,
            recoveryKey: cloud.masterKey
        )
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertFalse(candidate.isRestorable)
        XCTAssertNotNil(candidate.blockedReason)
    }

    // CT-053: a failed local verification must clear the verified state.
    func testCT053_FailedVerificationDoesNotRemainVerified() async throws {
        guard KopiaBinary.locate() != nil else { throw XCTSkip("KOPIA_PATH 未设置") }
        let root = try makeRoot("ct053")
        let paths = AppPaths(root: root.appendingPathComponent("app"))
        let keychain = KeychainStore(service: "com.codetime.test.\(UUID().uuidString)")
        defer {
            keychain.deleteAllSecrets()
            try? FileManager.default.removeItem(at: root)
        }
        let source = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "verify-me".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let service = try CodeTimeService(paths: paths, keychain: keychain)
        _ = try await service.bootstrap()
        let mirror = root.appendingPathComponent("mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        var settings = try await service.currentSettings()
        settings.iCloudEnabled = false
        settings.localMirrorPath = mirror.path
        settings.localMirrorBookmark = nil
        try await service.saveSettings(settings)
        let project = try await service.addProject(url: source)
        let outcome = try await service.createSnapshot(projectID: project.id, trigger: .manual)
        XCTAssertNil(outcome.cloudError)
        let generations = try await service.cloudGenerations()
        let generation = try XCTUnwrap(generations.first)

        // Remove one object from the mirror; verifyCloud must report failure and
        // must not persist the generation as verified.
        let enumerator = FileManager.default.enumerator(at: mirror, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true,
                  url.path.contains("/objects/"),
                  !url.lastPathComponent.hasPrefix(".tmp-") else { continue }
            try FileManager.default.removeItem(at: url)
            break
        }

        let result = try await service.verifyCloud()
        XCTAssertEqual(result?.outcome, .failed)
        let database = try SQLiteStore(path: paths.database.path)
        let stored = try await database.generation(id: generation.id)
        XCTAssertNotEqual(stored?.state, .verified)
        XCTAssertNil(stored?.verifiedAt, "失败校验不能保留 verifiedAt")
        await database.close()
    }

    // CT-054: an aborted GC with an unreadable tombstone must not delete referenced objects.
    func testCT054_AbortedTombstoneDoesNotDeleteObjects() async throws {
        let cloud = try RegressionCloud(name: "ct054")
        defer { cloud.cleanup() }
        let device = UUID()
        let journals = MemoryJournalStore()
        let store = cloud.store(deviceID: device, journalStore: journals, sweepGrace: 3_600)
        try cloud.workspace.writeFile("a.txt", "v1")
        _ = try await cloud.publish(store, deviceID: device, createdAt: Date().addingTimeInterval(-300))
        try cloud.workspace.writeFile("a.txt", "v2")
        _ = try await cloud.publish(store, deviceID: device, createdAt: Date().addingTimeInterval(-200))
        try cloud.workspace.writeFile("a.txt", "v3")
        _ = try await cloud.publish(store, deviceID: device, createdAt: Date().addingTimeInterval(-100))

        _ = try await store.cleanup(repositoryId: cloud.repositoryID, gracePeriod: 0, minimumGenerations: 1)
        let tombstone = try XCTUnwrap(cloud.workspace.tombstoneURLs(
            deviceID: device,
            repositoryID: cloud.repositoryID
        ).first)
        let corrupt = tombstone.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).1.ctm")
        try Data("not-a-manifest".utf8).write(to: corrupt)

        var journal = try XCTUnwrap(journals.latest(repositoryID: cloud.repositoryID))
        journal.phase = .aborted
        try await journals.saveGCJournal(journal)

        _ = try await store.cleanup(repositoryId: cloud.repositoryID, gracePeriod: 0, minimumGenerations: 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: cloud.workspace.objectURL(
                deviceID: device,
                repositoryID: cloud.repositoryID,
                hash: sha256Hex("v1")
            ).path),
            "无法恢复的墓碑引用对象不得被删除"
        )
    }

    // CT-055: two connections must have exactly one lease winner.
    func testCT055_TwoConnectionsCompeteForOneLease() async throws {
        let root = try makeRoot("ct055")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("db.sqlite").path
        let first = try SQLiteStore(path: path)
        let second = try SQLiteStore(path: path)
        let project = Project(name: "Lease", rootPath: root.path)
        try await first.upsertProject(project)
        let job = BackupJob(projectID: project.id, type: .backup)
        try await first.upsertJob(job)
        let owner = ProcessIdentity.current(isAgent: false)
        let expiry = Date().addingTimeInterval(600)

        async let leaseA = first.acquireJobLease(id: job.id, owner: owner, expiresAt: expiry)
        async let leaseB = second.acquireJobLease(id: job.id, owner: owner, expiresAt: expiry)
        let resultA = try await leaseA
        let resultB = try await leaseB
        XCTAssertEqual([resultA, resultB].compactMap { $0 }.count, 1, "同一任务只能有一个租约持有者")
        await first.close()
        await second.close()
    }

    // CT-056: SQLite loss must rediscover an existing local repository.
    func testCT056_LocalRepositoryIsRediscoveredWithoutDatabase() throws {
        let root = try makeRoot("ct056")
        defer { try? FileManager.default.removeItem(at: root) }
        let repositories = root.appendingPathComponent("repositories", isDirectory: true)
        let repositoryID = UUID()
        let repository = repositories.appendingPathComponent(repositoryID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: repository.appendingPathComponent("repo"), withIntermediateDirectories: true)
        try Data("repo".utf8).write(to: repository.appendingPathComponent("repo/kopia.repository"))
        let metadata = RepositoryMetadata(repositoryID: repositoryID, state: .ready)
        try JSONEncoder().encode(metadata).write(to: repository.appendingPathComponent("repository.json"))

        let discovered = try RepositoryDiscovery.discover(in: repositories)
        XCTAssertEqual(discovered.count, 1)
        XCTAssertEqual(discovered.first?.id, repositoryID)
        XCTAssertEqual(
            URL(fileURLWithPath: discovered.first?.path ?? "").resolvingSymlinksInPath(),
            repository.appendingPathComponent("repo").resolvingSymlinksInPath()
        )
    }

    // CT-057: choosing the iCloud mirror as a project would recursively back it up.
    func testCT057_ICloudMirrorPathIsRejected() throws {
        let root = try makeRoot("ct057")
        defer { try? FileManager.default.removeItem(at: root) }
        let iCloud = root.appendingPathComponent("iCloud/CodeTime", isDirectory: true)
        try FileManager.default.createDirectory(at: iCloud, withIntermediateDirectories: true)
        let result = ProjectPathValidator.validate(
            url: iCloud,
            existingProjects: [],
            appRoot: root.appendingPathComponent("app", isDirectory: true),
            mirrorPath: nil,
            iCloudMirrorPath: iCloud.path
        )
        XCTAssertFalse(result.isAcceptable)
    }
}
