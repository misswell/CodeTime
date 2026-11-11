import XCTest
import Foundation
@testable import BackupEngine

/// CT-167: FSEvents is wired as the change source, but it remains an optimization:
/// the gate still enforces the per-project minimum interval.
final class ProjectChangeMonitorTests: XCTestCase {
    final class Flag: @unchecked Sendable {
        let expectation: XCTestExpectation
        private let lock = NSLock()
        private var fired = false
        init(_ expectation: XCTestExpectation) { self.expectation = expectation }
        func fire() {
            lock.lock()
            guard !fired else { lock.unlock(); return }
            fired = true
            lock.unlock()
            expectation.fulfill()
        }
    }

    func testCT167_FSEventsDeliverChangeAndGateRespectsMinimumInterval() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsevents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let expectation = expectation(description: "fsevent")
        let flag = Flag(expectation)
        let monitor = ProjectChangeMonitor(
            root: root,
            configuration: .init(latency: 0.1, debounce: 0)
        ) {
            flag.fire()
        }
        XCTAssertTrue(monitor.start())
        XCTAssertTrue(monitor.isRunning)

        // Multiple writes make the test resilient to the first event being coalesced.
        for index in 0..<3 {
            try Data("change-\(index)".utf8)
                .write(to: root.appendingPathComponent("file\(index).txt"))
        }
        await fulfillment(of: [expectation], timeout: 10)
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)

        let now = Date()
        let gate = FileActivityGate(minimumInterval: 300)
        XCTAssertFalse(
            gate.shouldTrigger(lastBackupAt: now.addingTimeInterval(-100), now: now),
            "最小变化间隔内不得重复触发"
        )
        XCTAssertTrue(
            gate.shouldTrigger(lastBackupAt: now.addingTimeInterval(-400), now: now),
            "超过最小间隔后应允许变更触发"
        )
        XCTAssertTrue(gate.shouldTrigger(lastBackupAt: nil, now: now))
    }
}
