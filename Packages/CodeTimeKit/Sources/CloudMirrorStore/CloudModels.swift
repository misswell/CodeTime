import Foundation
import SharedModels
import CodeTimeSecurity

struct CloudFormatFile: Codable {
    var format: String
    var version: Int
    var objectAlgorithm: String
    var createdAt: Date
}

struct ManifestFile: Codable, Hashable {
    var relativePath: String
    var contentHash: String
    var size: Int64
    /// Stable file identity at scan time; used to detect a file changing between
    /// the scan and the upload.
    var fileIdentity: String?
}

/// CT-115/P1: `JSONEncoder` does not guarantee a stable key order between calls,
/// so the manifest's `repositoryHash` MUST be computed from a canonical encoding.
/// Sorting keys makes the hash reproducible across processes and Foundation
/// versions; without it, publish and validate could disagree on an unchanged
/// manifest and report false corruption.
enum ManifestIntegrityHasher {
    static func hash(files: [ManifestFile]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Hashing.sha256Hex(try encoder.encode(files))
    }
}

struct ManifestIntegrity: Codable, Hashable {
    var fileCount: Int
    var uniqueObjectCount: Int
    var totalBytes: Int64
    var repositoryHash: String
}

struct CloudManifest: Codable, Hashable {
    var formatVersion: Int
    var repositoryId: UUID
    var generationId: UUID
    var deviceId: UUID
    var deviceName: String?
    var createdAt: Date
    var sourceSnapshotIds: [String]
    var repositoryFiles: [ManifestFile]
    var integrity: ManifestIntegrity
    var objectAlgorithm: String

    var uniqueObjectHashes: Set<String> { Set(repositoryFiles.map(\.contentHash)) }
}

struct RecoveryPayload: Codable {
    var repositoryId: UUID
    var repositoryPassword: String
    var formatVersion: Int
    var createdAt: Date
    /// Proof that the sealing key matches the recovery key handed to the user.
    var keyFingerprint: String
}

struct RecoveryInfoFile: Codable {
    var formatVersion: Int
    var repositoryId: UUID
    var deviceId: UUID
    var deviceName: String?
    var createdAt: Date
    var keyFingerprint: String
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

public enum CloudStoreError: LocalizedError, Sendable, Equatable {
    case invalidFormat(String)
    case unsupportedFormat(String)
    case manifestUnavailable(String)
    case manifestNotDownloaded(String)
    case manifestCorrupt(String)
    case manifestExists(String)
    case objectMissing(String)
    case objectCorrupt(String)
    case objectQuarantined(String)
    case uploadIncomplete(String)
    case uploadNotConfirmed(String)
    case notICloudItem(String)
    case cloudContainerMismatch(String)
    case metadataUnavailable(String)
    case notDownloaded(String)
    case coordinationFailed(String)
    case unsafePath(String)
    case notFound(String)
    case gcBlocked(String)
    case gcJournalCorrupted(String)
    case restoreInterrupted(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormat(let detail): return "云端格式无效：\(detail)"
        case .unsupportedFormat(let detail): return "云端格式版本不受支持：\(detail)"
        case .manifestUnavailable(let detail): return "版本清单不可用：\(detail)"
        case .manifestNotDownloaded(let detail): return "版本清单尚未下载：\(detail)"
        case .manifestCorrupt(let detail): return "版本清单损坏：\(detail)"
        case .manifestExists(let detail): return "版本清单已存在，拒绝覆盖：\(detail)"
        case .objectMissing(let hash): return "云端对象缺失：\(hash)"
        case .objectCorrupt(let hash): return "云端对象校验失败：\(hash)"
        case .objectQuarantined(let hash): return "云端对象内容不匹配，已隔离：\(hash)"
        case .uploadIncomplete(let detail): return "上传未完成：\(detail)"
        case .uploadNotConfirmed(let detail): return "iCloud 未确认上传：\(detail)"
        case .notICloudItem(let name): return "文件不在 iCloud 容器中，不能确认上传：\(name)"
        case .cloudContainerMismatch(let path): return "文件不属于目标 iCloud 容器：\(path)"
        case .metadataUnavailable(let detail): return "无法读取 iCloud 状态：\(detail)"
        case .notDownloaded(let detail): return "iCloud 文件不可读取：\(detail)"
        case .coordinationFailed(let detail): return "iCloud 文件协调失败：\(detail)"
        case .unsafePath(let path): return "云端记录包含不安全路径：\(path)"
        case .notFound(let detail): return "云端版本不存在：\(detail)"
        case .gcBlocked(let detail): return "垃圾回收已暂停：\(detail)"
        case .gcJournalCorrupted(let detail): return "垃圾回收日志损坏：\(detail)"
        case .restoreInterrupted(let detail): return "恢复任务中断：\(detail)"
        }
    }
}
