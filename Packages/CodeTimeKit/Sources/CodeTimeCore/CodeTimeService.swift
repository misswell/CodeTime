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
    private var activeProjects: Set<UUID> = []
    private var backupGateClosed = false
    private var bootstrapReport: BootstrapReport?
    private var cachedSettings: AppSettings?

    private enum Keys {
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
        kopiaBinaryURL: URL? = nil
    ) throws {
        let paths = try paths ?? AppPaths.standard()
        try paths.createDirectories()
        self.paths = paths
        self.database = try SQLiteStore(path: paths.database.path)
        self.keychain = keychain
        self.logger = FileLogger(fileURL: paths.logs.appendingPathComponent("codetime.log"))
        self.gitInspector = GitInspector()
        self.kopiaBinaryURL = kopiaBinaryURL ?? KopiaBinary.locate()
    }

    // MARK: - Bootstrap

    @discardableResult
    public func bootstrap() async throws -> BootstrapReport {
        if let bootstrapReport { return bootstrapReport }

        var settings = try await currentSettings()
        let device = try await loadOrCreateDevice()
        let hadRepository = (try await database.codable(RepositoryRecord.self, forKey: Keys.repository)) != nil
        let repository = try await loadOrCreateRepository()
        self.device = device
        self.repository = repository
        // Never replace credentials when a repository already exists: an unreadable
        // Keychain item must send the user to recovery, not silently mint new keys.
        let secrets = try keychain.ensureSecrets(allowCreation: !hadRepository)
        if secrets.isNew {
            await logger.info("已创建新的应用密钥与恢复密钥")
        }

        let engine = try await currentEngine()
        try await engine.ensureRepository()
        let interrupted = try await database.recoverInterruptedJobs()
        let version = await KopiaBinary.version(at: engineBinaryURL())

        if interrupted > 0 {
            try await recordActivity(ActivityEvent(
                kind: .agent,
                level: .warning,
                message: "恢复了 \(interrupted) 个中断的备份任务并标记为未完成"
            ))
        }

        try await saveSettings(settings)

        let report = BootstrapReport(
            recoveryKeyText: secrets.isNew ? secrets.recoveryKeyText : nil,
            secretsWereCreated: secrets.isNew,
            device: device,
            repository: repository,
            kopiaVersion: version,
            recoveredInterruptedJobs: interrupted,
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
        if let stored = try await database.codable(DeviceIdentity.self, forKey: Keys.device) {
            return stored
        }
        let hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let device = DeviceIdentity(id: UUID(), name: hostName, model: Self.modelIdentifier())
        try await database.setCodable(device, forKey: Keys.device)
        return device
    }

    private func loadOrCreateRepository() async throws -> RepositoryRecord {
        if let stored = try await database.codable(RepositoryRecord.self, forKey: Keys.repository) {
            return stored
        }
        let id = UUID()
        let root = paths.repositories.appendingPathComponent(id.uuidString, isDirectory: true)
        let record = RepositoryRecord(
            id: id,
            path: root.appendingPathComponent("repo", isDirectory: true).path,
            configPath: root.appendingPathComponent("kopia.config").path
        )
        try await database.setCodable(record, forKey: Keys.repository)
        try await database.upsertRepository(record)
        return record
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

    public func currentSettings() async throws -> AppSettings {
        if let cachedSettings { return cachedSettings }
        if let stored = try await database.codable(AppSettings.self, forKey: Keys.settings) {
            cachedSettings = stored
            return stored
        }
        let defaults = AppSettings.default
        try await database.setCodable(defaults, forKey: Keys.settings)
        cachedSettings = defaults
        return defaults
    }

    public func saveSettings(_ settings: AppSettings) async throws {
        let previous = cachedSettings
        try await database.setCodable(settings, forKey: Keys.settings)
        cachedSettings = settings
        if previous?.performance != settings.performance {
            rebuildEngine()
        }
        notifyChange()
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
        let resolved = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CodeTimeError.repositoryUnavailable("请选择一个存在的目录")
        }
        let existing = try await database.projects()
        if existing.contains(where: { $0.rootPath == resolved.path }) {
            throw CodeTimeError.unsupported("该项目目录已在备份列表中")
        }

        let bookmark = try? SecurityScopedBookmarks.makeBookmark(for: resolved)
        let settings = try await currentSettings()
        let project = Project(
            name: name ?? resolved.lastPathComponent,
            rootPath: resolved.path,
            bookmark: bookmark,
            enabled: true,
            groupName: groupName
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

    public func updateProject(_ project: Project) async throws {
        try await database.upsertProject(project)
        notifyChange()
    }

    public func setProjectEnabled(_ id: UUID, enabled: Bool) async throws {
        guard var project = try await database.project(id: id) else { return }
        project.enabled = enabled
        project.status = enabled ? .idle : .paused
        try await database.upsertProject(project)
        notifyChange()
    }

    public func deleteProject(id: UUID) async throws {
        try await database.deleteProject(id: id)
        try await recordActivity(ActivityEvent(
            kind: .system,
            level: .warning,
            message: "已从列表移除项目（不会删除磁盘文件）"
        ))
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

    public func refreshSnapshots(projectID: UUID) async throws -> [Snapshot] {
        guard let project = try await database.project(id: projectID) else {
            throw CodeTimeError.repositoryUnavailable("项目不存在")
        }
        let cached = try await database.snapshots(projectID: projectID, limit: 1000)
        do {
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
                var updated = project
                if updated.lastSnapshotID != newest.id {
                    updated.lastSnapshotID = newest.id
                    updated.lastBackupAt = newest.createdAt
                    updated.status = (newest.cloudState == .synced || newest.cloudState == .localOnly)
                        ? .synced
                        : (newest.cloudState == .failed ? .warning : .idle)
                    try await database.upsertProject(updated)
                }
            }
            return merged.sorted { $0.createdAt > $1.createdAt }
        } catch {
            await logger.warning("刷新快照失败，使用本地缓存：\(error.localizedDescription)")
            return cached.sorted { $0.createdAt > $1.createdAt }
        }
    }

    @discardableResult
    public func createSnapshot(projectID: UUID, trigger: BackupTrigger) async throws -> BackupOutcome {
        guard var project = try await database.project(id: projectID) else {
            throw CodeTimeError.repositoryUnavailable("项目不存在")
        }
        guard let policy = try await database.policy(projectID: projectID) else {
            throw CodeTimeError.repositoryUnavailable("项目缺少备份策略")
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

        var job = BackupJob(projectID: projectID, type: .backup, state: .queued, trigger: trigger)
        try await database.upsertJob(job)
        job.state = .running
        job.startedAt = Date()
        try await database.upsertJob(job)

        project.status = .backingUp
        project.lastError = nil
        try await database.upsertProject(project)
        notifyChange()

        do {
            let engine = try await currentEngine()
            let snapshot = try await withProject(project) { resolved in
                try await engine.createSnapshot(project: resolved, policy: policy, trigger: trigger)
            }
            try await database.upsertSnapshot(snapshot)

            project.lastBackupAt = snapshot.createdAt
            project.lastSnapshotID = snapshot.id
            project.status = snapshot.status == .complete ? .idle : .warning
            try await database.upsertProject(project)

            job.state = .succeeded
            job.finishedAt = Date()
            try await database.upsertJob(job)

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
            if let refreshed = try await database.snapshot(id: snapshot.id) {
                project.status = (refreshed.cloudState == .synced || refreshed.cloudState == .localOnly)
                    ? .synced
                    : .warning
                try await database.upsertProject(project)
                notifyChange()
                return BackupOutcome(snapshot: refreshed, cloudError: cloudError)
            }
            notifyChange()
            return BackupOutcome(snapshot: snapshot, cloudError: cloudError)
        } catch {
            job.state = .failed
            job.finishedAt = Date()
            job.errorMessage = error.localizedDescription
            try await database.upsertJob(job)

            project.status = .error
            project.lastError = error.localizedDescription
            try await database.upsertProject(project)
            await logger.error("备份失败：\(error.localizedDescription)")
            try? await recordActivity(ActivityEvent(
                kind: .backup,
                level: .error,
                projectID: projectID,
                message: "\(project.name) 备份失败",
                details: error.localizedDescription
            ))
            notifyChange()
            throw error
        }
    }

    public func dueProjects(now: Date = Date()) async throws -> [Project] {
        let projects = try await database.projects()
        var due: [Project] = []
        for project in projects where project.enabled {
            guard !activeProjects.contains(project.id) else { continue }
            let storedInterval = try await database.policy(projectID: project.id)?.intervalMinutes
            let interval: Int
            if let storedInterval {
                interval = storedInterval
            } else {
                interval = try await currentSettings().globalIntervalMinutes
            }
            let last = project.lastBackupAt ?? .distantPast
            if now.timeIntervalSince(last) >= TimeInterval(max(1, interval) * 60) {
                due.append(project)
            }
        }
        return due
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

    public func searchFiles(snapshotID: String, query: String, limit: Int = 300) async throws -> [FileEntry] {
        let engine = try await currentEngine()
        return try await engine.searchFiles(snapshotID: snapshotID, query: query, limit: limit)
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

        var job = RestoreJob(
            projectID: request.projectID,
            snapshotID: request.snapshotID,
            relativePath: request.relativePath,
            mode: request.mode,
            targetPath: request.destination.path
        )
        try await database.upsertRestoreJob(job)

        if request.mode == .preview {
            job.status = .completed
            job.finishedAt = Date()
            try await database.upsertRestoreJob(job)
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
                        let backup = try Self.backupBeforeOverwrite(
                            target: target,
                            project: resolved,
                            recoveryRoot: paths.recovery
                        )
                        await logger.info("覆盖前已保护当前文件：\(backup.path)")
                    }
                    try await engine.restore(
                        snapshotID: request.snapshotID,
                        path: relativePath,
                        destination: target,
                        overwrite: true
                    )
                }
            case .copy, .wholeProject:
                let path = request.mode == .wholeProject ? nil : request.relativePath
                let destinationAccess = SecurityScopedAccess(url: request.destination)
                defer { destinationAccess.stop() }
                try await engine.restore(
                    snapshotID: request.snapshotID,
                    path: path,
                    destination: request.destination,
                    overwrite: false
                )
            }

            job.status = .completed
            job.finishedAt = Date()
            try await database.upsertRestoreJob(job)
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
            try await database.upsertRestoreJob(job)
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
            snapshot.verifiedAt = Date()
            snapshot.verificationLevel = .localRestore
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
        let generations = try await store.listGenerations(repositoryId: repository.id)
        guard let newest = generations.first else { return nil }
        var result = try await store.verifyGeneration(newest.id)
        result.projectID = nil
        try await database.insertVerification(result)
        var generation = newest
        generation.state = .verified
        generation.verifiedAt = Date()
        try await database.upsertGeneration(generation)
        try await recordActivity(ActivityEvent(
            kind: .verification,
            level: result.outcome == .passed ? .success : .error,
            message: "云端版本完整性校验\(result.outcome == .passed ? "通过" : "失败")",
            details: result.details
        ))
        return result
    }

    public func runPeriodicVerificationIfNeeded() async {
        do {
            let settings = try await currentSettings()
            guard settings.periodicVerificationDays > 0 else { return }
            let last = try await database.codable(Date.self, forKey: Keys.lastVerification) ?? .distantPast
            guard Date().timeIntervalSince(last) >= TimeInterval(settings.periodicVerificationDays * 86_400) else { return }
            if let result = try await verifyCloud(), result.outcome == .failed {
                await logger.error("周期云端校验失败：\(result.details)")
            }
            try await database.setCodable(Date(), forKey: Keys.lastVerification)
        } catch {
            await logger.warning("周期校验跳过：\(error.localizedDescription)")
        }
    }

    public func cleanupCloudIfNeeded() async {
        do {
            let settings = try await currentSettings()
            let last = try await database.codable(Date.self, forKey: Keys.lastCleanup) ?? .distantPast
            guard Date().timeIntervalSince(last) >= 86_400 else { return }
            _ = try await cleanupCloud()
            try await database.setCodable(Date(), forKey: Keys.lastCleanup)
        } catch {
            await logger.warning("周期清理跳过：\(error.localizedDescription)")
        }
    }

    @discardableResult
    public func cleanupCloud() async throws -> CloudCleanupReport? {
        let settings = try await currentSettings()
        guard let store = try await makeCloudStoreIfConfigured(settings: settings), let repository else {
            return nil
        }
        let report = try await store.cleanup(
            repositoryId: repository.id,
            gracePeriod: TimeInterval(settings.cloudGracePeriodDays * 86_400),
            minimumGenerations: settings.minimumCloudGenerations
        )
        try await recordActivity(ActivityEvent(
            kind: .cleanup,
            level: report.skippedReason == nil ? .success : .warning,
            message: report.skippedReason == nil
                ? "云端清理完成：删除 \(report.deletedObjects) 个对象，释放 \(CodeTimeFormat.bytes(report.freedBytes))"
                : "云端清理已暂停",
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
        return try await store.listGenerations(repositoryId: repository.id)
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
            var updatedSnapshot = snapshot
            updatedSnapshot.cloudState = .uploading
            updatedSnapshot.cloudGenerationID = generation.id
            try await database.upsertSnapshot(updatedSnapshot)
            if var project = try await database.project(id: snapshot.projectID) {
                project.status = .uploading
                try await database.upsertProject(project)
            }
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

            updatedSnapshot.cloudState = .synced
            try await database.upsertSnapshot(updatedSnapshot)
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
            await logger.error("云端同步失败：\(error.localizedDescription)")
            if var snapshotState = try? await database.snapshot(id: snapshot.id) {
                snapshotState.cloudState = .failed
                try? await database.upsertSnapshot(snapshotState)
            }
            if let generationID = activeGenerationID,
               var failedGeneration = try? await database.generation(id: generationID) {
                failedGeneration.state = .failed
                failedGeneration.errorMessage = error.localizedDescription
                try? await database.upsertGeneration(failedGeneration)
            }
            try? await recordActivity(ActivityEvent(
                kind: .upload,
                level: .error,
                projectID: snapshot.projectID,
                message: "云端同步失败，本地快照仍然有效",
                details: error.localizedDescription
            ))
            notifyChange()
            return error.localizedDescription
        }
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
            root = URL(fileURLWithPath: custom, isDirectory: true)
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
                .appendingPathComponent("repository.lock")
        ))
    }

    // MARK: - Disaster recovery

    public func recoverFromCloud(storageRoot: URL, recoveryKeyText: String) async throws -> CloudRecoveryResult {
        let key = try RecoveryKey.parse(recoveryKeyText)
        let recovered = try await CloudMirrorStore.recover(storageRoot: storageRoot, recoveryKey: key)
        guard try await database.snapshotCount() == 0 else {
            throw CodeTimeError.unsupported("本机已有备份数据，请在全新安装的 CodeTime 中执行云端恢复")
        }

        let repositoryRoot = paths.repositories.appendingPathComponent(recovered.repositoryID.uuidString, isDirectory: true)
        let repositoryURL = repositoryRoot.appendingPathComponent("repo", isDirectory: true)
        if FileManager.default.fileExists(atPath: repositoryURL.path) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: repositoryURL.path)) ?? []
            guard contents.isEmpty else {
                throw CodeTimeError.destinationExists(repositoryURL.path)
            }
        } else {
            try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        }

        // While recovering we must read from the publishing device's directory.
        // Future publishes from this Mac use its own device directory again.
        let store = CloudMirrorStore(configuration: .init(
            storageRoot: storageRoot,
            repositoryID: recovered.repositoryID,
            repositoryURL: repositoryURL,
            deviceID: recovered.deviceID,
            masterKeyProvider: StaticMasterKey(key: key),
            passwordProvider: StaticPassword(password: recovered.repositoryPassword),
            uploadTracker: NoopUploadTracker(),
            coordinatedIO: true
        ))
        let generations = try await store.listGenerations(repositoryId: recovered.repositoryID)
        guard let newest = generations.first else {
            throw CloudStoreError.notFound("没有可恢复的云端版本")
        }
        try await store.restoreRepository(generationId: newest.id, destination: repositoryURL)

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

        let engine = try await currentEngine()
        try await engine.ensureRepository()
        let sources = try await engine.snapshotSourcePaths()

        let verification = VerificationResult(
            generationID: newest.id,
            level: .crossDeviceRestore,
            outcome: .passed,
            details: "已从云端恢复仓库并重建 Kopia 仓库",
            bytesChecked: newest.byteSize
        )
        try await database.insertVerification(verification)
        try await recordActivity(ActivityEvent(
            kind: .restore,
            level: .success,
            message: "已从 iCloud 恢复备份仓库",
            details: "发现 \(sources.count) 个历史项目路径"
        ))
        try await database.setCodable(true, forKey: Keys.cloudRecoveryAttempted)
        return CloudRecoveryResult(
            repositoryID: recovered.repositoryID,
            generationID: newest.id,
            sourcePaths: sources,
            repositoryURL: repositoryURL
        )
    }

    // MARK: - Dashboard

    public func dashboard() async throws -> DashboardState {
        let settings = try await currentSettings()
        let projects = try await database.projects()
        let snapshots = try await database.snapshots(limit: 300)
        let count = try await database.snapshotCount()
        let activity = try await database.activities(limit: 80)
        let cloud = try? await cloudSummary()
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
        if let values = try? paths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage {
            let ok = available > 500 * 1024 * 1024
            checks.append(("磁盘空间", ok, CodeTimeFormat.bytes(available) + " 可用"))
        }
        return DiagnosticsReport(checks: checks.map { (name: $0.0, passed: $0.1, detail: $0.2) })
    }

    private var usageCache: (date: Date, bytes: Int64)?

    public func repositoryUsage() async -> Int64 {
        if let usageCache, Date().timeIntervalSince(usageCache.date) < 300 {
            return usageCache.bytes
        }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: paths.repositories, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        usageCache = (Date(), total)
        return total
    }

    // MARK: - Helpers

    private func withProject<T>(_ project: Project, _ body: (Project) async throws -> T) async throws -> T {
        var resolved = project
        var access: SecurityScopedAccess?
        if let bookmark = project.bookmark,
           let result = try? SecurityScopedBookmarks.resolve(bookmark) {
            resolved.rootPath = result.url.path
            access = SecurityScopedAccess(url: result.url)
            if result.isStale, let refreshed = try? SecurityScopedBookmarks.makeBookmark(for: result.url) {
                resolved.bookmark = refreshed
                try? await database.upsertProject(resolved)
            }
        } else {
            let url = URL(fileURLWithPath: project.rootPath)
            guard FileManager.default.isReadableFile(atPath: url.path) else {
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

    private static func backupBeforeOverwrite(target: URL, project: Project, recoveryRoot: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let relativePath = target.path.replacingOccurrences(of: project.rootPath + "/", with: "")
        let destination = recoveryRoot
            .appendingPathComponent(stamp, isDirectory: true)
            .appendingPathComponent(project.name, isDirectory: true)
            .appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: target, to: destination)
        return destination
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
