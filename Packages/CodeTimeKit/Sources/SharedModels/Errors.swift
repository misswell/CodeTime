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
    /// iCloud was enabled but the build/account/drive/container is not usable.
    case cloudSetupUnavailable(state: String, detail: String)
    case cloudPublishIncomplete(String)
    case integrityFailure(String)
    case recoveryKeyUnavailable
    case unauthorized(String)
    case cancelled
    case unsupported(String)
    /// A concurrent backup already owns this project (scheduler or another
    /// process). Informational, not a failure.
    case backupAlreadyRunning

    // MARK: - Repository lifecycle

    case repositoryMissing(String)
    case repositoryCorrupted(String)
    case repositoryIdentityMismatch(expected: String, actual: String)
    case repositoryBusy(String)
    case repositoryStateForbidden(state: String, operation: String)

    // MARK: - Cloud integrity

    case manifestUnreadable(generation: String, reason: String)
    case manifestNotDownloaded(String)
    case manifestCorrupted(String)
    case manifestVersionUnsupported(Int)
    case objectHashMismatch(hash: String, expected: String, actual: String)
    case objectMissing(String)
    case objectQuarantined(hash: String, reason: String)
    case cloudUploadFailed(String)
    case cloudStateUnknown(String)
    case cloudContainerMismatch(path: String, container: String)
    case generationNotFound(String)
    case emptyManifest(String)

    // MARK: - Garbage collection

    case gcUnsafe(reason: String)
    case gcJournalCorrupted(String)

    // MARK: - Restore

    case restoreInterrupted(String)
    case restoreVerificationFailed(String)
    case restoreSourceUnavailable(String)
    case restoreKeyMismatch
    case noRecoveryCandidate

    // MARK: - Security scope and migration

    case securityScopeUnavailable(String)
    case bookmarkFailed(String)
    case migrationFailed(String)
    case migrationConflict(String)
    case insufficientDiskSpace(required: Int64, available: Int64)

    // MARK: - Execution and scheduling

    case processExecutionFailed(String)
    case outputTruncated(limit: Int)
    case schedulerLeaseExpired(String)
    case leaseConflict(owner: String)
    case projectDeleted(String)
    case pathOverlap(path: String, conflictsWith: String)
    case retryExhausted(attempts: Int, lastError: String)
    case searchTruncated(reason: String)
    case diffUnavailable(String)
    case verificationUnavailable(String)

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
        case .cloudSetupUnavailable(_, let detail):
            return detail
        case .backupAlreadyRunning:
            return "已有备份正在进行，完成后再试"
        case .unsupported(let detail):
            return "当前环境不支持：\(detail)"

        case .repositoryMissing(let detail):
            return "备份仓库已丢失：\(detail)"
        case .repositoryCorrupted(let detail):
            return "备份仓库已损坏：\(detail)"
        case .repositoryIdentityMismatch(let expected, let actual):
            return "备份仓库身份不符（期望 \(expected)，实际 \(actual)）"
        case .repositoryBusy(let detail):
            return "备份仓库正被其他任务占用：\(detail)"
        case .repositoryStateForbidden(let state, let operation):
            return "仓库处于 \(state) 状态，不允许执行 \(operation)"

        case .manifestUnreadable(let generation, let reason):
            return "版本清单 \(generation) 无法读取：\(reason)"
        case .manifestNotDownloaded(let generation):
            return "版本清单 \(generation) 尚未从 iCloud 下载"
        case .manifestCorrupted(let detail):
            return "版本清单已损坏：\(detail)"
        case .manifestVersionUnsupported(let version):
            return "版本清单格式 \(version) 不受当前应用支持"
        case .objectHashMismatch(let hash, let expected, let actual):
            return "对象 \(hash) 校验失败（期望 \(expected)，实际 \(actual)）"
        case .objectMissing(let hash):
            return "云端缺少对象 \(hash)"
        case .objectQuarantined(let hash, let reason):
            return "对象 \(hash) 已隔离：\(reason)"
        case .cloudUploadFailed(let detail):
            return "云端上传失败：\(detail)"
        case .cloudStateUnknown(let detail):
            return "无法确认云端文件状态：\(detail)"
        case .cloudContainerMismatch(let path, let container):
            return "文件 \(path) 不属于 iCloud 容器 \(container)"
        case .generationNotFound(let id):
            return "找不到云端版本 \(id)"
        case .emptyManifest(let id):
            return "版本清单 \(id) 不包含任何仓库文件"

        case .gcUnsafe(let reason):
            return "已停止云端清理：\(reason)"
        case .gcJournalCorrupted(let detail):
            return "清理日志损坏：\(detail)"

        case .restoreInterrupted(let detail):
            return "恢复任务中断：\(detail)"
        case .restoreVerificationFailed(let detail):
            return "恢复后验证失败：\(detail)"
        case .restoreSourceUnavailable(let detail):
            return "恢复源不可用：\(detail)"
        case .restoreKeyMismatch:
            return "恢复密钥与该仓库不匹配"
        case .noRecoveryCandidate:
            return "未找到可用此恢复密钥解密的仓库"

        case .securityScopeUnavailable(let detail):
            return "无法取得目录安全访问权限：\(detail)"
        case .bookmarkFailed(let detail):
            return "无法创建安全书签：\(detail)"
        case .migrationFailed(let detail):
            return "数据迁移失败：\(detail)"
        case .migrationConflict(let detail):
            return "迁移目标已存在有效数据：\(detail)"
        case .insufficientDiskSpace(let required, let available):
            return "磁盘空间不足（需要 \(required) 字节，可用 \(available) 字节）"

        case .processExecutionFailed(let detail):
            return "子进程执行失败：\(detail)"
        case .outputTruncated(let limit):
            return "命令输出超过 \(limit) 字节上限，结果不完整"
        case .schedulerLeaseExpired(let detail):
            return "任务租约已过期：\(detail)"
        case .leaseConflict(let owner):
            return "任务已被进程 \(owner) 持有"
        case .projectDeleted(let id):
            return "项目 \(id) 已被删除"
        case .pathOverlap(let path, let other):
            return "目录 \(path) 与 \(other) 重叠，会造成递归备份"
        case .retryExhausted(let attempts, let lastError):
            return "已重试 \(attempts) 次仍失败：\(lastError)"
        case .searchTruncated(let reason):
            return "搜索结果不完整：\(reason)"
        case .diffUnavailable(let detail):
            return "无法读取差异：\(detail)"
        case .verificationUnavailable(let detail):
            return "无法完成完整性校验：\(detail)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .kopiaNotFound:
            return "请确认应用包内包含 Resources/Kopia/kopia，或设置 KOPIA_PATH。"
        case .cloudNotConfigured:
            return "在设置中启用 iCloud 或选择本地镜像目录。"
        case .unauthorized, .securityScopeUnavailable, .bookmarkFailed:
            return "重新选择目录以刷新安全书签。"
        case .repositoryMissing:
            return "不要重新初始化。请从云端恢复仓库，或确认磁盘挂载后重试。"
        case .repositoryCorrupted:
            return "仓库不会被自动覆盖。请从云端恢复或联系支持。"
        case .manifestNotDownloaded:
            return "等待 iCloud 下载完成后重试；清理已暂停以避免误删。"
        case .cloudStateUnknown, .cloudUploadFailed:
            return "检查网络与 iCloud 登录状态后重试。本次未发布任何云端版本。"
        case .objectHashMismatch, .objectQuarantined:
            return "该对象已被隔离，不会被覆盖。请重新发布版本。"
        case .gcUnsafe:
            return "清理已安全暂停，未删除任何数据。排除原因后会自动重试。"
        case .restoreInterrupted:
            return "恢复进度已保存，可直接继续；正式仓库未被修改。"
        case .restoreKeyMismatch, .noRecoveryCandidate:
            return "确认使用的是创建该仓库时展示的恢复密钥。"
        case .migrationFailed, .migrationConflict:
            return "原有 Beta 数据未被删除，可重试迁移或暂不迁移。"
        case .insufficientDiskSpace:
            return "释放磁盘空间后重试。原有数据未被修改。"
        case .pathOverlap:
            return "请选择项目目录之外的位置，或排除 CodeTime 数据目录。"
        case .retryExhausted:
            return "这是永久性错误，自动重试已停止。请处理原因后手动重试。"
        default:
            return nil
        }
    }

    /// Permanent errors must not be retried automatically; retrying cannot change the outcome.
    public var isPermanent: Bool {
        switch self {
        case .repositoryMissing, .repositoryCorrupted, .repositoryIdentityMismatch,
             .repositoryStateForbidden, .manifestCorrupted, .manifestVersionUnsupported,
             .objectHashMismatch, .objectQuarantined, .emptyManifest,
             .restoreKeyMismatch, .noRecoveryCandidate, .restoreVerificationFailed,
             .securityScopeUnavailable, .bookmarkFailed, .unauthorized,
             .migrationConflict, .pathOverlap, .pathOutsideProject,
             .kopiaNotFound, .unsupported, .cancelled, .projectDeleted, .backupAlreadyRunning,
             .gcJournalCorrupted, .destinationExists, .cloudSetupUnavailable:
            return true
        default:
            return false
        }
    }
}
/// Stable, user-visible error classification. Raw localized strings are for
/// humans; these codes are for logs, support and retry decisions.
public enum CodeTimeDiagnosticCode: String, Codable, Sendable, CaseIterable {
    case scanFailed = "scan_failed"
    case fileChangedDuringBackup = "file_changed_during_backup"
    case fileTypeUnsupported = "file_type_unsupported"
    case backupCancelled = "backup_cancelled"
    case uploadFailed = "upload_failed"
    case uploadRetryExhausted = "upload_retry_exhausted"
    case spoolFull = "spool_full"
    case iCloudUnavailable = "icloud_unavailable"
    case iCloudUploadIncomplete = "icloud_upload_incomplete"
    case iCloudDownloadFailed = "icloud_download_failed"
    case remoteObjectMissing = "remote_object_missing"
    case remoteObjectCorrupted = "remote_object_corrupted"
    case manifestInvalid = "manifest_invalid"
    case commitMissing = "commit_missing"
    case snapshotFormatUnsupported = "snapshot_format_unsupported"
    case restoreFailed = "restore_failed"
    case restoreCancelled = "restore_cancelled"
    case restoreIntegrityFailed = "restore_integrity_failed"
    case gcAborted = "gc_aborted"
    case gcReferenceIncomplete = "gc_reference_incomplete"
    case gcLockUnavailable = "gc_lock_unavailable"
    case migrationFailed = "migration_failed"
    case storageFull = "storage_full"
    case databaseCorrupted = "database_corrupted"
    case backupEngineMissing = "backup_engine_missing"
    case storageUnavailable = "storage_unavailable"
    case backupFailed = "backup_failed"
    case operationCancelled = "operation_cancelled"
    case verificationFailed = "verification_failed"
}

public extension CodeTimeError {
    var diagnosticCode: CodeTimeDiagnosticCode {
        switch self {
        case .kopiaNotFound:
            return .backupEngineMissing
        case .repositoryUnavailable, .repositoryBusy, .repositoryStateForbidden,
             .repositoryIdentityMismatch, .unauthorized, .securityScopeUnavailable,
             .bookmarkFailed:
            return .storageUnavailable
        case .repositoryMissing:
            return .storageUnavailable
        case .repositoryCorrupted, .gcJournalCorrupted:
            return .databaseCorrupted
        case .commandFailed, .invalidOutput, .processExecutionFailed, .outputTruncated,
             .retryExhausted, .schedulerLeaseExpired, .leaseConflict:
            return .backupFailed
        case .snapshotNotFound:
            return .commitMissing
        case .pathOutsideProject, .destinationExists, .fileTooLarge:
            return .restoreFailed
        case .cloudNotConfigured, .cloudSetupUnavailable, .cloudStateUnknown,
             .cloudContainerMismatch:
            return .iCloudUnavailable
        case .cloudPublishIncomplete, .cloudUploadFailed:
            return .iCloudUploadIncomplete
        case .integrityFailure, .objectHashMismatch, .objectQuarantined, .emptyManifest:
            return .remoteObjectCorrupted
        case .manifestUnreadable, .manifestNotDownloaded:
            return .iCloudDownloadFailed
        case .manifestCorrupted:
            return .manifestInvalid
        case .manifestVersionUnsupported:
            return .snapshotFormatUnsupported
        case .objectMissing, .generationNotFound:
            return .remoteObjectMissing
        case .recoveryKeyUnavailable:
            return .restoreFailed
        case .cancelled, .projectDeleted, .backupAlreadyRunning:
            return .operationCancelled
        case .unsupported:
            return .snapshotFormatUnsupported
        case .gcUnsafe:
            return .gcAborted
        case .restoreInterrupted:
            return .restoreCancelled
        case .restoreVerificationFailed:
            return .restoreIntegrityFailed
        case .restoreSourceUnavailable, .restoreKeyMismatch, .noRecoveryCandidate:
            return .restoreFailed
        case .migrationFailed, .migrationConflict:
            return .migrationFailed
        case .insufficientDiskSpace:
            return .storageFull
        case .pathOverlap:
            return .scanFailed
        case .searchTruncated, .diffUnavailable, .verificationUnavailable:
            return .verificationFailed
        }
    }

    /// Whether an automatic retry could plausibly succeed. Cancellation is never
    /// retried; a local permanent conflict is not either.
    var isRetryable: Bool {
        switch self {
        case .cancelled, .backupAlreadyRunning, .projectDeleted:
            return false
        default:
            return !isPermanent
        }
    }
}
