import Foundation

public struct Project: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var rootPath: String
    /// Security-scoped bookmark for sandboxed access. The raw path is display-only.
    public var bookmark: Data?
    public var enabled: Bool
    public var groupName: String?
    public var createdAt: Date
    public var lastBackupAt: Date?
    public var lastSnapshotID: String?
    public var lastError: String?
    public var status: ProjectStatus

    public init(
        id: UUID = UUID(),
        name: String,
        rootPath: String,
        bookmark: Data? = nil,
        enabled: Bool = true,
        groupName: String? = nil,
        createdAt: Date = Date(),
        lastBackupAt: Date? = nil,
        lastSnapshotID: String? = nil,
        lastError: String? = nil,
        status: ProjectStatus = .idle
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.bookmark = bookmark
        self.enabled = enabled
        self.groupName = groupName
        self.createdAt = createdAt
        self.lastBackupAt = lastBackupAt
        self.lastSnapshotID = lastSnapshotID
        self.lastError = lastError
        self.status = status
    }
}

public enum ProjectStatus: String, Codable, Sendable, CaseIterable {
    case idle
    case backingUp
    case uploading
    case synced
    case warning
    case paused
    case error

    public var displayName: String {
        switch self {
        case .idle: return "等待备份"
        case .backingUp: return "正在备份"
        case .uploading: return "正在上传"
        case .synced: return "已同步"
        case .warning: return "需要关注"
        case .paused: return "已暂停"
        case .error: return "备份失败"
        }
    }
}

public struct DeviceIdentity: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var model: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, model: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.model = model
        self.createdAt = createdAt
    }
}

public struct RepositoryRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var path: String
    public var configPath: String
    public var createdAt: Date
    public var formatVersion: Int

    public init(id: UUID = UUID(), path: String, configPath: String, createdAt: Date = Date(), formatVersion: Int = 1) {
        self.id = id
        self.path = path
        self.configPath = configPath
        self.createdAt = createdAt
        self.formatVersion = formatVersion
    }
}
