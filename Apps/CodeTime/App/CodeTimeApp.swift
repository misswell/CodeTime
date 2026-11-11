import SwiftUI
import AppKit
import SharedModels

@main
enum CodeTimeLauncher {
    static func main() {
        if CommandLine.arguments.contains("--icloud-selftest") {
            ICloudSelfTest.run()
        } else if CommandLine.arguments.contains("--agent") || ProcessInfo.processInfo.environment["CODETIME_AGENT_MODE"] == "1" {
            AgentRunner.run()
        } else {
            CodeTimeApp.main()
        }
    }
}

struct CodeTimeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environmentObject(model)
                .task { await model.start() }
                .frame(minWidth: 1080, minHeight: 700)
        }
        .defaultSize(width: 1200, height: 780)
        .commands {
            CodeTimeCommands(model: model)
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            Label("CodeTime", systemImage: "clock.arrow.circlepath")
        }
        .menuBarExtraStyle(.menu)
    }
}

struct CodeTimeCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("立即备份当前项目") {
                guard let id = model.selectedProjectID else { return }
                Task { await model.backupNow(projectID: id) }
            }
            .keyboardShortcut("b", modifiers: [.command])
            .disabled(model.selectedProjectID == nil || model.phase.isReady == false)
        }
        CommandMenu("视图") {
            ForEach(SidebarSection.allCases) { section in
                Button(section.title) {
                    model.selectedSection = section
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }
}

extension AppPhase {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .windowBackgroundColor),
                    CT.accent.opacity(0.035),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            switch model.phase {
            case .loading:
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("正在初始化 CodeTime")
                        .font(.headline)
                    Text("连接 Kopia 加密仓库、校验本地数据库与云端存储")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(CT.warning)
                    Text("CodeTime 无法启动")
                        .font(.title3.bold())
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                    Button("重试") {
                        Task { await model.retryStart() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .ready:
                if model.showOnboarding && !model.settings.hasCompletedOnboarding {
                    OnboardingView()
                } else {
                    MainWindowView()
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $model.restoreContext) { context in
            RestoreSheet(context: context)
                .environmentObject(model)
        }
        .sheet(item: $model.diffContext) { context in
            DiffViewerView(context: context)
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showProjectEditor) {
            if let project = model.editingProject {
                ProjectEditorView(project: project)
                    .environmentObject(model)
            }
        }
        .sheet(isPresented: $model.showRecoveryKey) {
            RecoveryKeySheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showCloudRecovery) {
            CloudRecoverySheet()
                .environmentObject(model)
        }
    }
}

struct MainWindowView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 238, max: 280)
        } detail: {
            Group {
                switch model.selectedSection {
                case .dashboard:
                    DashboardView()
                case .projects:
                    ProjectsView()
                case .timeline:
                    TimelineView()
                case .restores:
                    RestoreHistoryView()
                case .activity:
                    ActivityView()
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.35))
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.backupAll() }
                } label: {
                    Label("全部备份", systemImage: "arrow.clockwise")
                }
                .help("立即备份所有启用的项目")
                .disabled(model.projects.isEmpty)
            }
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [CT.accent, CT.mint], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 32, height: 32)
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("CodeTime")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("代码时间机器")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 10)

            List(selection: $model.selectedSection) {
                Section("工作区") {
                    ForEach(SidebarSection.allCases) { section in
                        Label(section.title, systemImage: section.symbol)
                            .tag(section)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            SidebarStatusView()
        }
        .background(.thinMaterial)
    }
}

struct SidebarStatusView: View {
    @EnvironmentObject var model: AppModel

    private var healthColor: Color {
        if model.projects.contains(where: { $0.status == .failed }) { return CT.danger }
        if model.projects.contains(where: { $0.status == .warning }) { return CT.warning }
        if model.projects.isEmpty { return .secondary }
        return CT.success
    }

    private var healthText: String {
        if model.projects.isEmpty { return "尚未添加项目" }
        if model.projects.contains(where: { $0.status == .failed }) { return "有项目备份失败" }
        if model.projects.contains(where: { $0.status == .warning }) { return "存在需要关注的项目" }
        return "运行正常"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            HStack(spacing: 7) {
                Circle().fill(healthColor).frame(width: 7, height: 7)
                Text(healthText)
                    .font(.caption.weight(.medium))
                Spacer()
            }
            HStack(spacing: 7) {
                Image(systemName: model.schedulerActive ? "bolt.horizontal.circle" : "pause.circle")
                    .font(.caption)
                    .foregroundStyle(model.schedulerActive ? CT.accent : .secondary)
                Text(model.schedulerActive ? "后台调度运行中" : "后台调度已暂停")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let cloud = model.cloudSummary {
                HStack(spacing: 7) {
                    Image(systemName: "icloud")
                        .font(.caption)
                        .foregroundStyle(CT.mint)
                    Text("\(cloud.generationCount) 个云端版本 · \(CodeTimeFormat.bytes(cloud.byteSize))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
    }
}

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Text(model.projects.isEmpty ? "尚未添加项目" : "\(model.projects.count) 个项目受保护")
            if let last = model.projects.compactMap(\.lastBackupAt).max() {
                Text("最近备份：\(CodeTimeFormat.relative(last))")
            }
            Divider()
            Button("打开 CodeTime") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("立即备份全部") {
                Task { await model.backupAll() }
            }
            .disabled(model.projects.isEmpty)
            Divider()
            if model.schedulerActive {
                Button("暂停自动备份") {
                    Task { await model.setSchedulerPaused(true) }
                }
            } else {
                Button("恢复自动备份") {
                    Task { await model.setSchedulerPaused(false) }
                }
            }
            Divider()
            Button("退出 CodeTime") {
                NSApp.terminate(nil)
            }
        }
    }
}
