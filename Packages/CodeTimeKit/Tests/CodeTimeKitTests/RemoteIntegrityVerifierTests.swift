import XCTest
import Foundation
@testable import BackupEngine
@testable import SharedModels
@testable import CodeTimeSecurity

/// Remote integrity: only actual cloud bytes count. Local cache/SQLite/file
/// existence is never evidence that an object is recoverable.
final class RemoteIntegrityVerifierTests: XCTestCase {
    final class CacheStub: RestoreObjectCache, @unchecked Sendable {
        var storage: [String: Data]
        private(set) var reads = 0
        private let lock = NSLock()
        init(storage: [String: Data] = [:]) { self.storage = storage }
        func cachedChunk(objectID: String) async throws -> Data? {
            lock.lock(); defer { lock.unlock() }
            reads += 1
            return storage[objectID]
        }
        func storeChunk(objectID: String, data: Data) async throws {
            lock.lock(); defer { lock.unlock() }
            storage[objectID] = data
        }
    }

    final class Projects: @unchecked Sendable {
        private var map: [String: UUID] = [:]
        private let lock = NSLock()
        func set(_ id: String, _ project: UUID) { lock.lock(); map[id] = project; lock.unlock() }
        func get(_ id: String) -> UUID? { lock.lock(); defer { lock.unlock() }; return map[id] }
    }

    private var root: URL!
    private let masterKey = Data("remote-integrity-key".utf8)
    private let projectID = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("tiny-content".utf8).write(to: root.appendingPathComponent("small.txt"))
        var random = Data(count: 2_000_000)
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        random.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<raw.count {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                base[index] = UInt8(truncatingIfNeeded: state >> 33)
            }
        }
        try random.write(to: root.appendingPathComponent("big.bin"))
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func makeBackup() async throws -> (InMemoryCloud, InMemoryIndex, BackupRunReport) {
        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let engine = CloudFirstBackupEngine(
            masterKey: masterKey,
            deviceID: "device-A",
            index: index,
            sink: cloud
        )
        let report = try await engine.run(
            projectID: projectID, root: root, matcher: ExclusionMatcher(rules: [])
        )
        return (cloud, index, report)
    }

    private func chunks(for path: String, index: InMemoryIndex) async throws -> [ChunkRef] {
        let files = try await index.fileNodes(projectID: projectID)
        return try XCTUnwrap(files.first(where: { $0.path == path })?.chunks)
    }

    func testCT183_InspectReportsAbsentCorruptInaccessibleAndVerified() async throws {
        let (cloud, index, _) = try await makeBackup()
        let verifier = RemoteIntegrityVerifier(masterKey: masterKey, source: cloud)
        let bigChunks = try await chunks(for: "big.bin", index: index)
        let standalone = try XCTUnwrap(bigChunks.first)
        let smallChunks = try await chunks(for: "small.txt", index: index)
        let packed = try XCTUnwrap(smallChunks.first)

        let verifiedState = await verifier.inspectObject(objectID: standalone.objectID)
        XCTAssertEqual(verifiedState, .presentVerified(size: Int(standalone.plaintextSize)))
        cloud.corruptObject(standalone.objectID)
        let corruptState = await verifier.inspectObject(objectID: standalone.objectID)
        if case .corrupted = corruptState {
            // expected
        } else {
            XCTFail("损坏对象必须报告 corrupted")
        }

        let otherVerifier = RemoteIntegrityVerifier(masterKey: masterKey, source: cloud)
        try await cloud.deleteObject(standalone.objectID)
        let absentState = await otherVerifier.inspectObject(objectID: standalone.objectID)
        XCTAssertEqual(absentState, .absent)

        if let packID = packed.packID {
            let packVerifier = RemoteIntegrityVerifier(masterKey: masterKey, source: cloud)
            let packState = await packVerifier.inspectPack(packID: packID)
            if case .presentVerified = packState {
                // expected
            } else {
                XCTFail("完整 Pack 应验证通过：\(packState)")
            }
        }

        cloud.failEnumeration = true
        let inaccessibleState = await verifier.inspectObject(objectID: standalone.objectID)
        if case .inaccessible = inaccessibleState {
            // expected: an unreadable namespace is not absence
        } else {
            XCTFail("无法访问必须报告 inaccessible")
        }
    }

    func testCT184_VerificationIgnoresCacheAndFailsOnCorruptCloudObject() async throws {
        let (cloud, index, report) = try await makeBackup()
        let bigChunks = try await chunks(for: "big.bin", index: index)
        let target = try XCTUnwrap(bigChunks.first)
        let sourceData = try Data(contentsOf: root.appendingPathComponent("big.bin"))
        let plaintextChunks = try FastCDCChunker().chunks(in: sourceData)
        let targetPlaintext = try XCTUnwrap(plaintextChunks.first { chunk in
            ContentHasher(masterKey: masterKey).objectID(forChunk: chunk.data) == target.objectID
        })
        let cache = CacheStub(storage: [target.objectID: targetPlaintext.data])
        cloud.corruptObject(target.objectID)

        // Normal restore may legitimately trust a verified local cache.
        let engineCached = CloudRestoreEngine(
            masterKey: masterKey,
            source: cloud,
            options: RestoreOptions(cache: cache, readPolicy: .cachePreferred, sourceRoots: [root])
        )
        let destination1 = root.deletingLastPathComponent()
            .appendingPathComponent("restore-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination1) }
        _ = try await engineCached.restore(
            projectID: projectID, snapshotID: report.snapshotID,
            target: .file(path: "big.bin"), destination: destination1
        )
        XCTAssertGreaterThan(cache.reads, 0)

        // verifyRemote must ignore the cache and read the damaged cloud object.
        let engineRemote = CloudRestoreEngine(
            masterKey: masterKey,
            source: cloud,
            options: RestoreOptions(cache: cache, readPolicy: .verifyRemote, sourceRoots: [root])
        )
        let destination2 = root.deletingLastPathComponent()
            .appendingPathComponent("restore-remote-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination2) }
        do {
            _ = try await engineRemote.restore(
                projectID: projectID, snapshotID: report.snapshotID,
                target: .file(path: "big.bin"), destination: destination2
            )
            XCTFail("verifyRemote 不得被缓存命中掩盖")
        } catch {
            // expected
        }

        // The BackupEngine verification surface must use the same remote-only path.
        let projects = Projects()
        projects.set(report.snapshotID, projectID)
        let adapter = CloudFirstEngineAdapter(
            masterKey: masterKey,
            deviceID: "device-A",
            index: index,
            sink: cloud,
            source: cloud,
            cache: cache,
            snapshotProjectProvider: { projects.get($0) }
        )
        let verification = try await adapter.verify(snapshotID: report.snapshotID)
        XCTAssertEqual(verification.outcome, .failed, "损坏的云端对象必须让校验失败")
    }

    func testCT185_PackCorruptionIsDetected() async throws {
        let (cloud, index, _) = try await makeBackup()
        let smallChunks = try await chunks(for: "small.txt", index: index)
        let packed = try XCTUnwrap(smallChunks.first)
        let packID = try XCTUnwrap(packed.packID)
        var pack = try XCTUnwrap(cloud.packs[packID])
        pack[pack.count / 2] ^= 0xFF
        cloud.replacePack(packID, with: pack)
        let packVerifier = RemoteIntegrityVerifier(masterKey: masterKey, source: cloud)
        let state = await packVerifier.inspectPack(packID: packID)
        if case .corrupted = state {
            // expected (content hash or AEAD)
        } else {
            XCTFail("损坏 Pack 必须报告 corrupted：\(state)")
        }
    }
}
