import SwiftUI
import SharedModels

struct ProjectsView: View {
    @EnvironmentObject var model: AppModel
    @State private var deleteTarget: Project?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(
                title: "项目",
                subtitle: "管理备份目录、频率与排除规则"
            ) {
                Button {
                    Task { await model.addProject() }
                } label: {
                    Label("添加项目", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, CT.pagePadding)
            .padding(.top, CT.pagePadding)

            if model.projects.isEmpty {
                EmptyStateView(
                    symbol: "folder.badge.plus",
                    title: "还没有项目",
                    message: "选择代码目录后，CodeTime 会按计划自动创建加密快照，不会提交或修改你的 Git 工作区。",
                    actionTitle: "选择目录…"
                ) {
                    Task { await model.addProject() }
                }
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(model.projects) { project in
                            ProjectCard(project: project) {
                                model.editProject(project)
                            } onDelete: {
                                deleteTarget = project
                            }
                        }
                    }
                    .padding(.horizontal, CT.pagePadding)
                    .padding(.bottom, CT.pagePadding)
                }
            }
        }
        .alert("移除项目？", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        ), presenting: deleteTarget) { project in
            Button("取消", role: .cancel) {}
            Button("移除", role: .destructive) {
                Task { await model.deleteProject(project) }
            }
        } message: { project in
            Text("将从 CodeTime 中移除 \(project.name)，不会删除磁盘上的任何代码文件。已生成的本地与云端快照仍保留在仓库中。")
        }
    }
}

struct ProjectCard: View {
    @EnvironmentObject var model: AppModel
    var project: Project
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        CTCard(padding: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(project.status.color.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: project.status.symbol)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(project.status.color)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(project.name)
                            .font(.system(size: 16, weight: .semibold))
                        let syncDisplay = ProjectSyncDisplay.derived(
                            status: project.status,
                            cloudState: project.lastCloudState
                        )
                        StatusPill(
                            text: syncDisplay.title,
                            color: syncDisplay.kind == .cloudFailed || syncDisplay.kind == .failed
                                ? CT.warning
                                : project.status.color
                        )
                        if let error = project.lastError {
                            TagChip(text: error, tint: CT.danger)
                                .lineLimit(1)
                        }
                    }
                    Text(project.rootPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 14) {
                        if let last = project.lastBackupAt {
                            Label("上次备份 \(CodeTimeFormat.relative(last))", systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Label("尚未备份", systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let group = project.groupName {
                            Label(group, systemImage: "square.stack.3d.up")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()

                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { project.enabled },
                        set: { value in Task { await model.toggleProject(project, enabled: value) } }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(project.enabled ? "暂停自动备份" : "恢复自动备份")

                    // `status == .backingUp` covers a SCHEDULED backup started by
                    // the agent/scheduler, which AppModel.activeProjectIDs cannot
                    // see; without it the button stays enabled and the click just
                    // reports "already running".
                    if model.activeProjectIDs.contains(project.id) || project.status == .backingUp {
                        ProgressView().controlSize(.small).frame(width: 26)
                    } else {
                        Button {
                            Task { await model.backupNow(projectID: project.id) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("立即备份")
                    }

                    Menu {
                        Button("备份设置…", action: onEdit)
                        Button("在时间机器中打开") {
                            Task { await model.loadWorkspace(projectID: project.id) }
                        }
                        Divider()
                        Button("移除项目", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
    }
}
