import SwiftUI
import SharedModels

struct DiffViewerView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let context: DiffContext

    @State private var diff: SnapshotDiff?
    @State private var diffError: String?
    @State private var selectedPath: String?
    @State private var fileResult: FileDiffResult?
    @State private var filter = ""
    @State private var isLoadingDiff = true
    @State private var isLoadingFile = false

    private var changedFiles: [ChangedFile] {
        let files = diff?.files ?? []
        guard !filter.isEmpty else { return files }
        return files.filter { $0.path.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                fileList
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
                detail
                    .frame(minWidth: 520)
            }
        }
        .frame(width: 1040, height: 700)
        .task {
            do {
                diff = try await model.snapshotDiff(context)
            } catch {
                diffError = error.localizedDescription
            }
            isLoadingDiff = false
            if selectedPath == nil {
                select(changedFiles.first?.path)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(CT.accent)
                .frame(width: 36, height: 36)
                .background(Circle().fill(CT.accent.opacity(0.12)))

            VStack(alignment: .leading, spacing: 2) {
                Text("版本差异")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("\(CodeTimeFormat.dateTime(context.from.createdAt))  →  \(CodeTimeFormat.dateTime(context.to.createdAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let diff {
                TagChip(text: "+\(diff.added)", tint: CT.success)
                TagChip(text: "−\(diff.removed)", tint: CT.danger)
                TagChip(text: "~\(diff.modified)", tint: CT.warning)
            }
            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            TextField("筛选文件", text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(10)
            Divider()
            if isLoadingDiff {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let diffError {
                EmptyStateView(
                    symbol: "exclamationmark.triangle",
                    title: "无法读取版本差异",
                    message: diffError
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if changedFiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "equal.circle")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("两个版本没有内容差异")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        if diff?.isTruncated == true {
                            Text("变更列表超过上限，仅显示部分文件")
                                .font(.caption2)
                                .foregroundStyle(CT.warning)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        ForEach(changedFiles, id: \.path) { file in
                            changeRow(file)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    private func changeRow(_ file: ChangedFile) -> some View {
        Button {
            select(file.path)
        } label: {
            HStack(spacing: 8) {
                Text(kindLetter(file.kind))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(kindColor(file.kind)))
                Text(file.path)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selectedPath == file.path ? CT.accent.opacity(0.14) : Color.clear)
                    .padding(.horizontal, 4)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detail: some View {
        if let path = selectedPath {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(path)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if let fileResult {
                        TagChip(text: "+\(fileResult.added)", tint: CT.success)
                        TagChip(text: "−\(fileResult.removed)", tint: CT.danger)
                    }
                    if isLoadingFile {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
                if isLoadingFile {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let fileResult {
                    switch fileResult.state {
                    case .message(let message):
                        EmptyStateView(
                            symbol: "doc.badge.ellipsis",
                            title: "无法显示文本差异",
                            message: message
                        )
                    case .text(let rows):
                        diffPanes(rows)
                    }
                } else {
                    EmptyStateView(symbol: "doc.text.magnifyingglass", title: "选择文件", message: "从左侧选择变更文件查看逐行差异。")
                }
            }
        } else {
            EmptyStateView(
                symbol: "arrow.left.arrow.right",
                title: "选择变更文件",
                message: "左侧列出了两个快照之间新增、修改和删除的文件。"
            )
        }
    }

    private func diffPanes(_ rows: [DiffRow]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("旧版本 · \(CodeTimeFormat.time(context.from.createdAt))")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("新版本 · \(CodeTimeFormat.time(context.to.createdAt))")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.thickMaterial.opacity(0.4))
            Divider()
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        HStack(spacing: 0) {
                            diffCell(line: row.left, side: .left)
                            Divider()
                            diffCell(line: row.right, side: .right)
                        }
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        }
    }

    private enum Side { case left, right }

    private func diffCell(line: DiffLine?, side: Side) -> some View {
        HStack(spacing: 0) {
            Text(line.map { String($0.number) } ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .trailing)
                .padding(.trailing, 8)
            Text(line?.text.isEmpty == false ? line!.text : " ")
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(for: line?.kind, side: side))
    }

    private func background(for kind: DiffLine.Kind?, side: Side) -> Color {
        switch kind {
        case .removed: return CT.danger.opacity(0.13)
        case .added: return CT.success.opacity(0.13)
        default: return .clear
        }
    }

    private func select(_ path: String?) {
        guard let path else { return }
        selectedPath = path
        fileResult = nil
        isLoadingFile = true
        Task {
            let result = await model.fileDiff(context: context, path: path)
            if selectedPath == path {
                fileResult = result
                isLoadingFile = false
            }
        }
    }

    private func kindLetter(_ kind: DiffKind) -> String {
        switch kind {
        case .added: return "A"
        case .removed: return "D"
        case .modified: return "M"
        }
    }

    private func kindColor(_ kind: DiffKind) -> Color {
        switch kind {
        case .added: return CT.success
        case .removed: return CT.danger
        case .modified: return CT.warning
        }
    }
}
