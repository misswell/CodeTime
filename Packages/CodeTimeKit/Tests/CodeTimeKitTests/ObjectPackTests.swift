import XCTest
import Foundation
@testable import BackupEngine
@testable import SharedModels
@testable import CodeTimeSecurity

/// CT-157: immutable object packs + their use by the backup and restore engines.
final class ObjectPackTests: XCTestCase {
    private func objectID(_ seed: Int) -> String {
        String(format: "%064x", seed)
    }

    private func payload(_ seed: Int, bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(($0 &+ seed) & 0xFF) })
    }

    func testCT157_PackFormatRoundTripsEveryObject() throws {
        let builder = ObjectPackBuilder(options: .init(targetBytes: 2048, maxBytes: 4096))
        let objects = (1...5).map { (objectID: objectID($0), payload: payload($0, bytes: 900)) }
        let packs = try builder.build(objects)
        XCTAssertGreaterThan(packs.count, 1, "超过目标大小必须切成多个包")

        let reader = ObjectPackReader()
        var recovered: [String: Data] = [:]
        for pack in packs {
            XCTAssertEqual(pack.payload.prefix(4), ObjectPackFormat.magic)
            let entries = try reader.entries(in: pack.payload)
            XCTAssertEqual(entries.count, pack.entries.count)
            let packID = CanonicalHashing.sha256Hex(pack.payload)
            XCTAssertEqual(pack.packID, packID, "包 ID 必须是内容哈希")
            for entry in entries {
                let data = try reader.object(entry.objectID, in: pack.payload)
                XCTAssertEqual(data.count, entry.length)
                recovered[entry.objectID] = data
            }
        }
        XCTAssertEqual(recovered.count, objects.count)
        for object in objects {
            XCTAssertEqual(recovered[object.objectID], object.payload, "包内对象必须逐字节一致")
        }
    }

    func testCT157_PackRejectsBadInputAndCorruptReads() throws {
        let builder = ObjectPackBuilder(options: .init(targetBytes: 1024, maxBytes: 1024))
        let firstID = objectID(1)
        let secondID = objectID(2)

        XCTAssertThrowsError(
            try builder.build([(firstID, payload(1, bytes: 10)), (firstID, payload(2, bytes: 10))])
        ) { error in
            XCTAssertEqual(error as? ObjectPackError, .duplicateObject(firstID))
        }
        XCTAssertThrowsError(try builder.build([(firstID, payload(1, bytes: 2000))])) { error in
            XCTAssertEqual(error as? ObjectPackError, .invalidRange(objectID: firstID))
        }

        let pack = try XCTUnwrap(try builder.build([(firstID, payload(1, bytes: 100))]).first)
        let reader = ObjectPackReader()
        XCTAssertThrowsError(try reader.object(secondID, in: pack.payload)) { error in
            XCTAssertEqual(error as? ObjectPackError, .objectNotFound(secondID))
        }

        var corrupt = pack.payload
        corrupt[0] = UInt8(ascii: "X")
        XCTAssertThrowsError(try reader.entries(in: corrupt)) { error in
            XCTAssertEqual(error as? ObjectPackError, .badMagic)
        }
        XCTAssertThrowsError(try reader.entries(in: pack.payload.prefix(6))) { error in
            XCTAssertEqual(error as? ObjectPackError, .tooShort)
        }

        // A truncated pack must not be parsed as if complete.
        let truncated = pack.payload.prefix(ObjectPackFormat.headerSize + 4)
        XCTAssertThrowsError(try reader.entries(in: truncated)) { error in
            XCTAssertEqual(error as? ObjectPackError, .truncatedEntry)
        }
    }

    func testCT157_EnginePacksSmallFilesAndRestoresThem() async throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("packs-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = work.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // Many tiny files: without packing each chunk would be its own iCloud item.
        for index in 1...12 {
            try Data("tiny-file-\(index)-content".utf8)
                .write(to: projectRoot.appendingPathComponent("file\(index).txt"))
        }

        let cloud = InMemoryCloud()
        let index = InMemoryIndex()
        let projectID = UUID()
        let masterKey = Data("pack-test-key".utf8)
        let engine = CloudFirstBackupEngine(
            masterKey: masterKey,
            deviceID: "device-A",
            index: index,
            sink: cloud,
            options: BackupRunOptions(
                chunker: ChunkerConfig(minSize: 1024, avgSize: 4096, maxSize: 16 * 1024),
                uploadConcurrency: 2,
                packObjectsUpTo: 64 * 1024
            )
        )

        let report = try await engine.run(
            projectID: projectID,
            root: projectRoot,
            matcher: ExclusionMatcher(rules: ExclusionPresets.defaultRules())
        )

        XCTAssertTrue(report.committed)
        XCTAssertGreaterThan(report.packsUploaded, 0, "小对象必须进入 pack")
        XCTAssertLessThan(
            cloud.totalObjectCount(),
            report.objectsUploaded,
            "对象数应少于分块数（说明确有打包）"
        )

        // Every chunk reference that lives in a pack knows its pack + offset.
        let nodes = try await index.fileNodes(projectID: projectID)
        let packed = nodes.flatMap(\.chunks).filter { $0.packID != nil }
        XCTAssertFalse(packed.isEmpty)
        for ref in packed {
            XCTAssertNotNil(ref.packOffset)
        }

        // Restore must reassemble through the pack.
        let restore = CloudRestoreEngine(masterKey: masterKey, source: cloud)
        let destination = work.appendingPathComponent("restored", isDirectory: true)
        let restoreReport = try await restore.restore(
            projectID: projectID,
            snapshotID: report.snapshotID,
            target: .project,
            destination: destination
        )
        XCTAssertGreaterThan(restoreReport.packsDownloaded, 0, "恢复必须从 pack 读取")
        for index in 1...12 {
            let data = try Data(contentsOf: destination.appendingPathComponent("file\(index).txt"))
            XCTAssertEqual(data, Data("tiny-file-\(index)-content".utf8))
        }

        // Concurrent files can produce the same chunk before either consults the
        // object registry; a pack must still contain it exactly once.
        let raceCloud = InMemoryCloud()
        let buffer = PackBuffer(
            threshold: 1024,
            sink: raceCloud,
            builder: ObjectPackBuilder(options: .init(targetBytes: 1 << 20))
        )
        let raceID = objectID(7)
        let racePayload = payload(7, bytes: 100)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try? await buffer.append(objectID: raceID, payload: racePayload)
                }
            }
        }
        try await buffer.flush()
        let locations = await buffer.locations
        XCTAssertEqual(locations.count, 1, "同一对象在并发暂存时只能进入包一次")
        let packID = try XCTUnwrap(locations[raceID]?.packID)
        let pack = try XCTUnwrap(raceCloud.packs[packID])
        let entries = try ObjectPackReader().entries(in: pack)
        XCTAssertEqual(entries.map(\.objectID), [raceID])
    }
}
