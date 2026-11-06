import SwiftUI
import AppKit
import SharedModels

struct TimelineView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TimelineHeader()
            Divider()
            if model.selectedProjectID == nil {
                EmptyStateView(
                    symbol: "clock.arrow.circlepath",
                    title: "选择要浏览的项目",
                    message: "添加项目并完成一次备份后，就可以像 Time Machine 一样查看任意时间点的文件。",
                    actionTitle: "添加项目"
                ) {
                    Task { await model.addProject() }
                }
            } else if model.snapshots.isEmpty {
                EmptyStateView(
                    symbol: "camera.metering.unknown",
                    title: "还没有快照",
                    message: "立即为 \(model.currentProject?.name ?? "项目") 创建第一个加密快照。",
                    actionTitle: "立即备份"
                ) {
                    if let id = model.selectedProjectID {
                        Task { await model.backupNow(projectID: id) }
                    }
                }
            } else {
                HSplitView {
                    FileBrowserPane()
                        .frame(minWidth: 260, idealWidth: 310, maxWidth: 420)
                    FilePreviewPane()
                        .frame(minWidth: 360)
                    TimelineRail()
                        .frame(minWidth: 250, idealWidth: 280, maxWidth: 340)
                }
            }
        }
        .focusable()
        .onMoveCommand { direction in
            guard model.selectedSection == .timeline,
                  let index = model.snapshots.firstIndex(where: { $0.id == model.selectedSnapshotID }) else { return }
            switch direction {
            case .up:
                if index > 0 {
                    Task { await model.selectSnapshot(model.snapshots[index - 1].id) }
                }
            case .down:
                if index + 1 < model.snapshots.count {
                    Task { await model.selectSnapshot(model.snapshots[index + 1].id) }
                }
            default:
                break
            }
        }
        .task(id: workspaceKey) {
            guard model.selectedSection == .timeline,
                  let projectID = model.selectedProjectID else { return }
            if model.snapshots.isEmpty || model.snapshots.first?.projectID != projectID {
                await model.loadWorkspace(projectID: projectID, switchSection: false)
            }
        }
    }

    private var workspaceKey: String {
        "\(model.selectedSection.rawValue)-\(model.selectedProjectID?.uuidString ?? "none")"
    }
}

private struct TimelineHeader: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Menu {
                ForEach(model.projects) { project in
                    Button {
                        Task { await model.loadWorkspace(projectID: project.id, switchSection: false) }
                    } label: {
                        if project.id == model.selectedProjectID {
                            Label(project.name, systemImage: "checkmark")
                        } else {
                            Text(project.name)
                        }
                    }
                }
                Divider()
                Button("管理项目…") {
                    model.selectedSection = .projects
                }
            } label: {
                HStack(spacing: 6) {
                    Text(model.currentProject?.name ?? "选择项目")
                        .font(.system(size: 17, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if let snapshot = model.selectedSnapshot {
                VStack(alignment: .leading, spacing: 2) {
                    Text(CodeTimeFormat.dateTime(snapshot.createdAt))
                        .font(.callout.weight(.medium))
                    HStack(spacing: 7) {
                        Text("\(snapshot.fileCount) 个文件 · \(CodeTimeFormat.bytes(snapshot.totalSize))")
                        if let git = snapshot.git, let branch = git.branch {
                            Text("· \(branch)\(git.isDirty ? "*" : "")")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                StatusPill(text: snapshot.cloudState.displayName, color: snapshot.cloudState.color)
                if snapshot.status != .complete {
                    StatusPill(text: snapshot.status.displayName, color: CT.warning)
                }
            }

            Spacer()

            if model.isBusy {
                ProgressView().controlSize(.small)
            }

            Button {
                if let id = model.selectedProjectID {
                    Task { await model.backupNow(projectID: id) }
                }
            } label: {
                if let id = model.selectedProjectID, model.activeProjectIDs.contains(id) {
                    ProgressView().controlSize(.small)
                } else {
                    Label("立即备份", systemImage: "camera")
                }
            }
            .buttonStyle(.bordered)

            Button {
                model.diffCurrentSnapshot()
            } label: {
                Label("版本差异", systemImage: "arrow.left.arrow.right")
            }
            .buttonStyle(.bordered)
            .disabled(model.previousSnapshot == nil)

            Menu {
                Button("恢复所选文件…") {
                    model.beginRestore(entry: selectedEntry)
                }
                .disabled(selectedEntry == nil || selectedEntry?.isDirectory == true)
                Button("恢复整个项目…") {
                    model.beginWholeProjectRestore()
                }
                Divider()
                Button("校验当前快照") {
                    Task { await model.verifySelectedSnapshot() }
                }
            } label: {
                Label("恢复", systemImage: "arrow.down.doc")
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .disabled(model.selectedSnapshot == nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var selectedEntry: FileEntry? {
        model.preview?.entry ?? model.entries.first { $0.id == model.selectedEntryID }
    }
}

// MARK: - File browser

private struct FileBrowserPane: View {
    @EnvironmentObject var model: AppModel
    @State private var isLoadingDirectory = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 4) {
                    Button {
                        Task { await model.navigate(to: "") }
                    } label: {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(CT.accent)
                    }
                    .buttonStyle(.borderless)
                    .help("项目根目录")

                    ForEach(Array(model.pathComponents.enumerated()), id: \.offset) { index, component in
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                        Button(component) {
                            let path = model.pathComponents.prefix(index + 1).joined(separator: "/")
                            Task { await model.navigate(to: path) }
                        }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    }
                    Spacer()
                    if !model.currentPath.isEmpty {
                        Button {
                            Task { await model.goUp() }
                        } label: {
                            Image(systemName: "arrow.up.left")
                        }
                        .buttonStyle(.borderless)
                        .help("上一级")
                    }
                }
                .lineLimit(1)

                HStack(spacing: 6) {
                    TextField("搜索当前目录，回车搜索整个快照", text: $model.searchText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit { Task { await model.searchAllFiles() } }
                    Button {
                        Task { await model.searchAllFiles() }
                    } label: {
                        if model.isSearching {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("在整个快照中搜索")
                    .disabled(model.searchText.isEmpty)
                    if model.globalSearchResults != nil {
                        Button {
                            model.clearSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }
                if let results = model.globalSearchResults {
                    Text("整个快照：找到 \(results.count) 个结果")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)

            Divider()

            if model.displayEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(model.globalSearchResults == nil ? "此目录为空" : "没有匹配的文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(model.displayEntries) { entry in
                            FileRow(
                                entry: entry,
                                isSelected: model.selectedEntryID == entry.id
                            ) {
                                Task {
                                    if entry.isDirectory {
                                        await model.navigate(to: entry.path)
                                    } else {
                                        await model.preview(entry)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }
}

private struct FileRow: View {
    var entry: FileEntry
    var isSelected: Bool
    var action: () -> Void

    private var icon: String {
        if entry.isDirectory { return "folder.fill" }
        if entry.isSymlink { return "link" }
        switch (entry.name as NSString).pathExtension.lowercased() {
        case "swift", "m", "mm", "c", "h", "cpp": return "swift"
        case "js", "ts", "jsx", "tsx": return "curlybraces"
        case "json", "yaml", "yml", "toml", "plist": return "doc.text"
        case "md", "txt": return "text.alignleft"
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tar": return "archivebox"
        default: return "doc"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(entry.isDirectory ? CT.accent : .secondary)
                    .frame(width: 18)
                Text(entry.name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if !entry.isDirectory {
                    Text(CodeTimeFormat.bytes(entry.size))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? CT.accent.opacity(0.16) : Color.clear)
                    .padding(.horizontal, 4)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

private struct FilePreviewPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let preview = model.preview {
                previewHeader(preview)
                Divider()
                previewBody(preview)
            } else if let snapshot = model.selectedSnapshot {
                snapshotOverview(snapshot)
            } else {
                EmptyStateView(
                    symbol: "doc.text.magnifyingglass",
                    title: "选择一个文件",
                    message: "左侧浏览快照中的目录结构，选择文件即可查看当时的内容。"
                )
            }
        }
    }

    private func previewHeader(_ preview: FilePreview) -> some View {
        HStack(spacing: 10) {
            Image(systemName: preview.entry.isDirectory ? "folder.fill" : "doc.text")
                .foregroundStyle(CT.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(preview.entry.path)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(CodeTimeFormat.bytes(preview.size))
                    if case .text = preview.kind {
                        Text("\(preview.lineCount) 行")
                    }
                    if let modified = preview.modifiedAt {
                        Text(CodeTimeFormat.dateTime(modified))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.beginRestore(entry: preview.entry)
            } label: {
                Label("恢复此版本", systemImage: "arrow.down.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thickMaterial.opacity(0.4))
    }

    @ViewBuilder
    private func previewBody(_ preview: FilePreview) -> some View {
        switch preview.kind {
        case .text(let text):
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
            .overlay(alignment: .bottomTrailing) {
                if preview.isTruncated {
                    Text("仅显示前 2 MB")
                        .font(.caption2)
                        .padding(6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                }
            }
        case .image(let image):
            GeometryReader { proxy in
                ZStack {
                    CheckerboardBackground()
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(20)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        case .binary:
            EmptyStateView(
                symbol: "doc.badge.gearshape",
                title: "二进制文件",
                message: "该文件无法作为文本预览，但可以安全地恢复为副本。"
            )
        case .error(let message):
            EmptyStateView(
                symbol: "exclamationmark.triangle",
                title: "无法预览",
                message: message
            )
        }
    }

    private func snapshotOverview(_ snapshot: Snapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snapshot.summary.isEmpty ? "历史快照" : snapshot.summary)
                            .font(.title3.bold())
                        Text(CodeTimeFormat.dateTime(snapshot.createdAt))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusPill(text: snapshot.status.displayName, color: snapshot.status == .complete ? CT.success : CT.warning)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    SnapshotFact(title: "文件数量", value: "\(snapshot.fileCount)", symbol: "doc.on.doc")
                    SnapshotFact(title: "快照大小", value: CodeTimeFormat.bytes(snapshot.totalSize), symbol: "externaldrive")
                    SnapshotFact(title: "排除文件", value: "\(snapshot.excludedFileCount)", symbol: "eye.slash")
                    SnapshotFact(title: "触发方式", value: snapshot.trigger.displayName, symbol: "bolt")
                }

                if let git = snapshot.git {
                    CTCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Git 上下文", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                TagChip(text: git.branch ?? "detached", tint: CT.accent)
                                TagChip(text: git.head ?? "无提交", tint: .secondary)
                                if git.isDirty {
                                    TagChip(text: "工作区有未提交修改", tint: CT.warning)
                                }
                                if git.hasUntrackedFiles {
                                    TagChip(text: "包含未跟踪文件", tint: CT.warning)
                                }
                            }
                            Text("Git 信息只读采集，不会改变工作区。")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                if snapshot.consistency == .possiblyInconsistent {
                    Label("备份期间检测到读取失败，快照可能不完整。", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(CT.warning)
                }

                Text("从左侧选择文件即可预览当时内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
        }
    }
}

private struct SnapshotFact: View {
    var title: String
    var value: String
    var symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(CT.accent)
                .frame(width: 26, height: 26)
                .background(Circle().fill(CT.accent.opacity(0.1)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
    }
}

private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 16
            let columns = Int(size.width / tile) + 1
            let rows = Int(size.height / tile) + 1
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile)
                    context.fill(Path(rect), with: .color(Color.primary.opacity(0.035)))
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    }
}

// MARK: - Timeline rail

private struct TimelineRail: View {
    @EnvironmentObject var model: AppModel
    @State private var sliderValue: Double = 0
    @State private var isDragging = false

    private var maxIndex: Double {
        Double(max(1, model.snapshots.count - 1))
    }

    private var selectedIndex: Int {
        model.snapshots.firstIndex { $0.id == model.selectedSnapshotID } ?? 0
    }

    private var sliderIndex: Int {
        let rounded = Int(sliderValue.rounded())
        let clamped = min(max(rounded, 0), max(0, model.snapshots.count - 1))
        return model.snapshots.count - 1 - clamped
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("历史版本")
                    .font(.headline)
                Spacer()
                Text("\(model.snapshots.count)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if let snapshot = model.snapshots[safe: sliderIndex] {
                VStack(alignment: .leading, spacing: 2) {
                    Text(CodeTimeFormat.dayHeader(snapshot.createdAt))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(CodeTimeFormat.time(snapshot.createdAt))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }

            VStack(spacing: 4) {
                Slider(value: Binding(
                    get: { sliderValue },
                    set: { value in
                        sliderValue = value
                        previewSelection(at: sliderIndex)
                    }
                ), in: 0...maxIndex) { editing in
                    isDragging = false
                    if !editing, let snapshot = model.snapshots[safe: sliderIndex] {
                        Task { await model.selectSnapshot(snapshot.id) }
                    }
                }
                .disabled(model.snapshots.count < 2)
                .padding(.horizontal, 14)

                HStack {
                    Text("更早")
                    Spacer()
                    Text("最近")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
            }
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.snapshotGroups, id: \.day) { group in
                        Section {
                            ForEach(group.snapshots) { snapshot in
                                SnapshotRailRow(
                                    snapshot: snapshot,
                                    isSelected: snapshot.id == model.selectedSnapshotID
                                ) {
                                    Task { await model.selectSnapshot(snapshot.id) }
                                }
                            }
                        } header: {
                            Text(CodeTimeFormat.dayHeader(group.day))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 12)
                                .background(.thinMaterial)
                        }
                    }
                }
                .padding(.bottom, 10)
            }

            Divider()
            HStack(spacing: 5) {
                Image(systemName: "keyboard")
                Text("↑ ↓ 切换版本")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        .onAppear { syncSlider() }
        .onChange(of: model.selectedSnapshotID) { _ in syncSlider() }
        .onChange(of: model.snapshots.count) { _ in syncSlider() }
    }

    private func syncSlider() {
        guard !isDragging, model.snapshots.count > 1 else {
            sliderValue = 0
            return
        }
        sliderValue = Double(max(0, model.snapshots.count - 1 - selectedIndex))
    }

    private func previewSelection(at index: Int) {
        guard let snapshot = model.snapshots[safe: index] else { return }
        if snapshot.id != model.selectedSnapshotID {
            // Selecting on drag would run a restore-tree load per tick; only update the label.
        }
    }
}

private struct SnapshotRailRow: View {
    var snapshot: Snapshot
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                VStack(spacing: 0) {
                    Circle()
                        .fill(isSelected ? CT.accent : Color.secondary.opacity(0.35))
                        .frame(width: 8, height: 8)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: 1)
                }
                .frame(width: 10)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(CodeTimeFormat.time(snapshot.createdAt))
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        if snapshot.cloudState == .synced {
                            Image(systemName: "icloud")
                                .font(.system(size: 9))
                                .foregroundStyle(CT.mint)
                        }
                        if snapshot.status != .complete {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(CT.warning)
                        }
                    }
                    Text("\(snapshot.fileCount) 个文件 · \(CodeTimeFormat.bytes(snapshot.totalSize))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(snapshot.trigger.displayName)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? CT.accent.opacity(0.12) : Color.clear)
                    .padding(.horizontal, 6)
            )
        }
        .buttonStyle(.plain)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
