import SwiftUI
import SharedModels

struct ActivityView: View {
    @EnvironmentObject var model: AppModel
    @State private var kindFilter: ActivityKind?
    @State private var query = ""

    private var projectNames: [UUID: String] {
        Dictionary(uniqueKeysWithValues: model.projects.map { ($0.id, $0.name) })
    }

    private var filtered: [ActivityEvent] {
        model.activity.filter { event in
            if let kindFilter, event.kind != kindFilter { return false }
            if !query.isEmpty {
                return event.message.localizedCaseInsensitiveContains(query)
                    || (event.details?.localizedCaseInsensitiveContains(query) ?? false)
            }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "活动记录", subtitle: "备份、同步、恢复、校验与清理事件") {
                HStack(spacing: 10) {
                    TextField("搜索活动", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 190)
                    Menu {
                        Button("全部") { kindFilter = nil }
                        Divider()
                        ForEach(ActivityKind.allCases, id: \.self) { kind in
                            Button(kind.displayName) { kindFilter = kind }
                        }
                    } label: {
                        Label(kindFilter?.displayName ?? "全部类型", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Button {
                        Task { await model.refreshAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, CT.pagePadding)
            .padding(.top, CT.pagePadding)

            if filtered.isEmpty {
                EmptyStateView(
                    symbol: "list.bullet.rectangle",
                    title: "没有匹配的活动",
                    message: query.isEmpty ? "备份与同步事件会记录在这里。" : "尝试更换筛选条件或搜索内容。"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { event in
                            ActivityRow(
                                event: event,
                                showsProject: true,
                                projectName: event.projectID.flatMap { projectNames[$0] }
                            )
                            Divider().opacity(0.45)
                        }
                    }
                    .padding(.horizontal, CT.pagePadding)
                    .padding(.vertical, 8)
                }
            }
        }
    }
}
