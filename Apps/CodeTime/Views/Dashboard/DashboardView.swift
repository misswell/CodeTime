import SwiftUI
import SharedModels

struct DashboardView: View {
    @EnvironmentObject var model: AppModel

    private var protectedCount: Int {
        model.projects.filter(\.enabled).count
    }

    private var lastBackup: Date? {
        model.projects.compactMap(\.lastBackupAt).max()
    }

    private var recentActivity: [ActivityEvent] {
        Array(model.activity.prefix(7))
    }

    private var projectNames: [UUID: String] {
        Dictionary(uniqueKeysWithValues: model.projects.map { ($0.id, $0.name) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: "备份概览",
                    subtitle: "所有项目的备份状态、云端容量与最近活动"
                ) {
                    HStack(spacing: 10) {
                        Button {
                            Task { await model.addProject() }
                        } label: {
                            Label("添加项目", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            Task { await model.backupAll() }
                        } label: {
                            Label("全部备份", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.projects.isEmpty)
                    }
                }

                HealthBanner()

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
                    MetricCard(
                        title: "保护中的项目",
                        value: "\(protectedCount)",
                        caption: model.projects.isEmpty ? "尚未添加项目" : "全部正常",
                        symbol: "folder.badge.gearshape",
                        tint: CT.accent
                    )
                    MetricCard(
                        title: "云端备份容量",
                        value: model.cloudSummary.map { CodeTimeFormat.bytes($0.byteSize) } ?? "纯本地",
                        caption: model.cloudSummary == nil ? "未启用 iCloud 镜像" : "增量去重后",
                        symbol: "icloud.and.arrow.up",
                        tint: CT.mint
                    )
                    MetricCard(
                        title: "历史快照",
                        value: CodeTimeFormat.count(model.totalSnapshotCount),
                        caption: "跨全部项目",
                        symbol: "clock.arrow.circlepath",
                        tint: CT.violet
                    )
                    MetricCard(
                        title: "最近备份",
                        value: lastBackup.map { CodeTimeFormat.time($0) } ?? "—",
                        caption: lastBackup.map { CodeTimeFormat.relative($0) } ?? "等待首次备份",
                        symbol: "checkmark.seal",
                        tint: CT.success
                    )
                }

                HStack(alignment: .top, spacing: 16) {
                    CTCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("项目")
                                    .font(.headline)
                                Spacer()
                                Button("管理项目") {
                                    model.selectedSection = .projects
                                }
                                .buttonStyle(.link)
                            }
                            if model.projects.isEmpty {
                                VStack(spacing: 12) {
                                    Image(systemName: "folder.badge.plus")
                                        .font(.system(size: 30, weight: .light))
                                        .foregroundStyle(.secondary)
                                    Text("添加第一个代码目录")
                                        .font(.callout.weight(.medium))
                                    Text("CodeTime 不会修改你的 Git 工作区，也不会要求提交代码。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                    Button("选择目录…") {
                                        Task { await model.addProject() }
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 28)
                            } else {
                                ForEach(model.projects.prefix(8)) { project in
                                    ProjectStatusRow(project: project) {
                                        Task { await model.loadWorkspace(projectID: project.id) }
                                    }
                                    if project.id != model.projects.prefix(8).last?.id {
                                        Divider().opacity(0.6)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    CTCard {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("最近活动")
                                    .font(.headline)
                                Spacer()
                                Button("全部") {
                                    model.selectedSection = .activity
                                }
                                .buttonStyle(.link)
                            }
                            if recentActivity.isEmpty {
                                Text("暂无活动")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 40)
                            } else {
                                ForEach(recentActivity) { event in
                                    ActivityRow(
                                        event: event,
                                        showsProject: true,
                                        projectName: event.projectID.flatMap { projectNames[$0] }
                                    )
                                    if event.id != recentActivity.last?.id {
                                        Divider().opacity(0.5)
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: 390)
                }

                StorageSummaryCard()
            }
            .padding(CT.pagePadding)
        }
        .scrollIndicators(.automatic)
    }
}

struct StorageSummaryCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        CTCard {
            HStack(spacing: 14) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(CT.accent)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(CT.accent.opacity(0.12)))
                VStack(alignment: .leading, spacing: 3) {
                    Text("本地加密仓库")
                        .font(.subheadline.weight(.semibold))
                    Text("Kopia 仓库保留完整数据副本，用于快速浏览与本地恢复。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(CodeTimeFormat.bytes(model.repositoryBytes))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text("去重后占用")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button("存储设置") {
                    model.selectedSection = .settings
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}
