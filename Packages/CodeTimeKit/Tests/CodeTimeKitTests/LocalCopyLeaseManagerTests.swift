import XCTest
import Foundation
@testable import CloudMirrorStore

/// CT-216…CT-219: readers/writers pin local iCloud copies until the last user is
/// done; an eviction claim never wins while a read or write is active.
final class LocalCopyLeaseManagerTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/codetime-lease-test")

    func testCT216_ReadersAndPinsPreventEviction() async {
        let manager = LocalCopyLeaseManager()
        await manager.acquireRead(url)
        let whileReading = await manager.beginEviction(url)
        XCTAssertFalse(whileReading)
        await manager.releaseRead(url)
        let afterRead = await manager.beginEviction(url)
        XCTAssertTrue(afterRead)
        await manager.endEviction(url)

        await manager.pin(url)
        let whilePinned = await manager.beginEviction(url)
        XCTAssertFalse(whilePinned)
        await manager.unpin(url)
        let afterUnpin = await manager.beginEviction(url)
        XCTAssertTrue(afterUnpin)
        await manager.endEviction(url)
    }

    func testCT217_ConcurrentReadersKeepCopyUntilLastRelease() async {
        let manager = LocalCopyLeaseManager()
        await manager.acquireRead(url)
        await manager.acquireRead(url)
        await manager.releaseRead(url)
        let oneReader = await manager.beginEviction(url)
        XCTAssertFalse(oneReader)
        await manager.releaseRead(url)
        let lastReader = await manager.beginEviction(url)
        XCTAssertTrue(lastReader)
        await manager.endEviction(url)
    }

    func testCT218_WriterExcludesReadersAndEviction() async {
        let manager = LocalCopyLeaseManager()
        await manager.acquireWrite(url)
        let eviction = await manager.beginEviction(url)
        XCTAssertFalse(eviction)
        let readerDone = expectation(description: "reader waits for writer")
        let task = Task {
            await manager.acquireRead(url)
            await manager.releaseRead(url)
            readerDone.fulfill()
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await manager.releaseWrite(url)
        await fulfillment(of: [readerDone], timeout: 2)
        await task.value
    }

    func testCT255_IdleLeaseStateIsRemoved() async {
        let manager = LocalCopyLeaseManager()
        await manager.acquireRead(url)
        var count = await manager.trackedStateCount
        XCTAssertEqual(count, 1)
        await manager.releaseRead(url)
        count = await manager.trackedStateCount
        XCTAssertEqual(count, 0)

        await manager.acquireWrite(url)
        count = await manager.trackedStateCount
        XCTAssertEqual(count, 1)
        await manager.releaseWrite(url)
        count = await manager.trackedStateCount
        XCTAssertEqual(count, 0)

        await manager.pin(url)
        count = await manager.trackedStateCount
        XCTAssertEqual(count, 1)
        await manager.unpin(url)
        count = await manager.trackedStateCount
        XCTAssertEqual(count, 0)
    }

    func testCT256_WaitingWriterRunsBeforeNewReaders() async {
        let manager = LocalCopyLeaseManager()
        await manager.acquireRead(url)
        actor Events {
            private var values: [String] = []
            func append(_ value: String) { values.append(value) }
            func snapshot() -> [String] { values }
        }
        let events = Events()
        let writer = Task {
            await manager.acquireWrite(url)
            await events.append("writer")
            await manager.releaseWrite(url)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let reader = Task {
            await manager.acquireRead(url)
            await events.append("reader")
            await manager.releaseRead(url)
        }
        await manager.releaseRead(url)
        await writer.value
        await reader.value
        let order = await events.snapshot()
        XCTAssertEqual(order, ["writer", "reader"], "等待中的 Writer 必须先于新 Reader 获得租约")
    }

    func testCT219_CoordinatedReadEvictsOnlyAfterLastReader() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lease-coord-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("value.bin")
        try Data("lease-value".utf8).write(to: file)

        final class Probe: UbiquitousItemProbing, @unchecked Sendable {
            var evicted: [URL] = []
            private let lock = NSLock()
            func isUploaded(_ url: URL) async -> Bool { true }
            func isUbiquitous(_ url: URL) async -> Bool { true }
            func evict(_ url: URL) async throws {
                lock.lock(); evicted.append(url); lock.unlock()
            }
            func snapshot() -> [URL] { lock.lock(); defer { lock.unlock() }; return evicted }
        }
        let probe = Probe()
        let coordinator = CloudAccessCoordinator(
            access: LocalFileAccess(),
            tracker: NoopUploadTracker(),
            eviction: ICloudEvictionManager(probe: probe),
            leaseManager: LocalCopyLeaseManager()
        )
        let first = try await coordinator.read(file)
        XCTAssertEqual(first, Data("lease-value".utf8))
        XCTAssertEqual(probe.snapshot().count, 1, "最后一个读取者结束后应释放本地副本")
    }
}
