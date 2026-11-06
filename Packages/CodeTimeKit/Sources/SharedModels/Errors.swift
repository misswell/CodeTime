import Foundation

public enum CodeTimeError: LocalizedError, Sendable, Equatable {
    case kopiaNotFound
    case repositoryUnavailable(String)
    case commandFailed(command: String, status: Int32, message: String)
    case invalidOutput(String)
    case snapshotNotFound(String)
    case fileTooLarge(Int64, limit: Int)
    case pathOutsideProject(String)
    case destinationExists(String)
    case cloudNotConfigured
    case cloudPublishIncomplete(String)
    case integrityFailure(String)
    case recoveryKeyUnavailable
    case unauthorized(String)
    case cancelled
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .kopiaNotFound:
            return "未找到 Kopia 备份引擎"
        case .repositoryUnavailable(let detail):
            return "备份仓库不可用：\(detail)"
        case .commandFailed(let command, let status, let message):
            return "命令 \(command) 失败（退出码 \(status)）：\(message)"
        case .invalidOutput(let detail):
            return "无法解析备份引擎输出：\(detail)"
        case .snapshotNotFound(let id):
            return "找不到快照 \(id)"
        case .fileTooLarge(let size, let limit):
            return "文件过大（\(size) 字节），预览上限为 \(limit) 字节"
        case .pathOutsideProject(let path):
            return "路径超出项目范围：\(path)"
        case .destinationExists(let path):
            return "目标已存在：\(path)"
        case .cloudNotConfigured:
            return "云端镜像尚未配置"
        case .cloudPublishIncomplete(let detail):
            return "云端版本未完整发布：\(detail)"
        case .integrityFailure(let detail):
            return "完整性校验失败：\(detail)"
        case .recoveryKeyUnavailable:
            return "无法读取恢复密钥"
        case .unauthorized(let detail):
            return "文件访问授权失效：\(detail)"
        case .cancelled:
            return "任务已取消"
        case .unsupported(let detail):
            return "当前环境不支持：\(detail)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .kopiaNotFound:
            return "请确认应用包内包含 Resources/Kopia/kopia，或设置 KOPIA_PATH。"
        case .cloudNotConfigured:
            return "在设置中启用 iCloud 或选择本地镜像目录。"
        case .unauthorized:
            return "重新选择项目目录以刷新安全书签。"
        default:
            return nil
        }
    }
}
