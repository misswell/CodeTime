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
    public var accessState: SecurityAccessState
    public var lifecycle: ProjectLifecycle
    /// Bumped on every user edit so field-level updates can detect a stale writer.
    public var configRevision: Int
    public var notes: String?

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
        status: ProjectStatus = .idle,
        accessState: SecurityAccessState = .unknown,
        lifecycle: ProjectLifecycle = .active,
        configRevision: Int = 0,
        notes: String? = nil
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
        self.accessState = accessState
        self.lifecycle = lifecycle
        self.configRevision = configRevision
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, rootPath, bookmark, enabled, groupName, createdAt
        case lastBackupAt, lastSnapshotID, lastError, status
        case accessState, lifecycle, configRevision, notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        rootPath = try c.decode(String.self, forKey: .rootPath)
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        groupName = try c.decodeIfPresent(String.self, forKey: .groupName)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastBackupAt = try c.decodeIfPresent(Date.self, forKey: .lastBackupAt)
        lastSnapshotID = try c.decodeIfPresent(String.self, forKey: .lastSnapshotID)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        status = try c.decodeIfPresent(ProjectStatus.self, forKey: .status) ?? .idle
        accessState = try c.decodeIfPresent(SecurityAccessState.self, forKey: .accessState)
            ?? (bookmark == nil ? .notRequired : .unknown)
        lifecycle = try c.decodeIfPresent(ProjectLifecycle.self, forKey: .lifecycle) ?? .active
        configRevision = try c.decodeIfPresent(Int.self, forKey: .configRevision) ?? 0
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }

    /// True when the user has disabled the project or it is being deleted.
    public var isSchedulable: Bool { enabled && lifecycle == .active }
}

public enum ProjectStatus: String, Codable, Sendable, CaseIterable {
    case idle
    case backingUp
    case publishing
    case verifying
    case synced
    case localOnly
    case warning
    case failed
    case missing
    case disabled

    public var displayName: String {
        switch self {
        case .idle: return "等待备份"
        case .backingUp: return "正在备份"
        case .publishing: return "正在上传"
        case .verifying: return "正在校验"
        case .synced: return "云端已同步"
        case .localOnly: return "仅本地备份"
        case .warning: return "需要关注"
        case .failed: return "备份失败"
        case .missing: return "目录不可访问"
        case .disabled: return "已暂停"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Legacy raw values from v1.0.0-beta.1 databases.
        switch raw {
        case "uploading": self = .publishing
        case "paused": self = .disabled
        case "error": self = .failed
        default:
            guard let value = ProjectStatus(rawValue: raw) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "未知项目状态：\(raw)"
                ))
            }
            self = value
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Local backup success and cloud sync success are independent facts.
    public var indicatesCloudSync: Bool { self == .synced }
    public var indicatesLocalBackup: Bool {
        switch self {
        case .synced, .localOnly, .publishing, .verifying: return true
        default: return false
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
    public var metadata: RepositoryMetadata?

    public init(
        id: UUID = UUID(),
        path: String,
        configPath: String,
        createdAt: Date = Date(),
        formatVersion: Int = 1,
        metadata: RepositoryMetadata? = nil
    ) {
        self.id = id
        self.path = path
        self.configPath = configPath
        self.createdAt = createdAt
        self.formatVersion = formatVersion
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, configPath, createdAt, formatVersion, metadata
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        configPath = try c.decode(String.self, forKey: .configPath)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        metadata = try c.decodeIfPresent(RepositoryMetadata.self, forKey: .metadata)
    }

    /// A repository with no recorded state is treated as ready only if it predates the
    /// state machine; the service re-derives the real state on bootstrap.
    public var effectiveState: RepositoryState { metadata?.state ?? .ready }
}