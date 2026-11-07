import SwiftUI
import SharedModels
import BackupEngine

struct ProjectEditorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var project: Project
    @State private var policy: BackupPolicy?
    @State private var newPattern = ""
    @State private var preview: ExclusionPreview?
    @State private var isPreviewing = false
    @State private var isLoading = true
    @State private var policyLoadError: String?

    private let presets = ExclusionPresets.load()

    init(project: Project) {
        _project = State(initialValue: project)
    }

    private var customRules: [ExclusionRule] {
        policy?.excludeRules.filter { $0.preset == nil } ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("项目备份设置")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(project.rootPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(22)

            Divider()

            if let policy {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        EditorSection(title: "基础") {
                            LabeledContent("项目名称") {
                                TextField("项目名称", text: $project.name)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 260)
                            }
                            LabeledContent("备份频率") {
                                Picker("", selection: Binding(
                                    get: { policy.intervalMinutes },
                                    set: { updateInterval($0) }
                                )) {
                                    ForEach([15, 30, 60, 120, 240, 480], id: \.self) { minutes in
                                        Text(CodeTimeFormat.interval(minutes)).tag(minutes)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 160)
                            }
                            Text("自动备份按上面的频率在后台轮询执行；睡眠唤醒后只补跑一次，不会为每次写入扫描。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        EditorSection(title: "保留策略") {
                            HStack(spacing: 18) {
                                RetentionStepper(title: "最近快照", value: binding(\.retention.keepLatest), range: 1...500)
                                RetentionStepper(title: "每日", value: binding(\.retention.keepDaily), range: 0...365)
                            }
                            HStack(spacing: 18) {
                                RetentionStepper(title: "每周", value: binding(\.retention.keepWeekly), range: 0...104)
                                RetentionStepper(title: "每月", value: binding(\.retention.keepMonthly), range: 0...120)
                            }
                            Text("Kopia 会按保留策略自动淘汰旧快照，云端清理使用单独的两阶段宽限期策略。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        EditorSection(title: "内置排除模板") {
                            ForEach(presets) { preset in
                                Toggle(isOn: Binding(
                                    get: { presetEnabled(preset) },
                                    set: { setPreset(preset, enabled: $0) }
                                )) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(preset.name)
                                            .font(.callout.weight(.medium))
                                        Text(preset.summary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .toggleStyle(.switch)
                            }
                            Text("模板会转换为 Kopia 忽略规则。Kopia 不支持 “!” 取反，预设规则均为排除规则。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        EditorSection(title: "自定义排除规则") {
                            if customRules.isEmpty {
                                Text("还没有自定义规则。目录规则建议以 / 结尾，例如 build/。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(customRules) { rule in
                                    HStack(spacing: 10) {
                                        Toggle("", isOn: Binding(
                                            get: { rule.isEnabled },
                                            set: { value in toggleRule(rule.id, enabled: value) }
                                        ))
                                        .labelsHidden()
                                        .toggleStyle(.checkbox)
                                        Text(rule.pattern)
                                            .font(.system(.callout, design: .monospaced))
                                        Spacer()
                                        Button {
                                            removeRule(rule.id)
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            HStack {
                                TextField("例如 node_modules/ 或 *.log", text: $newPattern)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit(addRule)
                                Button("添加", action: addRule)
                                    .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }

                        EditorSection(title: "敏感文件与 Git") {
                            Toggle("备份 .env 等敏感配置文件", isOn: binding(\.includeEnvFiles))
                            Text("关闭时会排除 .env、.env.local、.env.production 等常见密钥文件，但保留 .env.example。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Toggle("备份 .git 目录", isOn: binding(\.includeGitDirectory))
                            Text("保留 .git 能让整个项目恢复后仍然是一个完整的 Git 仓库。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Toggle("采集 Git 分支与工作区状态", isOn: binding(\.backupGitMetadata))
                            Text("只读执行 rev-parse 与 status，绝不 commit、stash、checkout 或 reset。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        EditorSection(title: "排除预览") {
                            HStack {
                                Button {
                                    Task { await runPreview(policy) }
                                } label: {
                                    if isPreviewing {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Label("计算预览", systemImage: "eye")
                                    }
                                }
                                .disabled(isPreviewing)
                                Spacer()
                                if let preview {
                                    Text("备份 \(preview.includedFiles) 个文件 · 排除 \(preview.excludedFiles) 个 · 已扫描 \(preview.scannedFiles) 项")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let preview {
                                HStack(spacing: 24) {
                                    PreviewMetric(title: "将备份", value: "\(preview.includedFiles) 个文件", caption: CodeTimeFormat.bytes(preview.includedBytes))
                                    PreviewMetric(title: "已排除", value: "\(preview.excludedFiles) 个文件", caption: CodeTimeFormat.bytes(preview.excludedBytes))
                                }
                                if !preview.isComplete {
                                    HStack(alignment: .top, spacing: 6) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(CT.warning)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("预览不完整，不能据此判断完整备份范围")
                                                .font(.caption.weight(.semibold))
                                            if let reason = preview.truncatedReason {
                                                Text(reason)
                                                    .font(.caption2)
                                            }
                                            if preview.permissionErrors > 0 {
                                                Text("\(preview.permissionErrors) 个路径无法读取，例如 \(preview.failedPaths.prefix(3).joined(separator: "、"))")
                                                    .font(.caption2)
                                                    .lineLimit(2)
                                            }
                                        }
                                        .foregroundStyle(.secondary)
                                    }
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(CT.warning.opacity(0.1)))
                                }
                                if !preview.samples.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("排除示例")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        ForEach(preview.samples.prefix(6), id: \.path) { sample in
                                            HStack(spacing: 8) {
                                                Text(sample.path)
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                Spacer()
                                                Text(sample.pattern)
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundStyle(CT.accent)
                                            }
                                        }
                                    }
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
                                }
                            }
                        }
                    }
                    .padding(22)
                }
            } else if let policyLoadError {
                EmptyStateView(
                    symbol: "exclamationmark.triangle",
                    title: "无法读取备份策略",
                    message: "\(policyLoadError)\n关闭后重试；为避免覆盖现有策略，保存已禁用。"
                )
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在载入备份策略…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    guard let policy else { return }
                    var updated = project
                    updated.name = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if updated.name.isEmpty { updated.name = URL(fileURLWithPath: updated.rootPath).lastPathComponent }
                    Task {
                        await model.saveProject(updated, policy: policy)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(policy == nil || policyLoadError != nil)
            }
            .padding(18)
        }
        .frame(width: 760, height: 780)
        .task {
            guard isLoading else { return }
            do {
                policy = try await model.policy(for: project.id)
            } catch {
                policyLoadError = error.localizedDescription
                model.showToast("读取备份策略失败：\(error.localizedDescription)", style: .error)
            }
            isLoading = false
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<BackupPolicy, T>) -> Binding<T> {
        Binding(
            get: { policy?[keyPath: keyPath] ?? BackupPolicy(projectID: project.id)[keyPath: keyPath] },
            set: { value in
                guard var current = policy else { return }
                current[keyPath: keyPath] = value
                policy = current
                preview = nil
            }
        )
    }

    private func presetEnabled(_ preset: ExclusionPreset) -> Bool {
        guard let policy else { return false }
        let rules = policy.excludeRules.filter { $0.preset == preset.id }
        return !rules.isEmpty && rules.contains(where: \.isEnabled)
    }

    private func setPreset(_ preset: ExclusionPreset, enabled: Bool) {
        guard var policy else { return }
        policy.excludeRules.removeAll { $0.preset == preset.id }
        if enabled {
            policy.excludeRules.append(contentsOf: preset.exclusionRules)
        }
        self.policy = policy
        preview = nil
    }

    private func updateInterval(_ value: Int) {
        guard var current = policy else { return }
        current.intervalMinutes = value
        policy = current
        preview = nil
    }

    private func toggleRule(_ id: UUID, enabled: Bool) {
        guard var policy, let index = policy.excludeRules.firstIndex(where: { $0.id == id }) else { return }
        policy.excludeRules[index].isEnabled = enabled
        self.policy = policy
        preview = nil
    }

    private func removeRule(_ id: UUID) {
        guard var policy else { return }
        policy.excludeRules.removeAll { $0.id == id }
        self.policy = policy
        preview = nil
    }

    private func addRule() {
        let pattern = newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty, var policy else { return }
        policy.excludeRules.append(ExclusionRule(pattern: pattern))
        self.policy = policy
        newPattern = ""
        preview = nil
    }

    private func runPreview(_ policy: BackupPolicy) async {
        isPreviewing = true
        defer { isPreviewing = false }
        preview = await model.exclusionPreview(project: project, policy: policy)
    }
}

private struct EditorSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        CTCard(padding: 16) {
            VStack(alignment: .leading, spacing: 11) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                content
            }
        }
    }
}

private struct RetentionStepper: View {
    var title: String
    @Binding var value: Int
    var range: ClosedRange<Int>

    var body: some View {
        HStack {
            Text(title)
                .font(.callout)
            Spacer()
            Stepper(value: $value, in: range) {
                Text("\(value)")
                    .font(.system(.callout, design: .monospaced))
                    .frame(width: 42, alignment: .trailing)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.035)))
    }
}

private struct PreviewMetric: View {
    var title: String
    var value: String
    var caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
