import XCTest
import Foundation
@testable import BackupEngine
@testable import SharedModels

/// CT-158: v2 → v3 migration state machine. The tests pin the ordering that
/// matters: nothing local is released before both the old cloud copy and the new
/// baseline are verified, cleanup needs explicit consent, and a crash resumes
/// without re-uploading or deleting early.
final class MigrationCoordinatorTests: XCTestCase {

    final class FakeProbe: MigrationProbing, @unchecked Sendable {
        var state = LegacyRepositoryState(
            localPresent: true, localBytes: 4_000_000_000, cloudV2Present: false, cloudV2Verified: false
        )
        var calls: [String] = []
        var failPublish = false
        var failVerifyLegacy = false
        var failBaseline = false
        var failBaselineVerify = false
        var failCleanup = false

        func inspectLegacy() async throws -> LegacyRepositoryState {
            calls.append("inspect")
            return state
        }

        func publishLegacyToCloud() async throws {
            calls.append("publish")
            if failPublish { throw NSError(domain: "probe", code: 1) }
            state.cloudV2Present = true
        }

        func verifyLegacyCloud() async throws -> Bool {
            calls.append("verifyLegacy")
            if failVerifyLegacy { return false }
            state.cloudV2Verified = true
            return true
        }

        func createNativeBaseline() async throws -> Bool {
            calls.append("baseline")
            if failBaseline { return false }
            return true
        }

        func verifyNativeBaseline() async throws -> Bool {
            calls.append("verifyBaseline")
            if failBaselineVerify { return false }
            return true
        }

        func cleanupLegacyLocal() async throws {
            calls.append("cleanup")
            if failCleanup { throw NSError(domain: "probe", code: 2) }
            state.localPresent = false
            state.localBytes = 0
        }
    }

    final class FakeJournal: MigrationJournaling, @unchecked Sendable {
        var phases: [String] = []
        private let lock = NSLock()

        func appendMigrationEvent(_ entry: MigrationJournalEntryV3) async throws {
            lock.lock(); defer { lock.unlock() }
            phases.append(entry.phase)
        }

        func latestMigrationPhase() async throws -> String? {
            lock.lock(); defer { lock.unlock() }
            return phases.last
        }

        func contains(_ phase: MigrationPhase) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return phases.contains(phase.rawValue)
        }
    }

    private func coordinator(_ probe: FakeProbe, _ journal: FakeJournal) -> BackupMigrationCoordinator {
        BackupMigrationCoordinator(probe: probe, journal: journal)
    }

    func testCT158_NoLegacyMeansNothingToDo() async throws {
        let probe = FakeProbe()
        probe.state = LegacyRepositoryState(localPresent: false, localBytes: 0, cloudV2Present: false, cloudV2Verified: false)
        let journal = FakeJournal()
        let status = await coordinator(probe, journal).run(consent: MigrationConsent(releaseLegacyLocalSpace: true))

        XCTAssertEqual(status.phase, .complete)
        XCTAssertEqual(probe.calls, ["inspect"], "没有旧数据时不得触发任何云操作")
        XCTAssertFalse(journal.contains(.legacyCloudPublishing))
    }

    func testCT158_HappyPathWithConsentReleasesLegacyLast() async throws {
        let probe = FakeProbe()
        let journal = FakeJournal()
        let status = await coordinator(probe, journal).run(
            consent: MigrationConsent(releaseLegacyLocalSpace: true)
        )

        XCTAssertEqual(status.phase, .complete)
        XCTAssertEqual(probe.calls, ["inspect", "publish", "verifyLegacy", "baseline", "verifyBaseline", "cleanup"])
        XCTAssertEqual(journal.phases.last, MigrationPhase.complete.rawValue)
        XCTAssertFalse(probe.state.localPresent)
    }

    func testCT158_WithoutConsentLegacyStaysOnDisk() async throws {
        let probe = FakeProbe()
        let journal = FakeJournal()
        let status = await coordinator(probe, journal).run(consent: .default)

        XCTAssertEqual(status.phase, .legacyLocalCleanupPending)
        XCTAssertTrue(status.requiresUserAction)
        XCTAssertEqual(status.legacyLocalBytes, 4_000_000_000)
        XCTAssertFalse(probe.calls.contains("cleanup"), "未获同意不得删除本地旧仓库")
        XCTAssertTrue(probe.state.localPresent)
        XCTAssertTrue(probe.state.cloudV2Verified, "旧备份必须先完成云端校验")
    }

    func testCT158_PublishFailureBlocksBeforeTouchingAnythingLocal() async throws {
        let probe = FakeProbe()
        probe.failPublish = true
        let journal = FakeJournal()
        let status = await coordinator(probe, journal).run(
            consent: MigrationConsent(releaseLegacyLocalSpace: true)
        )

        XCTAssertEqual(status.phase, .blocked)
        XCTAssertTrue(status.requiresUserAction)
        XCTAssertFalse(probe.calls.contains("cleanup"))
        XCTAssertFalse(probe.calls.contains("baseline"), "旧备份未上云前不得迁移")
        XCTAssertTrue(probe.state.localPresent, "失败路径必须保留旧仓库")
        XCTAssertTrue(journal.contains(.blocked))
    }

    func testCT158_ResumesAfterCrashInsteadOfReuploading() async throws {
        let probe = FakeProbe()
        probe.state.cloudV2Present = true
        probe.state.cloudV2Verified = true
        let journal = FakeJournal()
        // Simulate a crash right after the legacy copy was verified.
        try await journal.appendMigrationEvent(
            MigrationJournalEntryV3(phase: MigrationPhase.legacyCloudVerified.rawValue)
        )

        let status = await coordinator(probe, journal).run(
            consent: MigrationConsent(releaseLegacyLocalSpace: true)
        )

        XCTAssertEqual(status.phase, .complete)
        XCTAssertFalse(probe.calls.contains("publish"), "已完成的步骤不得重复执行")
        XCTAssertFalse(probe.calls.contains("verifyLegacy"))
        XCTAssertTrue(probe.calls.contains("baseline"))
    }

    func testCT158_BaselineFailureBlocksAndKeepsLegacy() async throws {
        let probe = FakeProbe()
        probe.failBaselineVerify = true
        let journal = FakeJournal()
        let status = await coordinator(probe, journal).run(
            consent: MigrationConsent(releaseLegacyLocalSpace: true)
        )

        XCTAssertEqual(status.phase, .blocked)
        XCTAssertFalse(probe.calls.contains("cleanup"), "新基线未验证前不得释放旧仓库")
        XCTAssertTrue(probe.state.localPresent)
    }

    func testCT158_CleanupFailureIsBlockedNotReportedAsComplete() async throws {
        let probe = FakeProbe()
        probe.failCleanup = true
        let journal = FakeJournal()
        let status = await coordinator(probe, journal).run(
            consent: MigrationConsent(releaseLegacyLocalSpace: true)
        )

        XCTAssertEqual(status.phase, .blocked)
        XCTAssertTrue(status.detail.contains("释放旧本地仓库失败"))
        XCTAssertTrue(probe.state.localPresent)
    }

    func testCT158_StatusReflectsPendingCleanupWithoutRunningWork() async throws {
        let probe = FakeProbe()
        probe.state.cloudV2Present = true
        probe.state.cloudV2Verified = true
        let journal = FakeJournal()
        try await journal.appendMigrationEvent(
            MigrationJournalEntryV3(phase: MigrationPhase.legacyLocalCleanupPending.rawValue)
        )

        let status = await coordinator(probe, journal).status()
        XCTAssertEqual(status.phase, .legacyLocalCleanupPending)
        XCTAssertTrue(status.requiresUserAction)
        XCTAssertEqual(probe.calls, ["inspect"], "status 不得执行任何迁移步骤")
    }
}
