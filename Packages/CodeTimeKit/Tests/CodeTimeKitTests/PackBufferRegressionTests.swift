import XCTest
import Foundation
@testable import BackupEngine
@testable import SharedModels

/// CT-201…CT-206: PackBuffer batches are immutable; appends during an awaited
/// flush are not discarded, concurrent flushes share one batch, and failed
/// batches remain retryable.
final class PackBufferRegressionTests: XCTestCase {
    final class RecordingSink: CloudObjectSink, @unchecked Sendable {
        struct Pack { var id: String; var payload: Data }
        private let lock = NSLock()
        private(set) var packs: [Pack] = []
        var failNextPack = false
        let gate: PackGate

        init(gate: PackGate) { self.gate = gate }

        func hasObject(_ objectID: String) async throws -> Bool { false }
        func putObject(_ payload: Data, objectID: String) async throws -> Bool { true }
        func putNode(_ node: DirectoryNode) async throws -> Bool { true }
        func hasPack(_ packID: String) async throws -> Bool {
            lock.lock(); defer { lock.unlock() }
            return packs.contains { $0.id == packID }
        }
        func putManifest(_ payload: Data, projectID: UUID, snapshotID: String) async throws -> String {
            CanonicalHashing.sha256Hex(payload)
        }
        func putCommit(_ commit: SnapshotCommit) async throws {}
        func putPack(_ payload: Data, packID: String) async throws -> Bool {
            await gate.enter()
            await gate.waitForRelease()
            lock.lock()
            let shouldFail = failNextPack
            failNextPack = false
            if !shouldFail {
                packs.append(Pack(id: packID, payload: payload))
            }
            lock.unlock()
            if shouldFail { throw TestError.packFailure }
            return true
        }

        func snapshot() -> [Pack] {
            lock.lock(); defer { lock.unlock() }
            return packs
        }
    }

    enum TestError: Error { case packFailure }

    actor PackGate {
        private var entered = 0
        private var released = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func enter() {
            entered += 1
            let waiters = entryWaiters
            entryWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        func waitUntilEntered(timeout: TimeInterval = 2) async {
            if entered > 0 { return }
            let deadline = Date().addingTimeInterval(timeout)
            while entered == 0, Date() < deadline {
                await withCheckedContinuation { continuation in
                    entryWaiters.append(continuation)
                }
                if entered > 0 { return }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        func waitForRelease() async {
            if released { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        func entryCount() -> Int { entered }
    }

    private func data(_ byte: UInt8, count: Int = 100) -> Data {
        Data(repeating: byte, count: count)
    }

    private func makeBuffer(
        gate: PackGate = PackGate(),
        sink: RecordingSink? = nil
    ) -> (PackBuffer, RecordingSink, ObjectRegistry) {
        let actualSink = sink ?? RecordingSink(gate: gate)
        let registry = ObjectRegistry(known: [:])
        let buffer = PackBuffer(
            threshold: 1 << 20,
            sink: actualSink,
            builder: ObjectPackBuilder(options: .init(targetBytes: 1 << 20)),
            registry: registry
        )
        return (buffer, actualSink, registry)
    }

    func testCT201_AppendDuringFlushDoesNotLoseChunks() async throws {
        let gate = PackGate()
        let (buffer, sink, _) = makeBuffer(gate: gate)
        let idA = String(repeating: "a", count: 64)
        let idB = String(repeating: "b", count: 64)
        try await buffer.append(objectID: idA, payload: data(1))

        let flush = Task { try await buffer.flush() }
        await gate.waitUntilEntered()
        let beforeUpload = await buffer.locations
        XCTAssertTrue(beforeUpload.isEmpty, "上传确认前不得暴露 PackLocation")

        // This append happens while flush is suspended in putPack.
        let staged = try await buffer.append(objectID: idB, payload: data(2))
        XCTAssertTrue(staged)
        await gate.release()
        try await flush.value
        let locations = try await buffer.finalize()
        XCTAssertNotNil(locations[idA])
        XCTAssertNotNil(locations[idB], "flush 期间追加的 Chunk 不得丢失")
        let allObjects = sink.snapshot().flatMap { pack in
            (try? ObjectPackReader().entries(in: pack.payload).map(\.objectID)) ?? []
        }
        XCTAssertEqual(Set(allObjects), [idA, idB])
    }

    func testCT202_ConcurrentFlushSharesInFlightBatch() async throws {
        let gate = PackGate()
        let (buffer, sink, _) = makeBuffer(gate: gate)
        let id = String(repeating: "c", count: 64)
        try await buffer.append(objectID: id, payload: data(3))
        let first = Task { try await buffer.flush() }
        await gate.waitUntilEntered()
        let second = Task { try await buffer.flush() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let entries = await gate.entryCount()
        XCTAssertEqual(entries, 1, "并发 flush 必须共享同一个 in-flight 批次")
        await gate.release()
        _ = try await first.value
        _ = try await second.value
        let locations = try await buffer.finalize()
        XCTAssertEqual(locations.count, 1)
        XCTAssertEqual(sink.snapshot().count, 1, "同一批次不得重复上传 Pack")
    }

    func testCT203_FailedBatchIsPreservedAndRetried() async throws {
        let gate = PackGate()
        await gate.release()
        let (buffer, sink, _) = makeBuffer(gate: gate)
        let id = String(repeating: "d", count: 64)
        try await buffer.append(objectID: id, payload: data(4))
        sink.failNextPack = true
        do {
            try await buffer.flush()
            XCTFail("Pack 上传失败必须抛出")
        } catch {
            // expected
        }
        let failedLocations = await buffer.locations
        XCTAssertTrue(failedLocations.isEmpty, "失败批次不得产生可用位置")
        let locations = try await buffer.finalize()
        XCTAssertNotNil(locations[id], "失败批次必须保留并可重试")
        XCTAssertEqual(sink.snapshot().count, 1)
    }

    func testCT204_FinalizeWaitsForAllPendingBatches() async throws {
        let gate = PackGate()
        await gate.release()
        let (buffer, sink, _) = makeBuffer(gate: gate)
        var ids: [String] = []
        for index in 0..<40 {
            let id = String(format: "%064x", index + 1)
            ids.append(id)
            try await buffer.append(objectID: id, payload: data(UInt8(index % 250)))
        }
        let locations = try await buffer.finalize()
        XCTAssertEqual(Set(locations.keys), Set(ids))
        XCTAssertEqual(sink.snapshot().count, 1)
    }

    func testCT205_DuplicateObjectIDIsPackedOnce() async throws {
        let gate = PackGate()
        await gate.release()
        let (buffer, sink, _) = makeBuffer(gate: gate)
        let id = String(repeating: "e", count: 64)
        let first = try await buffer.append(objectID: id, payload: data(5))
        let second = try await buffer.append(objectID: id, payload: data(5))
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        _ = try await buffer.finalize()
        let entries = try ObjectPackReader().entries(in: sink.snapshot()[0].payload)
        XCTAssertEqual(entries.map(\.objectID), [id])
    }

    func testCT206_PackLocationOnlyPublishedAfterConfirmation() async throws {
        let gate = PackGate()
        let (buffer, _, _) = makeBuffer(gate: gate)
        let id = String(repeating: "f", count: 64)
        try await buffer.append(objectID: id, payload: data(6))
        let flush = Task { try await buffer.flush() }
        await gate.waitUntilEntered()
        let before = await buffer.locations
        XCTAssertTrue(before.isEmpty)
        await gate.release()
        try await flush.value
        let after = await buffer.locations
        XCTAssertNotNil(after[id])
    }
}

/// CT-207…CT-210: the registry distinguishes uploading from uploaded and never
/// returns a zero-size placeholder as reusable.
final class ObjectRegistryConcurrencyTests: XCTestCase {
    private let location = StoredObjectLocation(storedSize: 42)

    func testCT207_PendingObjectIsNotReportedAsUploaded() async throws {
        let registry = ObjectRegistry(known: [:])
        let id = String(repeating: "1", count: 64)
        let acquired = try await registry.acquireStandalone(id)
        guard case .upload = acquired else { return XCTFail("首次 acquire 必须取得上传权") }
        let ready = await registry.readyLocation(id)
        XCTAssertNil(ready, "上传中的对象不得出现在 ready 位置")
        let uploading = await registry.isUploading(id)
        XCTAssertTrue(uploading)
    }

    func testCT208_ConcurrentDuplicateChunkWaitsForUpload() async throws {
        let registry = ObjectRegistry(known: [:])
        let id = String(repeating: "2", count: 64)
        let first = try await registry.acquireStandalone(id)
        guard case .upload = first else { return XCTFail("首任务必须上传") }
        let waiter = Task { try await registry.acquireStandalone(id) }
        try await Task.sleep(nanoseconds: 50_000_000)
        await registry.complete(id, location: location)
        let result = try await waiter.value
        guard case .ready(let ready) = result else { return XCTFail("等待者必须得到 ready") }
        XCTAssertEqual(ready, location)
    }

    func testCT209_UploadFailurePropagatesToAllWaiters() async throws {
        let registry = ObjectRegistry(known: [:])
        let id = String(repeating: "3", count: 64)
        _ = try await registry.acquireStandalone(id)
        let waiter = Task { try await registry.acquireStandalone(id) }
        try await Task.sleep(nanoseconds: 50_000_000)
        await registry.fail(id, error: CloudObjectLifecycleError.writerFailed(
            objectID: id, detail: "offline"
        ))
        do {
            _ = try await waiter.value
            XCTFail("上传失败必须传播给等待者")
        } catch {
            // expected
        }
    }

    func testCT210_ZeroStoredSizeKnownRecordIsNotReusableAndPackedLocationWins() async throws {
        let bad = ChunkRecordV3(
            objectID: String(repeating: "4", count: 64),
            plaintextSize: 10,
            storedSize: 0,
            keyVersion: 1
        )
        let goodID = String(repeating: "5", count: 64)
        let good = ChunkRecordV3(
            objectID: goodID,
            plaintextSize: 10,
            storedSize: 20,
            keyVersion: 1,
            packID: String(repeating: "p", count: 64),
            packOffset: 128
        )
        let registry = ObjectRegistry(known: [bad.objectID: bad, goodID: good])
        let invalid = await registry.readyLocation(bad.objectID)
        XCTAssertNil(invalid, "零大小索引行不得作为可复用对象")
        let stored = await registry.readyLocation(goodID)
        let ready = try XCTUnwrap(stored)
        XCTAssertEqual(ready.packID, good.packID)
        XCTAssertEqual(ready.storedSize, 20)
    }
}
