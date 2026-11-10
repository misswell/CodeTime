import Foundation

/// CT-132: the explicit cloud backup state machine. The local snapshot state and
/// the cloud state are separate on purpose: "snapshot created" never implies
/// "uploaded", and "uploaded" never implies "verified".
public enum CloudBackupState: String, Codable, Sendable, CaseIterable {
    /// No cloud destination configured (local-only install).
    case notConfigured
    /// Environment probe in progress.
    case checking
    /// Container available, nothing pending.
    case ready
    /// Waiting for iCloud/network to come back.
    case waitingForNetwork
    /// Objects are being written/uploaded.
    case uploading
    /// Objects confirmed; the encrypted manifest is being published.
    case publishing
    /// Manifest published and confirmed — this is the first state that may be
    /// shown as "已上传到 iCloud".
    case uploaded
    /// Cloud integrity verification in progress.
    case verifying
    /// Verification passed.
    case verified
    /// A failure occurred and a retry is scheduled.
    case retrying
    /// Automatic recovery is exhausted.
    case failed
    /// Needs the user (account, permission, credential, storage config).
    case requiresUserAction

    public var isCloudConfirmed: Bool {
        self == .uploaded || self == .verifying || self == .verified
    }

    public var displayName: String {
        switch self {
        case .notConfigured: return "仅本机备份"
        case .checking: return "正在检测 iCloud"
        case .ready: return "iCloud 已就绪"
        case .waitingForNetwork: return "等待 iCloud 恢复"
        case .uploading: return "正在上传到 iCloud"
        case .publishing: return "正在发布云端版本"
        case .uploaded: return "已上传到 iCloud"
        case .verifying: return "正在校验云端备份"
        case .verified: return "云端备份验证通过"
        case .retrying: return "云端同步等待重试"
        case .failed: return "云端同步失败"
        case .requiresUserAction: return "需要处理 iCloud 配置"
        }
    }

    /// Legal transitions. Illegal jumps (e.g. `uploading → verified`) are a bug:
    /// the manifest must be published and confirmed before verification can pass.
    public static func allows(from: CloudBackupState, to: CloudBackupState) -> Bool {
        if from == to { return true }
        switch from {
        case .notConfigured:
            return [.checking, .requiresUserAction, .ready].contains(to)
        case .checking:
            return [.ready, .notConfigured, .requiresUserAction, .waitingForNetwork].contains(to)
        case .ready:
            return [.uploading, .checking, .waitingForNetwork, .notConfigured, .requiresUserAction, .verifying].contains(to)
        case .waitingForNetwork:
            return [.checking, .uploading, .retrying, .requiresUserAction, .ready].contains(to)
        case .uploading:
            return [.publishing, .retrying, .failed, .waitingForNetwork, .requiresUserAction].contains(to)
        case .publishing:
            return [.uploaded, .retrying, .failed, .requiresUserAction].contains(to)
        case .uploaded:
            return [.verifying, .uploading, .verifying, .ready].contains(to)
        case .verifying:
            return [.verified, .retrying, .failed, .uploaded].contains(to)
        case .verified:
            return [.verifying, .uploading, .ready].contains(to)
        case .retrying:
            return [.uploading, .failed, .waitingForNetwork, .requiresUserAction, .ready].contains(to)
        case .failed:
            return [.retrying, .uploading, .requiresUserAction, .ready].contains(to)
        case .requiresUserAction:
            return [.checking, .ready, .notConfigured].contains(to)
        }
    }
}

/// CT-130: the single storage-target model. Derived from AppSettings so existing
/// databases keep working, with an explicit migration rule set.
public enum BackupDestination: Sendable, Equatable {
    case localOnly
    case iCloud
    case customLocal(path: String)

    /// Migration rules (goal §5). Existing fields are never cleared:
    /// 1. `iCloudEnabled` → iCloud
    /// 2. otherwise a configured mirror path → customLocal
    /// 3. otherwise → localOnly
    /// A mirror path whose bookmark became stale is still returned (the caller
    /// surfaces "needs attention" instead of silently dropping the config).
    public static func derived(
        iCloudEnabled: Bool,
        localMirrorPath: String?,
        localMirrorAccessState: SecurityAccessState
    ) -> BackupDestination {
        if iCloudEnabled { return .iCloud }
        if let path = localMirrorPath, !path.isEmpty { return .customLocal(path: path) }
        return .localOnly
    }

    public var requiresUserAttention: Bool { false }

    public var displayName: String {
        switch self {
        case .localOnly: return "仅本机备份"
        case .iCloud: return "iCloud 云端备份"
        case .customLocal: return "自定义本地镜像"
        }
    }
}
