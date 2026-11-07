import Foundation

// MARK: - Repository lifecycle (§5)

public enum RepositoryState: String, Codable, Sendable, CaseIterable {
    case uninitialized
    case initializing
    case ready
    case missing
    case corrupted
    case recovering
    case recoveryFailed

    public var displayName: String {
        switch self {
        case .uninitialized: return "未初始化"
        case .initializing: return "正在初始化"
        case .ready: return "就绪"
        case .missing: return "仓库丢失"
        case .corrupted: return "仓库损坏"
        case .recovering: return "正在恢复"
        case .recoveryFailed: return "恢复失败"
        }
    }

    /// Only a repository that has never been initialized may be created automatically.
    public var allowsAutomaticCreation: Bool { self == .uninitialized }

    public var allowsBackup: Bool { self == .ready }
}

public struct RepositoryMetadata: Codable, Hashable, Sendable {
    public var repositoryID: UUID
    public var schemaVersion: Int
    public var kopiaVersion: String
    public var createdAt: Date
    public var initializedAt: Date?
    public var encryptionVersion: Int
    public var cloudRepositoryID: UUID?
    public var state: RepositoryState
    /// Kopia's own `uniqueIDHex`, used to detect a silently recreated repository.
    public var kopiaUniqueID: String?
    public var lastVerifiedAt: Date?
    public var stateReason: String?

    public init(
        repositoryID: UUID,
        schemaVersion: Int = 1,
        kopiaVersion: String = "",
        createdAt: Date = Date(),
        initializedAt: Date? = nil,
        encryptionVersion: Int = 1,
        cloudRepositoryID: UUID? = nil,
        state: RepositoryState = .uninitialized,
        kopiaUniqueID: String? = nil,
        lastVerifiedAt: Date? = nil,
        stateReason: String? = nil
    ) {
        self.repositoryID = repositoryID
        self.schemaVersion = schemaVersion
        self.kopiaVersion = kopiaVersion
        self.createdAt = createdAt
        self.initializedAt = initializedAt
        self.encryptionVersion = encryptionVersion
        self.cloudRepositoryID = cloudRepositoryID
        self.state = state
        self.kopiaUniqueID = kopiaUniqueID
        self.lastVerifiedAt = lastVerifiedAt
        self.stateReason = stateReason
    }
}

// MARK: - Cloud upload state (§3.4)

/// Fail-closed upload state. `unknown` must never be treated as `uploaded`.
public enum CloudUploadState: Sendable, Equatable {
    case notStarted
    case uploading
    case uploaded
    case failed(String)
    case unknown(String)

    public var isUploaded: Bool { self == .uploaded }

    public var displayName: String {
        switch self {
        case .notStarted: return "未开始"
        case .uploading: return "上传中"
        case .uploaded: return "已上传"
        case .failed: return "上传失败"
        case .unknown: return "状态未知"
        }
    }
}

// MARK: - Generation readability (§3.6)

/// A manifest that cannot be read must stay visible; it must never disappear from
/// the generation list, because GC derives its retention set from that list.
public enum GenerationReadState: String, Codable, Sendable, Equatable {
    case valid
    case notDownloaded
    case unreadable
    case corrupted
    case unsupportedVersion

    public var isReadable: Bool { self == .valid }

    public var displayName: String {
        switch self {
        case .valid: return "正常"
        case .notDownloaded: return "尚未下载"
        case .unreadable: return "无法读取"
        case .corrupted: return "已损坏"
        case .unsupportedVersion: return "格式不受支持"
        }
    }
}

public struct CloudGenerationEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var generation: CloudGeneration?
    public var readState: GenerationReadState
    public var detail: String?
    public var manifestPath: String

    public init(
        id: UUID,
        generation: CloudGeneration? = nil,
        readState: GenerationReadState,
        detail: String? = nil,
        manifestPath: String = ""
    ) {
        self.id = id
        self.generation = generation
        self.readState = readState
        self.detail = detail
        self.manifestPath = manifestPath
    }

    public var isRestorable: Bool { readState == .valid && generation != nil }
}

// MARK: - Garbage collection journal (§3.7)

public enum GCPhase: String, Codable, Sendable, CaseIterable {
    case enumerating
    case marking
    case tombstoning
    case deletingManifests
    case awaitingSync
    case gracePeriod
    case revalidating
    case sweepingObjects
    case completed
    case aborted

    public var displayName: String {
        switch self {
        case .enumerating: return "枚举云端版本"
        case .marking: return "计算保留引用"
        case .tombstoning: return "记录删除意图"
        case .deletingManifests: return "删除过期清单"
        case .awaitingSync: return "等待删除同步"
        case .gracePeriod: return "宽限期"
        case .revalidating: return "重新验证引用"
        case .sweepingObjects: return "删除孤儿对象"
        case .completed: return "已完成"
        case .aborted: return "已中止"
        }
    }

    /// Phases at which it is safe to resume without re-deriving the retention set.
    public var isResumable: Bool {
        switch self {
        case .completed, .aborted: return false
        default: return true
        }
    }
}

public struct GCJournal: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var repositoryID: UUID
    public var phase: GCPhase
    public var startedAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var protectedGenerations: [UUID]
    public var plannedManifestDeletes: [UUID]
    public var plannedObjectDeletes: [String]
    public var completedManifestDeletes: [UUID]
    public var completedObjectDeletes: [String]
    public var graceDeadline: Date?
    public var lastError: String?
    public var retryCount: Int
    public var freedBytes: Int64

    public init(
        id: UUID = UUID(),
        repositoryID: UUID,
        phase: GCPhase = .enumerating,
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        protectedGenerations: [UUID] = [],
        plannedManifestDeletes: [UUID] = [],
        plannedObjectDeletes: [String] = [],
        completedManifestDeletes: [UUID] = [],
        completedObjectDeletes: [String] = [],
        graceDeadline: Date? = nil,
        lastError: String? = nil,
        retryCount: Int = 0,
        freedBytes: Int64 = 0
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.phase = phase
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.protectedGenerations = protectedGenerations
        self.plannedManifestDeletes = plannedManifestDeletes
        self.plannedObjectDeletes = plannedObjectDeletes
        self.completedManifestDeletes = completedManifestDeletes
        self.completedObjectDeletes = completedObjectDeletes
        self.graceDeadline = graceDeadline
        self.lastError = lastError
        self.retryCount = retryCount
        self.freedBytes = freedBytes
    }
}

// MARK: - Cloud restore (§4)

public enum RestoreJobState: String, Codable, Sendable, CaseIterable {
    case preparing
    case downloading
    case verifying
    case committing
    case completed
    case failed
    case cancelled
    case interrupted

    public var displayName: String {
        switch self {
        case .preparing: return "准备中"
        case .downloading: return "下载对象"
        case .verifying: return "校验完整性"
        case .committing: return "提交仓库"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .interrupted: return "已中断"
        }
    }

    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }

    public var isResumable: Bool {
        switch self {
        case .preparing, .downloading, .verifying, .interrupted, .failed: return true
        default: return false
        }
    }
}

/// A resumable cloud-to-local repository restore. Progress is persisted after every
/// verified object so a power loss never forces a full re-download.
public struct CloudRestoreJob: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var repositoryID: UUID
    public var generationID: UUID
    public var sourceDeviceID: UUID
    public var state: RestoreJobState
    public var stagingPath: String
    public var totalFiles: Int
    public var completedFiles: Int
    public var totalBytes: Int64
    public var completedBytes: Int64
    public var currentObject: String?
    public var startedAt: Date
    public var updatedAt: Date
    public var lastError: String?
    public var retryCount: Int
    /// Hashes already downloaded AND verified; these are reused on resume.
    public var verifiedHashes: [String]

    public init(
        id: UUID = UUID(),
        repositoryID: UUID,
        generationID: UUID,
        sourceDeviceID: UUID,
        state: RestoreJobState = .preparing,
        stagingPath: String = "",
        totalFiles: Int = 0,
        completedFiles: Int = 0,
        totalBytes: Int64 = 0,
        completedBytes: Int64 = 0,
        currentObject: String? = nil,
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        lastError: String? = nil,
        retryCount: Int = 0,
        verifiedHashes: [String] = []
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.generationID = generationID
        self.sourceDeviceID = sourceDeviceID
        self.state = state
        self.stagingPath = stagingPath
        self.totalFiles = totalFiles
        self.completedFiles = completedFiles
        self.totalBytes = totalBytes
        self.completedBytes = completedBytes
        self.currentObject = currentObject
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.lastError = lastError
        self.retryCount = retryCount
        self.verifiedHashes = verifiedHashes
    }

    public var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }
}

public struct RestoreReport: Codable, Hashable, Sendable {
    public var repositoryID: UUID
    public var sourceGenerationID: UUID
    public var totalObjects: Int
    public var verifiedObjects: Int
    public var failedObjects: [String]
    public var totalBytes: Int64
    public var duration: TimeInterval
    public var repositoryCheck: Bool
    public var snapshotCheck: Bool
    public var snapshotCount: Int
    public var result: VerificationOutcome
    public var details: String

    public init(
        repositoryID: UUID,
        sourceGenerationID: UUID,
        totalObjects: Int = 0,
        verifiedObjects: Int = 0,
        failedObjects: [String] = [],
        totalBytes: Int64 = 0,
        duration: TimeInterval = 0,
        repositoryCheck: Bool = false,
        snapshotCheck: Bool = false,
        snapshotCount: Int = 0,
        result: VerificationOutcome = .failed,
        details: String = ""
    ) {
        self.repositoryID = repositoryID
        self.sourceGenerationID = sourceGenerationID
        self.totalObjects = totalObjects
        self.verifiedObjects = verifiedObjects
        self.failedObjects = failedObjects
        self.totalBytes = totalBytes
        self.duration = duration
        self.repositoryCheck = repositoryCheck
        self.snapshotCheck = snapshotCheck
        self.snapshotCount = snapshotCount
        self.result = result
        self.details = details
    }

    /// Success requires every check, not just a completed file copy.
    public var isSuccessful: Bool {
        result == .passed
            && failedObjects.isEmpty
            && verifiedObjects == totalObjects
            && totalObjects > 0
            && repositoryCheck
            && snapshotCheck
    }
}

/// One decryptable repository found in the cloud, offered to the user as a restore source.
public struct RecoveryCandidate: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var repositoryID: UUID
    public var deviceID: UUID
    public var deviceName: String
    public var latestGenerationID: UUID?
    public var latestBackupAt: Date?
    public var generationCount: Int
    public var readableGenerationCount: Int
    public var repositoryBytes: Int64
    public var integrityOK: Bool
    public var kopiaVersion: String?
    public var recoveryInfoPath: String
    public var blockedReason: String?

    public init(
        id: UUID = UUID(),
        repositoryID: UUID,
        deviceID: UUID,
        deviceName: String = "",
        latestGenerationID: UUID? = nil,
        latestBackupAt: Date? = nil,
        generationCount: Int = 0,
        readableGenerationCount: Int = 0,
        repositoryBytes: Int64 = 0,
        integrityOK: Bool = false,
        kopiaVersion: String? = nil,
        blockedReason: String? = nil,
        recoveryInfoPath: String = ""
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.latestGenerationID = latestGenerationID
        self.latestBackupAt = latestBackupAt
        self.generationCount = generationCount
        self.readableGenerationCount = readableGenerationCount
        self.repositoryBytes = repositoryBytes
        self.integrityOK = integrityOK
        self.kopiaVersion = kopiaVersion
        self.blockedReason = blockedReason
        self.recoveryInfoPath = recoveryInfoPath
    }

    public var isRestorable: Bool { blockedReason == nil && latestGenerationID != nil }
}

// MARK: - Job leases (§6.3)

public enum CodeTimeJobType: String, Codable, Sendable, CaseIterable {
    case backup
    case publish
    case verify
    case cleanup
    case restore
    case migrate

    public var displayName: String {
        switch self {
        case .backup: return "备份"
        case .publish: return "云端发布"
        case .verify: return "完整性校验"
        case .cleanup: return "云端清理"
        case .restore: return "恢复"
        case .migrate: return "数据迁移"
        }
    }
}

/// Identifies the process that owns a job. `startTime` defeats PID reuse: a recycled
/// PID belonging to a different process must not be treated as the original owner.
public struct ProcessIdentity: Codable, Hashable, Sendable {
    public var pid: Int32
    public var startTime: Double
    public var isAgent: Bool

    public init(pid: Int32, startTime: Double, isAgent: Bool) {
        self.pid = pid
        self.startTime = startTime
        self.isAgent = isAgent
    }

    public static func current(isAgent: Bool) -> ProcessIdentity {
        ProcessIdentity(
            pid: ProcessInfo.processInfo.processIdentifier,
            startTime: ProcessIdentity.processStartTime(ProcessInfo.processInfo.processIdentifier),
            isAgent: isAgent
        )
    }

    /// Reads the process start time via sysctl(KERN_PROC_PID). Returns 0 when the
    /// process no longer exists, which callers must treat as "not alive".
    public static func processStartTime(_ pid: Int32) -> Double {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard result == size else { return 0 }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    }

    public static func isAlive(_ pid: Int32, startTime: Double) -> Bool {
        guard pid > 0 else { return false }
        let actual = processStartTime(pid)
        guard actual > 0 else { return false }
        // Start time is exact for the same process; any drift means the PID was reused.
        return abs(actual - startTime) < 1.0
    }

    public var isAlive: Bool { ProcessIdentity.isAlive(pid, startTime: startTime) }

    public var displayName: String { "\(isAgent ? "Agent" : "UI"):\(pid)" }
}

public struct JobLease: Codable, Hashable, Sendable {
    public var owner: ProcessIdentity
    public var heartbeatAt: Date
    public var leaseExpiresAt: Date
    public var configRevision: Int

    public init(
        owner: ProcessIdentity,
        heartbeatAt: Date = Date(),
        leaseExpiresAt: Date,
        configRevision: Int = 0
    ) {
        self.owner = owner
        self.heartbeatAt = heartbeatAt
        self.leaseExpiresAt = leaseExpiresAt
        self.configRevision = configRevision
    }

    /// A lease may only be reclaimed when the owner is provably gone AND the lease
    /// has expired. Either condition alone is insufficient.
    public func isReclaimable(now: Date = Date()) -> Bool {
        guard now >= leaseExpiresAt else { return false }
        return !owner.isAlive
    }

    public func isExpired(now: Date = Date()) -> Bool { now >= leaseExpiresAt }
}

// MARK: - Retry policy (§10.1)

public enum RetryErrorClass: String, Codable, Sendable {
    case transientNetwork
    case iCloudNotDownloaded
    case permission
    case diskSpace
    case repositoryCorrupted
    case userCancelled
    case configuration
    case unknown

    public var isPermanent: Bool {
        switch self {
        case .permission, .repositoryCorrupted, .userCancelled, .configuration: return true
        default: return false
        }
    }
}

public struct RetryPolicy: Codable, Hashable, Sendable {
    public var maxAttempts: Int
    public var jitterRatio: Double

    public init(maxAttempts: Int = 8, jitterRatio: Double = 0.2) {
        self.maxAttempts = maxAttempts
        self.jitterRatio = jitterRatio
    }

    public static let `default` = RetryPolicy()

    /// 1m → 5m → 15m → 30m → 60m, with jitter so projects do not retry in lockstep.
    public func delay(attempt: Int, errorClass: RetryErrorClass, random: Double = Double.random(in: 0...1)) -> TimeInterval? {
        guard !errorClass.isPermanent else { return nil }
        guard attempt < maxAttempts else { return nil }
        let base: TimeInterval
        switch attempt {
        case 0: base = 60
        case 1: base = 300
        case 2: base = 900
        case 3: base = 1800
        default: base = 3600
        }
        let jitter = base * jitterRatio * (random * 2 - 1)
        return max(1, base + jitter)
    }

    public static func classify(_ error: Error) -> RetryErrorClass {
        if let code = error as? CodeTimeError {
            if code.isPermanent {
                switch code {
                case .cancelled, .projectDeleted: return .userCancelled
                case .unauthorized, .securityScopeUnavailable, .bookmarkFailed: return .permission
                case .repositoryCorrupted, .repositoryMissing, .repositoryIdentityMismatch: return .repositoryCorrupted
                default: return .configuration
                }
            }
            switch code {
            case .manifestNotDownloaded, .cloudStateUnknown: return .iCloudNotDownloaded
            case .cloudUploadFailed, .cloudPublishIncomplete: return .transientNetwork
            case .insufficientDiskSpace: return .diskSpace
            default: return .unknown
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return .transientNetwork }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return .diskSpace }
        return .unknown
    }
}

// MARK: - Maintenance state (§10.3)

public struct MaintenanceTaskState: Codable, Hashable, Sendable {
    public var task: CodeTimeJobType
    public var lastSuccessAt: Date?
    public var lastAttemptAt: Date?
    public var nextRunAt: Date?
    public var failureCount: Int
    public var lastError: String?
    public var lastSkippedReason: String?

    public init(
        task: CodeTimeJobType,
        lastSuccessAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        nextRunAt: Date? = nil,
        failureCount: Int = 0,
        lastError: String? = nil,
        lastSkippedReason: String? = nil
    ) {
        self.task = task
        self.lastSuccessAt = lastSuccessAt
        self.lastAttemptAt = lastAttemptAt
        self.nextRunAt = nextRunAt
        self.failureCount = failureCount
        self.lastError = lastError
        self.lastSkippedReason = lastSkippedReason
    }

    /// A skipped or failed run must never advance the success timestamp.
    public func recordingSuccess(at date: Date = Date(), nextRunAt: Date?) -> MaintenanceTaskState {
        var copy = self
        copy.lastSuccessAt = date
        copy.lastAttemptAt = date
        copy.nextRunAt = nextRunAt
        copy.failureCount = 0
        copy.lastError = nil
        copy.lastSkippedReason = nil
        return copy
    }

    public func recordingFailure(_ message: String, at date: Date = Date(), nextRunAt: Date?) -> MaintenanceTaskState {
        var copy = self
        copy.lastAttemptAt = date
        copy.nextRunAt = nextRunAt
        copy.failureCount += 1
        copy.lastError = message
        return copy
    }

    public func recordingSkip(_ reason: String, at date: Date = Date(), nextRunAt: Date?) -> MaintenanceTaskState {
        var copy = self
        copy.lastAttemptAt = date
        copy.nextRunAt = nextRunAt
        copy.lastSkippedReason = reason
        return copy
    }
}

// MARK: - Object hash cache and cloud index (§3.3, §3.8)

/// Cache validity requires a stable file identity in addition to size and mtime.
/// A cache hit is a performance hint, never proof of content: the publish path
/// re-hashes before committing an object.
public struct ObjectHashCacheEntry: Codable, Hashable, Sendable {
    public var relativePath: String
    public var fileIdentity: String
    public var resourceIdentifier: String?
    public var size: Int64
    public var modifiedAt: Date
    public var contentHash: String
    public var algorithm: String
    public var cacheVersion: Int
    public var verifiedAt: Date

    public init(
        relativePath: String,
        fileIdentity: String,
        resourceIdentifier: String? = nil,
        size: Int64,
        modifiedAt: Date,
        contentHash: String,
        algorithm: String = "sha256",
        cacheVersion: Int = 1,
        verifiedAt: Date = Date()
    ) {
        self.relativePath = relativePath
        self.fileIdentity = fileIdentity
        self.resourceIdentifier = resourceIdentifier
        self.size = size
        self.modifiedAt = modifiedAt
        self.contentHash = contentHash
        self.algorithm = algorithm
        self.cacheVersion = cacheVersion
        self.verifiedAt = verifiedAt
    }

    public func matches(identity: String, size: Int64, modifiedAt: Date) -> Bool {
        cacheVersion == ObjectHashCacheEntry.currentVersion
            && algorithm == "sha256"
            && fileIdentity == identity
            && self.size == size
            && abs(self.modifiedAt.timeIntervalSince(modifiedAt)) < 0.001
    }

    public static let currentVersion = 1
}

public struct CloudObjectIndexEntry: Codable, Hashable, Sendable {
    public var relativePath: String
    public var size: Int64
    public var modifiedAt: Date
    public var fileIdentity: String
    public var sha256: String
    public var lastVerifiedAt: Date?
    public var uploadState: CloudObjectUploadState
    public var generationReferences: [UUID]

    public func matches(identity: String, size: Int64, modifiedAt: Date) -> Bool {
        fileIdentity == identity
            && self.size == size
            && abs(self.modifiedAt.timeIntervalSince(modifiedAt)) < 0.001
    }

    public init(
        relativePath: String,
        size: Int64,
        modifiedAt: Date,
        fileIdentity: String,
        sha256: String,
        lastVerifiedAt: Date? = nil,
        uploadState: CloudObjectUploadState = .pending,
        generationReferences: [UUID] = []
    ) {
        self.relativePath = relativePath
        self.size = size
        self.modifiedAt = modifiedAt
        self.fileIdentity = fileIdentity
        self.sha256 = sha256
        self.lastVerifiedAt = lastVerifiedAt
        self.uploadState = uploadState
        self.generationReferences = generationReferences
    }
}

/// Result of a repository scan. `isComplete == false` must block manifest publication.
public struct RepositoryScanResult: Codable, Hashable, Sendable {
    public var entries: [CloudObjectIndexEntry]
    public var isComplete: Bool
    public var skippedPaths: [String]
    public var errorCount: Int
    public var scannedAt: Date

    public init(
        entries: [CloudObjectIndexEntry] = [],
        isComplete: Bool = false,
        skippedPaths: [String] = [],
        errorCount: Int = 0,
        scannedAt: Date = Date()
    ) {
        self.entries = entries
        self.isComplete = isComplete
        self.skippedPaths = skippedPaths
        self.errorCount = errorCount
        self.scannedAt = scannedAt
    }
}

// MARK: - Search truncation (§11.3)

public struct SearchLimits: Codable, Hashable, Sendable {
    public var maxDirectories: Int
    public var maxFiles: Int
    public var maxDepth: Int
    public var maxDuration: TimeInterval
    public var maxResults: Int

    public init(
        maxDirectories: Int = 20_000,
        maxFiles: Int = 200_000,
        maxDepth: Int = 64,
        maxDuration: TimeInterval = 30,
        maxResults: Int = 300
    ) {
        self.maxDirectories = maxDirectories
        self.maxFiles = maxFiles
        self.maxDepth = maxDepth
        self.maxDuration = maxDuration
        self.maxResults = maxResults
    }

    public static let `default` = SearchLimits()
}

public struct FileSearchResult: Codable, Hashable, Sendable {
    public var entries: [FileEntry]
    public var truncated: Bool
    public var truncationReason: String?
    public var visitedDirectories: Int
    public var visitedFiles: Int
    public var failedDirectories: [String]
    public var duration: TimeInterval

    public init(
        entries: [FileEntry] = [],
        truncated: Bool = false,
        truncationReason: String? = nil,
        visitedDirectories: Int = 0,
        visitedFiles: Int = 0,
        failedDirectories: [String] = [],
        duration: TimeInterval = 0
    ) {
        self.entries = entries
        self.truncated = truncated
        self.truncationReason = truncationReason
        self.visitedDirectories = visitedDirectories
        self.visitedFiles = visitedFiles
        self.failedDirectories = failedDirectories
        self.duration = duration
    }
}

// MARK: - Snapshot query result (§11.1)

public enum SnapshotQueryResult: Sendable {
    case success([Snapshot])
    case unavailable(String)
    case corrupted(String)

    public var snapshotsOrEmpty: [Snapshot] {
        if case .success(let items) = self { return items }
        return []
    }

    public var isFailure: Bool {
        switch self {
        case .success: return false
        default: return true
        }
    }

    public var failureMessage: String? {
        switch self {
        case .success: return nil
        case .unavailable(let message): return message
        case .corrupted(let message): return message
        }
    }
}

// MARK: - Project access and lifecycle (§8.2, §6.1)

public enum SecurityAccessState: String, Codable, Sendable, CaseIterable {
    case unknown
    case granted
    case stale
    case denied
    case notRequired

    public var displayName: String {
        switch self {
        case .unknown: return "未验证"
        case .granted: return "已授权"
        case .stale: return "授权已过期"
        case .denied: return "授权被拒绝"
        case .notRequired: return "无需授权"
        }
    }

    public var needsReauthorization: Bool { self == .stale || self == .denied }
}

public enum ProjectLifecycle: String, Codable, Sendable {
    case active
    case deleting
    case deleted

    public var acceptsBackup: Bool { self == .active }
}

// MARK: - Migration (§8.1)

public enum MigrationState: String, Codable, Sendable, CaseIterable {
    case notNeeded
    case detected
    case awaitingConsent
    case copying
    case verifying
    case committed
    case failed
    case declined

    public var displayName: String {
        switch self {
        case .notNeeded: return "无需迁移"
        case .detected: return "发现旧版数据"
        case .awaitingConsent: return "等待确认"
        case .copying: return "正在复制"
        case .verifying: return "正在验证"
        case .committed: return "迁移完成"
        case .failed: return "迁移失败"
        case .declined: return "暂不迁移"
        }
    }
}

public struct MigrationJob: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var sourceVersion: String
    public var targetVersion: String
    public var sourcePath: String
    public var targetPath: String
    public var state: MigrationState
    public var progress: Double
    public var copiedBytes: Int64
    public var totalBytes: Int64
    public var lastError: String?
    public var startedAt: Date
    public var updatedAt: Date
    public var sourceBookmark: Data?

    public init(
        id: UUID = UUID(),
        sourceVersion: String,
        targetVersion: String,
        sourcePath: String,
        targetPath: String,
        state: MigrationState = .detected,
        progress: Double = 0,
        copiedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        lastError: String? = nil,
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        sourceBookmark: Data? = nil
    ) {
        self.id = id
        self.sourceVersion = sourceVersion
        self.targetVersion = targetVersion
        self.sourcePath = sourcePath
        self.targetPath = targetPath
        self.state = state
        self.progress = progress
        self.copiedBytes = copiedBytes
        self.totalBytes = totalBytes
        self.lastError = lastError
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.sourceBookmark = sourceBookmark
    }
}

// MARK: - Path validation (§12)

public struct PathValidationIssue: Codable, Hashable, Sendable {
    public var path: String
    public var reason: String
    public var suggestion: String

    public init(path: String, reason: String, suggestion: String) {
        self.path = path
        self.reason = reason
        self.suggestion = suggestion
    }
}

// MARK: - Scheduler settings (§7.1)

/// Persisted alongside AppSettings; SQLite is the single source of truth and
/// `configRevision` lets other processes detect that their cache is stale.
public struct SchedulerSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var globallyPaused: Bool
    public var autoBackupOnLaunch: Bool
    public var pauseOnLowPowerMode: Bool
    public var backupIntervalMinutes: Int
    public var verificationIntervalDays: Int
    public var cleanupIntervalDays: Int
    public var configRevision: Int
    public var updatedAt: Date

    public init(
        enabled: Bool = true,
        globallyPaused: Bool = false,
        autoBackupOnLaunch: Bool = true,
        pauseOnLowPowerMode: Bool = false,
        backupIntervalMinutes: Int = 30,
        verificationIntervalDays: Int = 7,
        cleanupIntervalDays: Int = 1,
        configRevision: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.enabled = enabled
        self.globallyPaused = globallyPaused
        self.autoBackupOnLaunch = autoBackupOnLaunch
        self.pauseOnLowPowerMode = pauseOnLowPowerMode
        self.backupIntervalMinutes = backupIntervalMinutes
        self.verificationIntervalDays = verificationIntervalDays
        self.cleanupIntervalDays = cleanupIntervalDays
        self.configRevision = configRevision
        self.updatedAt = updatedAt
    }

    public static let `default` = SchedulerSettings()

    public var allowsScheduling: Bool { enabled && !globallyPaused }
}

// MARK: - Persistence seams used by CloudMirrorStore (§3.7, §3.8)

/// GC journals must survive a crash between deletion phases. The store lives in the
/// app database; the cloud store only needs these three operations.
public protocol GCJournalProviding: Sendable {
    func loadUnfinishedGCJournal(repositoryID: UUID) async throws -> GCJournal?
    func saveGCJournal(_ journal: GCJournal) async throws
    func deleteGCJournal(id: UUID) async throws
}

public protocol CloudObjectIndexProviding: Sendable {
    func loadObjectIndex(repositoryID: UUID) async throws -> [CloudObjectIndexEntry]
    func saveObjectIndex(_ entries: [CloudObjectIndexEntry], repositoryID: UUID) async throws
}

public protocol ObjectHashCacheProviding: Sendable {
    func loadHashCache(repositoryID: UUID, paths: [String]) async throws -> [String: ObjectHashCacheEntry]
    func saveHashCache(_ entries: [ObjectHashCacheEntry], repositoryID: UUID) async throws
}

public struct NoopGCJournalStore: GCJournalProviding {
    public init() {}
    public func loadUnfinishedGCJournal(repositoryID: UUID) async throws -> GCJournal? { nil }
    public func saveGCJournal(_ journal: GCJournal) async throws {}
    public func deleteGCJournal(id: UUID) async throws {}
}

public struct NoopObjectIndexStore: CloudObjectIndexProviding {
    public init() {}
    public func loadObjectIndex(repositoryID: UUID) async throws -> [CloudObjectIndexEntry] { [] }
    public func saveObjectIndex(_ entries: [CloudObjectIndexEntry], repositoryID: UUID) async throws {}
}

public struct NoopHashCacheStore: ObjectHashCacheProviding {
    public init() {}
    public func loadHashCache(repositoryID: UUID, paths: [String]) async throws -> [String: ObjectHashCacheEntry] { [:] }
    public func saveHashCache(_ entries: [ObjectHashCacheEntry], repositoryID: UUID) async throws {}
}