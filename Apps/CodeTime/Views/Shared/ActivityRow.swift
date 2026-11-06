import SwiftUI
import SharedModels

struct ActivityRow: View {
    var event: ActivityEvent
    var showsProject: Bool = false
    var projectName: String?

    private var color: Color {
        switch event.level {
        case .success: return CT.success
        case .warning: return CT.warning
        case .error: return CT.danger
        case .info: return CT.accent
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: event.kind.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(Circle().fill(color.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.message)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    if let projectName, showsProject {
                        TagChip(text: projectName, tint: CT.accent)
                    }
                }
                if let details = event.details, !details.isEmpty {
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(CodeTimeFormat.relative(event.date))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
        .padding(.vertical, 7)
    }
}

struct ProjectStatusRow: View {
    @EnvironmentObject var model: AppModel
    var project: Project
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(project.status.color.opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: project.status.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(project.status.color)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(project.name)
                        .font(.system(size: 14, weight: .semibold))
                    if !project.enabled {
                        TagChip(text: "已暂停")
                    }
                }
                Text(project.rootPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 10) {
                    StatusPill(text: project.status.displayName, color: project.status.color)
                    if let last = project.lastBackupAt {
                        Text("上次备份 \(CodeTimeFormat.relative(last))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if model.activeProjectIDs.contains(project.id) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 70)
            } else {
                Button {
                    Task { await model.backupNow(projectID: project.id) }
                } label: {
                    Label("备份", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("立即备份")
            }
            Button("打开") {
                onOpen()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

struct HealthBanner: View {
    @EnvironmentObject var model: AppModel

    private var hasError: Bool {
        model.projects.contains { $0.status == .error }
    }

    private var hasWarning: Bool {
        model.projects.contains { $0.status == .warning }
    }

    private var title: String {
        if model.projects.isEmpty { return "还没有需要保护的项目" }
        if hasError { return "有项目备份失败" }
        if hasWarning { return "部分项目需要关注" }
        return "所有项目运行正常"
    }

    private var message: String {
        if model.projects.isEmpty {
            return "添加代码目录后，CodeTime 会按计划自动生成加密快照。"
        }
        if hasError {
            let names = model.projects.filter { $0.status == .error }.map(\.name).joined(separator: "、")
            return "\(names) 最近一次备份失败，请查看活动记录。"
        }
        if hasWarning {
            return "存在读取失败或云端未同步的快照，本地版本仍然可用。"
        }
        let protected = model.projects.filter(\.enabled).count
        let last = model.projects.compactMap(\.lastBackupAt).max()
        let lastText = last.map { "最近备份于 \(CodeTimeFormat.relative($0))" } ?? "等待首次备份"
        return "\(protected) 个项目受保护 · \(lastText)"
    }

    private var color: Color {
        if hasError { return CT.danger }
        if hasWarning { return CT.warning }
        if model.projects.isEmpty { return CT.accent }
        return CT.success
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(color.opacity(0.14)).frame(width: 42, height: 42)
                Image(systemName: hasError ? "exclamationmark.triangle.fill" : (hasWarning ? "exclamationmark.circle.fill" : "checkmark.shield.fill"))
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let cloud = model.cloudSummary {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("云端已发布 \(cloud.generationCount) 代")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(CT.mint)
                    Text(CodeTimeFormat.bytes(cloud.byteSize))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                StatusPill(text: "纯本地模式", color: .secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: CT.cardRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.12), Color(nsColor: .controlBackgroundColor).opacity(0.9)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: CT.cardRadius, style: .continuous)
                .strokeBorder(color.opacity(0.18), lineWidth: 1)
        )
    }
}
