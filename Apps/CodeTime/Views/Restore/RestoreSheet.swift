import SwiftUI
import AppKit
import SharedModels

struct RestoreSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let context: RestoreContext

    @State private var mode: RestoreMode
    @State private var copyDestination: URL?
    @State private var isRestoring = false
    @State private var errorMessage: String?

    init(context: RestoreContext) {
        self.context = context
        _mode = State(initialValue: context.relativePath == nil ? .wholeProject : .copy)
    }

    private var availableModes: [RestoreMode] {
        context.relativePath == nil ? [.wholeProject] : [.copy]
    }

    private var canRestore: Bool {
        !isRestoring && copyDestination != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(CT.accent)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(CT.accent.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("恢复")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                    Text("\(context.entryName) · \(CodeTimeFormat.dateTime(context.snapshotDate))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CTCard(padding: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("恢复方式")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            Picker("", selection: $mode) {
                                ForEach(availableModes, id: \.self) { option in
                                    Text(option.displayName).tag(option)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            Text(modeDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    CTCard(padding: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("恢复位置")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)

                            HStack {
                                Image(systemName: copyDestination == nil ? "folder.badge.questionmark" : "folder")
                                    .foregroundStyle(copyDestination == nil ? .secondary : CT.accent)
                                Text(copyDestination?.path ?? "尚未选择位置")
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(copyDestination == nil ? .secondary : .primary)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                Spacer()
                                Button("选择…") { chooseDestination() }
                                    .controlSize(.small)
                            }

                            if mode == .wholeProject {
                                Text("请选择一个独立的新目录。CodeTime 不会覆盖已有项目，也不会写入原始项目。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    CTCard(padding: 16) {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.shield")
                                .foregroundStyle(CT.success)
                            Text("CodeTime 对原始项目永久只读：恢复只写入你选择的独立位置，不改变当前开发代码。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(CT.danger)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(CT.danger.opacity(0.08)))
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Text(context.project.rootPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    performRestore()
                } label: {
                    if isRestoring {
                        HStack { ProgressView().controlSize(.small); Text("恢复中…") }
                    } else {
                        Text("开始恢复")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(CT.accent)
                .disabled(!canRestore)
            }
            .padding(18)
        }
        .frame(width: 620, height: 620)
        .onChange(of: mode) { _ in
            errorMessage = nil
        }
    }

    private var modeDescription: String {
        switch mode {
        case .preview:
            return "只查看历史内容，不写入磁盘。"
        case .copy:
            return "把历史版本写入你选择的新位置，项目中的当前文件保持不变。"
        case .overwrite:
            return "已禁用：CodeTime 对原始项目永久只读，不会覆盖项目中的任何文件。"
        case .wholeProject:
            return "把整个项目在指定目录中展开，包含源代码、目录结构与 .git 元数据。"
        }
    }

    private func chooseDestination() {
        if mode == .wholeProject {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "恢复到此处"
            panel.message = "选择一个新的空目录（或点击“新建文件夹”）"
            if panel.runModal() == .OK {
                copyDestination = panel.url
            }
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = context.entryName
            panel.canCreateDirectories = true
            panel.prompt = "恢复副本"
            panel.message = "选择恢复副本的保存位置"
            if panel.runModal() == .OK {
                copyDestination = panel.url
            }
        }
    }

    private func performRestore() {
        guard let destination = copyDestination else { return }
        isRestoring = true
        errorMessage = nil
        Task {
            let error = await model.performRestore(context: context, mode: mode, destination: destination)
            isRestoring = false
            if let error {
                errorMessage = error
            } else {
                dismiss()
            }
        }
    }
}

struct RestoreHistoryView: View {
    @EnvironmentObject var model: AppModel

    private var projects: [UUID: String] {
        Dictionary(uniqueKeysWithValues: model.projects.map { ($0.id, $0.name) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "恢复记录", subtitle: "已执行的恢复任务与结果") {
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, CT.pagePadding)
            .padding(.top, CT.pagePadding)

            if model.restoreJobs.isEmpty {
                EmptyStateView(
                    symbol: "arrow.down.doc",
                    title: "还没有恢复任务",
                    message: "从时间机器恢复文件或整个项目后，记录会出现在这里。"
                )
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.restoreJobs) { job in
                            CTCard(padding: 14) {
                                HStack(spacing: 12) {
                                    Image(systemName: job.status == .completed ? "checkmark.circle.fill" : (job.status == .failed ? "xmark.octagon.fill" : "clock"))
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(job.status.color)
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 8) {
                                            Text(job.mode.displayName)
                                                .font(.callout.weight(.semibold))
                                            if let name = projects[job.projectID] {
                                                TagChip(text: name, tint: CT.accent)
                                            }
                                            StatusPill(text: job.status.displayName, color: job.status.color)
                                        }
                                        Text(job.targetPath)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        if let error = job.errorMessage {
                                            Text(error)
                                                .font(.caption)
                                                .foregroundStyle(CT.danger)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(CodeTimeFormat.relative(job.createdAt))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(CodeTimeFormat.time(job.createdAt))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, CT.pagePadding)
                    .padding(.bottom, CT.pagePadding)
                }
            }
        }
    }
}
