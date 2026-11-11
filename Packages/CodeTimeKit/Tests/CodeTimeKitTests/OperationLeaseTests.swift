import XCTest
import Foundation
@testable import CodeTimeCore
@testable import SharedModels

/// Runtime lease: shared work (backup/restore/verify) may overlap; maintenance is
/// exclusive. The same file is used by UI and LaunchAgent.
final class OperationLeaseTests: XCTestCase {
    func testCT188_SharedLeasesOverlapAndExclusiveMaintenanceIsBlocked() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-lease-\(UUID().uuidString).lock").path
        let first = OperationLeaseManager(path: path)
        let second = OperationLeaseManager(path: path)

        let sharedA = try first.acquire(.shared, timeout: 0)
        let sharedB = try second.acquire(.shared, timeout: 0)
        XCTAssertTrue(sharedA.isHeld)
        XCTAssertTrue(sharedB.isHeld)

        XCTAssertThrowsError(try first.acquire(.exclusive, timeout: 0.1)) { error in
            guard case CodeTimeError.repositoryBusy = error else {
                return XCTFail("期望 repositoryBusy，实际 \(error)")
            }
        }

        sharedA.release()
        sharedB.release()

        let exclusive = try first.acquire(.exclusive, timeout: 0.1)
        XCTAssertThrowsError(try second.acquire(.shared, timeout: 0.1))
        exclusive.release()

        let after = try second.acquire(.shared, timeout: 0.1)
        XCTAssertTrue(after.isHeld)
        after.release()
    }

    func testCT189_LeaseReleaseIsIdempotent() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-lease-\(UUID().uuidString).lock").path
        let manager = OperationLeaseManager(path: path)
        let lease = try manager.acquire(.exclusive)
        lease.release()
        lease.release()
        XCTAssertFalse(lease.isHeld)
    }
}
