import SwiftUI
import AppKit
import SharedModels

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @State private var step = 0
    @State private var acknowledged = false
    @State private var iCloudEnabled = false

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
                        ForEach(0..<3) { index in
                            Capsule()
                                .fill(index == step ? CT.accent : Color.secondary.opacity(0.2))
                                .frame(width: index == step ? 22 : 7, height: 7)
                                .animation(.spring(response: 0.3), value: step)
                        }
                    }
                }
                .padding(22)

                Divider()

                Group {
                    switch step {
                    case 0: recoveryStep
                    case 1: projectStep
                    default: cloudStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                HStack {
                    if step > 0 {
                        Button("上一步") { step -= 1 }
                    }
                    Spacer()
                    Button(step == 0 ? "已保存，继续" : (step == 1 ? "继续" : "开始使用")) {
                        advance()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == 0 && !key.isEmpty && !acknowledged)
                }
                .padding(20)
            }
            .frame(width: 720, height: 640)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 14)
        }
        .onAppear {
            iCloudEnabled = model.settings.iCloudEnabled
            if key.isEmpty {
                Task { await ensureKey() }
            }
        }
    }

    private var recoveryStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("先保存恢复密钥")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("CodeTime 会用 Kopia 加密本机仓库，并把不可变对象同步到 iCloud。恢复密钥是打开云端清单、取回仓库密码的唯一人工凭据。")
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
                        Text("请写到密码管理器或打印离线保存。丢失它且本机 Keychain 损坏时，备份内容将无法解密。")
                            .font(.caption)
                            .foregroundStyle(CT.warning)
                    }
                }

                Toggle("我已将恢复密钥保存到安全的位置", isOn: $acknowledged)
                    .toggleStyle(.checkbox)
                    .font(.callout)

                HStack(spacing: 16) {
                    OnboardingFeature(symbol: "camera", title: "自动快照", detail: "按计划创建，不依赖 Git 提交")
                    OnboardingFeature(symbol: "clock.arrow.circlepath", title: "时间机器", detail: "浏览任意时间点的文件内容")
                    OnboardingFeature(symbol: "icloud", title: "云端灾难恢复", detail: "换机后凭恢复密钥重建仓库")
                }
            }
            .padding(28)
        }
    }

    private var projectStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("选择要保护的代码目录")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("CodeTime 只读取你选择的目录；不会修改 Git 工作区，也不会要求提交代码。")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if model.projects.isEmpty {
                    CTCard {
                        VStack(spacing: 12) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 32, weight: .light))
                                .foregroundStyle(.secondary)
                            Text("还没有添加项目")
                                .font(.callout.weight(.medium))
                            Button("选择目录…") {
                                Task { await model.addProject() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 26)
                    }
                } else {
                    CTCard {
                        VStack(spacing: 0) {
                            ForEach(model.projects) { project in
                                HStack(spacing: 10) {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(CT.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(project.name)
                                            .font(.callout.weight(.semibold))
                                        Text(project.rootPath)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer()
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(CT.success)
                                }
                                .padding(.vertical, 8)
                                if project.id != model.projects.last?.id { Divider() }
                            }
                        }
                    }
                    Button("继续添加…") {
                        Task { await model.addProject() }
                    }
                    .buttonStyle(.bordered)
                }

                Text("默认排除 node_modules、构建产物、日志与 .env 等敏感文件；可随时在项目设置中调整。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
        }
    }

    private var cloudStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("云端镜像（可选）")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text("启用 iCloud 后，CodeTime 会把加密仓库封装成不可变对象并同步到 iCloud Drive/CodeTime。也可以稍后在设置中配置本地镜像。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            CTCard {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("启用 iCloud 备份镜像", isOn: $iCloudEnabled)
                    if iCloudEnabled {
                        Text("发布顺序：数据对象全部上传 → 校验上传状态 → 最后写入加密版本清单。中断时旧版本保持有效。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("当前为纯本地模式。本地仓库保留完整数据副本，恢复速度更快。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 16) {
                OnboardingFeature(symbol: "lock.shield", title: "加密清单", detail: "AES-256-GCM + HKDF 独立密钥")
                OnboardingFeature(symbol: "arrow.uturn.backward.circle", title: "宽限期清理", detail: "至少保留两代可恢复版本")
                OnboardingFeature(symbol: "laptopcomputer.and.iphone", title: "设备隔离", detail: "每台 Mac 独立仓库，互不覆盖")
            }

            Spacer()
        }
        .padding(28)
        .onAppear {
            if iCloudEnabled != model.settings.iCloudEnabled {
                iCloudEnabled = model.settings.iCloudEnabled
            }
        }
    }

    private func advance() {
        if step == 0 {
            step = 1
        } else if step == 1 {
            step = 2
        } else {
            model.settings.iCloudEnabled = iCloudEnabled
            model.settingsChanged()
            Task { await model.completeOnboarding() }
        }
    }

    private func ensureKey() async {
        // Key is normally populated during bootstrap; this covers a reopened onboarding.
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
                    Text("云端 CodeTime 目录")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack {
                        Image(systemName: "icloud")
                            .foregroundStyle(CT.accent)
                        Text(storageRoot?.path ?? "请选择 iCloud Drive 中的 CodeTime 文件夹")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(storageRoot == nil ? .secondary : .primary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Spacer()
                        Button("选择…") { chooseStorageRoot() }
                            .controlSize(.small)
                            .disabled(isRestoring)
                    }
                    Text("该目录应包含 format.json 与 devices 文件夹。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
