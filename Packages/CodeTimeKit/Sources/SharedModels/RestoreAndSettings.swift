import Foundation

public enum RestoreMode: String, Codable, Sendable, CaseIterable {
    case preview
    case copy
    case overwrite
    case wholeProject

    public var displayName: String {
        switch self {
        case .preview: return "仅预览"
        case .copy: return "恢复副本"
        case .overwrite: return "覆盖原文件"
        case .wholeProject: return "恢复整个项目"
        }
    }

    public var isDestructive: Bool { self == .overwrite }
}

public enum RestoreStatus: String, Codable, Sendable {
    case running
    case completed
    case failed
    case cancelled

    public var displayName: String {
        switch self {
        case .running: return "进行中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

public struct RestoreJob: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var projectID: UUID
    public var snapshotID: String
    public var relativePath: String?
    public var mode: RestoreMode
    public var targetPath: String
    public var status: RestoreStatus
    public var createdAt: Date
    public var finishedAt: Date?
    public var errorMessage: String?
    public var restoredFileCount: Int
    public var restoredBytes: Int64

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        snapshotID: String,
        relativePath: String? = nil,
        mode: RestoreMode,
        targetPath: String,
        status: RestoreStatus = .running,
        createdAt: Date = Date(),
        finishedAt: Date? = nil,
        errorMessage: String? = nil,
        restoredFileCount: Int = 0,
        restoredBytes: Int64 = 0
    ) {
        self.id = id
        self.projectID = projectID
        self.snapshotID = snapshotID
        self.relativePath = relativePath
        self.mode = mode
        self.targetPath = targetPath
        self.status = status
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.errorMessage = errorMessage
        self.restoredFileCount = restoredFileCount
        self.restoredBytes = restoredBytes
    }
}

public enum VerificationLevel: String, Codable, Sendable, CaseIterable {
    case cloudIntegrity
    case localRestore
    case crossDeviceRestore

    public var displayName: String {
        switch self {
        case .cloudIntegrity: return "云端完整性"
        case .localRestore: return "本地恢复校验"
        case .crossDeviceRestore: return "异机恢复验证"
        }
    }
}

public enum VerificationOutcome: String, Codable, Sendable {
    case passed
    case failed
    case skipped
}

public struct VerificationResult: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var generationID: UUID?
    public var snapshotID: String?
    public var projectID: UUID?
    public var level: VerificationLevel
    public var outcome: VerificationOutcome
    public var checkedAt: Date
    public var details: String
    public var bytesChecked: Int64

    public init(
        id: UUID = UUID(),
        generationID: UUID? = nil,
        snapshotID: String? = nil,
        projectID: UUID? = nil,
        level: VerificationLevel,
        outcome: VerificationOutcome,
        checkedAt: Date = Date(),
        details: String = "",
        bytesChecked: Int64 = 0
    ) {
        self.id = id
        self.generationID = generationID
        self.snapshotID = snapshotID
        self.projectID = projectID
        self.level = level
        self.outcome = outcome
        self.checkedAt = checkedAt
        self.details = details
        self.bytesChecked = bytesChecked
    }
}

public enum ActivityKind: String, Codable, Sendable, CaseIterable {
    case backup
    case upload
    case restore
    case verification
    case cleanup
    case agent
    case security
    case system

    public var displayName: String {
        switch self {
        case .backup: return "备份"
        case .upload: return "同步"
        case .restore: return "恢复"
        case .verification: return "校验"
        case .cleanup: return "清理"
        case .agent: return "代理"
        case .security: return "安全"
        case .system: return "系统"
        }
    }

    public var symbolName: String {
        switch self {
        case .backup: return "clock.arrow.circlepath"
        case .upload: return "icloud.and.arrow.up"
        case .restore: return "arrow.down.doc"
        case .verification: return "checkmark.shield"
        case .cleanup: return "trash"
        case .agent: return "gearshape.2"
        case .security: return "lock.shield"
        case .system: return "info.circle"
        }
    }
}

public enum ActivityLevel: String, Codable, Sendable {
    case info
    case success
    case warning
    case error
}

public struct ActivityEvent: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var kind: ActivityKind
    public var level: ActivityLevel
    public var projectID: UUID?
    public var message: String
    public var details: String?

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        kind: ActivityKind,
        level: ActivityLevel = .info,
        projectID: UUID? = nil,
        message: String,
        details: String? = nil
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.level = level
        self.projectID = projectID
        self.message = message
        self.details = details
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var iCloudEnabled: Bool
    public var localMirrorPath: String?
    public var performance: PerformanceProfile
    public var launchAgentEnabled: Bool
    public var periodicVerificationDays: Int
    public var autoBackupOnLaunch: Bool
    public var globalIntervalMinutes: Int
    public var showExcludedPreview: Bool
    public var hasCompletedOnboarding: Bool
    public var lastRecoveryKeyAcknowledgedAt: Date?
    public var pauseOnBattery: Bool
    public var cloudGracePeriodDays: Int
    public var minimumCloudGenerations: Int

    public init(
        iCloudEnabled: Bool = false,
        localMirrorPath: String? = nil,
        performance: PerformanceProfile = .balanced,
        launchAgentEnabled: Bool = false,
        periodicVerificationDays: Int = 7,
        autoBackupOnLaunch: Bool = true,
        globalIntervalMinutes: Int = 30,
        showExcludedPreview: Bool = true,
        hasCompletedOnboarding: Bool = false,
        lastRecoveryKeyAcknowledgedAt: Date? = nil,
        pauseOnBattery: Bool = false,
        cloudGracePeriodDays: Int = 30,
        minimumCloudGenerations: Int = 2
    ) {
        self.iCloudEnabled = iCloudEnabled
        self.localMirrorPath = localMirrorPath
        self.performance = performance
        self.launchAgentEnabled = launchAgentEnabled
        self.periodicVerificationDays = periodicVerificationDays
        self.autoBackupOnLaunch = autoBackupOnLaunch
        self.globalIntervalMinutes = globalIntervalMinutes
        self.showExcludedPreview = showExcludedPreview
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.lastRecoveryKeyAcknowledgedAt = lastRecoveryKeyAcknowledgedAt
        self.pauseOnBattery = pauseOnBattery
        self.cloudGracePeriodDays = cloudGracePeriodDays
        self.minimumCloudGenerations = minimumCloudGenerations
    }

    public static let `default` = AppSettings()
}

public struct ExclusionPreview: Codable, Hashable, Sendable {
    public var includedFiles: Int
    public var includedBytes: Int64
    public var excludedFiles: Int
    public var excludedBytes: Int64
    public var samples: [ExcludedSample]

    public init(includedFiles: Int = 0, includedBytes: Int64 = 0, excludedFiles: Int = 0, excludedBytes: Int64 = 0, samples: [ExcludedSample] = []) {
        self.includedFiles = includedFiles
        self.includedBytes = includedBytes
        self.excludedFiles = excludedFiles
        self.excludedBytes = excludedBytes
        self.samples = samples
    }
}

public struct ExcludedSample: Codable, Hashable, Sendable {
    public var path: String
    public var pattern: String
    public var size: Int64

    public init(path: String, pattern: String, size: Int64) {
        self.path = path
        self.pattern = pattern
        self.size = size
    }
}
