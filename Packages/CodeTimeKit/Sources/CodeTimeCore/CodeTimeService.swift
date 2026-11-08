import Foundation
import Darwin
import SharedModels
import Persistence
import CodeTimeSecurity
import BackupEngine
import CloudMirrorStore
import GitIntegration
import Diagnostics

public struct BootstrapReport: Sendable {
    public var recoveryKeyText: String?
    public var secretsWereCreated: Bool
    public var device: DeviceIdentity
    public var repository: RepositoryRecord
    public var kopiaVersion: String?
    public var recoveredInterruptedJobs: Int
    public var settings: AppSettings

    public init(
        recoveryKeyText: String?,
        secretsWereCreated: Bool,
        device: DeviceIdentity,
        repository: RepositoryRecord,
        kopiaVersion: String?,
        recoveredInterruptedJobs: Int,
        settings: AppSettings
    ) {
        self.recoveryKeyText = recoveryKeyText
        self.secretsWereCreated = secretsWereCreated
        self.device = device
        self.repository = repository
        self.kopiaVersion = kopiaVersion
        self.recoveredInterruptedJobs = recoveredInterruptedJobs
        self.settings = settings
    }
}

public struct BackupOutcome: Sendable {
    public var snapshot: Snapshot
    public var cloudError: String?

    public init(snapshot: Snapshot, cloudError: String? = nil) {
        self.snapshot = snapshot
        self.cloudError = cloudError
    }
}

public struct RestoreRequest: Sendable {
    public var projectID: UUID
    public var snapshotID: String
    public var relativePath: String?
    public var mode: RestoreMode
    public var destination: URL

    public init(projectID: UUID, snapshotID: String, relativePath: String?, mode: RestoreMode, destination: URL) {
        self.projectID = projectID
        self.snapshotID = snapshotID
        self.relativePath = relativePath
        self.mode = mode
        self.destination = destination
    }
}

public struct CloudRecoveryResult: Sendable {
    public var repositoryID: UUID
    public var generationID: UUID
    public var sourcePaths: [String]
    public var repositoryURL: URL
    public var restoreJobID: UUID?
    public var report: RestoreReport?

    public init(
        repositoryID: UUID,
        generationID: UUID,
        sourcePaths: [String],
        repositoryURL: URL,
        restoreJobID: UUID? = nil,
        report: RestoreReport? = nil
    ) {
        self.repositoryID = repositoryID
        self.generationID = generationID
        self.sourcePaths = sourcePaths
        self.repositoryURL = repositoryURL
        self.restoreJobID = restoreJobID
        self.report = report
    }
}

public struct DashboardState: Sendable {
    public var projects: [Project]
    public var snapshots: [Snapshot]
    public var snapshotCount: Int
    public var activity: [ActivityEvent]
    public var cloudSummary: CloudStorageSummary?
    public var settings: AppSettings
    public var lastBackupAt: Date?
    public var diagnostics: DiagnosticsReport
}

private struct StaticMasterKey: MasterKeyProviding {
    let key: Data
    func masterKey() throws -> Data { key }
}

private struct StaticPassword: RepositoryPasswordProviding {
    let password: String
    func repositoryPassword() throws -> String { password }
}

public enum CloudLocation {
    public static func iCloudDocuments() async -> URL? {
        await Task.detached(priority: .userInitiated) {
            FileManager.default
                .url(forUbiquityContainerIdentifier: nil)?
                .appendingPathComponent("Documents", isDirectory: true)
        }.value
    }

    public static func iCloudStorageRoot() async -> URL? {
        await iCloudDocuments()?.appendingPathComponent("CodeTime", isDirectory: true)
    }
}

public actor CodeTimeService {
    public nonisolated let paths: AppPaths
    public nonisolated let database: SQLiteStore
    public nonisolated let keychain: KeychainStore
    public nonisolated let logger: FileLogger
    public nonisolated let gitInspector: GitInspector

    private let kopiaBinaryURL: URL?
    private var device: DeviceIdentity?
    private var repository: RepositoryRecord?
    private var engineCache: KopiaBackupEngine?
    /// CT-124: injectable hardware-identity anchor (IOPlatformUUID in
    /// production) so tests can simulate a database moving between Macs.
    private let hardwareUUIDProvider: @Sendable () -> String?
    private var activeProjects: Set<UUID> = []
    private var backupGateClosed = false
    private var bootstrapReport: BootstrapReport?
    private var cachedSettings: AppSettings?
    private var repositoryStateCache: RepositoryState = .missing
    private var repositoryWasRegistered = false
    private var mirrorAccess: SecurityScopedAccess?

    enum Keys {
        static let device = "device.identity"
        static let repository = "repository.record"
        static let settings = "app.settings"
        static let lastVerification = "verification.lastRun"
        static let lastCleanup = "cleanup.lastRun"
        static let cloudRecoveryAttempted = "cloud.recovery.attempted"
    }

    public init(
        paths: AppPaths? = nil,
        keychain: KeychainStore = .shared,
        kopiaBinaryURL: URL? = nil,
        hardwareUUIDProvider: (@Sendable () -> String?)? = nil
    ) throws {
        let paths = try paths ?? AppPaths.standard()
        try paths.createDirectories()
        self.paths = paths
        self.database = try SQLiteStore(path: paths.database.path)
        self.keychain = keychain
        self.logger = FileLogger(fileURL: paths.logs.appendingPathComponent("codetime.log"))
        self.gitInspector = GitInspector()
        self.kopiaBinaryURL = kopiaBinaryURL ?? KopiaBinary.locate()
        self.hardwareUUIDProvider = hardwareUUIDProvider ?? { PlatformIdentity.currentHardwareUUID() }
    }

    // MARK: - Bootstrap

    @discardableResult
    public func bootstrap() async throws -> BootstrapReport {
        if let bootstrapReport { return bootstrapReport }

        var settings = try await currentSettings()
        let device = try await loadOrCreateDevice()
        let hadRepository = (try await database.codable(RepositoryRecord.self, forKey: Keys.repository)) != nil
        repositoryWasRegistered = hadRepository
        let repository = try await loadOrCreateRepository()
        self.device = device
        self.repository = repository
        // Never replace credentials when a repository already exists: an unreadable
        // Keychain item must send the user to recovery, not silently mint new keys.
        // Discovery of an existing repository also means secrets must not be
        // minted for it; only a genuinely first-run repository may create keys.
        let secrets = try keychain.ensureSecrets(allowCreation: !repositoryWasRegistered)
        if secrets.isNew {
            await logger.info("已创建新的应用密钥与恢复密钥")
        }

        let engine = try await currentEngine()
        // Only an uninitialized repository may be created. Missing, corrupted or
        // half-recovered repositories stay visible as an explicit state; starting the
        // app must not mint a fresh empty repository over unreadable data.
        let state = await engine.repositoryState()
        switch state {
        case .uninitialized:
            if hadRepository {
                // The database says a repository existed, but its directory is gone.
                // Creating a fresh empty one here would silently orphan the old data.
                await logger.error("已登记仓库目录缺失，拒绝自动创建空仓库；请从云端或备份恢复")
            } else {
                do {
                    try await engine.ensureRepository()
                } catch {
                    await logger.error("备份仓库初始化失败：\(error.localizedDescription)")
                }
            }
        case .ready:
            do {
                try await engine.ensureRepository()
            } catch {
                await logger.error("备份仓库初始化失败：\(error.localizedDescription)")
            }
        default:
            await logger.warning("备份仓库状态为 \(state.displayName)，已跳过自动初始化")
        }
        let interrupted = try await database.recoverInterruptedJobs(legacyGrace: 60)
        var requeued = 0
        for id in interrupted {
            guard let job = try await database.job(id: id),
                  job.type == .backup,
                  job.retryCount < RetryPolicy.default.maxAttempts else { continue }
            do {
                try await database.scheduleRetry(
                    job,
                    after: 60,
                    errorClass: job.errorClass ?? .unknown,
                    message: "上次备份被中断，将自动重试"
                )
                requeued += 1
            } catch {
                await logger.error("恢复中断任务失败：\(error.localizedDescription)")
            }
            do {
                try await database.updateProjectRuntime(
                    id: job.projectID,
                    status: .warning,
                    lastError: "上次备份被中断，约 1 分钟后自动重试"
                )
            } catch {
                await logger.warning("更新项目状态失败：\(error.localizedDescription)")
            }
        }
        // Local restore jobs stuck in `running` after a crash are failed here so
        // they never linger as "running" forever.
        do {
            // CT-112: only jobs whose owner is provably gone (or truly legacy
            // unleased rows past the grace window) are reclaimed.
            let reclaimed = try await database.recoverInterruptedRestoreJobs(legacyGrace: 600)
            if !reclaimed.isEmpty {
                await logger.warning("已回收 \(reclaimed.count) 个中断的本地恢复任务")
            }
        } catch {
            await logger.warning("回收中断恢复任务失败：\(error.localizedDescription)")
        }
        // Abandoned cloud-restore staging directories (crash before commit, job
        // already terminal) are reclaimed. Only validated direct children named
        // `restore-*` that no resumable job references are ever touched.
        await reclaimAbandonedRestoreStaging()
        let version = await KopiaBinary.version(at: engineBinaryURL())
        var bootState = await engine.repositoryState()
        if bootState == .uninitialized, repositoryWasRegistered { bootState = .missing }
        repositoryStateCache = bootState

        if !interrupted.isEmpty {
            do {
                try await recordActivity(ActivityEvent(
                    kind: .agent,
                    level: .warning,
                    message: requeued > 0
                        ? "恢复了 \(requeued) 个中断的备份任务并安排重试"
                        : "恢复了 \(interrupted.count) 个中断的备份任务并标记为未完成"
                ))
            } catch {
                await logger.error("写入活动记录失败：\(error.localizedDescription)")
            }
        }

        // A first run on a machine where the iCloud container is already available
        // gets cloud mirroring by default; the user can turn it off in onboarding.
        if !settings.hasCompletedOnboarding,
           !settings.iCloudEnabled,
           settings.localMirrorPath == nil,
           await CloudLocation.iCloudStorageRoot() != nil {
            settings.iCloudEnabled = true
        }

        settings = try await saveSettings(settings)

        let report = BootstrapReport(
            recoveryKeyText: secrets.isNew ? secrets.recoveryKeyText : nil,
            secretsWereCreated: secrets.isNew,
            device: device,
            repository: repository,
            kopiaVersion: version,
            recoveredInterruptedJobs: interrupted.count,
            settings: settings
        )
        self.cachedSettings = settings
        self.bootstrapReport = report
        try await recordActivity(ActivityEvent(
            kind: .system,
            level: .info,
            message: "CodeTime 已启动",
            details: version
        ))
        return report
    }

    public func bootstrapSummary() -> BootstrapReport? { bootstrapReport }

    public func currentDevice() throws -> DeviceIdentity {
        guard let device else { throw CodeTimeError.repositoryUnavailable("服务尚未初始化") }
        return device
    }

    public func currentRepository() throws -> RepositoryRecord {
        guard let repository else { throw CodeTimeError.repositoryUnavailable("服务尚未初始化") }
        return repository
    }

    private func loadOrCreateDevice() async throws -> DeviceIdentity {
        let currentHardware = hardwareUUIDProvider()
        if let stored = try await database.codable(DeviceIdentity.self, forKey: Keys.device) {
            if let storedUUID = stored.hardwareUUID, let currentHardware, storedUUID != currentHardware {
                // CT-124: Migration Assistant can clone the app data onto a
                // different Mac. The stored identity must never be reused by
                // two machines — mint a fresh one; the previous device's cloud
                // data stays untouched under its own device ID.
                let hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
                let device = DeviceIdentity(
                    id: UUID(),
                    name: hostName,
                    model: Self.modelIdentifier(),
                    hardwareUUID: currentHardware
                )
                try await database.setCodable(device, forKey: Keys.device)
                await logger.warning(
                    "检测到硬件身份变化：原设备 \(stored.id.uuidString)（\(storedUUID.prefix(8))…）与本机（\(currentHardware.prefix(8))…）不一致，已生成新设备身份 \(device.id.uuidString)；原设备的云端仓库保留"
                )
                return device
            }
            if let currentHardware, stored.hardwareUUID == nil {
                // Adopt the hardware anchor on the first boot after upgrading.
                var adopted = stored
                adopted.hardwareUUID = currentHardware
                try await database.setCodable(adopted, forKey: Keys.device)
                return adopted
            }
            return stored
        }
        let hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let device = DeviceIdentity(
            id: UUID(),
            name: hostName,
            model: Self.modelIdentifier(),
            hardwareUUID: currentHardware
        )
        try await database.setCodable(device, forKey: Keys.device)
        return device
    }

    private func loadOrCreateRepository() async throws -> RepositoryRecord {
        let stored = try await database.codable(RepositoryRecord.self, forKey: Keys.repository)
        let discovered = try RepositoryDiscovery.discover(in: paths.repositories)
        // Single decision point for "which repository do we touch": a registered ID
        // is never silently switched, a matching ID wins even among many, and an
        // unregistered machine adopts exactly one repository or none.
        guard let selected = try RepositoryDiscovery.select(stored: stored, discovered: discovered) else {
            let id = UUID()
            let root = paths.repositories.appendingPathComponent(id.uuidString, isDirectory: true)
            let record = RepositoryRecord(
                id: id,
                path: root.appendingPathComponent("repo", isDirectory: true).path,
                configPath: root.appendingPathComponent("kopia.config").path
            )
            try await persist(repository: record)
            return record
        }

        let root = paths.repositories.appendingPathComponent(selected.id.uuidString, isDirectory: true)
        var normalized = selected
        normalized.path = root.appendingPathComponent("repo", isDirectory: true).path
        normalized.configPath = root.appendingPathComponent("kopia.config").path
        if selected.id == stored?.id {
            // The database already knows this repository; only refresh stale paths.
            if normalized != stored {
                try await persist(repository: normalized)
            }
            return normalized
        }
        // Adopted from disk after the database was lost: secrets must not be minted.
        repositoryWasRegistered = true
        try await persist(repository: normalized)
        return normalized
    }

    private func persist(repository record: RepositoryRecord) async throws {
        try await database.setCodable(record, forKey: Keys.repository)
        try await database.upsertRepository(record)
    }

    private static func modelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    // MARK: - Engine

    private func engineBinaryURL() -> URL {
        kopiaBinaryURL ?? URL(fileURLWithPath: "/nonexistent/kopia")
    }

    private func currentEngine() async throws -> KopiaBackupEngine {
        if let engineCache { return engineCache }
        guard let repository else {
            throw CodeTimeError.repositoryUnavailable("服务尚未初始化")
        }
        guard let binary = kopiaBinaryURL else {
            throw CodeTimeError.kopiaNotFound
        }
        let settings = try await currentSettings()
        let engine = KopiaBackupEngine(configuration: .init(
            repositoryID: repository.id,
            repositoriesRoot: paths.repositories,
            cacheURL: paths.cache,
            logsURL: paths.logs,
            binaryURL: binary,
            passwordProvider: keychain,
            gitProvider: gitInspector,
            defaultParallelism: settings.performance.backupParallelism
        ))
        engineCache = engine
        return engine
    }

    private func rebuildEngine() {
        engineCache = nil
    }

    // MARK: - Settings

    /// SQLite is the single source of truth. The UI and the background agent each
    /// cache their own copy, so every read goes back to the database instead of
    /// serving a value that another process has already replaced.
    public func currentSettings() async throws -> AppSettings {
        if let stored = try await database.codable(AppSettings.self, forKey: Keys.settings) {
            cachedSettings = stored
            return stored
        }
        let created = try await database.saveSettingsCAS(AppSettings.default, expectedRevision: nil)
        cachedSettings = created
        return created
    }

    public func settingsSnapshot() async throws -> AppSettings {
        try await currentSettings()
    }

    /// Compare-and-set: a stale editor receives `.conflict` instead of silently
    /// overwriting settings changed by another window or the agent.
    @discardableResult
    public func saveSettings(_ settings: AppSettings) async throws -> AppSettings {
        let previous = cachedSettings
        let saved = try await database.saveSettingsCAS(
            settings.synchronizingScheduler(),
            expectedRevision: settings.configRevision
        )
        cachedSettings = saved
        if previous?.performance != saved.performance {
            rebuildEngine()
        }
        notifyChange()
        return saved
    }

    /// Used by the agent when it must merge a cross-process change without losing it.
    @discardableResult
    public func mutateSettings(_ mutate: (inout AppSettings) -> Void) async throws -> AppSettings {
        var current = try await currentSettings()
        mutate(&current)
        return try await saveSettings(current)
    }

    /// Stores the local mirror as a security-scoped bookmark. In the sandbox a
    /// path string alone grants nothing after relaunch, so an unresolvable
    /// bookmark is surfaced instead of silently producing empty cloud reads.
    @discardableResult
    public func setLocalMirror(_ url: URL?) async throws -> AppSettings {
        var settings = try await currentSettings()
        if let url {
            let bookmark = try SecurityScopedBookmarks.makeBookmark(for: url)
            settings.localMirrorPath = url.path
            settings.localMirrorBookmark = bookmark
            settings.localMirrorAccessState = .granted
            settings.iCloudEnabled = false
        } else {
            mirrorAccess?.stop()
            mirrorAccess = nil
            settings.localMirrorPath = nil
            settings.localMirrorBookmark = nil
            settings.localMirrorAccessState = .notRequired
        }
        return try await saveSettings(settings)
    }

    private func markMirrorAccess(_ state: SecurityAccessState) async {
        do {
            var settings = try await currentSettings()
            guard settings.localMirrorAccessState != state else { return }
            settings.localMirrorAccessState = state
            _ = try await saveSettings(settings)
        } catch {
            await logger.warning("无法记录本地镜像授权状态：\(error.localizedDescription)")
        }
    }

    public func repositoryState() async -> RepositoryState {
        do {
            let engine = try await currentEngine()
            var state = await engine.repositoryState()
            if state == .uninitialized, repositoryWasRegistered {
                // The database says this repository existed, but its directory is
                // gone. Report missing rather than "never initialized".
                state = .missing
            }
            repositoryStateCache = state
            return state
        } catch {
            // The signature is non-throwing for the UI; surfacing the staleness in
            // the log is preferable to pretending the cached value is fresh.
            await logger.warning(
                "无法确定仓库状态，沿用上次结果（\(repositoryStateCache.displayName)）：\(error.localizedDescription)"
            )
            return repositoryStateCache
        }
    }

    public func completeOnboarding() async throws {
        var settings = try await currentSettings()
        settings.hasCompletedOnboarding = true
        keychain.markRecoveryKeyAcknowledged()
        try await saveSettings(settings)
    }

    public func takeRecoveryKeyText() throws -> String {
        try keychain.recoveryKeyText()
    }

    // MARK: - Projects

    public func projects() async throws -> [Project] {
        try await database.projects()
    }

    public func project(id: UUID) async throws -> Project? {
        try await database.project(id: id)
    }

    public func policy(projectID: UUID) async throws -> BackupPolicy? {
        try await database.policy(projectID: projectID)
    }

    @discardableResult
    public func addProject(url: URL, name: String? = nil, groupName: String? = nil) async throws -> Project {
        let existing = try await database.projects()
        let settings = try await currentSettings()
        let validation = ProjectPathValidator.validate(
            url: url,
            existingProjects: existing,
            appRoot: paths.root,
            mirrorPath: settings.localMirrorPath,
            iCloudMirrorPath: await iCloudMirrorPath(settings: settings)
        )
        guard validation.isAcceptable else {
            let first = validation.issues[0]
            if first.reason.contains("重叠") || first.reason.contains("内部") {
                throw CodeTimeError.pathOverlap(path: first.path, conflictsWith: first.reason)
            }
            throw CodeTimeError.unsupported("\(first.reason)：\(first.suggestion)")
        }
        let resolved = validation.resolvedURL

        // A path string is display-only under the sandbox; the bookmark is the
        // authorization. Failing to create one means the project cannot be backed up
        // after the next launch, so surface it now instead of storing a dead path.
        let bookmark = try SecurityScopedBookmarks.makeBookmark(for: resolved)
        let project = Project(
            name: name ?? resolved.lastPathComponent,
            rootPath: resolved.path,
            bookmark: bookmark,
            enabled: true,
            groupName: groupName,
            accessState: .granted
        )
        try await database.upsertProject(project)

        let presets = ExclusionPresets.defaultRules()
        let policy = BackupPolicy(
            projectID: project.id,
            intervalMinutes: settings.globalIntervalMinutes,
            excludeRules: presets,
            performance: settings.performance
        )
        try await database.upsertPolicy(policy)
        try await recordActivity(ActivityEvent(
            kind: .system,
            level: .success,
            projectID: project.id,
            message: "已添加项目 \(project.name)"
        ))
        return project
    }

    /// Registers a project discovered during cloud recovery. The source path may not
    /// exist on this Mac; snapshots remain browsable and restorable from the repository.
    @discardableResult
    public func addRecoveredProject(sourcePath: String) async throws -> Project {
        let existing = try await database.projects()
        if let match = existing.first(where: { $0.rootPath == sourcePath }) {
            return match
        }
        let url = URL(fileURLWithPath: sourcePath)
        let exists = FileManager.default.fileExists(atPath: sourcePath)
        if exists {
            return try await addProject(url: url, name: url.lastPathComponent)
        }
        let settings = try await currentSettings()
        let project = Project(
            name: url.lastPathComponent + "（已恢复）",
            rootPath: sourcePath,
            bookmark: nil,
            enabled: false,
            lastError: "本机不存在此路径，仅可浏览历史并恢复到新位置",
            status: .warning
        )
        try await database.upsertProject(project)
        try await database.upsertPolicy(BackupPolicy(
            projectID: project.id,
            intervalMinutes: settings.globalIntervalMinutes,
            excludeRules: ExclusionPresets.defaultRules(),
            performance: settings.performance
        ))
        try await recordActivity(ActivityEvent(
            kind: .restore,
            level: .warning,
            projectID: project.id,
            message: "已登记历史项目 \(sourcePath)，但本机路径不存在",
            details: "可以浏览快照，或恢复整个项目到新目录"
        ))
        return project
    }

    /// Configuration-only edit. Runtime fields (status, last backup, error) are
    /// re-read inside the store, so a stale editor cannot roll them back, and
    /// `configRevision` rejects a second editor that started from older data.
    public func updateProject(_ project: Project) async throws {
        let current = try await database.project(id: project.id)
        if let current, current.rootPath != project.rootPath {
            let existing = try await database.projects().filter { $0.id != project.id }
            let settings = try await currentSettings()
            let validation = ProjectPathValidator.validate(
                url: URL(fileURLWithPath: project.rootPath),
                existingProjects: existing,
                appRoot: paths.root,
                mirrorPath: settings.localMirrorPath,
                iCloudMirrorPath: await iCloudMirrorPath(settings: settings)
            )
            guard validation.isAcceptable else {
                let first = validation.issues[0]
                throw CodeTimeError.unsupported("\(first.reason)：\(first.suggestion)")
            }
        }
        _ = try await database.updateProjectConfig(
            id: project.id,
            expectedRevision: project.configRevision
        ) { updated in
            updated.name = project.name
            updated.rootPath = project.rootPath
            updated.bookmark = project.bookmark
            updated.enabled = project.enabled
            updated.groupName = project.groupName
            updated.notes = project.notes
            updated.accessState = project.accessState
        }
        notifyChange()
    }

    public func setProjectEnabled(_ id: UUID, enabled: Bool) async throws {
        // Field-level CAS write: a stale struct captured elsewhere in this actor must
        // never resurrect an old name, path, policy or exclusion set.
        _ = try await database.setProjectEnabled(id: id, enabled: enabled)
        notifyChange()
    }

    /// Deletion is a two-phase operation: the project stops accepting new backups
    /// first, then its rows are removed only after no live job still owns it. A
    /// timeout leaves it in `.deleting` rather than pulling rows from under a running
    /// kopia process.
    public func deleteProject(id: UUID) async throws {
        guard let project = try await database.project(id: id) else { return }
        if project.lifecycle == .deleted { return }
        try await database.markProjectDeleting(id: id)
        notifyChange()

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let busy = try await projectHasLiveJobs(id: id) || activeProjects.contains(id)
            if !busy { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        if try await projectHasLiveJobs(id: id) || activeProjects.contains(id) {
            throw CodeTimeError.repositoryBusy("项目「\(project.name)」仍在备份，已标记为待删除，请稍后重试")
        }

        try await database.deleteProject(id: id)
        notifyChange()
        try await recordActivity(ActivityEvent(
            kind: .system,
            level: .warning,
            message: "已从列表移除项目（不会删除磁盘文件）"
        ))
    }

    private func projectHasLiveJobs(id: UUID) async throws -> Bool {
        let jobs = try await database.jobs(
            projectID: id,
            states: [.queued, .running],
            limit: 50
        )
        return jobs.contains { job in
            if let lease = job.lease { return !lease.isReclaimable() }
            // Unleased legacy rows only count while running; a queued retry cannot
            // start because `.deleting` makes the project unschedulable.
            return job.state == .running
        }
    }

    public func updatePolicy(_ policy: BackupPolicy) async throws {
        try await database.upsertPolicy(policy)
        notifyChange()
    }

    public func exclusionPreview(projectID: UUID) async throws -> ExclusionPreview {
        guard let project = try await database.project(id: projectID),
              let policy = try await database.policy(projectID: projectID) else {
            throw CodeTimeError.repositoryUnavailable("项目不存在")
        }
        return try await withProject(project) { resolved in
            let matcher = ExclusionMatcher(
                rules: policy.excludeRules + KopiaIgnore.rules(at: URL(fileURLWithPath: resolved.rootPath)),
                includeEnvFiles: policy.includeEnvFiles,
                includeGitDirectory: policy.includeGitDirectory
            )
            return ExclusionScanner.preview(
                root: URL(fileURLWithPath: resolved.rootPath),
                matcher: matcher
            )
        }
    }

    public func exclusionPreview(
        directory: URL,
        rules: [ExclusionRule],
        includeEnvFiles: Bool,
        includeGitDirectory: Bool
    ) -> ExclusionPreview {
        let matcher = ExclusionMatcher(
            rules: rules + KopiaIgnore.rules(at: directory),
            includeEnvFiles: includeEnvFiles,
            includeGitDirectory: includeGitDirectory
        )
        return ExclusionScanner.preview(root: directory, matcher: matcher)
    }

    // MARK: - Snapshots

    /// Throws when the repository cannot be queried. A failed query is never rendered
    /// as "no backups"; callers keep the last known list and display the reason.
    public func refreshSnapshots(projectID: UUID) async throws -> [Snapshot] {
        guard let project = try await database.project(id: projectID) else {
            throw CodeTimeError.repositoryUnavailable("项目不存在")
        }
        let cached = try await database.snapshots(projectID: projectID, limit: 1000)
        let engine = try await currentEngine()
        // Listing snapshots reads only the repository; the source directory may
        // legitimately be absent after a machine migration.
        let fresh = try await engine.listSnapshots(project: project)
            .sorted { $0.createdAt > $1.createdAt }
        let stored = Dictionary(uniqueKeysWithValues: cached.map { ($0.id, $0) })
        var merged: [Snapshot] = []
        for var snapshot in fresh {
            if let old = stored[snapshot.id] {
                snapshot.git = old.git
                snapshot.cloudState = old.cloudState
                snapshot.cloudGenerationID = old.cloudGenerationID
                snapshot.verifiedAt = old.verifiedAt
                snapshot.verificationLevel = old.verificationLevel
                if old.trigger != .scheduled { snapshot.trigger = old.trigger }
            }
            try await database.upsertSnapshot(snapshot)
            merged.append(snapshot)
        }
        if let newest = merged.max(by: { $0.createdAt < $1.createdAt }) {
            if project.lastSnapshotID != newest.id {
                try await database.updateProjectRuntime(
                    id: projectID,
                    lastBackupAt: newest.createdAt,
                    lastSnapshotID: newest.id
                )
            }
        }
        // CT-091: one status rule everywhere (the old inline mapping showed
        // localOnly as synced — inconsistent with projectStatus(for:)).
        await recomputeProjectStatus(projectID: projectID)
        await refreshRepositoryStateCache()
        return merged.sorted { $0.createdAt > $1.createdAt }
    }

    /// Typed variant for UI code: an explicit `.unavailable`/`.corrupted` result is
    /// distinguishable from a genuinely empty project.
    public func snapshotQuery(projectID: UUID) async -> SnapshotQueryResult {
        do {
            return .success(try await refreshSnapshots(projectID: projectID))
        } catch {
            await logger.warning("读取快照列表失败：\(error.localizedDescription)")
            if case CodeTimeError.repositoryCorrupted(let detail) = error {
                return .corrupted(detail)
            }
            if case CodeTimeError.repositoryMissing(let detail) = error {
                return .unavailable("备份仓库已丢失：\(detail)")
            }
            if case CodeTimeError.repositoryStateForbidden(let state, _) = error {
                return .unavailable("仓库处于 \(state) 状态，暂时无法读取快照")
            }
            return .unavailable(error.localizedDescription)
        }
    }

    private func refreshRepositoryStateCache() async {
        do {
            let engine = try await currentEngine()
            var state = await engine.repositoryState()
            if state == .uninitialized, repositoryWasRegistered { state = .missing }
            repositoryStateCache = state
        } catch {
            await logger.warning("无法读取仓库状态：\(error.localizedDescription)")
        }
    }

    @discardableResult
    public func createSnapshot(
        projectID: UUID,
        trigger: BackupTrigger,
        retryJobID: UUID? = nil,
        allowsRetry: Bool = true
    ) async throws -> BackupOutcome {
        try beginWorkClaim()
        defer { endWorkClaim() }
        guard let project = try await database.project(id: projectID) else {
            throw CodeTimeError.repositoryUnavailable("项目不存在")
        }
        guard let policy = try await database.policy(projectID: projectID) else {
            throw CodeTimeError.repositoryUnavailable("项目缺少备份策略")
        }
        guard project.isSchedulable else {
            throw CodeTimeError.projectDeleted(projectID.uuidString)
        }
        guard !activeProjects.contains(projectID), !backupGateClosed else {
            throw CodeTimeError.unsupported("已有备份任务在运行，请稍后再试")
        }
        activeProjects.insert(projectID)
        backupGateClosed = true
        defer {
            activeProjects.remove(projectID)
            backupGateClosed = false
        }

        let owner = ProcessIdentity.current(isAgent: Self.isAgentProcess)
        let leaseDuration: TimeInterval = 90
        // Check the project and claim the job in one SQLite write transaction.
        // No stale job object is written back before the lease is acquired.
        guard let claimed = try await database.claimBackupJob(
            projectID: projectID,
            retryJobID: retryJobID,
            trigger: trigger,
            owner: owner,
            expiresAt: Date().addingTimeInterval(leaseDuration)
        ) else {
            throw CodeTimeError.leaseConflict(owner: "另一个备份任务")
        }
        let job = claimed.job
        let leaseState = LeaseState()
        let work = Task { [self] in
            let engine = try await currentEngine()
            return try await withProject(project) { resolved in
                try await engine.createSnapshot(project: resolved, policy: policy, trigger: trigger)
            }
        }
        // CT-101: register the in-flight job so a shutdown can cancel it and WAIT
        // for the Kopia child to be reaped before any lock is released.
        registerWork(
            ActiveWorkInfo(id: job.id, kind: .backup, projectID: projectID, startedAt: Date()),
            cancel: { work.cancel() }
        )
        defer { unregisterWork(job.id) }
        let heartbeat = Task { [database, logger] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                do {
                    let renewed = try await database.renewJobLease(
                        id: job.id,
                        owner: owner,
                        expiresAt: Date().addingTimeInterval(leaseDuration)
                    )
                    if !renewed {
                        leaseState.markLost()
                        work.cancel()
                        await logger.error("备份任务租约已丢失，正在停止当前任务")
                        return
                    }
                } catch {
                    await logger.warning("备份任务心跳写入失败：\(error.localizedDescription)")
                }
            }
        }
        defer { heartbeat.cancel() }

        try await database.updateProjectRuntime(
            id: projectID,
            status: .backingUp,
            clearLastError: true
        )
        notifyChange()

        do {
            // Propagate caller cancellation (scheduler stop / drain) into the work
            // task, which terminates the Kopia process group and waits for exit.
            let snapshot = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            if leaseState.isLost {
                throw CodeTimeError.leaseConflict(owner: "任务租约已被另一个进程接管")
            }
            // The project may have entered deletion while kopia was running. Do not
            // resurrect a row for a project the user already removed.
            guard try await database.project(id: projectID)?.lifecycle == .active else {
                throw CodeTimeError.projectDeleted(projectID.uuidString)
            }
            try await database.upsertSnapshot(snapshot)

            // CT-091: runtime fields are written together with the recompute;
            // the status itself is derived, never decided here.
            try await database.updateProjectRuntime(
                id: projectID,
                lastBackupAt: snapshot.createdAt,
                lastSnapshotID: snapshot.id,
                clearLastError: true
            )
            await recomputeProjectStatus(projectID: projectID)

            heartbeat.cancel()
            try await finishJob(job.id, state: .succeeded, owner: owner)

            try await recordActivity(ActivityEvent(
                kind: .backup,
                level: snapshot.status == .complete ? .success : .warning,
                projectID: projectID,
                message: snapshot.status == .complete
                    ? "\(project.name) 备份完成"
                    : "\(project.name) 备份完成但存在读取失败",
                details: "\(snapshot.fileCount) 个文件 · \(CodeTimeFormat.bytes(snapshot.totalSize))"
            ))

            let cloudError = await publishIfConfigured(snapshot: snapshot)
            // CT-091: the post-publish status comes from the unified recompute —
            // which reads the NEWEST snapshot, so a concurrent newer snapshot's
            // failure cannot be masked by this (older) upload finishing.
            await recomputeProjectStatus(projectID: projectID)
            if let refreshed = try await database.snapshot(id: snapshot.id) {
                notifyChange()
                return BackupOutcome(snapshot: refreshed, cloudError: cloudError)
            }
            notifyChange()
            return BackupOutcome(snapshot: snapshot, cloudError: cloudError)
        } catch {
            heartbeat.cancel()
            if leaseState.isLost {
                // Another process owns this job now; do not overwrite its state or
                // schedule a retry against its lease.
                throw CodeTimeError.leaseConflict(owner: "任务租约已被另一个进程接管")
            }
            // CT-101: a shutdown/cancel is not a failure to retry. The job is
            // marked interrupted (with an explicit reason) and the project stays
            // scheduled, so the next launch or due time continues normally.
            let wasCancelled = Self.isCancellation(error)
            if wasCancelled {
                do {
                    try await finishJob(
                        job.id,
                        state: BackupJobState.interrupted,
                        errorMessage: "任务被中断（进程退出或用户取消）",
                        owner: owner
                    )
                } catch {
                    await logger.error("写入任务中断状态失败：\(error.localizedDescription)")
                }
                try? await database.updateProjectRuntime(
                    id: projectID,
                    status: .warning,
                    lastError: "备份被中断，下次调度会继续"
                )
                await logger.warning("备份任务被取消：\(error.localizedDescription)")
                throw error
            }
            let errorClass = RetryPolicy.classify(error)
            let retryDelay = allowsRetry
                ? RetryPolicy.default.delay(attempt: job.retryCount, errorClass: errorClass)
                : nil
            if let retryDelay {
                let scheduled: Bool
                do {
                    scheduled = try await database.scheduleRetry(
                        id: job.id,
                        owner: owner,
                        after: retryDelay,
                        errorClass: errorClass,
                        message: error.localizedDescription
                    )
                } catch {
                    await logger.error("写入重试计划失败：\(error.localizedDescription)")
                    throw error
                }
                guard scheduled else {
                    throw CodeTimeError.leaseConflict(owner: "任务租约已被另一个进程接管")
                }
                let retryNote = "\(error.localizedDescription)（约 \(max(1, Int(retryDelay / 60))) 分钟后自动重试）"
                try await database.updateProjectRuntime(
                    id: projectID,
                    status: .warning,
                    lastError: retryNote
                )
                await logger.warning("备份失败，已安排重试：\(error.localizedDescription)")
                do {
                    try await recordActivity(ActivityEvent(
                        kind: .backup,
                        level: .warning,
                        projectID: projectID,
                        message: "\(project.name) 备份失败，等待重试",
                        details: retryNote
                    ))
                } catch {
                    await logger.error("写入活动记录失败：\(error.localizedDescription)")
                }
            } else {
                do {
                    try await finishJob(job.id, state: .failed, errorMessage: error.localizedDescription, owner: owner)
                } catch {
                    await logger.error("写入任务失败状态出错：\(error.localizedDescription)")
                }
                try await database.updateProjectRuntime(
                    id: projectID,
                    status: .failed,
                    lastError: error.localizedDescription
                )
                await logger.error("备份失败：\(error.localizedDescription)")
                do {
                    try await recordActivity(ActivityEvent(
                        kind: .backup,
                        level: .error,
                        projectID: projectID,
                        message: "\(project.name) 备份失败",
                        details: error.localizedDescription
                    ))
                } catch {
                    await logger.error("写入活动记录失败：\(error.localizedDescription)")
                }
            }
            notifyChange()
            throw error
        }
    }

    public func dueProjects(now: Date = Date()) async throws -> [Project] {
        let settings = try await currentSettings()
        // Pausing must stop every process, not just the window that toggled it.
        guard settings.scheduler.allowsScheduling else { return [] }
        let projects = try await database.projects()
        var due: [Project] = []
        for project in projects where project.isSchedulable {
            guard !activeProjects.contains(project.id) else { continue }
            let storedInterval = try await database.policy(projectID: project.id)?.intervalMinutes
            let interval = storedInterval ?? settings.scheduler.backupIntervalMinutes
            let last = project.lastBackupAt ?? .distantPast
            if now.timeIntervalSince(last) >= TimeInterval(max(1, interval) * 60) {
                due.append(project)
            }
        }
        return due
    }

    /// Queued retry jobs whose backoff has elapsed. The scheduler claims each one
    /// through its lease before running, so two processes cannot both execute it.
    public func dueRetryJobs(now: Date = Date()) async throws -> [BackupJob] {
        try await database.dueRetryJobs(now: now, limit: 20)
    }

    public func snapshots(projectID: UUID? = nil, limit: Int = 500) async throws -> [Snapshot] {
        try await database.snapshots(projectID: projectID, limit: limit)
    }

    public func snapshot(id: String) async throws -> Snapshot? {
        try await database.snapshot(id: id)
    }

    // MARK: - Browse / diff

    public func listDirectory(snapshotID: String, path: String) async throws -> [FileEntry] {
        let engine = try await currentEngine()
        return try await engine.listDirectory(snapshotID: snapshotID, path: path)
    }

    public func searchFiles(
        snapshotID: String,
        query: String,
        limits: SearchLimits = .default
    ) async throws -> FileSearchResult {
        let engine = try await currentEngine()
        return try await engine.searchFiles(snapshotID: snapshotID, query: query, limits: limits)
    }

    public func readFile(snapshotID: String, path: String, maxBytes: Int = 2 * 1024 * 1024) async throws -> Data {
        let engine = try await currentEngine()
        return try await engine.readFile(snapshotID: snapshotID, path: path, maxBytes: maxBytes)
    }

    public func diff(projectID: UUID, from snapshotA: String, to snapshotB: String) async throws -> SnapshotDiff {
        guard try await database.snapshot(id: snapshotA)?.projectID == projectID,
              try await database.snapshot(id: snapshotB)?.projectID == projectID else {
            throw CodeTimeError.unsupported("只能比较同一项目的快照")
        }
        let engine = try await currentEngine()
        return try await engine.diff(from: snapshotA, to: snapshotB)
    }

    // MARK: - Restore

    @discardableResult
    public func restore(_ request: RestoreRequest) async throws -> RestoreJob {
        guard let project = try await database.project(id: request.projectID) else {
            throw CodeTimeError.repositoryUnavailable("项目不存在")
        }
        guard let snapshotRecord = try await database.snapshot(id: request.snapshotID),
              snapshotRecord.projectID == request.projectID else {
            throw CodeTimeError.snapshotNotFound(request.snapshotID)
        }

        try beginWorkClaim()
        defer { endWorkClaim() }

        var job = RestoreJob(
            projectID: request.projectID,
            snapshotID: request.snapshotID,
            relativePath: request.relativePath,
            mode: request.mode,
            targetPath: request.destination.path
        )

        // CT-111: two restores must never write the same destination. The lock
        // file lives in the lifecycle dir (keyed by the destination path), so the
        // user's target directory is never polluted.
        let targetLockURL = paths.lifecycleDir.appendingPathComponent(
            "restore-target-\(Self.stablePathHash(request.destination.standardizedFileURL.path)).lock"
        )
        let targetLock = RepositoryLock(path: targetLockURL.path)
        guard await Self.acquireFileLock(targetLock, timeout: 60) else {
            throw CodeTimeError.repositoryUnavailable(
                "另一个恢复任务正在写入 \(request.destination.path)"
            )
        }
        defer { targetLock.release() }

        try await database.upsertRestoreJob(job)
        if let conflicting = try await database.liveRestoreForTarget(
            request.destination.path, excluding: job.id
        ) {
            throw CodeTimeError.repositoryUnavailable(
                "另一个恢复任务（\(conflicting.id)）正在写入同一目标"
            )
        }
        let restoreOwner = ProcessIdentity.current(isAgent: Self.isAgentProcess)
        let restoreLeaseDuration: TimeInterval = 90
        guard try await database.claimRestoreJob(
            id: job.id,
            owner: restoreOwner,
            expiresAt: Date().addingTimeInterval(restoreLeaseDuration)
        ) != nil else {
            throw CodeTimeError.leaseConflict(owner: "另一个恢复任务")
        }
        do {
            _ = try await database.upsertRestoreJob(job, owner: restoreOwner)
        } catch {
            do {
                try await database.releaseRestoreLease(id: job.id, owner: restoreOwner)
            } catch {
                await logger.error("本地恢复首次写入失败后释放租约失败：\(error.localizedDescription)")
            }
            throw error
        }
        let restoreLeaseState = LeaseState()
        let restoreHeartbeat = Task { [database, logger] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                do {
                    let renewed = try await database.renewRestoreLease(
                        id: job.id,
                        owner: restoreOwner,
                        expiresAt: Date().addingTimeInterval(restoreLeaseDuration)
                    )
                    if !renewed {
                        restoreLeaseState.markLost()
                        await logger.error("本地恢复任务租约已丢失")
                        return
                    }
                } catch {
                    await logger.warning("本地恢复心跳写入失败：\(error.localizedDescription)")
                }
            }
        }
        defer { restoreHeartbeat.cancel() }

        if request.mode == .preview {
            job.status = .completed
            job.finishedAt = Date()
            _ = try await database.upsertRestoreJob(job, owner: restoreOwner)
            do {
                try await database.releaseRestoreLease(id: job.id, owner: restoreOwner)
            } catch {
                await logger.error("预览恢复后释放租约失败：\(error.localizedDescription)")
            }
            return job
        }

        do {
            let engine = try await currentEngine()
            switch request.mode {
            case .preview:
                break
            case .overwrite:
                guard let relativePath = request.relativePath, !relativePath.isEmpty else {
                    throw CodeTimeError.unsupported("覆盖恢复必须指定单个文件")
                }
                try await withProject(project) { resolved in
                    let target = try Self.safeTargetURL(projectRoot: resolved.rootPath, relativePath: relativePath)
                    if FileManager.default.fileExists(atPath: target.path) {
                        let receipt: ProtectedCopyStore.CopyReceipt
                        do {
                            receipt = try ProtectedCopyStore.createCopy(
                                target: target,
                                projectID: project.id,
                                projectRoot: URL(fileURLWithPath: resolved.rootPath),
                                recoveryRoot: paths.recovery
                            )
                        } catch {
                            // CT-117: an overwrite without a working protection
                            // copy must never proceed — fail loudly instead.
                            await logger.error("覆盖前保护副本创建失败，已中止覆盖恢复：\(error.localizedDescription)")
                            throw error
                        }
                        // CT-122: the restore below references this copy, so it
                        // stays protected from every prune until the restore ends.
                        ProtectedCopyStore.registerActiveCopy(receipt.directory)
                        defer { ProtectedCopyStore.unregisterActiveCopy(receipt.directory) }
                        await logger.info(
                            "覆盖前已保护当前文件：\(receipt.directory.path)（\(receipt.sizeBytes) 字节\(receipt.overBudget ? "，超出保护容量预算，副本已保留" : "")）"
                        )
                        for removal in receipt.removals {
                            await logger.info(
                                "保护副本清理：删除 \(removal.directory.lastPathComponent)（\(removal.bytes) 字节，原因 \(removal.reason.rawValue)）"
                            )
                        }
                    }
                    try await runRegisteredOperation(
                        id: job.id,
                        kind: .restore,
                        projectID: request.projectID
                    ) {
                        try await engine.restore(
                            snapshotID: request.snapshotID,
                            path: relativePath,
                            destination: target,
                            overwrite: true
                        )
                    }
                }
            case .copy, .wholeProject:
                let path = request.mode == .wholeProject ? nil : request.relativePath
                // CT-086: the user-chosen destination must not point into the
                // app's data root (repositories / recovery / cache / database).
                try SafePath.validateRestoreDestination(
                    request.destination,
                    protectedRoots: [paths.root]
                )
                let destinationAccess = SecurityScopedAccess(url: request.destination)
                defer { destinationAccess.stop() }
                try await runRegisteredOperation(
                    id: job.id,
                    kind: .restore,
                    projectID: request.projectID
                ) {
                    try await engine.restore(
                        snapshotID: request.snapshotID,
                        path: path,
                        destination: request.destination,
                        overwrite: false
                    )
                }
            }

            guard !restoreLeaseState.isLost else {
                throw CodeTimeError.leaseConflict(owner: "恢复任务租约已被接管")
            }
            job.status = .completed
            job.finishedAt = Date()
            _ = try await database.upsertRestoreJob(job, owner: restoreOwner)
            do {
                try await database.releaseRestoreLease(id: job.id, owner: restoreOwner)
            } catch {
                await logger.error("恢复完成后释放租约失败：\(error.localizedDescription)")
            }
            // CT-091: restore outcome routes through the unified status recompute.
            await recomputeProjectStatus(projectID: request.projectID)
            try await recordActivity(ActivityEvent(
                kind: .restore,
                level: .success,
                projectID: request.projectID,
                message: "\(project.name) 恢复完成",
                details: request.mode.displayName + " → " + request.destination.path
            ))
            return job
        } catch {
            job.status = .failed
            job.finishedAt = Date()
            job.errorMessage = error.localizedDescription
            _ = try? await database.upsertRestoreJob(job, owner: restoreOwner)
            do {
                try await database.releaseRestoreLease(id: job.id, owner: restoreOwner)
            } catch {
                await logger.error("恢复失败后释放租约失败（租约过期后自动回收）：\(error.localizedDescription)")
            }
            try? await recordActivity(ActivityEvent(
                kind: .restore,
                level: .error,
                projectID: request.projectID,
                message: "\(project.name) 恢复失败",
                details: error.localizedDescription
            ))
            throw error
        }
    }

    public func restoreJobs(limit: Int = 100) async throws -> [RestoreJob] {
        try await database.restoreJobs(limit: limit)
    }

    // MARK: - Verification

    @discardableResult
    public func verifySnapshot(projectID: UUID, snapshotID: String) async throws -> VerificationResult {
        guard let project = try await database.project(id: projectID) else {
            throw CodeTimeError.repositoryUnavailable("项目不存在")
        }
        let engine = try await currentEngine()
        var result = try await engine.verify(snapshotID: snapshotID)
        result.projectID = projectID
        try await database.insertVerification(result)
        if var snapshot = try await database.snapshot(id: snapshotID) {
            if result.outcome == .passed {
                snapshot.verifiedAt = Date()
                snapshot.verificationLevel = .localRestore
            } else {
                // A failed verification must never leave an older "verified"
                // timestamp in place: that is a false success on the dashboard.
                snapshot.verifiedAt = nil
                snapshot.verificationLevel = nil
            }
            try await database.upsertSnapshot(snapshot)
        }
        try await recordActivity(ActivityEvent(
            kind: .verification,
            level: result.outcome == .passed ? .success : .error,
            projectID: projectID,
            message: result.outcome == .passed ? "\(project.name) 恢复校验通过" : "\(project.name) 恢复校验失败",
            details: result.details
        ))
        return result
    }

    @discardableResult
    public func verifyCloud() async throws -> VerificationResult? {
        let settings = try await currentSettings()
        guard let store = try await makeCloudStoreIfConfigured(settings: settings) else {
            return nil
        }
        guard let repository else { return nil }
        // Use the entry list, not `listGenerations`, because the latter silently
        // drops unreadable generations and would verify an older version while
        // presenting the result as if the newest version had passed.
        let entries = try await store.listGenerationEntries(repositoryId: repository.id)
        guard let newest = entries.first else { return nil }

        let result: VerificationResult
        if let generation = newest.generation {
            result = try await store.verifyGeneration(generation.id)
        } else {
            result = VerificationResult(
                generationID: newest.id,
                level: .cloudIntegrity,
                outcome: .failed,
                details: "最新云端版本不可读取：\(newest.detail ?? newest.readState.rawValue)"
            )
            // The latest generation may have an older verified state in SQLite.
            // A failed/unreadable verification must clear it explicitly.
            if var stored = try? await database.generation(id: newest.id) {
                stored.state = .published
                stored.verifiedAt = nil
                stored.errorMessage = result.details
                try? await database.upsertGeneration(stored)
            }
        }
        try await database.insertVerification(result)

        if var generation = newest.generation {
            if result.outcome == .passed {
                generation.state = .verified
                generation.verifiedAt = Date()
                generation.errorMessage = nil
            } else {
                generation.state = .published
                generation.verifiedAt = nil
                generation.errorMessage = "完整性校验失败：\(result.details)"
            }
            try await database.upsertGeneration(generation)
        }

        try await recordActivity(ActivityEvent(
            kind: .verification,
            level: result.outcome == .passed ? .success : .error,
            message: "云端版本完整性校验\(result.outcome == .passed ? "通过" : "失败")",
            details: result.details
        ))
        return result
    }

    public func runPeriodicVerificationIfNeeded() async {
        await runMaintenanceIfDue(.verify)
    }

    public func cleanupCloudIfNeeded() async {
        await runMaintenanceIfDue(.cleanup)
    }

    /// Runs a maintenance task only when its persisted next-run time has passed.
    /// Success and failure are recorded separately: a skipped or failed run must
    /// never look like a successful verification.
    public func runMaintenanceIfDue(_ task: CodeTimeJobType, now: Date = Date()) async {
        let settings: AppSettings
        do {
            settings = try await currentSettings()
        } catch {
            await logger.warning("维护任务无法读取设置：\(error.localizedDescription)")
            return
        }
        guard settings.scheduler.allowsScheduling else { return }

        let intervalSeconds: TimeInterval
        switch task {
        case .verify:
            guard settings.scheduler.verificationIntervalDays > 0 else { return }
            intervalSeconds = TimeInterval(settings.scheduler.verificationIntervalDays * 86_400)
        case .cleanup:
            intervalSeconds = TimeInterval(max(1, settings.scheduler.cleanupIntervalDays) * 86_400)
        default:
            return
        }

        let stored: MaintenanceTaskState?
        do {
            stored = try await database.maintenanceState(task)
        } catch {
            await logger.error("无法读取维护状态：\(error.localizedDescription)")
            return
        }
        if let next = stored?.nextRunAt, next > now { return }

        let started = Date()
        do {
            switch task {
            case .verify:
                guard let result = try await verifyCloud() else {
                    try await recordMaintenanceSkip(task, reason: "未配置云端镜像", at: started, interval: intervalSeconds)
                    return
                }
                guard result.outcome == .passed else {
                    throw CodeTimeError.integrityFailure(result.details)
                }
                // CT-120 / 二.7: the periodic verify task also re-verifies the
                // local protection copies; corrupt ones are marked invalid.
                try await auditProtectionCopies()
            case .cleanup:
                guard let report = try await cleanupCloud() else {
                    try await recordMaintenanceSkip(task, reason: "未配置云端镜像", at: started, interval: intervalSeconds)
                    return
                }
                if let reason = report.skippedReason {
                    try await recordMaintenanceSkip(task, reason: reason, at: started, interval: intervalSeconds)
                    return
                }
            default:
                return
            }
            var state = stored ?? MaintenanceTaskState(task: task)
            state = state.recordingSuccess(at: Date(), nextRunAt: Date().addingTimeInterval(intervalSeconds))
            try await database.saveMaintenanceState(state)
        } catch {
            var state = stored ?? MaintenanceTaskState(task: task)
            state = state.recordingFailure(
                error.localizedDescription,
                at: Date(),
                nextRunAt: Date().addingTimeInterval(min(intervalSeconds, 3_600))
            )
            do {
                try await database.saveMaintenanceState(state)
            } catch {
                await logger.error("无法保存维护失败状态：\(error.localizedDescription)")
            }
            await logger.warning("维护任务 \(task.displayName) 失败：\(error.localizedDescription)")
        }
    }

    /// CT-120 / 二.7: re-verifies every project's protection copies. Corrupt
    /// copies are marked `.invalid` on disk by `ProtectedCopyStore.verifyCopy`;
    /// any failure fails the verify maintenance task so it surfaces in status.
    private func auditProtectionCopies() async throws {
        let projects = try await database.projects()
        var failures: [String] = []
        for project in projects {
            for failure in ProtectedCopyStore.auditProject(projectID: project.id, recoveryRoot: paths.recovery) {
                failures.append("\(project.name)：\(failure.directory.lastPathComponent) — \(failure.reason)")
            }
        }
        guard failures.isEmpty else {
            for failure in failures {
                await logger.error("保护副本校验失败：\(failure)")
            }
            throw CodeTimeError.integrityFailure("\(failures.count) 个保护副本校验失败")
        }
    }

    private func recordMaintenanceSkip(
        _ task: CodeTimeJobType,
        reason: String,
        at date: Date,
        interval: TimeInterval
    ) async throws {
        let stored = try await database.maintenanceState(task)
        var state = stored ?? MaintenanceTaskState(task: task)
        state = state.recordingSkip(reason, at: date, nextRunAt: date.addingTimeInterval(interval))
        try await database.saveMaintenanceState(state)
    }

    @discardableResult
    /// CT-105: `allowPhysicalDelete` defaults to false — an iCloud store then only
    /// reports what it WOULD delete. The UI's explicit "立即清理" action passes
    /// true after the user confirms; automatic maintenance never does.
    public func cleanupCloud(allowPhysicalDelete: Bool = false) async throws -> CloudCleanupReport? {
        let settings = try await currentSettings()
        guard let store = try await makeCloudStoreIfConfigured(settings: settings), let repository else {
            return nil
        }
        let report = try await store.cleanup(
            repositoryId: repository.id,
            gracePeriod: TimeInterval(settings.cloudGracePeriodDays * 86_400),
            minimumGenerations: settings.minimumCloudGenerations,
            allowPhysicalDelete: allowPhysicalDelete
        )
        let message: String
        if report.deletedObjects > 0 {
            message = "云端清理完成：删除 \(report.deletedObjects) 个对象，释放 \(CodeTimeFormat.bytes(report.freedBytes))"
        } else if report.plannedDeletes > 0 {
            message = "云端清理预览：可清理 \(report.plannedDeletes) 个对象（\(report.plannedGenerationDeletes) 个历史版本）"
        } else {
            message = "云端清理已暂停"
        }
        try await recordActivity(ActivityEvent(
            kind: .cleanup,
            level: report.deletedObjects > 0 ? .success : .warning,
            message: message,
            details: report.skippedReason
        ))
        return report
    }

    public func cloudSummary() async throws -> CloudStorageSummary? {
        let settings = try await currentSettings()
        guard let store = try await makeCloudStoreIfConfigured(settings: settings), let repository else {
            return nil
        }
        return try await store.storageSummary(repositoryId: repository.id)
    }

    public func cloudGenerations() async throws -> [CloudGeneration] {
        let settings = try await currentSettings()
        guard let store = try await makeCloudStoreIfConfigured(settings: settings), let repository else {
            return []
        }
        let entries = try await store.listGenerationEntries(repositoryId: repository.id)
        return entries.map { entry in
            if let generation = entry.generation { return generation }
            // Classify unreadable cause instead of blanket-failing everything.
            let state: CloudGenerationState
            switch entry.readState {
            case .notDownloaded: state = .staging
            case .unreadable: state = .published
            case .corrupted, .unsupportedVersion: state = .failed
            case .valid: state = .published
            }
            return CloudGeneration(
                id: entry.id,
                repositoryID: repository.id,
                deviceID: device?.id ?? UUID(),
                createdAt: entry.manifestModifiedAt ?? .distantPast,
                state: state,
                errorMessage: entry.detail ?? entry.readState.rawValue
            )
        }
    }

    // MARK: - Cloud internals

    private func publishIfConfigured(snapshot: Snapshot) async -> String? {
        var activeGenerationID: UUID?
        do {
            let settings = try await currentSettings()
            guard let store = try await makeCloudStoreIfConfigured(settings: settings),
                  let repository, let device else {
                return nil
            }

            let snapshotIDs = try await database.snapshots(limit: 10_000).map { $0.id }
            var generation = CloudGeneration(
                repositoryID: repository.id,
                deviceID: device.id,
                state: .staging,
                snapshotIDs: snapshotIDs
            )
            activeGenerationID = generation.id
            try await database.upsertGeneration(generation)
            try await database.updateSnapshotCloud(
                id: snapshot.id,
                cloudState: .uploading,
                cloudGenerationID: generation.id
            )
            try await database.updateProjectRuntime(id: snapshot.projectID, status: .publishing)
            notifyChange()

            generation.state = .uploading
            try await database.upsertGeneration(generation)

            try await store.publish(repositoryId: repository.id, generation: generation)

            if let published = try await store.listGenerations(repositoryId: repository.id)
                .first(where: { $0.id == generation.id }) {
                generation = published
            }
            generation.state = .published
            generation.publishedAt = Date()
            try await database.upsertGeneration(generation)

            try await database.updateSnapshotCloud(
                id: snapshot.id,
                cloudState: .synced,
                cloudGenerationID: generation.id
            )
            try await recordActivity(ActivityEvent(
                kind: .upload,
                level: .success,
                projectID: snapshot.projectID,
                message: "云端版本已发布",
                details: "\(generation.objectCount) 个对象 · \(CodeTimeFormat.bytes(generation.byteSize))"
            ))
            notifyChange()
            return nil
        } catch {
            // The manifest may already be committed even if a later step failed.
            // Confirm the actual cloud state before reporting a failed publish.
            if let generationID = activeGenerationID {
                if let settings = try? await currentSettings(),
                   let store = try? await makeCloudStoreIfConfigured(settings: settings),
                   await store.confirmPublished(generationId: generationID) {
                    if var generation = try? await database.generation(id: generationID) {
                        generation.state = .published
                        generation.publishedAt = generation.publishedAt ?? Date()
                        generation.errorMessage = nil
                        try? await database.upsertGeneration(generation)
                    }
                    try? await database.updateSnapshotCloud(
                        id: snapshot.id,
                        cloudState: .synced,
                        cloudGenerationID: generationID
                    )
                    await refreshProjectCloudStatus(projectID: snapshot.projectID)
                    await logger.warning("云端发布已确认成功，后续本地记录失败已修复")
                    return nil
                }
            }

            await logger.error("云端同步失败：\(error.localizedDescription)")
            if let generationID = activeGenerationID {
                let errorClass = RetryPolicy.classify(error)
                if let delay = RetryPolicy.default.delay(attempt: 0, errorClass: errorClass) {
                    let uploadJob = BackupJob(
                        projectID: snapshot.projectID,
                        type: .upload,
                        state: .queued,
                        trigger: .scheduled,
                        repositoryID: repository?.id,
                        generationID: generationID,
                        snapshotID: snapshot.id,
                        errorClass: errorClass
                    )
                    do {
                        try await database.upsertJob(uploadJob)
                        try await database.scheduleRetry(
                            uploadJob,
                            after: delay,
                            errorClass: errorClass,
                            message: error.localizedDescription
                        )
                    } catch {
                        await logger.error("无法创建云端发布重试任务：\(error.localizedDescription)")
                    }
                }
            }
            do {
                if var snapshotState = try await database.snapshot(id: snapshot.id) {
                    snapshotState.cloudState = .failed
                    try await database.upsertSnapshot(snapshotState)
                }
            } catch {
                await logger.error("无法记录快照云端失败状态：\(error.localizedDescription)")
            }
            if let generationID = activeGenerationID {
                do {
                    if var failedGeneration = try await database.generation(id: generationID) {
                        failedGeneration.state = .failed
                        failedGeneration.errorMessage = error.localizedDescription
                        try await database.upsertGeneration(failedGeneration)
                    }
                } catch {
                    await logger.error("无法记录云端版本失败状态：\(error.localizedDescription)")
                }
            }
            do {
                try await recordActivity(ActivityEvent(
                    kind: .upload,
                    level: .error,
                    projectID: snapshot.projectID,
                    message: "云端同步失败，本地快照仍然有效",
                    details: error.localizedDescription
                ))
            } catch {
                await logger.error("无法写入云端失败活动：\(error.localizedDescription)")
            }
            notifyChange()
            return error.localizedDescription
        }
    }

    /// Retries a cloud publish independently of local snapshots. The lease prevents
    /// UI and Agent from uploading the same generation at the same time.
    /// CT-097: the lease is short-lived and renewed by a heartbeat — a dead
    /// uploader never blocks the retry for an hour, and a worker whose lease was
    /// taken over never commits state it no longer owns.
    @discardableResult
    public func retryCloudPublish(job: BackupJob) async -> Bool {
        guard let generationID = job.generationID, let repository else { return false }
        let owner = ProcessIdentity.current(isAgent: Self.isAgentProcess)
        let uploadLeaseDuration: TimeInterval = 90
        guard (try? await database.acquireJobLease(
            id: job.id,
            owner: owner,
            expiresAt: Date().addingTimeInterval(uploadLeaseDuration)
        )) != nil else {
            return false
        }
        let uploadLeaseState = LeaseState()
        let uploadHeartbeat = Task { [database, logger] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                do {
                    let renewed = try await database.renewJobLease(
                        id: job.id,
                        owner: owner,
                        expiresAt: Date().addingTimeInterval(uploadLeaseDuration)
                    )
                    if !renewed {
                        uploadLeaseState.markLost()
                        await logger.error("云端发布任务租约已丢失，正在停止当前上传")
                        return
                    }
                } catch {
                    await logger.warning("云端发布心跳写入失败：\(error.localizedDescription)")
                }
            }
        }
        defer { uploadHeartbeat.cancel() }
        do {
            let settings = try await currentSettings()
            guard let store = try await makeCloudStoreIfConfigured(settings: settings) else {
                throw CodeTimeError.cloudNotConfigured
            }
            guard var generation = try await database.generation(id: generationID) else {
                throw CodeTimeError.generationNotFound(generationID.uuidString)
            }
            try await store.publish(repositoryId: repository.id, generation: generation)
            // CT-097: an irreversible publish must not be committed by a stale owner.
            guard !uploadLeaseState.isLost else {
                throw CodeTimeError.leaseConflict(owner: "云端发布任务租约已被接管")
            }
            generation.state = .published
            generation.publishedAt = generation.publishedAt ?? Date()
            generation.errorMessage = nil
            try await database.upsertGeneration(generation)
            if let snapshotID = job.snapshotID {
                try await database.updateSnapshotCloud(
                    id: snapshotID,
                    cloudState: .synced,
                    cloudGenerationID: generationID
                )
            }
            await recomputeProjectStatus(projectID: job.projectID)
            try await finishJob(job.id, state: .succeeded, owner: owner)
            try await recordActivity(ActivityEvent(
                kind: .upload,
                level: .success,
                projectID: job.projectID,
                message: "云端发布重试成功",
                details: generation.id.uuidString
            ))
            return true
        } catch {
            if let settings = try? await currentSettings(),
               let store = try? await makeCloudStoreIfConfigured(settings: settings),
               await store.confirmPublished(generationId: generationID) {
                if var generation = try? await database.generation(id: generationID) {
                    generation.state = .published
                    generation.publishedAt = generation.publishedAt ?? Date()
                    generation.errorMessage = nil
                    try? await database.upsertGeneration(generation)
                }
                if let snapshotID = job.snapshotID {
                    try? await database.updateSnapshotCloud(
                        id: snapshotID,
                        cloudState: .synced,
                        cloudGenerationID: generationID
                    )
                }
                try? await finishJob(job.id, state: .succeeded, owner: owner)
                await recomputeProjectStatus(projectID: job.projectID)
                return true
            }
            let errorClass = RetryPolicy.classify(error)
            if let delay = RetryPolicy.default.delay(attempt: job.retryCount, errorClass: errorClass) {
                do {
                    let scheduled = try await database.scheduleRetry(
                        id: job.id,
                        owner: owner,
                        after: delay,
                        errorClass: errorClass,
                        message: error.localizedDescription
                    )
                    if !scheduled { return false }
                } catch {
                    await logger.error("无法安排云端发布重试：\(error.localizedDescription)")
                }
            } else {
                try? await finishJob(job.id, state: .failed, errorMessage: error.localizedDescription, owner: owner)
            }
            await refreshProjectCloudStatus(
                projectID: job.projectID,
                fallbackError: "云端发布失败：\(error.localizedDescription)"
            )
            return false
        }
    }

    public static func projectStatus(for cloudState: CloudSyncState) -> ProjectStatus {
        switch cloudState {
        case .synced: return .synced
        case .localOnly: return .localOnly
        default: return .warning
        }
    }

    /// CT-091: single source of truth for project sync status. Every terminal or
    /// transitional business outcome (backup success/failure, publish success/
    /// failure, retry, restore, snapshot refresh) must route through here instead
    /// of deciding the final status itself.
    ///
    /// Rules (Goal §7.2):
    /// - A live (non-reclaimable) backup job pins `.backingUp` — an old upload
    ///   callback can never flip a running project to synced.
    /// - The NEWEST snapshot decides the sync state — an old snapshot's upload
    ///   finishing last can never override a newer snapshot's failure.
    /// - A newest snapshot with partial read failures stays `.warning` even when
    ///   its cloud state is synced.
    /// - Deleted / disabled projects are never resurrected by a recompute.
    func recomputeProjectStatus(projectID: UUID, fallbackError: String? = nil) async {
        do {
            // CT-110: one SQLite transaction — no stale read can be written back
            // over a newer snapshot from another process.
            guard let status = try await database.recomputeProjectRuntimeState(projectID: projectID) else {
                return
            }
            if let fallbackError, status != .synced, status != .localOnly {
                try await database.updateProjectRuntime(id: projectID, lastError: fallbackError)
            }
        } catch {
            await logger.warning("无法重算项目状态：\(error.localizedDescription)")
        }
    }

    /// Stable, launch-independent hash used for per-target lock file names.
    static func stablePathHash(_ path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Legacy entry point kept for existing callers; delegates to the unified
    /// recompute.
    func refreshProjectCloudStatus(projectID: UUID, fallbackError: String? = nil) async {
        await recomputeProjectStatus(projectID: projectID, fallbackError: fallbackError)
    }

    private func iCloudMirrorPath(settings: AppSettings) async -> String? {
        guard settings.iCloudEnabled else { return nil }
        return await CloudLocation.iCloudStorageRoot()?.path
    }

    private func makeCloudStoreIfConfigured(settings: AppSettings) async throws -> CloudMirrorStore? {
        guard let repository else { return nil }
        let root: URL
        let coordinated: Bool
        let tracker: any CloudUploadTracking

        if settings.iCloudEnabled {
            guard let iCloud = await CloudLocation.iCloudStorageRoot() else {
                throw CodeTimeError.cloudNotConfigured
            }
            root = iCloud
            coordinated = true
            tracker = UbiquitousUploadTracker()
        } else if let custom = settings.localMirrorPath, !custom.isEmpty {
            if let bookmark = settings.localMirrorBookmark {
                do {
                    let resolved = try SecurityScopedBookmarks.resolve(bookmark)
                    if mirrorAccess?.url.standardizedFileURL.path != resolved.url.standardizedFileURL.path {
                        mirrorAccess?.stop()
                        mirrorAccess = SecurityScopedAccess(url: resolved.url)
                    }
                    root = resolved.url
                } catch {
                    await markMirrorAccess(.stale)
                    throw CodeTimeError.bookmarkFailed("本地镜像授权已失效：\(error.localizedDescription)")
                }
            } else {
                let url = URL(fileURLWithPath: custom, isDirectory: true)
                // The mirror may be configured before it is created; only fail when
                // the directory cannot be created or written.
                do {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                } catch {
                    throw CodeTimeError.securityScopeUnavailable("\(custom)：\(error.localizedDescription)")
                }
                if !FileManager.default.isWritableFile(atPath: url.path) {
                    throw CodeTimeError.securityScopeUnavailable(custom)
                }
                root = url
            }
            coordinated = false
            tracker = NoopUploadTracker()
        } else {
            return nil
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return CloudMirrorStore(configuration: .init(
            storageRoot: root,
            repositoryID: repository.id,
            repositoryURL: URL(fileURLWithPath: repository.path),
            deviceID: try currentDevice().id,
            masterKeyProvider: keychain,
            passwordProvider: keychain,
            uploadTracker: tracker,
            coordinatedIO: coordinated,
            lockURL: URL(fileURLWithPath: repository.configPath)
                .deletingLastPathComponent()
                .appendingPathComponent("repository.lock"),
            publishLockURL: URL(fileURLWithPath: repository.configPath)
                .deletingLastPathComponent()
                .appendingPathComponent("publish.lock"),
            warningHandler: { [logger] message in
                Task { await logger.warning(message) }
            },
            uploadParallelism: settings.performance.uploadParallelism
        ))
    }

    // MARK: - Disaster recovery

    /// Enumerates every decryptable device/repository pair instead of silently
    /// picking the first directory on disk.
    public func cloudRecoveryCandidates(storageRoot: URL, recoveryKeyText: String) async throws -> [RecoveryCandidate] {
        let key = try RecoveryKey.parse(recoveryKeyText)
        return try await CloudMirrorStore.recoverCandidates(storageRoot: storageRoot, recoveryKey: key)
    }

    public func recoverFromCloud(storageRoot: URL, recoveryKeyText: String) async throws -> CloudRecoveryResult {
        let candidates = try await cloudRecoveryCandidates(storageRoot: storageRoot, recoveryKeyText: recoveryKeyText)
        guard let candidate = candidates.first(where: { $0.isRestorable }) else {
            throw CodeTimeError.noRecoveryCandidate
        }
        return try await recoverFromCloud(
            candidate: candidate,
            storageRoot: storageRoot,
            recoveryKeyText: recoveryKeyText
        )
    }

    /// Repairs the Keychain after a Beta → Release migration when the old
    /// Keychain item is not readable by the Release signing identity. The
    /// repository itself is already present; only the encrypted recovery payload
    /// is used to install the master key and repository password.
    public func installSecretsFromCloud(storageRoot: URL, recoveryKeyText: String) async throws {
        let key = try RecoveryKey.parse(recoveryKeyText)
        guard let record = try await database.codable(RepositoryRecord.self, forKey: Keys.repository) else {
            throw CodeTimeError.repositoryUnavailable("本机没有待修复的仓库记录")
        }
        let recovered = try await CloudMirrorStore.recover(
            storageRoot: storageRoot,
            recoveryKey: key,
            repositoryID: record.id
        )
        guard recovered.repositoryID == record.id else {
            throw CodeTimeError.restoreKeyMismatch
        }
        try keychain.installSecrets(
            masterKey: key,
            repositoryPassword: recovered.repositoryPassword
        )
        self.repository = record
        rebuildEngine()
    }

    public func latestCloudRestoreJob() async throws -> CloudRestoreJob? {
        let jobs = try await database.cloudRestoreJobs(limit: 20)
        return jobs.first { !$0.state.isTerminal }
    }

    // MARK: Cloud restore commit journal (CT-102)

    /// Explicit crash positions for the restore commit. The journal lives in the
    /// repository root (OUTSIDE the staging directory, which is about to be moved)
    /// and is the authority on whether the move already happened.
    struct RestoreCommitJournal: Codable, Sendable {
        enum Phase: String, Codable, Sendable {
            /// Staging is verified and about to be moved into place.
            case prepared
            /// `moveItem(staging -> repo)` has completed.
            case replaced
        }

        var jobID: UUID
        var repositoryID: UUID
        var generationID: UUID
        var stagingPath: String
        var repositoryURL: String
        var phase: Phase
        var updatedAt: Date
    }

    /// P2-6: the single validation every restore staging path must pass before
    /// any download or filesystem write. Extracted so tests can exercise the
    /// production function instead of re-implementing its steps.
    static func validateRestoreStaging(_ path: String, repositoryRoot: URL) throws -> URL {
        try SafePath.assertRealDirectoryNotSymlink(path)
        return try SafePath.containedDirectChild(path, within: repositoryRoot)
    }

    static func restoreCommitJournalURL(repositoryRoot: URL, jobID: UUID) -> URL {
        repositoryRoot.appendingPathComponent(
            "restore-commit-\(jobID.uuidString.prefix(8)).json",
            isDirectory: false
        )
    }

    /// Reads and validates the journal. A journal whose identity does not match
    /// this job/repository/generation is an error — never silently ignored.
    static func loadRestoreCommitJournal(
        at url: URL, jobID: UUID, repositoryID: UUID, generationID: UUID
    ) throws -> RestoreCommitJournal? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let journal: RestoreCommitJournal
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            journal = try decoder.decode(RestoreCommitJournal.self, from: data)
        } catch {
            throw CodeTimeError.restoreInterrupted("恢复提交日志损坏：\(url.path)（\(error.localizedDescription)）")
        }
        guard journal.jobID == jobID,
              journal.repositoryID == repositoryID,
              journal.generationID == generationID else {
            throw CodeTimeError.restoreInterrupted("恢复提交日志与任务身份不一致：\(url.path)")
        }
        return journal
    }

    static func writeRestoreCommitJournal(_ journal: RestoreCommitJournal, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(journal).write(to: url, options: .atomic)
    }

    /// CT-102: the restore commit position. Pure — no filesystem access — so the
    /// whole crash matrix is unit-testable.
    enum RestoreCommitPosition: Equatable, Sendable {
        /// Staging must be (re)created and the repository downloaded.
        case download
        /// Staging exists with a `prepared` journal: verify and move.
        case resumeCommit
        /// The repository in place IS the restored data; finish metadata only.
        case alreadyCommitted
        /// A non-empty repository exists that we cannot prove is ours.
        case blockedDestination
    }

    static func restoreCommitPosition(
        journal: RestoreCommitJournal?,
        stagingExists: Bool,
        repositoryExists: Bool,
        repositoryHasMarker: Bool,
        jobState: RestoreJobState
    ) -> RestoreCommitPosition {
        if stagingExists {
            // A non-empty repository next to a live staging directory is a
            // conflict we must not resolve by deleting either side.
            return repositoryExists && repositoryHasMarker && journal?.phase == .replaced
                ? .alreadyCommitted
                : .resumeCommit
        }
        guard repositoryExists else {
            // Nothing on disk: a fresh download (the caller creates staging).
            return .download
        }
        guard repositoryHasMarker else {
            // A non-repository directory occupies the slot — never overwrite it.
            return .blockedDestination
        }
        // The move happened iff the journal recorded it, or the job was persisted
        // as committing/verifying (legacy rows from before the journal existed).
        let journalProvesMove = journal?.phase == .prepared || journal?.phase == .replaced
        let stateProvesMove = jobState == .committing || jobState == .verifying
        return (journalProvesMove || stateProvesMove) ? .alreadyCommitted : .blockedDestination
    }

    /// Cross-process lock with a timeout. Async on purpose (P2-10): the previous
    /// `Thread.sleep` loop ran ON the service actor and froze every other call in
    /// the process for up to the timeout.
    static func acquireFileLock(_ lock: RepositoryLock, timeout: TimeInterval) async -> Bool {
        if lock.tryAcquire() { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return false
            }
            if Task.isCancelled { return false }
            if lock.tryAcquire() { return true }
        }
        return false
    }

    /// Downloads into a sibling staging directory, verifies every copied file, then
    /// switches it into place with a single rename.
    ///
    /// CT-102 crash protocol (journal first, staging second):
    ///   prepared  → staging verified, `repo` not yet replaced
    ///   replaced  → `repo` replaced, metadata/DB completion pending
    /// Re-entry reads the journal BEFORE any staging directory is created, so a
    /// crash after the move is completed instead of being blocked by a
    /// re-created empty staging directory.
    public func recoverFromCloud(
        candidate: RecoveryCandidate,
        storageRoot: URL,
        recoveryKeyText: String,
        resuming jobID: UUID? = nil,
        progress: (@Sendable (CloudRestoreJob) -> Void)? = nil
    ) async throws -> CloudRecoveryResult {
        guard candidate.isRestorable, let generationID = candidate.latestGenerationID else {
            throw CodeTimeError.cloudPublishIncomplete(candidate.blockedReason ?? "候选版本不可恢复")
        }
        try beginWorkClaim()
        defer { endWorkClaim() }
        let key = try RecoveryKey.parse(recoveryKeyText)
        // Do not gate recovery on stale snapshot rows. A database can retain
        // metadata after its Kopia repository is lost; the repository slot below
        // is the authoritative check.
        let recovered = try await CloudMirrorStore.recover(
            storageRoot: storageRoot,
            recoveryKey: key,
            repositoryID: candidate.repositoryID,
            deviceID: candidate.deviceID
        )
        guard recovered.repositoryID == candidate.repositoryID,
              recovered.deviceID == candidate.deviceID else {
            throw CodeTimeError.restoreSourceUnavailable("恢复凭据与所选设备不一致")
        }
        let repositoryRoot = paths.repositories.appendingPathComponent(recovered.repositoryID.uuidString, isDirectory: true)
        let repositoryURL = repositoryRoot.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryRoot, withIntermediateDirectories: true)
        // CT-107/108: no level of the restore path may be a symlink.
        try SafePath.assertRealDirectoryNotSymlink(paths.repositories.path)
        try SafePath.assertRealDirectoryNotSymlink(repositoryRoot.path)

        // CT-104: one restore per repository. The job lease protects a single job;
        // different jobs (different generations) target the same `repo` directory,
        // so a repository-level flock covers staging, commit, metadata and the
        // final verification.
        // NOTE: the SAME lock file is used by the Kopia engine itself, and flock is
        // not reentrant across descriptors — this lock is therefore released before
        // any engine call (see the verification block below).
        var repositoryLock: RepositoryLock? = RepositoryLock(
            path: repositoryRoot.appendingPathComponent("repository.lock").path
        )
        guard let acquiredLock = repositoryLock, await Self.acquireFileLock(acquiredLock, timeout: 120) else {
            throw CodeTimeError.repositoryUnavailable(
                "仓库 \(recovered.repositoryID.uuidString.prefix(8)) 正被另一个恢复任务使用"
            )
        }
        defer { repositoryLock?.release() }

        let repositoryExists = FileManager.default.fileExists(atPath: repositoryURL.path)
        let repositoryContents: [String]
        if repositoryExists {
            try SafePath.assertRealDirectoryNotSymlink(repositoryURL.path)
            repositoryContents = try FileManager.default.contentsOfDirectory(atPath: repositoryURL.path)
        } else {
            repositoryContents = []
        }
        let repositoryHasMarker = repositoryContents.contains {
            $0 == "kopia.repository.f" || $0 == "kopia.repository" || $0 == ".shards"
        }

        var job: CloudRestoreJob
        let resumable: CloudRestoreJob?
        if let jobID {
            resumable = try await database.cloudRestoreJob(id: jobID)
        } else {
            resumable = try await database.resumableCloudRestore(
                repositoryID: recovered.repositoryID,
                generationID: generationID
            )
        }
        let isFreshJob = !(resumable?.state.isResumable ?? false)
        if let existing = resumable, existing.state.isResumable {
            // CT-074: Validate full identity binding before reusing a stale job.
            guard existing.repositoryID == recovered.repositoryID else {
                throw CodeTimeError.restoreSourceUnavailable(
                    "恢复任务 \(existing.id) 属于仓库 \(existing.repositoryID)，与目标 \(recovered.repositoryID) 不匹配"
                )
            }
            guard existing.generationID == generationID else {
                throw CodeTimeError.restoreSourceUnavailable(
                    "恢复任务 \(existing.id) 属于 Generation \(existing.generationID)，与目标 \(generationID) 不匹配"
                )
            }
            guard existing.sourceDeviceID == recovered.deviceID else {
                throw CodeTimeError.restoreSourceUnavailable(
                    "恢复任务 \(existing.id) 来自设备 \(existing.sourceDeviceID)，与目标 \(recovered.deviceID) 不匹配"
                )
            }
            // CT-086: direct child of the repository root, standardized AND resolved.
            _ = try SafePath.containedDirectChild(existing.stagingPath, within: repositoryRoot)
            job = existing
            // CT-086 §3.1(8/9): staging is derived from repository + job ID. Legacy
            // `restore-<8hex>` rows are reconciled to the derived name once.
            let derived = SafePath.stagingURL(
                in: repositoryRoot,
                repositoryID: recovered.repositoryID,
                jobID: existing.id
            )
            if job.stagingPath != derived.path {
                let legacyExists = FileManager.default.fileExists(atPath: job.stagingPath)
                let derivedExists = FileManager.default.fileExists(atPath: derived.path)
                if legacyExists && !derivedExists {
                    try SafePath.assertRealDirectoryNotSymlink(job.stagingPath)
                    try FileManager.default.moveItem(
                        at: URL(fileURLWithPath: job.stagingPath, isDirectory: true),
                        to: derived
                    )
                } else if legacyExists && derivedExists {
                    throw CodeTimeError.restoreInterrupted(
                        "恢复暂存目录与派生目录同时存在，请手动处理 \(repositoryRoot.path)"
                    )
                }
                job.stagingPath = derived.path
            }
        } else {
            // CT-086: fresh jobs derive the staging path from IDs only.
            let fresh = CloudRestoreJob(
                repositoryID: recovered.repositoryID,
                generationID: generationID,
                sourceDeviceID: recovered.deviceID,
                state: .preparing,
                stagingPath: ""
            )
            job = fresh
            job.stagingPath = SafePath.stagingURL(
                in: repositoryRoot,
                repositoryID: fresh.repositoryID,
                jobID: fresh.id
            ).path
        }

        // CT-102: read the journal BEFORE creating or inspecting staging.
        let journalURL = Self.restoreCommitJournalURL(repositoryRoot: repositoryRoot, jobID: job.id)
        var journal = try Self.loadRestoreCommitJournal(
            at: journalURL,
            jobID: job.id,
            repositoryID: recovered.repositoryID,
            generationID: generationID
        )

        let stagingExists = FileManager.default.fileExists(atPath: job.stagingPath)
        if stagingExists {
            _ = try Self.validateRestoreStaging(job.stagingPath, repositoryRoot: repositoryRoot)
        }
        // A journal that describes a different staging directory is not ours.
        if let loaded = journal, loaded.stagingPath != job.stagingPath,
           !(loaded.phase == .replaced && !stagingExists) {
            journal = nil
        }

        // CT-102: the crash position is decided by the JOURNAL + the on-disk
        // truth, NEVER by re-creating staging first. See restoreCommitPosition.
        let position = Self.restoreCommitPosition(
            journal: journal,
            stagingExists: stagingExists,
            repositoryExists: repositoryExists,
            repositoryHasMarker: repositoryHasMarker,
            jobState: job.state
        )
        let adoptingMovedRepository = position == .alreadyCommitted
        switch position {
        case .alreadyCommitted:
            break
        case .download:
            try FileManager.default.createDirectory(
                atPath: job.stagingPath,
                withIntermediateDirectories: true
            )
            try SafePath.assertRealDirectoryNotSymlink(job.stagingPath)
        case .resumeCommit:
            // P2-12: staging next to a non-empty repository is not resolvable by
            // retrying — surface it as a blocked destination instead of looping.
            if repositoryExists, !repositoryContents.isEmpty {
                throw CodeTimeError.destinationExists(repositoryURL.path)
            }
        case .blockedDestination:
            throw CodeTimeError.destinationExists(repositoryURL.path)
        }

        // CT-103: claim the lease only after the read-only preflight, and persist
        // the job row before the claim (a fresh row is ours alone; a resumed row
        // is written owner-checked after the claim).
        job.updatedAt = Date()
        if isFreshJob {
            job.state = .preparing
            job.retryCount = 0
        } else if adoptingMovedRepository {
            job.state = .committing
        } else if job.state == .committing {
            // P2-5: `committing → preparing` is illegal. When the journal proves
            // the move did NOT happen, the job re-enters at `verifying` (the
            // staging content is re-checked before the move).
            job.state = .verifying
            job.retryCount += 1
        } else {
            job.state = .preparing
            job.retryCount += 1
        }
        assert(
            RestoreStateMachine.allows(job.state, job.state),
            "restore state write must be a legal state"
        )
        job.lastError = nil
        if isFreshJob {
            try await database.upsertCloudRestoreJob(job)
        }
        let owner = ProcessIdentity.current(isAgent: Self.isAgentProcess)
        let restoreLeaseDuration: TimeInterval = 90
        guard try await database.claimCloudRestoreJob(
            id: job.id,
            owner: owner,
            expiresAt: Date().addingTimeInterval(restoreLeaseDuration)
        ) != nil else {
            throw CodeTimeError.leaseConflict(owner: "另一个恢复任务")
        }
        // P2-3: if this first write fails, the lease must not leak — a live
        // owner's lease is not reclaimable and would block an immediate retry.
        do {
            _ = try await database.upsertCloudRestoreJob(job, owner: owner)
        } catch {
            do {
                try await database.releaseCloudRestoreLease(id: job.id, owner: owner)
            } catch {
                await logger.error("首次状态写入失败后释放租约失败：\(error.localizedDescription)")
            }
            throw error
        }

        // CT-101: registered so a shutdown can stop this job and wait for it.
        let cancelFlag = CancellationFlag()
        registerWork(
            ActiveWorkInfo(id: job.id, kind: .cloudRestore, projectID: nil, startedAt: Date()),
            cancel: { cancelFlag.cancel() }
        )
        defer { unregisterWork(job.id) }

        let restoreLeaseState = LeaseState()
        let restoreHeartbeat = Task { [database, logger] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                do {
                    let renewed = try await database.renewCloudRestoreLease(
                        id: job.id,
                        owner: owner,
                        expiresAt: Date().addingTimeInterval(restoreLeaseDuration)
                    )
                    if !renewed {
                        restoreLeaseState.markLost()
                        await logger.error("恢复任务租约已丢失，正在停止当前任务")
                        return
                    }
                } catch {
                    await logger.warning("恢复任务心跳写入失败：\(error.localizedDescription)")
                }
            }
        }
        defer { restoreHeartbeat.cancel() }
        progress?(job)
        let started = Date()
        let restoreJobID = job.id
        let staging = URL(fileURLWithPath: job.stagingPath, isDirectory: true)

        func writeJournal(_ phase: RestoreCommitJournal.Phase) throws {
            var updated = journal ?? RestoreCommitJournal(
                jobID: job.id,
                repositoryID: recovered.repositoryID,
                generationID: generationID,
                stagingPath: job.stagingPath,
                repositoryURL: repositoryURL.path,
                phase: phase,
                updatedAt: Date()
            )
            updated.phase = phase
            updated.stagingPath = job.stagingPath
            updated.updatedAt = Date()
            try Self.writeRestoreCommitJournal(updated, to: journalURL)
            journal = updated
        }

        // Used for the download and for the generation/snapshot checks after the
        // commit. Constructing it has no side effects.
        let store = CloudMirrorStore(configuration: .init(
            storageRoot: storageRoot,
            repositoryID: recovered.repositoryID,
            repositoryURL: staging,
            deviceID: recovered.deviceID,
            masterKeyProvider: StaticMasterKey(key: key),
            passwordProvider: StaticPassword(password: recovered.repositoryPassword),
            uploadTracker: NoopUploadTracker(),
            coordinatedIO: true
        ))

        do {
            if !adoptingMovedRepository {
                job.state = .downloading
                job.updatedAt = Date()
                _ = try await database.upsertCloudRestoreJob(job, owner: owner)

                try await store.restoreRepository(
                    generationId: generationID,
                    destination: staging,
                    allowResume: true
                ) { [weak self] update in
                    guard let self else { return }
                    await self.recordCloudRestoreProgress(
                        jobID: restoreJobID,
                        owner: owner,
                        update: update,
                        progress: progress
                    )
                }

                // Progress callbacks persisted the counters; merge them back so the
                // report reflects what was actually verified, not the initial zeros.
                if let persisted = try await database.cloudRestoreJob(id: restoreJobID) {
                    job.totalFiles = persisted.totalFiles
                    job.completedFiles = persisted.completedFiles
                    job.totalBytes = persisted.totalBytes
                    job.completedBytes = persisted.completedBytes
                }
                job.state = .verifying
                job.updatedAt = Date()
                _ = try await database.upsertCloudRestoreJob(job, owner: owner)
                progress?(job)

                let stagedContents = try FileManager.default.contentsOfDirectory(atPath: staging.path)
                guard stagedContents.contains("kopia.repository.f")
                    || stagedContents.contains("kopia.repository")
                    || stagedContents.contains(".shards") else {
                    throw CodeTimeError.restoreVerificationFailed("恢复目录缺少 Kopia 仓库标记文件")
                }

                // CT-102: persist `prepared` BEFORE the destructive step so a crash
                // in the middle of the move is explainable on the next launch.
                try writeJournal(.prepared)

                // CT-087: never commit a job whose lease was taken over.
                guard !restoreLeaseState.isLost else {
                    throw CodeTimeError.leaseConflict(owner: "恢复任务租约已丢失")
                }
                try cancelFlag.check()

                job.state = .committing
                job.updatedAt = Date()
                _ = try await database.upsertCloudRestoreJob(job, owner: owner)
                progress?(job)

                if FileManager.default.fileExists(atPath: repositoryURL.path) {
                    try SafePath.assertRealDirectoryNotSymlink(repositoryURL.path)
                    let contents = try FileManager.default.contentsOfDirectory(atPath: repositoryURL.path)
                    guard contents.isEmpty else {
                        throw CodeTimeError.destinationExists(repositoryURL.path)
                    }
                    try FileManager.default.removeItem(at: repositoryURL)
                }
                try FileManager.default.moveItem(at: staging, to: repositoryURL)
                try writeJournal(.replaced)
            } else {
                // A crash after the move: the repository in place IS the restored
                // data. Record the explicit position and continue with metadata.
                if journal == nil {
                    try writeJournal(.replaced)
                } else if journal?.phase == .prepared {
                    try writeJournal(.replaced)
                }
                job.state = .committing
                job.updatedAt = Date()
                _ = try await database.upsertCloudRestoreJob(job, owner: owner)
                progress?(job)
            }

            // Secrets and the repository record are part of the commit. Re-running
            // them is idempotent, so a crash here is recoverable.
            try keychain.installSecrets(masterKey: key, repositoryPassword: recovered.repositoryPassword)
            let record = RepositoryRecord(
                id: recovered.repositoryID,
                path: repositoryURL.path,
                configPath: repositoryRoot.appendingPathComponent("kopia.config").path
            )
            try await database.setCodable(record, forKey: Keys.repository)
            try await database.upsertRepository(record)
            self.repository = record
            rebuildEngine()
        } catch {
            let cancelled = Self.isCancellation(error)
            let permanent = RetryPolicy.classify(error).isPermanent && !cancelled
            job.state = job.state == .committing
                ? .committing
                : (cancelled ? .interrupted : (permanent ? .permanentlyFailed : .retryableFailed))
            job.lastError = error.localizedDescription
            job.updatedAt = Date()
            _ = try? await database.upsertCloudRestoreJob(job, owner: owner)
            // CT-103: every failure exit releases the lease — a still-running
            // process must not block an immediate user retry.
            do {
                try await database.releaseCloudRestoreLease(id: job.id, owner: owner)
            } catch {
                await logger.error("恢复失败后释放租约失败（租约过期后自动回收）：\(error.localizedDescription)")
            }
            progress?(job)
            throw error
        }

        // CT-104: the commit window is over. Release the repository lock BEFORE
        // the engine-based verification, which acquires the same file itself.
        repositoryLock?.release()
        repositoryLock = nil

        var repositoryCheck = false
        var snapshotCheck = false
        var sources: [String] = []
        let checkDetails = "已从云端恢复仓库并重建 Kopia 仓库"
        do {
            let engine = try await currentEngine()
            try await engine.ensureRepository()
            repositoryCheck = true
            sources = try await engine.snapshotSourcePaths()
            let expected = try await store.listGenerations(repositoryId: recovered.repositoryID)
                .first(where: { $0.id == generationID })?.snapshotIDs ?? []
            let actual = try await engine.snapshotIdentifiers()
            // A valid repository must contain every snapshot named by the
            // generation manifest. "The command did not throw" is not a check.
            snapshotCheck = !expected.isEmpty && Set(expected).isSubset(of: actual)
        } catch {
            do {
                let engine = try await currentEngine()
                try await engine.markRecoveryFailed(reason: error.localizedDescription)
            } catch {
                await logger.error("无法记录仓库恢复失败状态：\(error.localizedDescription)")
            }
            job.state = .retryableFailed
            job.lastError = "仓库恢复后校验失败：\(error.localizedDescription)"
            job.updatedAt = Date()
            _ = try? await database.upsertCloudRestoreJob(job, owner: owner)
            do {
                try await database.releaseCloudRestoreLease(id: job.id, owner: owner)
            } catch {
                await logger.error("恢复校验失败后释放租约失败：\(error.localizedDescription)")
            }
            throw CodeTimeError.restoreVerificationFailed(job.lastError ?? error.localizedDescription)
        }

        let report = RestoreReport(
            repositoryID: recovered.repositoryID,
            sourceGenerationID: generationID,
            totalObjects: job.totalFiles,
            verifiedObjects: job.completedFiles,
            failedObjects: [],
            totalBytes: job.totalBytes,
            duration: Date().timeIntervalSince(started),
            repositoryCheck: repositoryCheck,
            snapshotCheck: snapshotCheck,
            snapshotCount: sources.count,
            result: (repositoryCheck && snapshotCheck) ? .passed : .failed,
            details: checkDetails
        )
        guard report.isSuccessful else {
            job.state = .retryableFailed
            job.lastError = "恢复后校验未通过"
            job.updatedAt = Date()
            _ = try? await database.upsertCloudRestoreJob(job, owner: owner)
            do {
                try await database.releaseCloudRestoreLease(id: job.id, owner: owner)
            } catch {
                await logger.error("恢复校验未通过后释放租约失败：\(error.localizedDescription)")
            }
            throw CodeTimeError.restoreVerificationFailed(job.lastError ?? "恢复后校验未通过")
        }

        // CT-087: a stale worker must never claim completion after losing the lease.
        guard !restoreLeaseState.isLost else {
            do {
                try await database.releaseCloudRestoreLease(id: job.id, owner: owner)
            } catch {
                await logger.error("提交完成前释放租约失败：\(error.localizedDescription)")
            }
            throw CodeTimeError.leaseConflict(owner: "恢复任务租约已丢失")
        }
        job.state = .completed
        job.updatedAt = Date()
        _ = try await database.upsertCloudRestoreJob(job, owner: owner)
        do {
            try await database.releaseCloudRestoreLease(id: job.id, owner: owner)
        } catch {
            await logger.error("恢复完成后释放租约失败：\(error.localizedDescription)")
        }
        progress?(job)
        // The commit journal is removed only after the database state is complete.
        try? FileManager.default.removeItem(at: journalURL)

        let verification = VerificationResult(
            generationID: generationID,
            level: .crossDeviceRestore,
            outcome: .passed,
            details: checkDetails,
            bytesChecked: job.completedBytes
        )
        try await database.insertVerification(verification)
        try await recordActivity(ActivityEvent(
            kind: .restore,
            level: .success,
            message: "已从 iCloud 恢复备份仓库",
            details: "校验 \(report.verifiedObjects) 个对象，发现 \(sources.count) 个历史项目路径"
        ))
        try await database.setCodable(true, forKey: Keys.cloudRecoveryAttempted)
        return CloudRecoveryResult(
            repositoryID: recovered.repositoryID,
            generationID: generationID,
            sourcePaths: sources,
            repositoryURL: repositoryURL,
            restoreJobID: job.id,
            report: report
        )
    }

    private func recordCloudRestoreProgress(
        jobID: UUID,
        owner: ProcessIdentity,
        update: CloudMirrorStore.RestoreProgress,
        progress: (@Sendable (CloudRestoreJob) -> Void)?
    ) async {
        do {
            guard var job = try await database.cloudRestoreJob(id: jobID) else { return }
            job.state = .downloading
            job.totalFiles = update.totalFiles
            job.completedFiles = update.completedFiles
            job.totalBytes = update.totalBytes
            job.completedBytes = update.completedBytes
            job.currentObject = update.currentPath
            job.updatedAt = Date()
            // Owner-checked: a stale worker whose lease was taken over must not
            // keep writing progress over the new owner's row.
            _ = try await database.upsertCloudRestoreJob(job, owner: owner)
            progress?(job)
        } catch {
            await logger.warning("云端恢复进度写入失败：\(error.localizedDescription)")
        }
    }

    /// How long an unreferenced staging directory survives before the janitor
    /// reclaims it (P2-9). Re-downloading is always possible.
    static let abandonedStagingLifetime: TimeInterval = 30 * 86_400

    /// Reclaims abandoned cloud-restore staging directories. A `restore-*`
    /// directory is only removed when it is a validated direct child of a
    /// repository root, no resumable job references it, and no commit journal
    /// exists that may still need it. Everything else is kept — 宁可保留.
    private func reclaimAbandonedRestoreStaging() async {
        let fm = FileManager.default
        do {
            let repositoryDirs = try fm.contentsOfDirectory(
                at: paths.repositories, includingPropertiesForKeys: [.isDirectoryKey]
            )
            let jobs = try await database.cloudRestoreJobs(limit: 200)
            // Standardize both sides: a symlinked prefix (/tmp vs /private/tmp)
            // must not make a live staging path look abandoned.
            // CT-103: any job that may still resume preserves its staging — that
            // includes retryable failures, whose verified objects are the only
            // copy of the downloaded data.
            let liveStaging = Set(
                jobs.filter(\.state.preservesStaging)
                    .map { URL(fileURLWithPath: $0.stagingPath).standardizedFileURL.path }
            )
            for repositoryDir in repositoryDirs {
                guard (try? repositoryDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                    continue
                }
                // CT-108: the repository directory itself must be a real direct
                // child of the repositories root — a symlinked repository dir
                // would make every containment check below meaningless.
                do {
                    try SafePath.assertRealDirectoryNotSymlink(repositoryDir.path)
                    _ = try SafePath.containedDirectChild(repositoryDir.path, within: paths.repositories)
                } catch {
                    await logger.warning("跳过可疑仓库目录（\(repositoryDir.lastPathComponent)）：\(error.localizedDescription)")
                    continue
                }
                let children = (try? fm.contentsOfDirectory(
                    at: repositoryDir, includingPropertiesForKeys: nil
                )) ?? []
                // P2-9: a commit journal only protects ITS OWN staging directory.
                // Treating any journal as "skip the whole repository" let one
                // failed restore freeze staging cleanup forever.
                let journalJobPrefixes: Set<String> = Set(children.compactMap { url -> String? in
                    let name = url.lastPathComponent
                    guard name.hasPrefix("restore-commit-"), name.hasSuffix(".json") else { return nil }
                    return String(name.dropFirst("restore-commit-".count).dropLast(".json".count))
                })
                for child in children where SafePath.isStagingName(child.lastPathComponent) {
                    let childStandardized = child.standardizedFileURL.path
                    guard liveStaging.contains(childStandardized) == false else { continue }
                    // A journal whose job prefix matches this staging name owns it.
                    let ownedByJournal = journalJobPrefixes.contains { prefix in
                        child.lastPathComponent.contains(prefix)
                    }
                    if ownedByJournal { continue }
                    // Retryable staging is preserved, but not forever: after the
                    // expiry it is reclaimed (the data is re-downloadable).
                    let age = (try? URL(fileURLWithPath: childStandardized)
                        .resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate.map { Date().timeIntervalSince($0) }) ?? nil
                    let expired = (age ?? 0) > Self.abandonedStagingLifetime
                    let referencedByResumableJob = !liveStaging.isEmpty
                    if referencedByResumableJob && !expired { continue }
                    do {
                        // Never recurse into an unvalidated path. Staging dirs
                        // are direct children of THIS repository dir, not of the
                        // repositories root.
                        try SafePath.assertRealDirectoryNotSymlink(child.path)
                        try SafePath.containedDirectChild(child.path, within: repositoryDir)
                        try fm.removeItem(at: child)
                        await logger.warning("已回收遗留恢复暂存目录：\(child.lastPathComponent)")
                    } catch {
                        await logger.warning("遗留暂存目录保留（\(child.lastPathComponent)）：\(error.localizedDescription)")
                    }
                }
            }
        } catch {
            await logger.warning("恢复暂存目录回收扫描失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Dashboard

    public func dashboard() async throws -> DashboardState {
        let settings = try await currentSettings()
        let projects = try await database.projects()
        let snapshots = try await database.snapshots(limit: 300)
        let count = try await database.snapshotCount()
        let activity = try await database.activities(limit: 80)
        let cloud: CloudStorageSummary?
        do {
            cloud = try await cloudSummary()
        } catch {
            await logger.warning("云端概览读取失败，面板暂不显示云端数据：\(error.localizedDescription)")
            cloud = nil
        }
        let lastBackup = projects.compactMap(\.lastBackupAt).max()
        let diagnostics = await self.diagnostics(settings: settings)
        return DashboardState(
            projects: projects,
            snapshots: snapshots,
            snapshotCount: count,
            activity: activity,
            cloudSummary: cloud,
            settings: settings,
            lastBackupAt: lastBackup,
            diagnostics: diagnostics
        )
    }

    public func activity(limit: Int = 200) async throws -> [ActivityEvent] {
        try await database.activities(limit: limit)
    }

    public func diagnostics(settings: AppSettings) async -> DiagnosticsReport {
        var checks: [(String, Bool, String)] = []
        let fm = FileManager.default
        if let repository {
            let exists = fm.fileExists(atPath: repository.path)
            let config = fm.fileExists(atPath: repository.configPath)
            checks.append(("备份仓库", exists, exists ? repository.path : "仓库目录不存在"))
            checks.append(("Kopia 配置", config, config ? "已连接" : "尚未连接"))
        } else {
            checks.append(("备份仓库", false, "尚未初始化"))
        }
        do {
            let count = try await database.snapshotCount()
            checks.append(("任务数据库", true, "\(count) 个快照记录"))
        } catch {
            checks.append(("任务数据库", false, error.localizedDescription))
        }
        if settings.iCloudEnabled {
            let root = await CloudLocation.iCloudStorageRoot()
            checks.append(("iCloud 容器", root != nil, root?.path ?? "未找到 iCloud Documents 容器"))
        } else if let mirror = settings.localMirrorPath, !mirror.isEmpty {
            let exists = fm.fileExists(atPath: mirror)
            checks.append(("本地镜像", exists, mirror))
        } else {
            checks.append(("云端镜像", true, "未启用（纯本地模式）"))
        }
        do {
            let key = try keychain.masterKey()
            checks.append(("恢复凭据", key.count == 32, "恢复密钥已保存于 Keychain"))
        } catch {
            checks.append(("恢复凭据", false, error.localizedDescription))
        }
        do {
            let values = try paths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let available = values.volumeAvailableCapacityForImportantUsage {
                let ok = available > 500 * 1024 * 1024
                checks.append(("磁盘空间", ok, CodeTimeFormat.bytes(available) + " 可用"))
            } else {
                checks.append(("磁盘空间", false, "系统未提供可用空间"))
            }
        } catch {
            checks.append(("磁盘空间", false, "无法读取可用空间：\(error.localizedDescription)"))
        }
        return DiagnosticsReport(checks: checks.map { (name: $0.0, passed: $0.1, detail: $0.2) })
    }

    private var usageCache: (date: Date, rootModifiedAt: Date, bytes: Int64)?

    // MARK: Active work registry (CT-101)

    /// A job that is currently executing a blocking filesystem/kopia operation.
    public struct ActiveWorkInfo: Sendable, Identifiable {
        public var id: UUID
        public var kind: ActiveWorkKind
        public var projectID: UUID?
        public var startedAt: Date
    }

    public enum ActiveWorkKind: String, Sendable {
        case backup
        case restore
        case cloudRestore
    }

    private struct RegisteredWork {
        let info: ActiveWorkInfo
        let cancel: @Sendable () -> Void
    }

    private var registeredWork: [UUID: RegisteredWork] = [:]
    /// Claims that have entered a blocking operation but have not registered a
    /// cancellable task yet (the claim happens before the job ID exists).
    /// Drain waits for this to reach zero, closing the register-after-claim gap.
    private var pendingWorkClaims = 0
    /// Set synchronously by `drainActiveWork`; every blocking entry point checks
    /// it BEFORE its first await.
    private var shuttingDown = false

    /// Synchronous gate: throws when a shutdown is in progress, so a job can
    /// never start between "drain decided" and the process exiting.
    func beginWorkClaim() throws {
        guard !shuttingDown else { throw CodeTimeError.cancelled }
        pendingWorkClaims += 1
    }

    func endWorkClaim() {
        pendingWorkClaims = max(0, pendingWorkClaims - 1)
    }

    public func beginShutdown() {
        shuttingDown = true
    }

    public func cancelShutdown() {
        shuttingDown = false
    }

    func registerWork(_ info: ActiveWorkInfo, cancel: @escaping @Sendable () -> Void) {
        registeredWork[info.id] = RegisteredWork(info: info, cancel: cancel)
    }

    func unregisterWork(_ id: UUID) {
        registeredWork.removeValue(forKey: id)
    }

    public func activeWork() -> [ActiveWorkInfo] {
        registeredWork.values.map(\.info).sorted { $0.startedAt < $1.startedAt }
    }

    /// CT-101: cancels every in-flight job and waits until each one has released
    /// its locks and reaped its Kopia child. Returns the work that is STILL
    /// running after the timeout — a non-empty result means the caller must NOT
    /// release locks or exit (the migration then fails safely instead).
    public func drainActiveWork(timeout: TimeInterval = 30) async -> [ActiveWorkInfo] {
        shuttingDown = true
        defer { shuttingDown = false }
        let snapshot = registeredWork.values.map { $0.info }
        guard !snapshot.isEmpty || pendingWorkClaims > 0 else { return [] }
        await logger.warning("正在停止 \(snapshot.count) 个进行中的任务：\(snapshot.map(\.kind.rawValue).joined(separator: ", "))")
        for work in registeredWork.values {
            work.cancel()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Both conditions are required: every job must have finished its own
            // cleanup (state persisted, repository lock released) AND every child
            // process must be provably reaped.
            if registeredWork.isEmpty,
               pendingWorkClaims == 0,
               ActiveChildProcesses.shared.livePIDs().isEmpty {
                return []
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return registeredWork.values.map(\.info)
    }

    /// Last-resort shutdown guard: hard-terminates any surviving Kopia child
    /// groups. Returns true only when every child is provably gone.
    @discardableResult
    public func terminateOrphanChildren(grace: TimeInterval = 3) -> Bool {
        ActiveChildProcesses.shared.terminateAll(grace: grace)
    }

    /// CT-096: bounded, fail-closed repository usage scan.
    /// - Hidden files ARE counted (the migration path counts them; both sides
    ///   must agree, and a Kopia repository keeps most data in plain names but
    ///   that is not guaranteed).
    /// - Any enumeration error aborts with `nil` (unknown) — a partial walk is
    ///   never reported as a smaller-but-valid total.
    /// - The cache is bound to the repositories root path, so a relocated data
    ///   directory can never serve another root's number.
    /// - Exceeding the entry cap returns `nil` instead of a truncated value.
    public func repositoryUsage() async -> Int64? {
        let fm = FileManager.default
        let root = paths.repositories
        // CT-096: the cache is bound to the repositories root AND its structural
        // change date — adding/removing repository entries invalidates the cache
        // immediately; deep file changes refresh via the TTL.
        let rootModifiedAt = ((try? FileManager.default.attributesOfItem(
            atPath: root.path
        )[.modificationDate]) as? Date) ?? Date()
        if let usageCache,
           Date().timeIntervalSince(usageCache.date) < 300,
           usageCache.rootModifiedAt == rootModifiedAt {
            return usageCache.bytes
        }
        // An enumeration error only SKIPS the failed subtree — the walk would
        // otherwise return a silently partial total. Any error invalidates the
        // whole result: the usage becomes "unknown", never "smaller but valid".
        var scanFailed = false
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [],
            errorHandler: { _, _ in
                scanFailed = true
                return false
            }
        ) else {
            return nil
        }
        var total: Int64 = 0
        var visited = 0
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited > 200_000 { return nil }
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if values.isDirectory == true { continue }
                total += Int64(values.fileSize ?? 0)
            } catch {
                // A single unreadable entry makes the total unknown — fail closed.
                return nil
            }
        }
        if scanFailed { return nil }
        usageCache = (Date(), rootModifiedAt, total)
        return total
    }

    // MARK: - Helpers

    /// CT-101: runs a blocking engine call in its own task, registers it so a
    /// shutdown can cancel it, and propagates caller cancellation into it. The
    /// Kopia child is terminated and reaped before this returns or throws.
    func runRegisteredOperation<T: Sendable>(
        id: UUID,
        kind: ActiveWorkKind,
        projectID: UUID?,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let task = Task { try await operation() }
        registerWork(
            ActiveWorkInfo(id: id, kind: kind, projectID: projectID, startedAt: Date()),
            cancel: { task.cancel() }
        )
        defer { unregisterWork(id) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// CT-101: both real CancellationError and the engine's cancellation error
    /// mean "asked to stop", not "failed".
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let code = error as? CodeTimeError {
            if case .cancelled = code { return true }
        }
        return false
    }

    private static var isAgentProcess: Bool {
        ProcessInfo.processInfo.environment["CODETIME_AGENT_MODE"] == "1"
    }

    private func finishJob(
        _ jobID: UUID,
        state: BackupJobState,
        errorMessage: String? = nil,
        owner: ProcessIdentity? = nil
    ) async throws {
        if let owner {
            try await database.finishJob(
                id: jobID,
                state: state,
                owner: owner,
                errorMessage: errorMessage
            )
            return
        }
        guard var job = try await database.job(id: jobID) else { return }
        job.state = state
        job.finishedAt = Date()
        job.errorMessage = errorMessage
        job.lease = nil
        if state == .succeeded {
            job.nextRetryAt = nil
            job.errorClass = nil
            job.attempt = 0
        }
        try await database.upsertJob(job)
    }

    private func withProject<T>(_ project: Project, _ body: (Project) async throws -> T) async throws -> T {
        var resolved = project
        var access: SecurityScopedAccess?
        if let bookmark = project.bookmark {
            do {
                let result = try SecurityScopedBookmarks.resolve(bookmark)
                resolved.rootPath = result.url.path
                access = SecurityScopedAccess(url: result.url)
                if result.isStale {
                    do {
                        let refreshed = try SecurityScopedBookmarks.makeBookmark(for: result.url)
                        resolved.bookmark = refreshed
                        _ = try await database.updateProjectConfig(id: project.id) { updated in
                            updated.bookmark = refreshed
                            updated.accessState = .granted
                        }
                    } catch {
                        await logger.warning("刷新项目书签失败：\(error.localizedDescription)")
                        try await database.updateProjectRuntime(id: project.id, accessState: .stale)
                    }
                }
            } catch {
                await logger.error("项目书签无法解析：\(error.localizedDescription)")
                try await database.updateProjectRuntime(id: project.id, accessState: .stale)
                throw CodeTimeError.unauthorized(project.rootPath)
            }
        } else {
            let url = URL(fileURLWithPath: project.rootPath)
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                try await database.updateProjectRuntime(id: project.id, accessState: .denied)
                throw CodeTimeError.unauthorized(project.rootPath)
            }
        }
        defer { access?.stop() }
        return try await body(resolved)
    }

    private static func safeTargetURL(projectRoot: String, relativePath: String) throws -> URL {
        let root = URL(fileURLWithPath: projectRoot).standardizedFileURL
        let target = root.appendingPathComponent(relativePath).standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard target.path.hasPrefix(prefix) else {
            throw CodeTimeError.pathOutsideProject(relativePath)
        }
        let resolvedRoot = root.resolvingSymlinksInPath().path
        let resolvedTarget = target.resolvingSymlinksInPath().path
        let resolvedPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        guard resolvedTarget.hasPrefix(resolvedPrefix) else {
            throw CodeTimeError.pathOutsideProject(relativePath)
        }
        return target
    }

    private func recordActivity(_ event: ActivityEvent) async throws {
        try await database.appendActivity(event)
        switch event.level {
        case .error: await logger.error(event.message)
        case .warning: await logger.warning(event.message)
        default: await logger.info(event.message)
        }
        try? await database.trimActivities()
        notifyChange()
    }

    private func notifyChange() {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.codetime.changed"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}

/// CT-101: cooperative cancellation for long jobs that run in the caller's task
/// (cloud restore). Registered in the service's active-work table so a shutdown
/// can request the stop at the next phase boundary.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        if isCancelled { throw CodeTimeError.cancelled }
    }
}

private final class LeaseState: @unchecked Sendable {
    private let lock = NSLock()
    private var lost = false

    var isLost: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lost
    }

    func markLost() {
        lock.lock()
        lost = true
        lock.unlock()
    }
}
