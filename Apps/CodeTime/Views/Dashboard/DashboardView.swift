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

                BackupSafetyOverview()

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
                        value: model.settings.engineMode == .cloudFirst
                            ? "已同步"
                            : (model.cloudSummary.map { CodeTimeFormat.bytes($0.byteSize) } ?? "纯本地"),
                        caption: model.settings.engineMode == .cloudFirst
                            ? "按内容块去重 · 按需恢复"
                            : (model.cloudSummary == nil ? "未启用 iCloud 镜像" : "增量去重后"),
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

    private var isV3: Bool { model.settings.engineMode == .cloudFirst }

    var body: some View {
        CTCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Image(systemName: isV3 ? "icloud.and.arrow.up" : "internaldrive")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(CT.accent)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(CT.accent.opacity(0.12)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isV3 ? "云端优先 · 本地只保留必要数据" : "本地加密仓库")
                            .font(.subheadline.weight(.semibold))
                        Text(isV3
                             ? "完整历史保存在 iCloud；本地是索引、有限下载缓存和受保护的待上传数据。"
                             : "Kopia 仓库保留完整数据副本，用于快速浏览与本地恢复。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isV3 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(CodeTimeFormat.bytes(model.v3Storage?.cacheBytes ?? 0))
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                            Text("下载缓存 / \(CodeTimeFormat.bytes(model.v3Storage?.cacheBudgetBytes ?? 0))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(model.repositoryBytes.map(CodeTimeFormat.bytes) ?? "无法统计")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                            Text("去重后占用")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("存储设置") {
                        model.selectedSection = .settings
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let storage = model.v3Storage {
                    HStack(spacing: 18) {
                        storageItem(
                            "元数据索引",
                            CodeTimeFormat.bytes(storage.indexedChunkBytes),
                            "重建即可恢复"
                        )
                        storageItem(
                            "下载缓存",
                            CodeTimeFormat.bytes(storage.cacheBytes),
                            "可安全清理"
                        )
                        storageItem(
                            "待上传数据",
                            CodeTimeFormat.bytes(storage.pendingBytes),
                            storage.pendingTasks == 0 ? "云端已确认" : "\(storage.pendingTasks) 个任务 · 不可删除"
                        )
                        storageItem(
                            "iCloud 备份",
                            model.cloudSummary.map { CodeTimeFormat.bytes($0.byteSize) } ?? "已启用",
                            "最终恢复来源"
                        )
                        Spacer()
                        if storage.cacheBytes > 0 {
                            Button("清理下载缓存") {
                                Task { await model.clearDownloadCache() }
                            }
                            .controlSize(.small)
                        }
                        if storage.pendingTasks > 0 {
                            Button("立即上传") {
                                Task { await model.resumePendingUploads() }
                            }
                            .controlSize(.small)
                        }
                    }
                    if storage.isSpoolOversized {
                        Label(
                            "待上传数据已达到软上限，新备份会暂停而不是删除未上传数据。请等待 iCloud 恢复。",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                } else if model.repositoryBytes ?? 0 > 0 {
                    HStack {
                        Text("检测到旧版本地仓库。迁移会保留旧历史并验证新格式，之后才允许释放本地空间。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("迁移到云端优先引擎") {
                            Task { await model.runMigration() }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func storageItem(_ title: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded))
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// CT-135: the honest one-glance summary. Local backup, iCloud upload and cloud
/// verification are separate rows — a green local row never implies cloud safety.
private struct BackupSafetyOverview: View {
    @EnvironmentObject var model: AppModel

    private var localLine: (text: String, ok: Bool) {
        let enabled = model.projects.filter(\.enabled)
        guard !enabled.isEmpty else { return ("尚未添加项目", false) }
        if let latest = enabled.compactMap(\.lastBackupAt).max() {
            return ("正常 · 最近 \(CodeTimeFormat.relative(latest))", true)
        }
        return ("等待首次备份", false)
    }

    private var cloudLine: (text: String, ok: Bool) {
        guard model.settings.iCloudEnabled else {
            return ("未启用（本地备份不受影响）", false)
        }
        if !model.cloudSetup.isReady {
            return ("\(model.cloudSetup.title) · \(model.cloudSetup.detail)", false)
        }
        let total = model.projects.filter(\.enabled).count
        let synced = model.projects.filter { $0.enabled && $0.lastCloudState == .synced }.count
        if total > 0 && synced == total { return ("已上传 · \(synced)/\(total) 个项目", true) }
        if synced == 0 { return ("等待上传 · 0/\(total) 个项目", false) }
        return ("部分同步 · \(synced)/\(total) 个项目", false)
    }

    private var pendingProjects: [Project] {
        model.projects.filter { $0.enabled && $0.lastCloudState != .synced }
    }

    var body: some View {
        CTCard(padding: 16) {
            HStack(alignment: .top, spacing: 24) {
                row(symbol: "internaldrive", title: "本地备份", line: localLine)
                Divider().frame(height: 34)
                row(symbol: "icloud", title: "iCloud", line: cloudLine)
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    if !pendingProjects.isEmpty && model.cloudSetup.isReady {
                        Text("\(pendingProjects.count) 个项目待同步")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("立即重试") {
                            Task { await model.retryCloudSyncNow() }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func row(symbol: String, title: String, line: (text: String, ok: Bool)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(line.ok ? CT.success : .secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill((line.ok ? CT.success : Color.secondary).opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(line.text)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }
}
