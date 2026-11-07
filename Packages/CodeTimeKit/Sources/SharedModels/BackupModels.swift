import Foundation

public struct ExclusionRule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var pattern: String
    public var isEnabled: Bool
    public var preset: String?
    public var note: String?

    public init(
        id: UUID = UUID(),
        pattern: String,
        isEnabled: Bool = true,
        preset: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.pattern = pattern
        self.isEnabled = isEnabled
        self.preset = preset
        self.note = note
    }

    /// A trailing slash means the rule only applies to directories.
    public var isDirectoryOnly: Bool { pattern.hasSuffix("/") }
    public var normalizedPattern: String {
        var p = pattern
        while p.hasPrefix("./") { p.removeFirst(2) }
        if p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

public struct ExclusionPreset: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var rules: [String]

    public init(id: String, name: String, summary: String, rules: [String]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.rules = rules
    }

    public var exclusionRules: [ExclusionRule] {
        rules.map { ExclusionRule(pattern: $0, preset: id) }
    }
}

public struct RetentionPolicy: Codable, Hashable, Sendable {
    public var keepLatest: Int
    public var keepDaily: Int
    public var keepWeekly: Int
    public var keepMonthly: Int

    public init(keepLatest: Int = 96, keepDaily: Int = 30, keepWeekly: Int = 12, keepMonthly: Int = 12) {
        self.keepLatest = keepLatest
        self.keepDaily = keepDaily
        self.keepWeekly = keepWeekly
        self.keepMonthly = keepMonthly
    }

    public static let `default` = RetentionPolicy()
}

public enum PerformanceProfile: String, Codable, Sendable, CaseIterable {
    case eco
    case balanced
    case high

    public var displayName: String {
        switch self {
        case .eco: return "节能"
        case .balanced: return "平衡"
        case .high: return "高性能"
        }
    }

    public var backupParallelism: Int {
        switch self {
        case .eco: return 1
        case .balanced: return 2
        case .high: return 4
        }
    }

    public var uploadParallelism: Int {
        switch self {
        case .eco: return 1
        case .balanced: return 3
        case .high: return 6
        }
    }

    public var hashParallelism: Int {
        switch self {
        case .eco: return 1
        case .balanced: return 2
        case .high: return 4
        }
    }

    public var scanParallelism: Int {
        switch self {
        case .eco: return 1
        case .balanced: return 2
        case .high: return 4
        }
    }

    /// Upper bound on in-flight object bytes, so a large repository cannot exhaust memory.
    public var maxMemoryUsage: Int64 {
        switch self {
        case .eco: return 64 * 1024 * 1024
        case .balanced: return 256 * 1024 * 1024
        case .high: return 512 * 1024 * 1024
        }
    }

    /// Upper bound on staging/restore temporary space before the operation is refused.
    public var maxTemporaryStorage: Int64 {
        switch self {
        case .eco: return 2 * 1024 * 1024 * 1024
        case .balanced: return 10 * 1024 * 1024 * 1024
        case .high: return 50 * 1024 * 1024 * 1024
        }
    }

    public var pauseOnBattery: Bool { self != .high }
}

public struct BackupPolicy: Codable, Hashable, Sendable {
    public var projectID: UUID
    public var intervalMinutes: Int
    public var retention: RetentionPolicy
    public var excludeRules: [ExclusionRule]
    public var backupGitMetadata: Bool
    public var includeEnvFiles: Bool
    public var includeGitDirectory: Bool
    public var performance: PerformanceProfile
    public var minimumChangeIntervalMinutes: Int

    public init(
        projectID: UUID,
        intervalMinutes: Int = 30,
        retention: RetentionPolicy = .default,
        excludeRules: [ExclusionRule] = [],
        backupGitMetadata: Bool = true,
        includeEnvFiles: Bool = false,
        includeGitDirectory: Bool = true,
        performance: PerformanceProfile = .balanced,
        minimumChangeIntervalMinutes: Int = 5
    ) {
        self.projectID = projectID
        self.intervalMinutes = intervalMinutes
        self.retention = retention
        self.excludeRules = excludeRules
        self.backupGitMetadata = backupGitMetadata
        self.includeEnvFiles = includeEnvFiles
        self.includeGitDirectory = includeGitDirectory
        self.performance = performance
        self.minimumChangeIntervalMinutes = minimumChangeIntervalMinutes
    }

    public var activeExclusionPatterns: [String] {
        excludeRules.filter(\.isEnabled).map(\.pattern)
    }

    public func applied(to presetRules: [ExclusionRule]) -> [ExclusionRule] {
        presetRules + excludeRules
    }
}

public enum BackupTrigger: String, Codable, Sendable, CaseIterable {
    case scheduled
    case manual
    case wakeCatchUp
    case retry
    case agent
    case fileActivity

    public var displayName: String {
        switch self {
        case .scheduled: return "定时备份"
        case .manual: return "手动备份"
        case .wakeCatchUp: return "唤醒补跑"
        case .retry: return "失败重试"
        case .agent: return "后台代理"
        case .fileActivity: return "变更触发"
        }
    }
}

public enum SnapshotStatus: String, Codable, Sendable, CaseIterable {
    case complete
    case incomplete
    case failed

    public var displayName: String {
        switch self {
        case .complete: return "完整"
        case .incomplete: return "不完整"
        case .failed: return "失败"
        }
    }
}

public enum SnapshotConsistency: String, Codable, Sendable {
    case consistent
    case possiblyInconsistent
    case unknown

    public var displayName: String {
        switch self {
        case .consistent: return "一致"
        case .possiblyInconsistent: return "备份期间有文件变化"
        case .unknown: return "未确认"
        }
    }
}

public enum CloudSyncState: String, Codable, Sendable {
    case localOnly
    case pending
    case uploading
    case synced
    case failed
    case unknown

    public var displayName: String {
        switch self {
        case .localOnly: return "仅本地"
        case .pending: return "等待上传"
        case .uploading: return "正在上传"
        case .synced: return "云端已同步"
        case .failed: return "同步失败"
        case .unknown: return "状态未知"
        }
    }
}

public struct GitMetadata: Codable, Hashable, Sendable {
    public var branch: String?
    public var head: String?
    public var isDirty: Bool
    public var hasUntrackedFiles: Bool
    public var capturedAt: Date

    public init(branch: String?, head: String?, isDirty: Bool, hasUntrackedFiles: Bool, capturedAt: Date = Date()) {
        self.branch = branch
        self.head = head
        self.isDirty = isDirty
        self.hasUntrackedFiles = hasUntrackedFiles
        self.capturedAt = capturedAt
    }
}

public struct Snapshot: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var projectID: UUID
    public var createdAt: Date
    public var finishedAt: Date?
    public var summary: String
    public var trigger: BackupTrigger
    public var status: SnapshotStatus
    public var consistency: SnapshotConsistency
    public var fileCount: Int
    public var totalSize: Int64
    public var errorCount: Int
    public var excludedFileCount: Int
    public var excludedSize: Int64
    public var git: GitMetadata?
    public var cloudState: CloudSyncState
    public var cloudGenerationID: UUID?
    public var verifiedAt: Date?
    public var verificationLevel: VerificationLevel?

    public init(
        id: String,
        projectID: UUID,
        createdAt: Date,
        finishedAt: Date? = nil,
        summary: String = "",
        trigger: BackupTrigger = .manual,
        status: SnapshotStatus = .complete,
        consistency: SnapshotConsistency = .consistent,
        fileCount: Int = 0,
        totalSize: Int64 = 0,
        errorCount: Int = 0,
        excludedFileCount: Int = 0,
        excludedSize: Int64 = 0,
        git: GitMetadata? = nil,
        cloudState: CloudSyncState = .localOnly,
        cloudGenerationID: UUID? = nil,
        verifiedAt: Date? = nil,
        verificationLevel: VerificationLevel? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.summary = summary
        self.trigger = trigger
        self.status = status
        self.consistency = consistency
        self.fileCount = fileCount
        self.totalSize = totalSize
        self.errorCount = errorCount
        self.excludedFileCount = excludedFileCount
        self.excludedSize = excludedSize
        self.git = git
        self.cloudState = cloudState
        self.cloudGenerationID = cloudGenerationID
        self.verifiedAt = verifiedAt
        self.verificationLevel = verificationLevel
    }
}

public struct FileEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var size: Int64
    public var modifiedAt: Date?
    public var objectID: String?

    public init(
        path: String,
        name: String,
        isDirectory: Bool,
        isSymlink: Bool = false,
        size: Int64 = 0,
        modifiedAt: Date? = nil,
        objectID: String? = nil
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.size = size
        self.modifiedAt = modifiedAt
        self.objectID = objectID
    }
}

public enum DiffKind: String, Codable, Sendable {
    case added
    case removed
    case modified
}

public struct ChangedFile: Codable, Hashable, Sendable {
    public var path: String
    public var kind: DiffKind
    public var detail: String?

    public init(path: String, kind: DiffKind, detail: String? = nil) {
        self.path = path
        self.kind = kind
        self.detail = detail
    }
}

public struct SnapshotDiff: Codable, Hashable, Sendable {
    public var added: Int
    public var removed: Int
    public var modified: Int
    public var files: [ChangedFile]
    /// The engine stops after a fixed number of entries; the UI must say so rather
    /// than implying the list is the complete change set.
    public var isTruncated: Bool

    public init(
        added: Int = 0,
        removed: Int = 0,
        modified: Int = 0,
        files: [ChangedFile] = [],
        isTruncated: Bool = false
    ) {
        self.added = added
        self.removed = removed
        self.modified = modified
        self.files = files
        self.isTruncated = isTruncated
    }

    private enum CodingKeys: String, CodingKey {
        case added, removed, modified, files, isTruncated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        added = try c.decodeIfPresent(Int.self, forKey: .added) ?? 0
        removed = try c.decodeIfPresent(Int.self, forKey: .removed) ?? 0
        modified = try c.decodeIfPresent(Int.self, forKey: .modified) ?? 0
        files = try c.decodeIfPresent([ChangedFile].self, forKey: .files) ?? []
        isTruncated = try c.decodeIfPresent(Bool.self, forKey: .isTruncated) ?? false
    }

    public var totalChanges: Int { added + removed + modified }
}
