import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SharedModels
import BackupEngine
import CodeTimeCore
import Diagnostics

enum SidebarSection: String, CaseIterable, Identifiable {
    case dashboard
    case projects
    case timeline
    case restores
    case activity
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "概览"
        case .projects: return "项目"
        case .timeline: return "时间机器"
        case .restores: return "恢复记录"
        case .activity: return "活动记录"
        case .settings: return "设置"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .projects: return "folder"
        case .timeline: return "clock.arrow.circlepath"
        case .restores: return "arrow.down.doc"
        case .activity: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }
}

enum AppPhase {
    case loading
    case ready
    case failed(String)
}

struct FilePreview: Identifiable {
    enum Kind {
        case text(String)
        case image(NSImage)
        case binary
        case error(String)
    }

    let id = UUID()
    var entry: FileEntry
    var snapshotID: String
    var kind: Kind
    var size: Int64
    var modifiedAt: Date?
    var isTruncated: Bool

    var lineCount: Int {
        if case .text(let value) = kind {
            return value.split(separator: "\n", omittingEmptySubsequences: false).count
        }
        return 0
    }
}

struct Toast: Identifiable, Equatable {
    enum Style: Equatable {
        case success
        case warning
        case error
        case info
    }

    let id = UUID()
    var message: String
    var style: Style
}

struct RestoreContext: Identifiable {
    let id = UUID()
    var project: Project
    var snapshotID: String
    var snapshotDate: Date
    var relativePath: String?
    var entryName: String
    var isDirectory: Bool
}

struct DiffContext: Identifiable {
    let id = UUID()
    var projectID: UUID
    var from: Snapshot
    var to: Snapshot
}

struct FileDiffResult {
    enum State {
        case text([DiffRow])
        case message(String)
    }

    var path: String
    var state: State
    var added: Int
    var removed: Int
}

@MainActor
final class AppModel: ObservableObject {
    @Published var phase: AppPhase = .loading
    @Published var bootstrap: BootstrapReport?
    @Published var settings: AppSettings = .default
    @Published var projects: [Project] = []
    @Published var snapshots: [Snapshot] = []
    @Published var allSnapshots: [Snapshot] = []
    @Published var totalSnapshotCount: Int = 0
    @Published var activity: [ActivityEvent] = []
    @Published var restoreJobs: [RestoreJob] = []
    @Published var cloudSummary: CloudStorageSummary?
    @Published var diagnostics = DiagnosticsReport()
    @Published var repositoryBytes: Int64?
    @Published var v3Storage: V3StorageStatus?
    @Published var migrationStatus: MigrationStatus?
    @Published var migrationEstimate: MigrationCapacityEstimate?

    @Published var selectedSection: SidebarSection = .dashboard
    @Published var selectedProjectID: UUID?
    @Published var selectedSnapshotID: String?
    @Published var entries: [FileEntry] = []
    @Published var currentPath: String = ""
    @Published var selectedEntryID: String?
    @Published var preview: FilePreview?
    @Published var searchText: String = ""
    @Published var globalSearchResults: [FileEntry]?
    @Published var isSearching = false

    @Published var isBusy = false
    @Published var busyLabel: String?
    @Published var activeProjectIDs: Set<UUID> = []
    @Published var toast: Toast?

    @Published var showOnboarding = false
    @Published var showProjectEditor = false
    @Published var editingProject: Project?
    @Published var restoreContext: RestoreContext?
    @Published var diffContext: DiffContext?
    @Published var showRecoveryKey = false
    @Published var showCloudRecovery = false
    @Published var secretRecoveryMode = false
    @Published var recoveryKeyText: String = ""
    @Published var recoveryCandidates: [RecoveryCandidate] = []
    @Published var v3RecoveryCandidates: [V3RecoveryProject] = []
    @Published var recoveryRestoreJob: CloudRestoreJob?
    @Published var recoveryImportNotice: String?
    @Published var schedulerActive = false
    @Published var snapshotLoadError: String?
    @Published var searchNotice: String?
    @Published var migrationNotice: String?
    /// Last cloud diagnostic line (shown in Settings → Advanced).
    @Published var cloudDiagnosticSummary: String = ""
    /// Shown when startup is waiting on an OS-level authorization.
    @Published var startupHint: String?

    @Published private(set) var service: CodeTimeService?

    // MARK: iCloud setup (CT-129/130/131)

    /// Live environment probe result. The UI NEVER infers iCloud capability from
    /// settings alone — this is the single source of truth.
    @Published private(set) var cloudSetup: CloudSetupStatus = .checking
    /// First-run backup progress (onboarding step 4).
    @Published var firstBackup: FirstBackupProgress = .idle

    struct FirstBackupProgress: Equatable {
        enum Phase: String, Equatable {
            case idle
            case initializing
            case snapshot
            case uploading
            case verifying
            case done
            case localDoneCloudFailed
        }
        var phase: Phase = .idle
        var detail: String = ""
        var projectCount: Int = 0
        var completedProjects: Int = 0
        var fileCount: Int = 0

        static let idle = FirstBackupProgress()
        var isRunning: Bool {
            [.initializing, .snapshot, .uploading, .verifying].contains(phase)
        }
        var isFinished: Bool {
            phase == .done || phase == .localDoneCloudFailed
        }
    }
    private var lifecycleLock: LifecycleLock?
    private var scheduler: BackupScheduler?
    private var started = false
    private var persistedSettings: AppSettings = .default
    private var refreshTask: Task<Void, Never>?
    private var saveSettingsTask: Task<Void, Never>?
    private var refreshDebounceTask: Task<Void, Never>?
    private var notifications: [NSObjectProtocol] = []

    deinit {
        refreshTask?.cancel()
        saveSettingsTask?.cancel()
        refreshDebounceTask?.cancel()
        for token in notifications {
            DistributedNotificationCenter.default().removeObserver(token)
        }
    }

    var currentProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    var selectedSnapshot: Snapshot? {
        snapshots.first { $0.id == selectedSnapshotID }
    }

    var previousSnapshot: Snapshot? {
        guard let index = snapshots.firstIndex(where: { $0.id == selectedSnapshotID }),
              index + 1 < snapshots.count else { return nil }
        return snapshots[index + 1]
    }

    var filteredEntries: [FileEntry] {
        guard !searchText.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var displayEntries: [FileEntry] {
        globalSearchResults ?? filteredEntries
    }

    var pathComponents: [String] {
        currentPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    var snapshotGroups: [(day: Date, snapshots: [Snapshot])] {
        let calendar = Calendar.current
        var groups: [(Date, [Snapshot])] = []
        for snapshot in snapshots {
            let day = calendar.startOfDay(for: snapshot.createdAt)
            if let index = groups.firstIndex(where: { $0.0 == day }) {
                groups[index].1.append(snapshot)
            } else {
                groups.append((day, [snapshot]))
            }
        }
        return groups.map { (day: $0.0, snapshots: $0.1) }
    }

    // MARK: - Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        phase = .loading
        do {
            let paths = try AppPaths.standard()
            try paths.createDirectories()
            // CT-072: The stable migration lock (outside the replaceable root)
            // blocks SQLite access while a whole-root swap is in progress.
            if FileManager.default.fileExists(atPath: paths.migrationLock.path) {
                let migrationLock = RepositoryLock(path: paths.migrationLock.path)
                if !migrationLock.tryAcquire() {
                    // Migration is actively running; wait for it.
                    for _ in 0..<120 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        if !FileManager.default.fileExists(atPath: paths.migrationLock.path) { break }
                    }
                } else {
                    migrationLock.release()
                }
            }
            if DataMigrator.hasPendingRequest(target: paths.root) {
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try DataMigrator.performPending(target: paths.root)
                    }.value
                    if let result {
                        migrationNotice = "已从 Beta 数据目录迁移 \(result.fileCount) 个文件（\(CodeTimeFormat.bytes(result.totalBytes))）。旧目录未删除。"
                    }
                } catch {
                    throw CodeTimeError.migrationFailed(error.localizedDescription)
                }
            }
            // CT-072: Acquire a shared lifecycle lock. Migration holds exclusive.
            let lifecycleLock = LifecycleLock(path: paths.lifecycleLockPath.path)
            if !lifecycleLock.tryAcquire(.shared) {
                // Migration holds the exclusive lock; wait for it to complete.
                var acquired = false
                for _ in 0..<120 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if lifecycleLock.tryAcquire(.shared) { acquired = true; break }
                }
                guard acquired else {
                    throw CodeTimeError.repositoryUnavailable("迁移占用生命周期锁超时")
                }
            }
            // CT-083: Hold the lock for the entire UI lifetime, not just start().
            // Release happens in deinit or explicit cleanup.
            self.lifecycleLock = lifecycleLock
            let service = try CodeTimeService()
            self.service = service
            // Keychain access can block indefinitely when macOS is showing an
            // authorization dialog (e.g. after the app's signature changed).
            // Never leave the user on a blank loading screen: bound the wait and
            // explain what to click. The bootstrap keeps running in the background.
            let report = try await Self.awaitBootstrap(service: service, timeout: 25) {
                self.startupHint = "macOS 正在请求钥匙串访问权限：请在弹出的系统对话框中点击「允许」（或「始终允许」）。"
            }
            bootstrap = report
            settings = report.settings
            persistedSettings = report.settings
            if let newKey = report.recoveryKeyText {
                recoveryKeyText = newKey
            } else {
                await refreshRecoveryKeyText()
            }
            projects = try await service.projects()
            await refreshAll(silent: true)
            showOnboarding = !settings.hasCompletedOnboarding
            phase = .ready
            await startScheduler()
            if settings.launchAgentEnabled {
                do {
                    try LaunchAgentManager.setEnabled(true)
                } catch {
                    showToast("后台代理启动失败：\(error.localizedDescription)", style: .warning)
                }
            }
            installObservers()
            startRefreshLoop()
            if let migrationNotice {
                showToast(migrationNotice, style: .success)
            }
        } catch {
            let message = error.localizedDescription
            if message.contains("master-key")
                || message.contains("repository-password")
                || message.contains("Keychain") {
                // A migrated repository can exist while the Beta Keychain item is
                // not readable by the Release signing identity. Do not dead-end:
                // offer the cloud recovery-key repair path.
                secretRecoveryMode = true
                showCloudRecovery = true
                phase = .failed(
                    "\(message)\n请使用恢复密钥从云端修复本机密钥；不会生成新密钥覆盖现有仓库。"
                )
            } else {
                phase = .failed(message)
            }
        }
    }

    /// Schedules a Beta data import for the next launch. Refuses when the current
    /// install already has projects, because merging two databases is not safe.
    func requestLegacyMigration(source: URL) async {
        guard let service else { return }
        do {
            let plan = try DataMigrator.inspect(
                source: source,
                target: service.paths.root,
                ignoreTargetConflicts: true
            )
            guard plan.hasDatabase || plan.repositoryCount > 0 else {
                showToast("所选目录没有 CodeTime 数据", style: .warning)
                return
            }
            let existingSnapshots = try await service.snapshots(limit: 1)
            if !projects.isEmpty || !existingSnapshots.isEmpty {
                showToast("当前已有项目或快照，不能合并另一份数据库；请在全新安装上执行迁移", style: .warning)
                return
            }
            try DataMigrator.requestMigration(
                source: source,
                target: service.paths.root,
                allowReplaceRoot: true
            )
            showToast("已记录迁移请求：请退出并重新打开 CodeTime 完成导入", style: .success)
        } catch {
            showToast("无法准备迁移：\(error.localizedDescription)", style: .error)
        }
    }

    func retryStart() async {
        started = false
        await start()
    }

    private func startScheduler() async {
        guard let service else { return }
        let scheduler = BackupScheduler(service: service, lockPath: service.paths.schedulerLock.path)
        self.scheduler = scheduler
        await scheduler.start(checkImmediately: settings.autoBackupOnLaunch)
        schedulerActive = settings.scheduler.allowsScheduling
    }

    func setSchedulerPaused(_ paused: Bool) async {
        // Persist the pause: the LaunchAgent reads the same row, so pausing in the
        // window must stop background snapshots too.
        settings.scheduler.globallyPaused = paused
        await persistSettings()
        schedulerActive = settings.scheduler.allowsScheduling
        guard let scheduler else { return }
        if paused || !settings.scheduler.allowsScheduling {
            await scheduler.stop()
        } else {
            await scheduler.start(checkImmediately: true)
        }
    }

    func setLocalMirror(_ url: URL?) async {
        guard let service else { return }
        do {
            let saved = try await service.setLocalMirror(url)
            settings = saved
            persistedSettings = saved
            schedulerActive = saved.scheduler.allowsScheduling
        } catch {
            showToast("本地镜像设置失败：\(error.localizedDescription)", style: .error)
        }
    }

    func setLaunchAgent(enabled: Bool) async {
        settings.launchAgentEnabled = enabled
        await persistSettings()
        do {
            try LaunchAgentManager.setEnabled(enabled)
            switch LaunchAgentManager.state {
            case .enabled:
                showToast("后台代理已启用", style: .success)
            case .requiresApproval:
                showToast("后台代理需要在“系统设置 › 通用 › 登录项”中允许", style: .warning)
            case .notFound, .notRegistered, .unknown:
                showToast(enabled ? "后台代理尚未注册，请重新打开 CodeTime" : "后台代理已关闭", style: enabled ? .warning : .success)
            }
        } catch {
            settings.launchAgentEnabled = LaunchAgentManager.state == .enabled
            await persistSettings()
            showToast("后台代理设置失败：\(error.localizedDescription)", style: .error)
        }
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if Task.isCancelled { break }
                await self?.refreshAll(silent: true)
            }
        }
    }

    /// Runs bootstrap with a bounded wait. The work continues in the background;
    /// `onSlowPath` fires once if it has not finished in time.
    private static func awaitBootstrap(
        service: CodeTimeService,
        timeout: TimeInterval,
        onSlowPath: @escaping @MainActor () -> Void
    ) async throws -> BootstrapReport {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var finished = false
            private var result: Result<BootstrapReport, Error>?
            func complete(_ result: Result<BootstrapReport, Error>) {
                lock.lock(); self.result = result; finished = true; lock.unlock()
            }
            var isFinished: Bool {
                lock.lock(); defer { lock.unlock() }; return finished
            }
            var value: Result<BootstrapReport, Error>? {
                lock.lock(); defer { lock.unlock() }; return result
            }
        }
        let box = Box()
        Task.detached(priority: .userInitiated) {
            do { box.complete(.success(try await service.bootstrap())) }
            catch { box.complete(.failure(error)) }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var warned = false
        while !box.isFinished && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !warned, !box.isFinished {
                await MainActor.run { onSlowPath() }
                warned = true
            }
        }
        guard let result = box.value else {
            throw CodeTimeError.repositoryUnavailable(
                "启动被系统授权阻塞：请在钥匙串访问对话框中点击「允许」后重新打开 CodeTime。"
            )
        }
        return try result.get()
    }

    private func installObservers() {
        // CT-129: iCloud account / Drive availability can change while the app
        // runs (sign-in, sign-out, Drive toggled). Re-probe instead of showing a
        // stale capability.
        let ubiquityToken = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshCloudSetup()
            }
        }
        notifications.append(ubiquityToken)

        let center = DistributedNotificationCenter.default()
        let token = center.addObserver(
            forName: NSNotification.Name("com.codetime.changed"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRefresh()
            }
        }
        notifications.append(token)

        let workspaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let scheduler = self.scheduler else { return }
                await scheduler.handleWake()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { await self.scheduler?.stop() }
        }
        notifications.append(workspaceToken)
    }

    private func scheduleRefresh() {
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshAll(silent: true)
        }
    }

    // MARK: - Refresh

    func refreshAll(silent: Bool = false) async {
        guard let service else { return }
        if !silent {
            isBusy = true
            busyLabel = "正在刷新…"
        }
        defer {
            if !silent {
                isBusy = false
                busyLabel = nil
            }
        }
        do {
            let dashboard = try await service.dashboard()
            projects = dashboard.projects
            allSnapshots = dashboard.snapshots
            totalSnapshotCount = dashboard.snapshotCount
            activity = dashboard.activity
            cloudSummary = dashboard.cloudSummary
            diagnostics = dashboard.diagnostics
            // Never clobber edits the user has not saved yet; the debounced save
            // merges them onto the latest revision once it lands.
            let hadLocalEdits = settings != persistedSettings
            persistedSettings = dashboard.settings
            if !hadLocalEdits {
                settings = dashboard.settings
            }
            do {
                restoreJobs = try await service.restoreJobs(limit: 80)
            } catch {
                if !silent { showToast("读取恢复任务失败：\(error.localizedDescription)", style: .warning) }
            }
            repositoryBytes = await service.repositoryUsage()
            v3Storage = await service.v3StorageStatus()
            if settings.engineMode == .cloudFirst {
                migrationStatus = await service.backupMigrationStatus()
            }
            migrationEstimate = await service.migrationCapacityEstimate()
            if selectedProjectID == nil, let first = projects.first {
                selectedProjectID = first.id
            }
        } catch {
            if !silent { showToast(error.localizedDescription, style: .error) }
        }
    }

    // MARK: - Projects

    /// Adds one or more directories (goal §3.2: batch selection).
    func addProject() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加项目"
        panel.message = "选择需要自动备份的代码目录（可多选）"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        await addProjects(urls: panel.urls)
    }

    /// Shared by the picker and the onboarding suggestion list. One invalid
    /// directory never aborts the rest, and the sum is reported honestly.
    func addProjects(urls: [URL]) async {
        guard let service, !urls.isEmpty else { return }
        var added: [Project] = []
        var failures: [String] = []
        for url in urls {
            do {
                let project = try await service.addProject(url: url)
                added.append(project)
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        await refreshAll(silent: true)
        if let last = added.last {
            selectedProjectID = last.id
            await loadWorkspace(projectID: last.id, switchSection: false)
        }
        if added.isEmpty {
            showToast(failures.first ?? "没有添加任何项目", style: .error)
        } else if failures.isEmpty {
            showToast(added.count == 1 ? "已添加 \(added[0].name)" : "已添加 \(added.count) 个项目", style: .success)
        } else {
            showToast("已添加 \(added.count) 个，\(failures.count) 个失败：\(failures[0])", style: .warning)
        }
    }

    /// Candidate project directories to SUGGEST in onboarding. Bounded depth and
    /// only well-known developer folders — never a whole-disk scan, and never a
    /// TCC-protected folder (CT-146: probing ~/Documents raised a privacy prompt
    /// the instant step 2 opened).
    func suggestedProjectDirectories() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = ProjectDiscovery.effectiveCandidates
        var result: [URL] = []
        for name in candidates {
            guard ProjectDiscovery.isAutoScannable(name) else { continue }
            let url = home.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: url.path) else { continue }
            result.append(contentsOf: gitRepositories(in: url, maxDepth: 2))
        }
        // Stable, de-duplicated, bounded list.
        var seen = Set<String>()
        return result.filter { seen.insert($0.standardizedFileURL.path).inserted }.prefix(12).map { $0 }
    }

    private func gitRepositories(in root: URL, maxDepth: Int) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        func walk(_ url: URL, depth: Int) {
            guard depth <= maxDepth, found.count < 40 else { return }
            if fm.fileExists(atPath: url.appendingPathComponent(".git").path) {
                found.append(url)
                return // a repo's subdirectories are part of it
            }
            guard let children = try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { return }
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return found
    }

    func editProject(_ project: Project) {
        editingProject = project
        showProjectEditor = true
    }

    func toggleProject(_ project: Project, enabled: Bool) async {
        do {
            try await service?.setProjectEnabled(project.id, enabled: enabled)
            await refreshAll(silent: true)
        } catch {
            showToast(error.localizedDescription, style: .error)
        }
    }

    func deleteProject(_ project: Project) async {
        do {
            try await service?.deleteProject(id: project.id)
            if selectedProjectID == project.id {
                selectedProjectID = projects.first(where: { $0.id != project.id })?.id
                snapshots = []
                entries = []
                preview = nil
            }
            await refreshAll(silent: true)
            showToast("已移除项目 \(project.name)", style: .info)
        } catch {
            showToast(error.localizedDescription, style: .error)
        }
    }

    func policy(for projectID: UUID) async throws -> BackupPolicy? {
        try await service?.policy(projectID: projectID)
    }

    func saveProject(_ project: Project, policy: BackupPolicy) async {
        do {
            try await service?.updateProject(project)
            try await service?.updatePolicy(policy)
            showProjectEditor = false
            editingProject = nil
            await refreshAll(silent: true)
            if selectedProjectID == project.id {
                await refreshSnapshots()
            }
            showToast("项目设置已保存", style: .success)
        } catch {
            showToast(error.localizedDescription, style: .error)
        }
    }

    func exclusionPreview(project: Project, policy: BackupPolicy) async -> ExclusionPreview? {
        guard let service else { return nil }
        let url = URL(fileURLWithPath: project.rootPath)
        return await service.exclusionPreview(
            directory: url,
            rules: policy.excludeRules,
            includeEnvFiles: policy.includeEnvFiles,
            includeGitDirectory: policy.includeGitDirectory
        )
    }

    // MARK: - iCloud setup

    /// True when the CURRENT binary carries the iCloud entitlement. Beta/Debug
    /// builds return false, so their UI must disable iCloud instead of pretending.
    var buildSupportsICloud: Bool {
        CloudSetupService.processHasICloudEntitlement()
    }

    /// Current storage target derived from settings (never cleared implicitly).
    var backupDestination: BackupDestination {
        BackupDestination.derived(
            iCloudEnabled: settings.iCloudEnabled,
            localMirrorPath: settings.localMirrorPath,
            localMirrorAccessState: settings.localMirrorAccessState
        )
    }

    /// Re-runs the full environment probe. Safe to call at any time.
    func refreshCloudSetup() async {
        guard let service else { return }
        if !buildSupportsICloud {
            cloudSetup = .unsupported
            return
        }
        cloudSetup = .checking
        cloudSetup = await service.cloudSetupStatus()
        cloudDiagnosticSummary = cloudSetup.detail
    }

    // MARK: - Storage (v3)

    func refreshStorageStatus() async {
        guard let service else { return }
        v3Storage = await service.v3StorageStatus()
        migrationStatus = await service.backupMigrationStatus()
        migrationEstimate = await service.migrationCapacityEstimate()
    }

    /// Clears only rebuildable download data; un-uploaded objects are never here.
    func clearDownloadCache() async {
        guard let service else { return }
        guard let report = await service.clearDownloadCache() else {
            showToast("当前引擎没有可清理的下载缓存", style: .info)
            return
        }
        if let reason = report.skippedReason {
            showToast(reason, style: .warning)
        } else {
            showToast("已释放 \(CodeTimeFormat.bytes(report.freedBytes)) 下载缓存", style: .success)
        }
        await refreshStorageStatus()
    }

    func applyCachePreset(_ preset: AppSettings.CachePreset, customBytes: Int64? = nil) async {
        guard let service else { return }
        do {
            settings = try await service.applyCachePreset(preset, customBytes: customBytes)
            persistedSettings = settings
            await refreshStorageStatus()
            showToast("缓存策略已更新为 \(preset.displayName)", style: .success)
        } catch {
            showToast(error.localizedDescription, style: .error)
        }
    }

    func resumePendingUploads() async {
        guard let service else { return }
        guard let report = await service.resumeV3Uploads() else {
            showToast("当前没有待上传队列", style: .info)
            return
        }
        if report.failed > 0 || report.skippedRetryExhausted > 0 {
            showToast(
                "上传仍未完成：\(report.failed) 个失败、\(report.skippedRetryExhausted) 个重试耗尽；数据仍在待上传目录",
                style: .warning
            )
        } else {
            showToast("待上传数据已全部确认上传", style: .success)
        }
        await refreshStorageStatus()
    }

    /// Runs the v2→v3 migration. Releasing the old local repository is a separate
    /// explicit decision; without it the baseline is still verified and v3 becomes
    /// the active engine.
    func runMigration(releaseLegacyLocalSpace: Bool = false) async {
        guard let service else { return }
        isBusy = true
        busyLabel = "正在迁移旧备份…"
        defer { isBusy = false; busyLabel = nil }
        let status = await service.runBackupMigration(releaseLegacyLocalSpace: releaseLegacyLocalSpace)
        migrationStatus = status
        settings = await (try? service.currentSettings()) ?? settings
        persistedSettings = settings
        switch status.phase {
        case .complete:
            showToast("迁移完成", style: .success)
        case .legacyLocalCleanupPending:
            showToast("基线已验证。旧本地仓库仍占用空间，可选择释放", style: .info)
        case .blocked:
            showToast("迁移已暂停：\(status.detail)", style: .warning)
        default:
            showToast(status.detail, style: .info)
        }
        await refreshAll(silent: true)
    }

    /// One-tap enable. Verifies the target BEFORE persisting anything; on failure
    /// the existing configuration and every existing backup stay untouched.
    @discardableResult
    func enableICloudBackup() async -> Bool {
        guard let service else { return false }
        do {
            _ = try await service.configureStorage(.iCloud)
            settings = try await service.currentSettings()
            cloudSetup = await service.cloudSetupStatus()
            showToast("已启用 iCloud 备份", style: .success)
            await refreshAll(silent: true)
            return true
        } catch {
            // Keep the previous storage target; only surface the reason.
            cloudSetup = await service.cloudSetupStatus()
            showToast(error.localizedDescription, style: .warning)
            return false
        }
    }

    /// Turns off iCloud mirroring; local snapshots, cloud objects and the local
    /// mirror path are all preserved.
    func disableICloudBackup() async {
        guard let service else { return }
        do {
            try await service.disableICloudBackup()
            settings = try await service.currentSettings()
            await refreshAll(silent: true)
        } catch {
            showToast(error.localizedDescription, style: .error)
        }
    }

    /// Opens the exact System Settings pane for iCloud Drive.
    func openICloudSystemSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings",
            "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
        showToast("请打开 系统设置 → Apple 账户 → iCloud", style: .info)
    }

    /// CT-131: the first REAL backup. Each phase reflects actual service state;
    /// "已上传到 iCloud" is only reached when the manifest is published and
    /// confirmed (outcome.snapshot.cloudState == .synced).
    func runFirstBackup() async {
        guard let service else { return }
        let targets = projects.filter(\.enabled)
        firstBackup = FirstBackupProgress(
            phase: .initializing,
            detail: "正在初始化本地备份仓库…",
            projectCount: targets.count,
            completedProjects: 0,
            fileCount: 0
        )
        var files = 0
        var cloudFailure: String?
        for (index, project) in targets.enumerated() {
            firstBackup.phase = .snapshot
            firstBackup.detail = "正在备份 \(project.name)…"
            do {
                let outcome = try await service.createSnapshot(projectID: project.id, trigger: .manual)
                files += outcome.snapshot.fileCount
                firstBackup.fileCount = files
                firstBackup.completedProjects = index + 1
                if let cloudError = outcome.cloudError {
                    cloudFailure = cloudError
                }
            } catch {
                // A failed project must not lose the ones that succeeded.
                cloudFailure = cloudFailure ?? error.localizedDescription
            }
        }
        await refreshAll(silent: true)

        let anySynced = projects.contains { $0.lastCloudState == .synced }
        if settings.iCloudEnabled {
            if anySynced && cloudFailure == nil {
                firstBackup.phase = .verifying
                firstBackup.detail = "正在确认云端版本…"
                firstBackup.phase = .done
                firstBackup.detail = "首次备份已完成，并已上传到 iCloud。"
            } else {
                firstBackup.phase = .localDoneCloudFailed
                firstBackup.detail = "本地备份已完成；iCloud 同步失败：\(cloudFailure ?? "请稍后重试")"
            }
        } else {
            firstBackup.phase = .done
            firstBackup.detail = "首次本地备份已完成。可在设置中随时启用 iCloud。"
        }
    }

    /// Retries the cloud publish for every project that has an unsynced snapshot.
    func retryCloudSyncNow() async {
        guard let service else { return }
        do {
            try await service.retryPendingCloudPublishes()
            await refreshAll(silent: true)
            showToast("已重新安排云端同步", style: .info)
        } catch {
            showToast(error.localizedDescription, style: .error)
        }
    }

    // MARK: - Backup

    func backupNow(projectID: UUID, trigger: BackupTrigger = .manual) async {
        guard !activeProjectIDs.contains(projectID) else { return }
        activeProjectIDs.insert(projectID)
        defer { activeProjectIDs.remove(projectID) }
        do {
            guard let outcome = try await service?.createSnapshot(projectID: projectID, trigger: trigger) else { return }
            await refreshAll(silent: true)
            if selectedProjectID == projectID, selectedSection == .timeline {
                await refreshSnapshots(selectNewest: true)
            }
            if let cloudError = outcome.cloudError {
                showToast("本地备份完成，但云端同步失败：\(cloudError)", style: .warning)
            } else {
                showToast("备份完成 · \(outcome.snapshot.fileCount) 个文件", style: .success)
            }
        } catch {
            if let code = error as? CodeTimeError, case .backupAlreadyRunning = code {
                // A scheduled (or other-process) backup is running: not an error,
                // and its completion will refresh the UI.
                showToast("正在备份中，完成后会自动更新", style: .info)
                await refreshAll(silent: true)
            } else {
                showToast(error.localizedDescription, style: .error)
            }
        }
    }

    func backupAll() async {
        for project in projects where project.enabled {
            await backupNow(projectID: project.id)
        }
    }

    // MARK: - Timeline workspace

    func loadWorkspace(projectID: UUID, switchSection: Bool = true) async {
        if selectedProjectID != projectID {
            snapshots = []
            selectedSnapshotID = nil
            entries = []
            selectedEntryID = nil
            preview = nil
            searchText = ""
            globalSearchResults = nil
            currentPath = ""
        }
        selectedProjectID = projectID
        if switchSection { selectedSection = .timeline }
        isBusy = true
        busyLabel = "正在载入快照…"
        defer {
            isBusy = false
            busyLabel = nil
        }
        await refreshSnapshots(selectNewest: true)
    }

    func refreshSnapshots(selectNewest: Bool = false) async {
        guard let projectID = selectedProjectID else { return }
        let result = await service?.snapshotQuery(projectID: projectID) ?? .success([])
        // Discard results for a project the user already switched away from.
        guard selectedProjectID == projectID else { return }
        snapshotLoadError = result.failureMessage
        let fresh = result.snapshotsOrEmpty.sorted { $0.createdAt > $1.createdAt }
        snapshots = fresh
        if selectNewest || selectedSnapshotID == nil || !fresh.contains(where: { $0.id == selectedSnapshotID }) {
            selectedSnapshotID = fresh.first?.id
        }
        await reloadDirectory()
    }

    func selectSnapshot(_ id: String) async {
        selectedSnapshotID = id
        globalSearchResults = nil
        await reloadDirectory()
    }

    func reloadDirectory() async {
        guard let snapshotID = selectedSnapshotID else {
            entries = []
            preview = nil
            return
        }
        do {
            entries = try await service?.listDirectory(snapshotID: snapshotID, path: currentPath) ?? []
            selectedEntryID = nil
            preview = nil
        } catch {
            if !currentPath.isEmpty {
                currentPath = ""
                await reloadDirectory()
            } else {
                showToast(error.localizedDescription, style: .error)
            }
        }
    }

    func navigate(to path: String) async {
        currentPath = path
        globalSearchResults = nil
        await reloadDirectory()
    }

    func searchAllFiles() async {
        guard let snapshotID = selectedSnapshotID,
              !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            globalSearchResults = nil
            searchNotice = nil
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            let result = try await service?.searchFiles(
                snapshotID: snapshotID,
                query: searchText.trimmingCharacters(in: .whitespaces)
            )
            globalSearchResults = result?.entries ?? []
            if let result {
                var notes: [String] = []
                if result.truncated {
                    notes.append(result.truncationReason ?? "结果数量已达上限，仅显示部分匹配")
                }
                if !result.failedDirectories.isEmpty {
                    notes.append("\(result.failedDirectories.count) 个目录无法读取")
                }
                searchNotice = notes.isEmpty ? nil : notes.joined(separator: "；")
            } else {
                searchNotice = nil
            }
        } catch {
            globalSearchResults = []
            searchNotice = nil
            showToast(error.localizedDescription, style: .error)
        }
    }

    func clearSearch() {
        searchText = ""
        globalSearchResults = nil
        searchNotice = nil
    }

    func goUp() async {
        guard !currentPath.isEmpty else { return }
        let components = pathComponents.dropLast()
        await navigate(to: components.joined(separator: "/"))
    }

    func open(_ entry: FileEntry) async {
        if entry.isDirectory {
            await navigate(to: entry.path)
        } else {
            await preview(entry)
        }
    }

    func preview(_ entry: FileEntry) async {
        guard let snapshotID = selectedSnapshotID else { return }
        selectedEntryID = entry.id
        do {
            let data = try await service?.readFile(snapshotID: snapshotID, path: entry.path, maxBytes: 2 * 1024 * 1024) ?? Data()
            preview = makePreview(entry: entry, snapshotID: snapshotID, data: data)
        } catch {
            preview = FilePreview(
                entry: entry,
                snapshotID: snapshotID,
                kind: .error(error.localizedDescription),
                size: entry.size,
                modifiedAt: entry.modifiedAt,
                isTruncated: false
            )
        }
    }

    private func makePreview(entry: FileEntry, snapshotID: String, data: Data) -> FilePreview {
        let ext = (entry.name as NSString).pathExtension.lowercased()
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "bmp", "webp", "ico"]
        if imageExtensions.contains(ext), let image = NSImage(data: data) {
            return FilePreview(entry: entry, snapshotID: snapshotID, kind: .image(image), size: entry.size, modifiedAt: entry.modifiedAt, isTruncated: false)
        }
        let binaryHint = ext == "pdf" || ext == "zip" || ext == "gz" || ext == "png" || ext == "jpg" || ext == "sqlite"
        if let text = String(data: data, encoding: .utf8), !text.isEmpty, !binaryHint, !text.contains("\0") {
            let truncated = data.count >= 2 * 1024 * 1024
            return FilePreview(entry: entry, snapshotID: snapshotID, kind: .text(text), size: entry.size, modifiedAt: entry.modifiedAt, isTruncated: truncated)
        }
        return FilePreview(entry: entry, snapshotID: snapshotID, kind: .binary, size: entry.size, modifiedAt: entry.modifiedAt, isTruncated: false)
    }

    // MARK: - Diff

    func diffCurrentSnapshot() {
        guard let projectID = selectedProjectID,
              let current = selectedSnapshot,
              let older = previousSnapshot else {
            showToast("没有更早的快照可供比较", style: .warning)
            return
        }
        diffContext = DiffContext(projectID: projectID, from: older, to: current)
    }

    func snapshotDiff(_ context: DiffContext) async throws -> SnapshotDiff {
        guard let service else { throw CodeTimeError.repositoryUnavailable("服务尚未就绪") }
        return try await service.diff(projectID: context.projectID, from: context.from.id, to: context.to.id)
    }

    func fileDiff(context: DiffContext, path: String) async -> FileDiffResult {
        guard let service else {
            return FileDiffResult(path: path, state: .message("服务尚未就绪"), added: 0, removed: 0)
        }
        var fromData: Data?
        var toData: Data?
        var readErrors: [String] = []
        do {
            fromData = try await service.readFile(snapshotID: context.from.id, path: path, maxBytes: 4 * 1024 * 1024)
        } catch {
            readErrors.append("旧版本：\(error.localizedDescription)")
        }
        do {
            toData = try await service.readFile(snapshotID: context.to.id, path: path, maxBytes: 4 * 1024 * 1024)
        } catch {
            readErrors.append("新版本：\(error.localizedDescription)")
        }
        let fromText = fromData.flatMap { String(data: $0, encoding: .utf8) }
        let toText = toData.flatMap { String(data: $0, encoding: .utf8) }
        if fromText == nil, toText == nil {
            return FileDiffResult(
                path: path,
                state: .message(readErrors.isEmpty ? "二进制文件或无法解码的文本" : readErrors.joined(separator: "；")),
                added: 0,
                removed: 0
            )
        }
        if (fromData?.count ?? 0) >= 4 * 1024 * 1024 || (toData?.count ?? 0) >= 4 * 1024 * 1024 {
            return FileDiffResult(path: path, state: .message("文件超过 4 MB，无法在应用内完整比较"), added: 0, removed: 0)
        }
        let old = fromText ?? ""
        let new = toText ?? ""
        if old.components(separatedBy: .newlines).count > 1500 || new.components(separatedBy: .newlines).count > 1500 {
            return FileDiffResult(path: path, state: .message("文件超过 1500 行，无法在应用内并排比较"), added: 0, removed: 0)
        }
        let rows = LineDiff.rows(from: old, to: new)
        let added = rows.filter { $0.right?.kind == .added }.count
        let removed = rows.filter { $0.left?.kind == .removed }.count
        return FileDiffResult(path: path, state: .text(rows), added: added, removed: removed)
    }

    // MARK: - Restore

    func beginRestore(entry: FileEntry?) {
        guard let project = currentProject,
              let snapshot = selectedSnapshot else {
            showToast("请先选择项目和快照", style: .warning)
            return
        }
        let context = RestoreContext(
            project: project,
            snapshotID: snapshot.id,
            snapshotDate: snapshot.createdAt,
            relativePath: entry?.isDirectory == true ? nil : entry?.path,
            entryName: entry?.name ?? project.name,
            isDirectory: entry?.isDirectory ?? false
        )
        restoreContext = context
    }

    func beginWholeProjectRestore() {
        guard let project = currentProject, let snapshot = selectedSnapshot else { return }
        restoreContext = RestoreContext(
            project: project,
            snapshotID: snapshot.id,
            snapshotDate: snapshot.createdAt,
            relativePath: nil,
            entryName: project.name,
            isDirectory: true
        )
    }

    func performRestore(context: RestoreContext, mode: RestoreMode, destination: URL) async -> String? {
        guard let service else { return "服务尚未就绪" }
        do {
            let request = RestoreRequest(
                projectID: context.project.id,
                snapshotID: context.snapshotID,
                relativePath: context.relativePath,
                mode: mode,
                destination: destination
            )
            _ = try await service.restore(request)
            restoreContext = nil
            restoreJobs = (try? await service.restoreJobs(limit: 80)) ?? restoreJobs
            await refreshAll(silent: true)
            showToast("恢复完成", style: .success)
            return nil
        } catch {
            showToast(error.localizedDescription, style: .error)
            return error.localizedDescription
        }
    }

    // MARK: - Verification & cloud

    func verifySelectedSnapshot() async {
        guard let projectID = selectedProjectID, let snapshotID = selectedSnapshotID else { return }
        isBusy = true
        busyLabel = "正在校验快照…"
        defer {
            isBusy = false
            busyLabel = nil
        }
        do {
            let result = try await service?.verifySnapshot(projectID: projectID, snapshotID: snapshotID)
            if result?.outcome == .passed {
                showToast("快照校验通过", style: .success)
            } else {
                showToast(result?.details ?? "校验失败", style: .error)
            }
            await refreshAll(silent: true)
        } catch {
            showToast(error.localizedDescription, style: .error)
        }
    }

    func verifyCloud() async {
        isBusy = true
        busyLabel = "正在校验云端版本…"
        defer {
            isBusy = false
            busyLabel = nil
        }
        do {
            let result = try await service?.verifyCloud()
            if let result {
                showToast(result.outcome == .passed ? "云端校验通过" : result.details, style: result.outcome == .passed ? .success : .error)
            } else {
                showToast("云端镜像未启用", style: .info)
            }
            await refreshAll(silent: true)
        } catch {
            showToast(error.localizedDescription, style: .error)
        }
    }

    /// CT-105: default is a read-only PREVIEW. Physical deletion requires an
    /// explicit user confirmation (the settings button asks first).
    func cleanupCloud(allowPhysicalDelete: Bool = false) async {
        do {
            let report = try await service?.cleanupCloud(allowPhysicalDelete: allowPhysicalDelete)
            if let report {
                if report.deletedObjects > 0 {
                    showToast("已清理 \(report.deletedObjects) 个对象", style: .success)
                } else if report.plannedDeletes > 0 {
                    showToast(
                        "可清理 \(report.plannedDeletes) 个对象（\(report.plannedGenerationDeletes) 个历史版本）；安全策略下未执行删除",
                        style: .warning
                    )
                } else if let reason = report.skippedReason {
                    showToast("清理已暂停：\(reason)", style: .warning)
                } else {
                    showToast("没有需要清理的对象", style: .success)
                }
            }
            await refreshAll(silent: true)
        } catch {
            showToast(error.localizedDescription, style: .error)
        }
    }

    func loadRecoveryCandidates(storageRoot: URL, recoveryKey: String) async throws -> [RecoveryCandidate] {
        guard let service else { throw CodeTimeError.repositoryUnavailable("服务尚未就绪") }
        let key = recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CodeTimeError.unsupported("请先输入恢复密钥") }
        recoveryImportNotice = nil
        let candidates = try await service.cloudRecoveryCandidates(storageRoot: storageRoot, recoveryKeyText: key)
        recoveryCandidates = candidates
        // v3 projects are discovered independently and merged into the same sheet.
        v3RecoveryCandidates = (try? await service.v3RecoveryCandidates(
            storageRoot: storageRoot,
            recoveryKeyText: key
        )) ?? []
        return candidates
    }

    /// §9.5: restore one v3 project on this Mac. The whole project is restored
    /// from cloud chunks and registered locally; no Kopia repository is involved.
    @discardableResult
    func recoverV3Project(
        candidate: V3RecoveryProject,
        storageRoot: URL,
        recoveryKey: String,
        destination: URL
    ) async throws -> UUID {
        guard let service else { throw CodeTimeError.repositoryUnavailable("服务尚未就绪") }
        let key = recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CodeTimeError.unsupported("请先输入恢复密钥") }
        let projectID = try await service.recoverV3Project(
            storageRoot: storageRoot,
            recoveryKeyText: key,
            candidate: candidate,
            destination: destination
        )
        await refreshAll(silent: true)
        return projectID
    }

    /// Restores the chosen candidate. A previous failed attempt is resumed
    /// automatically by the service (verified objects are never re-downloaded).
    func recoverFromCloud(candidate: RecoveryCandidate, storageRoot: URL, recoveryKey: String) async throws -> Int {
        guard let service else { throw CodeTimeError.repositoryUnavailable("服务尚未就绪") }
        recoveryImportNotice = nil
        recoveryRestoreJob = nil
        let result = try await service.recoverFromCloud(
            candidate: candidate,
            storageRoot: storageRoot,
            recoveryKeyText: recoveryKey,
            progress: { [weak self] job in
                Task { @MainActor [weak self] in
                    self?.recoveryRestoreJob = job
                }
            }
        )
        recoveryRestoreJob = nil

        var imported = 0
        var failures: [String] = []
        for path in result.sourcePaths {
            do {
                _ = try await service.addRecoveredProject(sourcePath: path)
                imported += 1
            } catch {
                failures.append("\(path)：\(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            recoveryImportNotice = "有 \(failures.count) 个历史项目未能自动登记："
                + failures.joined(separator: "\n")
        }
        await refreshAll(silent: true)
        showToast(
            "云端仓库恢复完成，已登记 \(imported) 个项目；路径缺失的项目仍可浏览与整项目恢复",
            style: failures.isEmpty ? .success : .warning
        )
        return imported
    }

    func installSecretsFromCloud(storageRoot: URL, recoveryKey: String) async throws {
        guard let service else { throw CodeTimeError.repositoryUnavailable("服务尚未就绪") }
        try await service.installSecretsFromCloud(
            storageRoot: storageRoot,
            recoveryKeyText: recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        secretRecoveryMode = false
        await retryStart()
    }

    func latestRecoveryRestoreJob() async throws -> CloudRestoreJob? {
        guard let service else { return nil }
        return try await service.latestCloudRestoreJob()
    }

    // MARK: - Settings

    func settingsChanged() {
        saveSettingsTask?.cancel()
        saveSettingsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.persistSettings()
            await self.refreshAll(silent: true)
        }
    }

    /// Saves the local settings. If another process bumped `configRevision` first,
    /// the user's changed fields are re-applied on top of the latest revision
    /// instead of being silently discarded or overwriting the other change.
    private func persistSettings() async {
        guard let service else { return }
        do {
            let saved = try await service.saveSettings(settings)
            settings = saved
            persistedSettings = saved
        } catch {
            do {
                let latest = try await service.currentSettings()
                let merged = try mergeSettings(local: settings, base: persistedSettings, latest: latest)
                let saved = try await service.saveSettings(merged)
                settings = saved
                persistedSettings = saved
            } catch {
                showToast("设置保存失败：\(error.localizedDescription)", style: .error)
            }
        }
    }

    private func mergeSettings(local: AppSettings, base: AppSettings, latest: AppSettings) throws -> AppSettings {
        let encoder = JSONEncoder()
        guard let baseObject = try JSONSerialization.jsonObject(with: encoder.encode(base)) as? [String: Any],
              let localObject = try JSONSerialization.jsonObject(with: encoder.encode(local)) as? [String: Any],
              var latestObject = try JSONSerialization.jsonObject(with: encoder.encode(latest)) as? [String: Any] else {
            return latest
        }
        for (key, localValue) in localObject where !jsonEqual(baseObject[key], localValue) {
            latestObject[key] = localValue
        }
        let data = try JSONSerialization.data(withJSONObject: latestObject)
        return try JSONDecoder().decode(AppSettings.self, from: data)
    }

    private func jsonEqual(_ lhs: Any?, _ rhs: Any) -> Bool {
        guard let lhs, let rhsObject = rhs as? NSObject else { return false }
        return (lhs as? NSObject)?.isEqual(rhsObject) ?? false
    }

    func completeOnboarding() async {
        do {
            try await service?.completeOnboarding()
            settings.hasCompletedOnboarding = true
            showOnboarding = false
            await refreshAll(silent: true)
        } catch {
            showToast(error.localizedDescription, style: .error)
        }
    }

    func loadRecoveryKey() async {
        await refreshRecoveryKeyText()
        showRecoveryKey = true
    }

    func refreshRecoveryKeyText() async {
        guard let service else { return }
        if let text = try? await service.takeRecoveryKeyText() {
            recoveryKeyText = text
        }
    }

    func copyRecoveryKey() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recoveryKeyText, forType: .string)
        showToast("恢复密钥已复制，请离线保存", style: .success)
    }

    // MARK: - Toast

    func showToast(_ message: String, style: Toast.Style) {
        let toast = Toast(message: message, style: style)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            self.toast = toast
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard let self, self.toast?.id == toast.id else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                self.toast = nil
            }
        }
    }
}
