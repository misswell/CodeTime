import SwiftUI
import AppKit
import SharedModels
import Diagnostics

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "设置", subtitle: "云端、加密、性能与诊断")
                .padding(.horizontal, CT.pagePadding)
                .padding(.top, CT.pagePadding)
                .padding(.bottom, 12)

            TabView(selection: $tab) {
                GeneralSettingsView()
                    .tabItem { Label("通用", systemImage: "gearshape") }
                    .tag(0)
                CloudSettingsView()
                    .tabItem { Label("云端", systemImage: "icloud") }
                    .tag(1)
                SecuritySettingsView()
                    .tabItem { Label("安全", systemImage: "lock.shield") }
                    .tag(2)
                PerformanceSettingsView()
                    .tabItem { Label("性能", systemImage: "speedometer") }
                    .tag(3)
                DiagnosticsSettingsView()
                    .tabItem { Label("诊断", systemImage: "stethoscope") }
                    .tag(4)
            }
            .padding(.horizontal, CT.pagePadding)
            .padding(.bottom, CT.pagePadding)
        }
    }
}

private struct SettingsCard<Content: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        CTCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                content
            }
        }
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsCard(title: "自动备份", subtitle: "后台调度使用“下次应执行时间 + 串行任务”，不会在唤醒后反复补跑。") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("新项目默认频率")
                            Text("添加项目时可单独修改。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: binding(\.globalIntervalMinutes)) {
                            ForEach([15, 30, 60, 120, 240, 480], id: \.self) { minutes in
                                Text(CodeTimeFormat.interval(minutes)).tag(minutes)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                    Divider()
                    Toggle("启动 CodeTime 后检查是否需要补跑", isOn: binding(\.autoBackupOnLaunch))
                    Toggle("使用后台代理（LaunchAgent）", isOn: Binding(
                        get: { model.settings.launchAgentEnabled },
                        set: { value in
                            model.settings.launchAgentEnabled = value
                            model.settingsChanged()
                            model.setLaunchAgent(enabled: value)
                        }
                    ))
                    Text("代理与主应用通过文件锁选主，同一时刻只有一个进程创建快照。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsCard(title: "校验与诊断") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("周期校验")
                            Text("对最新的云端版本执行完整性校验。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Stepper(value: binding(\.periodicVerificationDays), in: 0...90) {
                            Text(model.settings.periodicVerificationDays == 0 ? "关闭" : "每 \(model.settings.periodicVerificationDays) 天")
                                .font(.callout)
                                .frame(width: 90, alignment: .trailing)
                        }
                    }
                    Toggle("在排除编辑器中显示文件预览", isOn: binding(\.showExcludedPreview))
                }

                SettingsCard(title: "关于") {
                    HStack {
                        Label("CodeTime 1.0", systemImage: "clock.arrow.circlepath")
                        Spacer()
                    }
                    if let version = model.bootstrap?.kopiaVersion {
                        Text("Kopia：\(version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let repository = model.bootstrap?.repository {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("本机仓库 ID")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(repository.id.uuidString)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 10)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { model.settings[keyPath: keyPath] = $0; model.settingsChanged() }
        )
    }
}

private struct CloudSettingsView: View {
    @EnvironmentObject var model: AppModel

    private var cloudCheck: (passed: Bool, detail: String)? {
        model.diagnostics.checks.first { $0.name == "iCloud 容器" || $0.name == "本地镜像" }
            .map { ($0.passed, $0.detail) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsCard(title: "iCloud Drive", subtitle: "使用原生 iCloud Documents 容器同步 CodeTime Cloud Format v1。") {
                    Toggle("启用 iCloud 备份镜像", isOn: Binding(
                        get: { model.settings.iCloudEnabled },
                        set: { value in
                            model.settings.iCloudEnabled = value
                            if value { model.settings.localMirrorPath = nil }
                            model.settingsChanged()
                        }
                    ))
                    if let cloudCheck {
                        HStack(spacing: 7) {
                            Image(systemName: cloudCheck.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(cloudCheck.passed ? CT.success : CT.warning)
                            Text(cloudCheck.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Text("云端目录：iCloud Drive/CodeTime。不可变对象先上传，加密版本清单最后发布。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsCard(title: "本地镜像", subtitle: "没有 iCloud 容器时仍可完整验证云端格式与恢复流程。") {
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(model.settings.localMirrorPath ?? "未选择")
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("选择…") { chooseMirror() }
                            .controlSize(.small)
                        if model.settings.localMirrorPath != nil {
                            Button("清除") {
                                model.settings.localMirrorPath = nil
                                model.settingsChanged()
                            }
                            .controlSize(.small)
                        }
                    }
                    Text("选择本地镜像会关闭 iCloud，用于开发与灾难恢复演练。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsCard(title: "云端容量与保留", subtitle: "云端对象不可变；清理采用引用检查 + 宽限期，且至少保留两代。") {
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(CodeTimeFormat.bytes(model.cloudSummary?.byteSize ?? 0))
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                            Text("\(model.cloudSummary?.objectCount ?? 0) 个不可变对象")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(model.cloudSummary?.generationCount ?? 0)")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                            Text("已发布版本")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Divider()
                    HStack {
                        Stepper(value: binding(\.cloudGracePeriodDays), in: 1...365) {
                            Text("清理宽限期：\(model.settings.cloudGracePeriodDays) 天")
                                .font(.callout)
                                .frame(width: 160, alignment: .trailing)
                        }
                    }
                    HStack {
                        Stepper(value: binding(\.minimumCloudGenerations), in: 2...20) {
                            Text("至少保留：\(model.settings.minimumCloudGenerations) 代")
                                .font(.callout)
                                .frame(width: 160, alignment: .trailing)
                        }
                    }
                    HStack(spacing: 10) {
                        Button("校验云端版本") {
                            Task { await model.verifyCloud() }
                        }
                        .buttonStyle(.bordered)
                        Button("立即清理") {
                            Task { await model.cleanupCloud() }
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Button("从云端恢复…") {
                            model.showCloudRecovery = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 10)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { model.settings[keyPath: keyPath] = $0; model.settingsChanged() }
        )
    }

    private func chooseMirror() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "使用此目录"
        panel.message = "选择一个本地镜像目录（建议为空目录）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.localMirrorPath = url.path
        model.settings.iCloudEnabled = false
        model.settingsChanged()
    }
}

private struct SecuritySettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsCard(title: "恢复密钥", subtitle: "恢复密钥等同于云端备份的最高访问凭据，请离线保存。") {
                    HStack {
                        Image(systemName: "key.horizontal.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(CT.warning)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("在全新 Mac 上，只需要恢复密钥与 iCloud 中的 CodeTime 目录即可重建仓库。")
                                .font(.callout)
                            Text("恢复密钥保存在本机 Keychain；云端清单使用独立派生的 AES-256-GCM 密钥。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("查看恢复密钥") {
                            Task { await model.loadRecoveryKey() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                SettingsCard(title: "加密模型") {
                    SecurityFact(symbol: "lock.fill", title: "内容加密", detail: "Kopia 使用 AES-256-GCM 加密仓库内容，CodeTime 不替换其算法。")
                    SecurityFact(symbol: "key.fill", title: "密钥派生", detail: "云端清单密钥通过 HKDF-SHA256 从恢复密钥与独立 Salt 派生。")
                    SecurityFact(symbol: "checkmark.seal.fill", title: "清单认证", detail: "清单 AAD 绑定仓库 ID 与版本 ID，无法跨版本重放。")
                    SecurityFact(symbol: "externaldrive.badge.checkmark", title: "本地凭据", detail: "Kopia 仓库密码与恢复密钥存入 macOS Keychain（AfterFirstUnlock）。")
                }

                SettingsCard(title: "安全边界", subtitle: "请确认理解以下限制。") {
                    Text("如果恢复密钥丢失，且本机 Keychain 也不可用，CodeTime 无法找回 Kopia 仓库密码与备份内容。")
                        .font(.callout)
                        .foregroundStyle(CT.warning)
                    Text("iCloud 报告“已上传”只代表同步完成的信号，不等于异机恢复一定成功；CodeTime 需要额外的完整性校验与恢复演练。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 10)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct SecurityFact: View {
    var symbol: String
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(CT.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct PerformanceSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsCard(title: "性能模式", subtitle: "并发数只是设计目标，实际吞吐仍取决于磁盘与网络。") {
                    Picker("", selection: binding(\.performance)) {
                        ForEach(PerformanceProfile.allCases, id: \.self) { profile in
                            Text(profile.displayName).tag(profile)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    HStack(spacing: 18) {
                        PerformanceStat(title: "备份读取并发", value: "\(model.settings.performance.backupParallelism)")
                        PerformanceStat(title: "云端上传并发", value: "\(model.settings.performance.uploadParallelism)")
                        PerformanceStat(title: "开发时干扰", value: model.settings.performance == .eco ? "最低" : (model.settings.performance == .balanced ? "较低" : "较高"))
                    }
                    Toggle("低电量模式下暂停自动备份", isOn: binding(\.pauseOnBattery))
                    Text("节能模式适合笔记本电池供电时使用；FSEvents 变更会合并并防抖，不会每次写入都触发完整扫描。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsCard(title: "本地仓库") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("完整数据副本")
                            Text("本地 Kopia 仓库占用 \(CodeTimeFormat.bytes(model.repositoryBytes))，不能视为零本地占用的云备份。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 10)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { model.settings[keyPath: keyPath] = $0; model.settingsChanged() }
        )
    }
}

private struct PerformanceStat: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
    }
}

private struct DiagnosticsSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsCard(title: "系统检查") {
                    ForEach(model.diagnostics.checks, id: \.name) { check in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: check.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(check.passed ? CT.success : CT.warning)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(check.name)
                                    .font(.callout.weight(.medium))
                                Text(check.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                        }
                    }
                }

                SettingsCard(title: "维护操作") {
                    HStack(spacing: 10) {
                        Button("校验当前快照") {
                            Task { await model.verifySelectedSnapshot() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.selectedSnapshotID == nil)
                        Button("校验云端") {
                            Task { await model.verifyCloud() }
                        }
                        .buttonStyle(.bordered)
                        Button("清理云端") {
                            Task { await model.cleanupCloud() }
                        }
                        .buttonStyle(.bordered)
                        Button("打开日志目录") {
                            if let url = model.service?.paths.logs {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("校验会读取并验证快照对象；云端清理仅在保留版本引用完整时执行。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsCard(title: "路径") {
                    if let service = model.service {
                        PathRow(title: "应用数据", path: service.paths.root.path)
                        PathRow(title: "任务数据库", path: service.paths.database.path)
                        PathRow(title: "备份仓库", path: model.bootstrap?.repository.path)
                    }
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 10)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct PathRow: View {
    var title: String
    var path: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(path ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
        }
    }
}
