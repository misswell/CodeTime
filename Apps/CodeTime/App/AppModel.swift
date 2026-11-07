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
    @Published var recoveryRestoreJob: CloudRestoreJob?
    @Published var recoveryImportNotice: String?
    @Published var schedulerActive = false
    @Published var snapshotLoadError: String?
    @Published var searchNotice: String?
    @Published var migrationNotice: String?

    @Published private(set) var service: CodeTimeService?
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
            let service = try CodeTimeService()
            self.service = service
            let report = try await service.bootstrap()
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

    private func installObservers() {
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
            if selectedProjectID == nil, let first = projects.first {
                selectedProjectID = first.id
            }
        } catch {
            if !silent { showToast(error.localizedDescription, style: .error) }
        }
    }

    // MARK: - Projects

    func addProject() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加项目"
        panel.message = "选择需要自动备份的代码目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let project = try await service?.addProject(url: url)
            await refreshAll(silent: true)
            if let project {
                selectedProjectID = project.id
                await loadWorkspace(projectID: project.id, switchSection: false)
                showToast("已添加 \(project.name)", style: .success)
            }
        } catch {
            showToast(error.localizedDescription, style: .error)
        }
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
            showToast(error.localizedDescription, style: .error)
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

    func cleanupCloud() async {
        do {
            let report = try await service?.cleanupCloud()
            if let report {
                if let reason = report.skippedReason {
                    showToast("清理已暂停：\(reason)", style: .warning)
                } else {
                    showToast("已清理 \(report.deletedObjects) 个对象", style: .success)
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
        return candidates
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
