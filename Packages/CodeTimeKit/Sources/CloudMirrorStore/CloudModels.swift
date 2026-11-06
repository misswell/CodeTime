import Foundation
import SharedModels

struct CloudFormatFile: Codable {
    var format: String
    var version: Int
    var createdAt: Date
}

struct ManifestFile: Codable, Hashable {
    var relativePath: String
    var contentHash: String
    var size: Int64
}

struct ManifestIntegrity: Codable, Hashable {
    var fileCount: Int
    var totalBytes: Int64
    var repositoryHash: String
}

struct CloudManifest: Codable, Hashable {
    var formatVersion: Int
    var repositoryId: UUID
    var generationId: UUID
    var deviceId: UUID
    var createdAt: Date
    var sourceSnapshotIds: [String]
    var repositoryFiles: [ManifestFile]
    var integrity: ManifestIntegrity
}

struct RecoveryPayload: Codable {
    var repositoryId: UUID
    var repositoryPassword: String
    var formatVersion: Int
    var createdAt: Date
}

struct RecoveryInfoFile: Codable {
    var formatVersion: Int
    var repositoryId: UUID
    var deviceId: UUID
    var createdAt: Date
    var payload: Data
}

public struct RecoveredAccess: Sendable {
    public var repositoryID: UUID
    public var deviceID: UUID
    public var repositoryPassword: String
    public var createdAt: Date

    public init(repositoryID: UUID, deviceID: UUID, repositoryPassword: String, createdAt: Date) {
        self.repositoryID = repositoryID
        self.deviceID = deviceID
        self.repositoryPassword = repositoryPassword
        self.createdAt = createdAt
    }
}

public enum CloudStoreError: LocalizedError, Sendable {
    case invalidFormat(String)
    case manifestUnavailable(String)
    case manifestCorrupt(String)
    case objectMissing(String)
    case objectCorrupt(String)
    case uploadIncomplete(String)
    case unsafePath(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormat(let detail): return "云端格式无效：\(detail)"
        case .manifestUnavailable(let detail): return "版本清单不可用：\(detail)"
        case .manifestCorrupt(let detail): return "版本清单损坏：\(detail)"
        case .objectMissing(let hash): return "云端对象缺失：\(hash)"
        case .objectCorrupt(let hash): return "云端对象校验失败：\(hash)"
        case .uploadIncomplete(let detail): return "上传未完成：\(detail)"
        case .unsafePath(let path): return "云端记录包含不安全路径：\(path)"
        case .notFound(let detail): return "云端版本不存在：\(detail)"
        }
    }
}
