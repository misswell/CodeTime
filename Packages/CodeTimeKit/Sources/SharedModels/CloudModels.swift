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
}

public enum BackupJobState: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled

    public var isTerminal: Bool { self == .succeeded || self == .failed || self == .cancelled }
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
        checkpoint: Data? = nil
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
    }
}
