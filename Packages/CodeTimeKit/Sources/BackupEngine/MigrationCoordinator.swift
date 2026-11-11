import Foundation
import SharedModels

/// v2 (Kopia) → v3 migration phases (§14.2).
///
/// The ordering is the safety property: the local Kopia repository is only ever
/// released *after* the old cloud copy is verified and the new native baseline is
/// verified. Nothing here deletes anything before that, and cleanup additionally
/// requires an explicit user decision.
public enum MigrationPhase: String, Codable, Sendable, CaseIterable {
    case legacyDetected
    case legacyCloudPublishing
    case legacyCloudVerified
    case nativeBaselineUploading
    case nativeBaselineVerified
    case legacyLocalCleanupPending
    case complete
    case blocked

    /// Monotonic rank used to decide what still has to be done after a crash.
    public var rank: Int {
        switch self {
        case .legacyDetected: return 0
        case .legacyCloudPublishing: return 1
        case .legacyCloudVerified: return 2
        case .nativeBaselineUploading: return 3
        case .nativeBaselineVerified: return 4
        case .legacyLocalCleanupPending: return 5
        case .complete: return 6
        case .blocked: return -1
        }
    }

    public var isTerminal: Bool { self == .complete }
}

public struct LegacyRepositoryState: Sendable, Equatable {
    public var localPresent: Bool
    public var localBytes: Int64
    public var cloudV2Present: Bool
    public var cloudV2Verified: Bool

    public init(localPresent: Bool, localBytes: Int64, cloudV2Present: Bool, cloudV2Verified: Bool) {
        self.localPresent = localPresent
        self.localBytes = localBytes
        self.cloudV2Present = cloudV2Present
        self.cloudV2Verified = cloudV2Verified
    }

    public var hasLegacy: Bool { localPresent || cloudV2Present }
}

public protocol MigrationProbing: Sendable {
    func inspectLegacy() async throws -> LegacyRepositoryState
    /// Publishes the legacy repository to Cloud Format v2. Must be idempotent.
    func publishLegacyToCloud() async throws
    func verifyLegacyCloud() async throws -> Bool
    /// Creates and verifies a native v3 baseline for every project.
    func createNativeBaseline() async throws -> Bool
    func verifyNativeBaseline() async throws -> Bool
    /// Frees the local Kopia repositories. Only called with explicit consent.
    func cleanupLegacyLocal() async throws
}

public struct MigrationConsent: Sendable, Equatable {
    /// The user explicitly opted into releasing the old local repository.
    public var releaseLegacyLocalSpace: Bool

    public init(releaseLegacyLocalSpace: Bool = false) {
        self.releaseLegacyLocalSpace = releaseLegacyLocalSpace
    }

    public static let `default` = MigrationConsent()
}

public struct MigrationStatus: Sendable, Equatable {
    public var phase: MigrationPhase
    public var detail: String
    public var requiresUserAction: Bool
    public var legacyLocalBytes: Int64
    public var resumeAfterPhase: MigrationPhase?

    public init(
        phase: MigrationPhase,
        detail: String = "",
        requiresUserAction: Bool = false,
        legacyLocalBytes: Int64 = 0,
        resumeAfterPhase: MigrationPhase? = nil
    ) {
        self.phase = phase
        self.detail = detail
        self.requiresUserAction = requiresUserAction
        self.legacyLocalBytes = legacyLocalBytes
        self.resumeAfterPhase = resumeAfterPhase
    }
}

public struct BackupMigrationCoordinator: Sendable {
    private let probe: MigrationProbing
    private let journal: MigrationJournaling
    private let clock: @Sendable () -> Date

    public init(
        probe: MigrationProbing,
        journal: MigrationJournaling,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.probe = probe
        self.journal = journal
        self.clock = clock
    }

    /// Where the migration currently stands, without performing any work.
    public func status() async -> MigrationStatus {
        do {
            let state = try await probe.inspectLegacy()
            let recorded = try await journal.latestMigrationPhase().flatMap(MigrationPhase.init(rawValue:))
            if !state.hasLegacy {
                return MigrationStatus(phase: .complete, detail: "没有旧版备份需要迁移")
            }
            let phase = recorded ?? (state.cloudV2Verified ? .legacyCloudVerified : .legacyDetected)
            return MigrationStatus(
                phase: phase == .blocked ? .blocked : phase,
                detail: "检测到旧版本地仓库 \(state.localBytes) 字节",
                requiresUserAction: phase == .legacyLocalCleanupPending,
                legacyLocalBytes: state.localBytes
            )
        } catch {
            return MigrationStatus(phase: .blocked, detail: "无法检查旧备份：\(error)")
        }
    }

    /// Runs (or resumes) the migration. Idempotent: steps already proven by the
    /// journal are skipped, so a crash between publish and verify never re-uploads
    /// and never deletes early.
    public func run(
        consent: MigrationConsent = .default,
        isCancelled: @Sendable () -> Bool = { false }
    ) async -> MigrationStatus {
        let state: LegacyRepositoryState
        do {
            state = try await probe.inspectLegacy()
        } catch {
            return await block("无法检查旧备份：\(error)", bytes: 0)
        }

        if !state.hasLegacy {
            try? await journal.appendMigrationEvent(
                MigrationJournalEntryV3(phase: MigrationPhase.complete.rawValue, updatedAt: clock())
            )
            return MigrationStatus(phase: .complete, detail: "没有旧版备份需要迁移")
        }

        let recorded = (try? await journal.latestMigrationPhase())
            .flatMap(MigrationPhase.init(rawValue:))
        var phase = recorded ?? .legacyDetected

        // 1. Publish the legacy repository to the cloud (must be idempotent).
        if phase.rank < MigrationPhase.legacyCloudVerified.rank {
            if isCancelled() { return MigrationStatus(phase: phase, detail: "已取消", resumeAfterPhase: phase) }
            phase = .legacyCloudPublishing
            try? await journal.appendMigrationEvent(
                MigrationJournalEntryV3(phase: phase.rawValue, updatedAt: clock())
            )
            do {
                try await probe.publishLegacyToCloud()
            } catch {
                return await block("旧备份上传未能完成：\(error)", bytes: state.localBytes)
            }
            do {
                guard try await probe.verifyLegacyCloud() else {
                    return await block("旧备份云端校验未通过，已停止迁移", bytes: state.localBytes)
                }
            } catch {
                return await block("旧备份云端校验出错：\(error)", bytes: state.localBytes)
            }
            phase = .legacyCloudVerified
            try? await journal.appendMigrationEvent(
                MigrationJournalEntryV3(phase: phase.rawValue, updatedAt: clock())
            )
        }

        // 2. Create the native v3 baseline and prove it.
        if phase.rank < MigrationPhase.nativeBaselineVerified.rank {
            if isCancelled() { return MigrationStatus(phase: phase, detail: "已取消", resumeAfterPhase: phase) }
            phase = .nativeBaselineUploading
            try? await journal.appendMigrationEvent(
                MigrationJournalEntryV3(phase: phase.rawValue, updatedAt: clock())
            )
            do {
                guard try await probe.createNativeBaseline() else {
                    return await block("新格式基线创建失败，已停止迁移", bytes: state.localBytes)
                }
                guard try await probe.verifyNativeBaseline() else {
                    return await block("新格式基线校验未通过，已停止迁移", bytes: state.localBytes)
                }
            } catch {
                return await block("新格式基线出错：\(error)", bytes: state.localBytes)
            }
            phase = .nativeBaselineVerified
            try? await journal.appendMigrationEvent(
                MigrationJournalEntryV3(phase: phase.rawValue, updatedAt: clock())
            )
        }

        // 3. Releasing old local space needs the user's explicit decision.
        if !consent.releaseLegacyLocalSpace {
            try? await journal.appendMigrationEvent(
                MigrationJournalEntryV3(phase: MigrationPhase.legacyLocalCleanupPending.rawValue, updatedAt: clock())
            )
            return MigrationStatus(
                phase: .legacyLocalCleanupPending,
                detail: "旧本地仓库仍占用 \(state.localBytes) 字节；释放后旧版本仍可从 iCloud 恢复，但恢复时需要临时下载完整旧仓库",
                requiresUserAction: true,
                legacyLocalBytes: state.localBytes
            )
        }

        do {
            try await probe.cleanupLegacyLocal()
        } catch {
            return await block("释放旧本地仓库失败：\(error)", bytes: state.localBytes)
        }
        try? await journal.appendMigrationEvent(
            MigrationJournalEntryV3(phase: MigrationPhase.complete.rawValue, updatedAt: clock())
        )
        return MigrationStatus(phase: .complete, detail: "迁移完成", legacyLocalBytes: 0)
    }

    private func block(_ detail: String, bytes: Int64) async -> MigrationStatus {
        try? await journal.appendMigrationEvent(
            MigrationJournalEntryV3(phase: MigrationPhase.blocked.rawValue, updatedAt: clock(), detail: detail)
        )
        return MigrationStatus(
            phase: .blocked,
            detail: detail,
            requiresUserAction: true,
            legacyLocalBytes: bytes
        )
    }
}
