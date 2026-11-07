import Foundation

public enum CloudGenerationState: String, Codable, Sendable {
    case staging
    case uploading
    case published
    case verified
    case failed

    public var displayName: String {
        switch self {
        case .staging: return "准备清单"
        case .uploading: return "上传对象"
        case .published: return "已发布"
        case .verified: return "已校验"
        case .failed: return "失败"
        }
    }
}

public struct CloudGeneration: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var repositoryID: UUID
    public var deviceID: UUID
    public var createdAt: Date
    public var publishedAt: Date?
    public var state: CloudGenerationState
    public var manifestHash: String
    public var objectCount: Int
    public var byteSize: Int64
    public var snapshotIDs: [String]
    public var uploadedObjectCount: Int
    public var verifiedAt: Date?
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        repositoryID: UUID,
        deviceID: UUID,
        createdAt: Date = Date(),
        publishedAt: Date? = nil,
        state: CloudGenerationState = .staging,
        manifestHash: String = "",
        objectCount: Int = 0,
        byteSize: Int64 = 0,
        snapshotIDs: [String] = [],
        uploadedObjectCount: Int = 0,
        verifiedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.deviceID = deviceID
        self.createdAt = createdAt
        self.publishedAt = publishedAt
        self.state = state
        self.manifestHash = manifestHash
        self.objectCount = objectCount
        self.byteSize = byteSize
        self.snapshotIDs = snapshotIDs
        self.uploadedObjectCount = uploadedObjectCount
        self.verifiedAt = verifiedAt
        self.errorMessage = errorMessage
    }
}

public enum CloudObjectUploadState: String, Codable, Sendable {
    case pending
    case uploading
    case uploaded
    case failed
}

public struct CloudObject: Codable, Hashable, Sendable {
    public var hash: String
    public var size: Int64
    public var uploadState: CloudObjectUploadState
    public var firstSeenAt: Date
    public var uploadedAt: Date?
    public var lastCheckedAt: Date?

    public init(
        hash: String,
        size: Int64,
        uploadState: CloudObjectUploadState = .pending,
        firstSeenAt: Date = Date(),
        uploadedAt: Date? = nil,
        lastCheckedAt: Date? = nil
    ) {
        self.hash = hash
        self.size = size
        self.uploadState = uploadState
        self.firstSeenAt = firstSeenAt
        self.uploadedAt = uploadedAt
        self.lastCheckedAt = lastCheckedAt
    }
}

public struct CloudStorageSummary: Codable, Hashable, Sendable {
    public var objectCount: Int
    public var byteSize: Int64
    public var generationCount: Int
    public var lastPublishedAt: Date?
    public var lastVerifiedAt: Date?

    public init(objectCount: Int = 0, byteSize: Int64 = 0, generationCount: Int = 0, lastPublishedAt: Date? = nil, lastVerifiedAt: Date? = nil) {
        self.objectCount = objectCount
        self.byteSize = byteSize
        self.generationCount = generationCount
        self.lastPublishedAt = lastPublishedAt
        self.lastVerifiedAt = lastVerifiedAt
    }
}

public enum BackupJobType: String, Codable, Sendable {
    case backup
    case upload
    case verify
    case cleanup
    case restore
    case migrate

    public var unifiedType: CodeTimeJobType {
        switch self {
        case .backup: return .backup
        case .upload: return .publish
        case .verify: return .verify
        case .cleanup: return .cleanup
        case .restore: return .restore
        case .migrate: return .migrate
        }
    }
}

public enum BackupJobState: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
    case interrupted

    public var isTerminal: Bool {
        self == .succeeded || self == .failed || self == .cancelled || self == .interrupted
    }
}

public struct BackupJob: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var projectID: UUID
    public var type: BackupJobType
    public var state: BackupJobState
    public var trigger: BackupTrigger
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var attempt: Int
    public var errorMessage: String?
    public var checkpoint: Data?
    public var repositoryID: UUID?
    public var lease: JobLease?
    public var retryCount: Int
    public var nextRetryAt: Date?
    public var progress: Double
    public var errorClass: RetryErrorClass?

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        type: BackupJobType,
        state: BackupJobState = .queued,
        trigger: BackupTrigger = .scheduled,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        attempt: Int = 1,
        errorMessage: String? = nil,
        checkpoint: Data? = nil,
        repositoryID: UUID? = nil,
        lease: JobLease? = nil,
        retryCount: Int = 0,
        nextRetryAt: Date? = nil,
        progress: Double = 0,
        errorClass: RetryErrorClass? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.type = type
        self.state = state
        self.trigger = trigger
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.attempt = attempt
        self.errorMessage = errorMessage
        self.checkpoint = checkpoint
        self.repositoryID = repositoryID
        self.lease = lease
        self.retryCount = retryCount
        self.nextRetryAt = nextRetryAt
        self.progress = progress
        self.errorClass = errorClass
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectID, type, state, trigger, createdAt, startedAt, finishedAt
        case attempt, errorMessage, checkpoint, repositoryID, lease
        case retryCount, nextRetryAt, progress, errorClass
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        projectID = try c.decode(UUID.self, forKey: .projectID)
        type = try c.decode(BackupJobType.self, forKey: .type)
        state = try c.decodeIfPresent(BackupJobState.self, forKey: .state) ?? .queued
        trigger = try c.decodeIfPresent(BackupTrigger.self, forKey: .trigger) ?? .scheduled
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        attempt = try c.decodeIfPresent(Int.self, forKey: .attempt) ?? 1
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        checkpoint = try c.decodeIfPresent(Data.self, forKey: .checkpoint)
        repositoryID = try c.decodeIfPresent(UUID.self, forKey: .repositoryID)
        lease = try c.decodeIfPresent(JobLease.self, forKey: .lease)
        retryCount = try c.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        nextRetryAt = try c.decodeIfPresent(Date.self, forKey: .nextRetryAt)
        progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        errorClass = try c.decodeIfPresent(RetryErrorClass.self, forKey: .errorClass)
    }
}
