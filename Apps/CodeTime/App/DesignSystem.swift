import SwiftUI
import AppKit
import SharedModels

enum CT {
    static let accent = Color(red: 0.22, green: 0.55, blue: 0.98)
    static let mint = Color(red: 0.16, green: 0.72, blue: 0.62)
    static let success = Color(red: 0.20, green: 0.70, blue: 0.42)
    static let warning = Color(red: 0.94, green: 0.60, blue: 0.16)
    static let danger = Color(red: 0.90, green: 0.30, blue: 0.28)
    static let violet = Color(red: 0.52, green: 0.40, blue: 0.92)

    static let cardRadius: CGFloat = 16
    static let pagePadding: CGFloat = 26
}

struct PageHeader: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var actions: () -> AnyView

    init(title: String, subtitle: String? = nil, @ViewBuilder actions: @escaping () -> some View = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.actions = { AnyView(actions()) }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            actions()
        }
    }
}

struct CTCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CT.cardRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CT.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

struct MetricCard: View {
    var title: String
    var value: String
    var caption: String
    var symbol: String
    var tint: Color

    var body: some View {
        CTCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(tint.opacity(0.14)))
                    Spacer()
                }
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct StatusPill: View {
    var text: String
    var color: Color
    var showsDot: Bool = true

    var body: some View {
        HStack(spacing: 5) {
            if showsDot {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

struct TagChip: View {
    var text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.1)))
    }
}

struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct ToastView: View {
    var toast: Toast

    private var color: Color {
        switch toast.style {
        case .success: return CT.success
        case .warning: return CT.warning
        case .error: return CT.danger
        case .info: return CT.accent
        }
    }

    private var symbol: String {
        switch toast.style {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(toast.message)
                .font(.callout.weight(.medium))
                .lineLimit(3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}

extension ProjectStatus {
    var color: Color {
        switch self {
        case .synced: return CT.success
        case .backingUp: return CT.accent
        case .publishing: return CT.mint
        case .verifying: return CT.mint
        case .warning: return CT.warning
        case .failed: return CT.danger
        case .missing: return CT.danger
        case .disabled: return .secondary
        case .localOnly: return CT.accent
        case .idle: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .synced: return "checkmark.circle.fill"
        case .backingUp: return "arrow.triangle.2.circlepath"
        case .publishing: return "icloud.and.arrow.up"
        case .verifying: return "checkmark.shield"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .missing: return "questionmark.folder"
        case .disabled: return "pause.circle"
        case .localOnly: return "internaldrive"
        case .idle: return "clock"
        }
    }
}

extension CloudSyncState {
    var color: Color {
        switch self {
        case .synced: return CT.success
        case .uploading, .pending: return CT.mint
        case .failed: return CT.danger
        case .localOnly, .unknown: return .secondary
        }
    }
}

extension VerificationOutcome {
    var color: Color {
        switch self {
        case .passed: return CT.success
        case .failed: return CT.danger
        case .skipped: return .secondary
        }
    }
}

extension RestoreStatus {
    var color: Color {
        switch self {
        case .completed: return CT.success
        case .failed: return CT.danger
        case .running: return CT.accent
        case .cancelled: return .secondary
        }
    }
}

extension View {
    func ctPagePadding() -> some View {
        padding(.horizontal, CT.pagePadding)
    }
}
