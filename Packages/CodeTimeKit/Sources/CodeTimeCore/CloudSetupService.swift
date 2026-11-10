import Foundation
import Security
import SharedModels

/// CT-129: one place that answers "can this build actually back up to iCloud, and
/// why not?". The UI never guesses from a toggle: every state has an actionable
/// message, and a build without iCloud entitlements (Beta/Debug) reports
/// `unsupportedBuild` instead of pretending iCloud is merely "not configured".
public struct CloudSetupStatus: Sendable, Equatable {
    public enum State: String, Sendable, Codable {
        /// Probe in progress (UI only; `detect()` never returns it).
        case checking
        /// This binary has no iCloud entitlement (beta / ad-hoc / debug builds).
        case unsupportedBuild
        /// No Apple Account signed in.
        case accountNotSignedIn
        /// Signed in, but iCloud Drive is off.
        case driveDisabled
        /// iCloud Drive is on, but CodeTime's container is unavailable.
        case containerUnavailable
        /// Container exists but the backup directory is not writable.
        case notWritable
        /// Everything works; `storageRoot` is ready to receive objects.
        case ready

        public var isReady: Bool { self == .ready }
        public var isChecking: Bool { self == .checking }

        /// Stable code for logs and support ("ICLOUD_…"), so a failure is
        /// diagnosable without translating user-facing Chinese text.
        public var diagnosticCode: String {
            switch self {
            case .checking: return "ICLOUD_CHECKING"
            case .unsupportedBuild: return "ICLOUD_UNSUPPORTED_BUILD"
            case .accountNotSignedIn: return "ICLOUD_ACCOUNT_UNAVAILABLE"
            case .driveDisabled: return "ICLOUD_DRIVE_DISABLED"
            case .containerUnavailable: return "ICLOUD_CONTAINER_UNAVAILABLE"
            case .notWritable: return "ICLOUD_PERMISSION_DENIED"
            case .ready: return "ICLOUD_READY"
            }
        }
    }

    public var state: State
    /// Short user-facing line ("iCloud 已就绪" / "请先登录 Apple 账户" …).
    public var title: String
    /// One-sentence explanation or remediation.
    public var detail: String
    /// `true` when the fix requires the user to change a system setting.
    public var requiresSystemSettings: Bool
    public var containerURL: URL?
    public var storageRoot: URL?

    public init(
        state: State,
        title: String,
        detail: String,
        requiresSystemSettings: Bool = false,
        containerURL: URL? = nil,
        storageRoot: URL? = nil
    ) {
        self.state = state
        self.title = title
        self.detail = detail
        self.requiresSystemSettings = requiresSystemSettings
        self.containerURL = containerURL
        self.storageRoot = storageRoot
    }

    public var isReady: Bool { state.isReady }
    public var isChecking: Bool { state.isChecking }
    public var diagnosticCode: String { state.diagnosticCode }

    public static let checking = CloudSetupStatus(
        state: .checking,
        title: "正在检测 iCloud",
        detail: "检查当前版本、账户、iCloud Drive 与备份目录…"
    )

    public static let unsupported = CloudSetupStatus(
        state: .unsupportedBuild,
        title: "当前版本不支持 iCloud 备份",
        detail: "这个构建没有 iCloud 权限（Beta/本地构建仅支持本机备份）。正式签名版本可用。"
    )
}

/// Injectable environment so every branch is testable without a real iCloud
/// account (CT-129). Production uses `CloudSetupService.liveProbe`.
public struct CloudEnvironmentProbe: Sendable {
    /// Does THIS binary carry the iCloud entitlement?
    public var buildSupportsICloud: @Sendable () -> Bool
    /// Is an Apple Account signed in (ubiquity identity token present)?
    public var hasUbiquityIdentity: @Sendable () -> Bool
    /// The container URL for CodeTime's identifier, if available.
    public var containerURL: @Sendable (String) -> URL?
    /// The default (nil-identifier) container URL — distinguishes "Drive off"
    /// from "CodeTime container missing".
    public var defaultContainerURL: @Sendable () -> URL?

    public init(
        buildSupportsICloud: @escaping @Sendable () -> Bool,
        hasUbiquityIdentity: @escaping @Sendable () -> Bool,
        containerURL: @escaping @Sendable (String) -> URL?,
        defaultContainerURL: @escaping @Sendable () -> URL?
    ) {
        self.buildSupportsICloud = buildSupportsICloud
        self.hasUbiquityIdentity = hasUbiquityIdentity
        self.containerURL = containerURL
        self.defaultContainerURL = defaultContainerURL
    }

    public static let live = CloudEnvironmentProbe(
        buildSupportsICloud: { CloudSetupService.processHasICloudEntitlement() },
        hasUbiquityIdentity: { FileManager.default.ubiquityIdentityToken != nil },
        containerURL: { identifier in
            FileManager.default.url(forUbiquityContainerIdentifier: identifier)
        },
        defaultContainerURL: { FileManager.default.url(forUbiquityContainerIdentifier: nil) }
    )
}

public enum CloudSetupService {
    public static let containerIdentifier = "iCloud.com.codetime.app"
    /// Folder inside the container that holds the mirror (Documents/CodeTime).
    public static let storageFolderName = "CodeTime"

    /// Reads the CURRENT process's iCloud entitlement. Beta/Debug builds return
    /// false, which is exactly why their iCloud toggle must be disabled.
    public static func processHasICloudEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let key = "com.apple.developer.icloud-container-identifiers" as CFString
        guard let value = SecTaskCopyValueForEntitlement(task, key, nil) else { return false }
        if let identifiers = value as? [String] {
            return identifiers.contains(containerIdentifier)
        }
        return false
    }

    /// Full detection. Never throws: every failure is a state with a reason.
    /// `probe` and `fileManager` are injectable for tests.
    public static func detect(
        probe: CloudEnvironmentProbe = .live,
        fileManager: FileManager = .default,
        provision: Bool = true
    ) async -> CloudSetupStatus {
        await Task.detached(priority: .userInitiated) { () -> CloudSetupStatus in
            guard probe.buildSupportsICloud() else { return .unsupported }
            guard probe.hasUbiquityIdentity() else {
                return CloudSetupStatus(
                    state: .accountNotSignedIn,
                    title: "请先登录 Apple 账户",
                    detail: "iCloud 备份需要一个已登录的 Apple 账户。登录后回到这里点「重新检测」。",
                    requiresSystemSettings: true
                )
            }
            guard let container = probe.containerURL(containerIdentifier) else {
                // Distinguish "iCloud Drive is off" from "our container is missing".
                if probe.defaultContainerURL() == nil {
                    return CloudSetupStatus(
                        state: .driveDisabled,
                        title: "请开启 iCloud Drive",
                        detail: "系统设置 → Apple 账户 → iCloud → iCloud Drive 打开后重试。",
                        requiresSystemSettings: true
                    )
                }
                return CloudSetupStatus(
                    state: .containerUnavailable,
                    title: "iCloud 服务暂时不可用",
                    detail: "已登录且 iCloud Drive 正常，但 CodeTime 的 iCloud 容器无法访问。请稍后重试，或检查是否限制了该 App 的 iCloud 权限。"
                )
            }
            let documents = container.appendingPathComponent("Documents", isDirectory: true)
            let storageRoot = documents.appendingPathComponent(storageFolderName, isDirectory: true)
            guard provision else {
                return CloudSetupStatus(
                    state: .ready,
                    title: "iCloud 已就绪",
                    detail: "备份会保存到 iCloud Drive / CodeTime。",
                    containerURL: container,
                    storageRoot: storageRoot
                )
            }
            // Create + write-probe: a container that cannot be written is not
            // "ready", and enabling it would fail later during the first upload.
            do {
                try fileManager.createDirectory(at: storageRoot, withIntermediateDirectories: true)
                let probeURL = storageRoot.appendingPathComponent(
                    ".codetime-setup-\(UUID().uuidString.prefix(8)).txt"
                )
                let payload = Data("codetime-icloud-probe".utf8)
                try payload.write(to: probeURL, options: .atomic)
                let readBack = try Data(contentsOf: probeURL)
                try? fileManager.removeItem(at: probeURL)
                guard readBack == payload else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            } catch {
                return CloudSetupStatus(
                    state: .notWritable,
                    title: "iCloud 备份目录不可写",
                    detail: "无法在 iCloud Drive/CodeTime 创建文件：\(error.localizedDescription)。请检查磁盘空间或 iCloud 权限后重试。",
                    containerURL: container,
                    storageRoot: storageRoot
                )
            }
            return CloudSetupStatus(
                state: .ready,
                title: "iCloud 已就绪",
                detail: "备份会保存到 iCloud Drive / CodeTime，并自动同步与校验。",
                containerURL: container,
                storageRoot: storageRoot
            )
        }.value
    }
}
