import SwiftUI
import AppKit
import SharedModels
import CodeTimeCore

/// CT-133: the zero-configuration first-run wizard.
///
/// 保护你的代码项目 → 选择存储位置（自动检测 iCloud）→ 选择项目 → 保存恢复密钥
/// → 首次备份（真实执行，本地与云端状态分开）。
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel

    private enum Step: Int, CaseIterable {
        case storage, projects, recoveryKey, firstBackup
    }

    @State private var step: Step = .storage
    @State private var acknowledged = false
    @State private var isWorking = false
    @State private var storageError: String?
    @State private var refreshTick = 0

    private var key: String { model.recoveryKeyText }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [CT.accent.opacity(0.14), Color(nsColor: .windowBackgroundColor), CT.mint.opacity(0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider()
                Group {
                    switch step {
                    case .storage: storageStep
                    case .projects: projectsStep
                    case .recoveryKey: recoveryStep
                    case .firstBackup: firstBackupStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                footer
            }
            .frame(width: 760, height: 700)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 14)
        }
        .onAppear {
            if key.isEmpty {
                Task { await ensureKey() }
            }
            Task { await model.refreshCloudSetup() }
        }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [CT.accent, CT.mint], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 36, height: 36)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("CodeTime")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text("macOS 原生代码时间机器")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { item in
                    Capsule()
                        .fill(item == step ? CT.accent : Color.secondary.opacity(0.2))
                        .frame(width: item == step ? 22 : 7, height: 7)
                        .animation(.spring(response: 0.3), value: step)
                }
            }
        }
        .padding(22)
    }

    private var footer: some View {
        HStack {
            if step.rawValue > 0, !isWorking {
                Button("上一步") { step = Step(rawValue: step.rawValue - 1) ?? .storage }
            }
            Spacer()
            if isWorking {
                ProgressView().controlSize(.small)
            }
            Button(primaryTitle) {
                Task { await advance() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(primaryDisabled)
        }
        .padding(20)
    }

    private var primaryTitle: String {
        switch step {
        case .storage: return "继续"
        case .projects: return "继续"
        case .recoveryKey: return "继续"
        case .firstBackup: return model.firstBackup.isFinished ? "进入 CodeTime" : "首次备份进行中…"
        }
    }

    private var primaryDisabled: Bool {
        if isWorking { return true }
        switch step {
        case .storage:
            return model.cloudSetup.isChecking
        case .projects:
            return model.projects.isEmpty
        case .recoveryKey:
            return !key.isEmpty && !acknowledged
        case .firstBackup:
            return !model.firstBackup.isFinished
        }
    }

    // MARK: Step 1 — storage

    private var storageStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("保护你的代码项目")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("CodeTime 自动保存项目历史版本，即使误删文件、改错代码或更换 Mac，也能找回之前的版本。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.cloudSetup.isChecking {
                    CTCard(padding: 16) {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("正在检测 iCloud…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    iCloudCard
                }

                CTCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "internaldrive")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(CT.accent)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(CT.accent.opacity(0.12)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("仅使用本机备份")
                                    .font(.callout.weight(.semibold))
                                Text("加密备份保存在这台 Mac 上，之后可以随时切换到云端。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("使用本机") {
                                Task { await chooseLocalOnly() }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isWorking)
                        }
                    }
                }

                if let storageError {
                    Text(storageError)
                        .font(.caption)
                        .foregroundStyle(CT.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 16) {
                    OnboardingFeature(symbol: "camera", title: "自动快照", detail: "按计划创建，不依赖 Git 提交")
                    OnboardingFeature(symbol: "clock.arrow.circlepath", title: "时间机器", detail: "浏览任意时间点的文件内容")
                    OnboardingFeature(symbol: "icloud", title: "云端灾难恢复", detail: "换机后凭恢复密钥重建仓库")
                }
            }
            .padding(28)
        }
    }

    @ViewBuilder
    private var iCloudCard: some View {
        let status = model.cloudSetup
        CTCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(status.isReady ? CT.accent : .secondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill((status.isReady ? CT.accent : Color.secondary).opacity(0.12)))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("iCloud 云端备份")
                                .font(.callout.weight(.semibold))
                            Text("推荐")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(CT.accent.opacity(0.14)))
                                .foregroundStyle(CT.accent)
                        }
                        Text(status.isReady ? (status.storageRoot?.path ?? "iCloud Drive / CodeTime") : status.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if status.isReady {
                        Button("启用 iCloud 备份") {
                            Task { await chooseICloud() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking)
                    }
                }

                if !status.isReady {
                    if !status.passedChecks.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(status.passedChecks, id: \.self) { check in
                                Label(check, systemImage: "checkmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(CT.success)
                            }
                            Label(status.title, systemImage: "exclamationmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(CT.warning)
                        }
                    }
                    Text(status.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button("重新检测") {
                            Task { await model.refreshCloudSetup() }
                        }
                        .controlSize(.small)
                        if status.requiresSystemSettings {
                            Button("打开系统设置") { model.openICloudSystemSettings() }
                                .controlSize(.small)
                        }
                        Text("系统设置 → Apple 账户 → iCloud → iCloud Drive")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("备份位置与目录会自动创建，加密后才同步；无需手动选择文件夹。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Step 2 — projects

    @State private var suggested: [URL] = []
    @State private var selectedSuggestions: Set<String> = []

    private var projectsStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("选择要保护的代码项目")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("只读取你选择的目录，不会修改 Git 工作区，也不会要求提交代码。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !suggested.isEmpty {
                    CTCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("在这台 Mac 上发现的项目")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(suggested, id: \.self) { url in
                                let selected = selectedSuggestions.contains(url.path)
                                let added = model.projects.contains { $0.rootPath == url.path }
                                Button {
                                    if selected { selectedSuggestions.remove(url.path) }
                                    else { selectedSuggestions.insert(url.path) }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: added ? "checkmark.circle.fill"
                                              : (selected ? "checkmark.square.fill" : "square"))
                                            .foregroundStyle(added ? CT.success : (selected ? CT.accent : .secondary))
                                        Text(url.lastPathComponent)
                                            .font(.callout)
                                        Text(url.path)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        if added {
                                            Text("已添加").font(.caption2).foregroundStyle(CT.success)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(added)
                            }
                            if !selectedSuggestions.isEmpty {
                                Button("添加选中的 \(selectedSuggestions.count) 个项目") {
                                    let urls = suggested.filter { selectedSuggestions.contains($0.path) }
                                    Task {
                                        await model.addProjects(urls: urls)
                                        selectedSuggestions.removeAll()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                    }
                }

                CTCard(padding: 16) {
                    VStack(spacing: 10) {
                        if model.projects.isEmpty {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 30, weight: .light))
                                .foregroundStyle(.secondary)
                            Text("还没有添加项目")
                                .font(.callout.weight(.medium))
                        }
                        Button("选择文件夹…（可多选）") {
                            Task { await model.addProject() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, model.projects.isEmpty ? 22 : 6)
                }

                if !model.projects.isEmpty {
                    CTCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(model.projects) { project in
                                HStack(spacing: 10) {
                                    Image(systemName: "folder.fill").foregroundStyle(CT.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(project.name).font(.callout.weight(.semibold))
                                        Text(project.rootPath)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer()
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(CT.success)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                if project.id != model.projects.last?.id { Divider() }
                            }
                        }
                    }
                }

                Text("默认排除 node_modules、构建产物、缓存、日志与 .env 等敏感文件；可在项目设置中查看与调整排除规则。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
        }
        .onAppear {
            if suggested.isEmpty {
                suggested = model.suggestedProjectDirectories()
            }
        }
    }

    // MARK: Step 3 — recovery key

    private var recoveryStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("保存备份恢复密钥")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("恢复密钥用于在新的 Mac 上恢复加密备份。建议保存到密码管理器；它不会自动上传到 iCloud。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                CTCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("恢复密钥", systemImage: "key.horizontal.fill")
                                .font(.callout.weight(.semibold))
                            Spacer()
                            Button {
                                if model.recoveryKeyText.isEmpty { model.recoveryKeyText = key }
                                model.copyRecoveryKey()
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        Text(key.isEmpty ? "无法读取恢复密钥" : key)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
                        Text("丢失它且本机 Keychain 凭据不可用时，云端备份将无法解密。")
                            .font(.caption)
                            .foregroundStyle(CT.warning)
                    }
                }

                Button {
                    acknowledged.toggle()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: acknowledged ? "checkmark.square.fill" : "square")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(acknowledged ? CT.accent : Color.secondary)
                        Text("我已将恢复密钥保存到安全的位置")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(acknowledged ? CT.accent.opacity(0.10) : Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(acknowledged ? CT.accent.opacity(0.55) : Color.primary.opacity(0.10))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if !acknowledged {
                    Text("勾选确认后才能继续（按钮在窗口右下角）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(28)
        }
    }

    // MARK: Step 4 — first backup

    private var firstBackupStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("首次备份")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(model.settings.iCloudEnabled
                         ? "先创建本地加密快照，再上传到 iCloud。只有上传确认并发布版本清单后才算云端完成。"
                         : "创建本地加密快照。之后可在设置中随时启用 iCloud 备份。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                CTCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        progressRow(
                            "本地加密备份",
                            done: model.firstBackup.phase == .done || model.firstBackup.phase == .localDoneCloudFailed,
                            active: model.firstBackup.phase == .initializing || model.firstBackup.phase == .snapshot
                        )
                        if model.settings.iCloudEnabled {
                            progressRow(
                                "上传到 iCloud 并发布版本",
                                done: model.firstBackup.phase == .done,
                                active: model.firstBackup.phase == .uploading || model.firstBackup.phase == .verifying
                            )
                        }
                        if !model.firstBackup.detail.isEmpty {
                            Text(model.firstBackup.detail)
                                .font(.caption)
                                .foregroundStyle(model.firstBackup.phase == .localDoneCloudFailed ? CT.warning : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if model.firstBackup.phase == .localDoneCloudFailed {
                    Button("重新同步 iCloud") {
                        Task { await model.retryCloudSyncNow() }
                    }
                    .buttonStyle(.bordered)
                }

                if !model.firstBackup.isRunning && model.firstBackup.phase == .idle {
                    Button("开始首次备份") {
                        Task { await model.runFirstBackup() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(28)
        }
        .onAppear {
            if model.firstBackup.phase == .idle {
                Task { await model.runFirstBackup() }
            }
        }
    }

    private func progressRow(_ title: String, done: Bool, active: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(CT.success)
                } else if active {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 18)
            Text(title)
                .font(.callout)
                .foregroundStyle(done ? .primary : .secondary)
            Spacer()
        }
    }

    // MARK: Actions

    private func chooseICloud() async {
        isWorking = true
        storageError = nil
        defer { isWorking = false }
        let ok = await model.enableICloudBackup()
        if ok {
            step = .projects
        } else {
            storageError = "iCloud 未启用：\(model.cloudSetup.detail)"
        }
    }

    private func chooseLocalOnly() async {
        isWorking = true
        storageError = nil
        defer { isWorking = false }
        if model.settings.iCloudEnabled {
            await model.disableICloudBackup()
        }
        step = .projects
    }

    private func advance() async {
        switch step {
        case .storage:
            // "继续" without an explicit choice prefers iCloud when it is ready.
            if model.cloudSetup.isReady && !model.settings.iCloudEnabled {
                await chooseICloud()
            } else {
                step = .projects
            }
        case .projects:
            guard !model.projects.isEmpty else { return }
            step = .recoveryKey
        case .recoveryKey:
            guard acknowledged || key.isEmpty else { return }
            step = .firstBackup
        case .firstBackup:
            guard model.firstBackup.isFinished else { return }
            await model.completeOnboarding()
        }
    }

    private func ensureKey() async {
        await model.refreshRecoveryKeyText()
    }
}

private struct OnboardingFeature: View {
    var symbol: String
    var title: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(CT.accent)
                .frame(width: 28, height: 28)
                .background(Circle().fill(CT.accent.opacity(0.12)))
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
    }
}

struct RecoveryKeySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Label("恢复密钥", systemImage: "key.horizontal.fill")
                    .font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Text(model.recoveryKeyText.isEmpty ? "无法读取恢复密钥" : model.recoveryKeyText)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            Text("恢复密钥可以解密云端版本清单，并取回 Kopia 仓库密码。请离线保存，不要保存在同一台 Mac 上。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("复制恢复密钥") {
                    model.copyRecoveryKey()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 560)
        .task {
            if model.recoveryKeyText.isEmpty {
                await model.refreshRecoveryKeyText()
            }
        }
    }
}

struct CloudRecoverySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var storageRoot: URL?
    @State private var isDetecting = false
    @State private var detectMessage = ""
    @State private var didAutoDetect = false
    @State private var isScanning = false
    @State private var hasScanned = false
    @State private var selectedCandidateID: UUID?
    @State private var isRestoring = false
    @State private var restoreAttempts = 0
    @State private var errorMessage: String?

    private var selectedCandidate: RecoveryCandidate? {
        model.recoveryCandidates.first { $0.id == selectedCandidateID }
    }

    private var canScan: Bool {
        storageRoot != nil && !key.trimmingCharacters(in: .whitespaces).isEmpty && !isRestoring
    }

    private var canRestore: Bool {
        guard let selectedCandidate, selectedCandidate.isRestorable, storageRoot != nil, !isRestoring else {
            return false
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("从云端恢复仓库")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("用于 Mac 损坏、重装或更换设备后的灾难恢复。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isRestoring)
            }

            CTCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("iCloud 备份位置")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if isDetecting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: storageRoot == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(storageRoot == nil ? CT.warning : CT.success)
                        }
                        Text(storageRoot?.path
                             ?? (detectMessage.isEmpty ? "正在查找 iCloud 备份…" : detectMessage))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(storageRoot == nil ? .secondary : .primary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Spacer()
                        Button("重新检测") { Task { await autoDetectStorage() } }
                            .controlSize(.small)
                            .disabled(isRestoring)
                    }
                    HStack(spacing: 8) {
                        Text("CodeTime 会自动使用 iCloud Drive / CodeTime，无需手动选择文件夹。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("选择其他目录…") { chooseStorageRoot() }
                            .controlSize(.small)
                            .buttonStyle(.link)
                            .disabled(isRestoring)
                    }
                }
            }

            CTCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("恢复密钥")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("CT1-XXXXX-XXXXX-…", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .disabled(isRestoring)
                    Text("恢复后会从云端重建 Kopia 仓库，并自动发现历史项目路径。已有的本地备份数据不会被覆盖。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if hasScanned || isScanning {
                candidateSection
            }

            if let job = model.recoveryRestoreJob {
                restoreProgressCard(job)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(CT.danger)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(CT.danger.opacity(0.08)))
            }

            if let notice = model.recoveryImportNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(CT.warning)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(CT.warning.opacity(0.10)))
            }

            HStack {
                if isScanning {
                    ProgressView().controlSize(.small)
                    Text("正在读取云端版本清单…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !hasScanned {
                    Button("查找可恢复备份") { scan() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canScan)
                } else {
                    Button(restoreAttempts > 0 ? "重试恢复（续传已验证对象）" : "恢复所选备份") {
                        restore()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRestore)
                }
            }
        }
        .padding(22)
        .frame(width: 640)
        .onAppear {
            guard !didAutoDetect else { return }
            didAutoDetect = true
            Task { await autoDetectStorage() }
        }
    }

    @ViewBuilder
    private var candidateSection: some View {
        CTCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("可恢复备份")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if hasScanned {
                        Button("重新查找") { scan() }
                            .controlSize(.small)
                            .disabled(isRestoring || !canScan)
                    }
                }

                if isScanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在解密并校验各设备版本…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if model.recoveryCandidates.isEmpty {
                    Text("没有找到能用此恢复密钥解密的备份。请确认目录与密钥来自同一账号。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(model.recoveryCandidates) { candidate in
                                candidateRow(candidate)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }

                Text("恢复始终选择一份历史版本；对象在恢复时会逐个校验 SHA-256，不会混用不同设备的数据。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func candidateRow(_ candidate: RecoveryCandidate) -> some View {
        let isSelected = candidate.id == selectedCandidateID
        return Button {
            selectedCandidateID = candidate.id
            errorMessage = nil
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? CT.accent : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(candidate.deviceName.isEmpty ? "未命名设备" : candidate.deviceName)
                            .font(.system(size: 12.5, weight: .semibold))
                        if candidate.integrityOK {
                            Label("清单与对象齐全", systemImage: "checkmark.seal.fill")
                                .font(.caption2)
                                .foregroundStyle(CT.success)
                        } else {
                            Label("候选不完整", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(CT.warning)
                        }
                    }
                    Text(candidateSubtitle(candidate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let blocked = candidate.blockedReason {
                        Text(blocked)
                            .font(.caption2)
                            .foregroundStyle(CT.danger)
                    }
                }
                Spacer()
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? CT.accent.opacity(0.10) : Color.primary.opacity(0.03))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(isRestoring || !candidate.isRestorable)
        .opacity(candidate.isRestorable ? 1 : 0.65)
    }

    private func candidateSubtitle(_ candidate: RecoveryCandidate) -> String {
        var parts: [String] = []
        if let date = candidate.latestBackupAt {
            parts.append("最近备份 \(CodeTimeFormat.relative(date))")
        } else {
            parts.append("没有可读备份版本")
        }
        parts.append("可读版本 \(candidate.readableGenerationCount)/\(candidate.generationCount)")
        parts.append(CodeTimeFormat.bytes(candidate.repositoryBytes))
        if let version = candidate.kopiaVersion {
            parts.append("Kopia \(version)")
        }
        return parts.joined(separator: " · ")
    }

    private func restoreProgressCard(_ job: CloudRestoreJob) -> some View {
        CTCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("恢复进度")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(job.state.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: job.progress)
                HStack {
                    Text("已恢复 \(CodeTimeFormat.count(job.completedFiles)) / \(CodeTimeFormat.count(job.totalFiles)) 个对象")
                    Spacer()
                    Text("\(CodeTimeFormat.bytes(job.completedBytes)) / \(CodeTimeFormat.bytes(job.totalBytes))")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if let current = job.currentObject {
                    Text(current)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let lastError = job.lastError {
                    Text(lastError)
                        .font(.caption2)
                        .foregroundStyle(CT.danger)
                }
                if job.retryCount > 0 {
                    Text("已续传 \(job.retryCount) 次；已验证的对象不会重复下载。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// CT-136: find the CodeTime folder in iCloud automatically. Only when the
    /// build/account/container cannot be used do we ask the user for a folder.
    private func autoDetectStorage() async {
        isDetecting = true
        defer { isDetecting = false }
        let status = await CloudSetupService.detect()
        if status.isReady, let root = status.storageRoot {
            storageRoot = root
            detectMessage = "已找到 iCloud 备份位置"
        } else {
            detectMessage = "\(status.title)：\(status.detail)"
        }
    }

    private func chooseStorageRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.prompt = "选择 CodeTime 目录"
        panel.message = "选择 iCloud Drive 中的 CodeTime 文件夹"
        if panel.runModal() == .OK {
            storageRoot = panel.url
            hasScanned = false
            selectedCandidateID = nil
            errorMessage = nil
            model.recoveryCandidates = []
        }
    }

    private func scan() {
        guard let storageRoot else { return }
        isScanning = true
        hasScanned = true
        errorMessage = nil
        selectedCandidateID = nil
        Task {
            do {
                let candidates = try await model.loadRecoveryCandidates(storageRoot: storageRoot, recoveryKey: key)
                selectedCandidateID = candidates.first(where: { $0.isRestorable })?.id
                isScanning = false
                if candidates.isEmpty {
                    errorMessage = "此目录中没有可用该恢复密钥解密的备份。"
                }
            } catch {
                isScanning = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func restore() {
        guard let storageRoot, let candidate = selectedCandidate, candidate.isRestorable else { return }
        isRestoring = true
        restoreAttempts += 1
        errorMessage = nil
        Task {
            do {
                if model.secretRecoveryMode {
                    try await model.installSecretsFromCloud(
                        storageRoot: storageRoot,
                        recoveryKey: key
                    )
                    isRestoring = false
                    dismiss()
                    return
                }
                _ = try await model.recoverFromCloud(candidate: candidate, storageRoot: storageRoot, recoveryKey: key)
                isRestoring = false
                dismiss()
            } catch {
                isRestoring = false
                errorMessage = "恢复未完成：\(error.localizedDescription)。可点击“重试恢复”从已校验的对象继续，无需重新下载。"
                // Refresh persisted counters so the retry card reflects what survived.
                do {
                    if let job = try await model.latestRecoveryRestoreJob() {
                        model.recoveryRestoreJob = job
                    }
                } catch {
                    errorMessage = (errorMessage ?? "") + "\n无法读取上次恢复进度：\(error.localizedDescription)"
                }
            }
        }
    }
}
