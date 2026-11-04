import SwiftUI

/// §3 状态徽标：symbol + 文字，颜色语义统一。
struct StatusBadge: View {
    let item: UpdateItem
    var showMessage = true

    private var color: Color {
        if item.isSelfUpdating { return .secondary }
        switch item.status {
        case .outdated: return item.canUpdate ? .orange : .secondary
        case .upToDate, .updated: return .green
        case .failed: return .red
        case .updating: return .accentColor
        case .checking, .unknown: return .secondary
        }
    }

    private var symbol: String? {
        if item.isSelfUpdating { return "arrow.triangle.2.circlepath" }
        switch item.status {
        case .checking, .updating: return nil
        case .outdated:
            if item.canUpdate { return "arrow.up.circle.fill" }
            return (item.hint ?? "").contains("pin") ? "pin.fill" : "arrow.up.circle"
        case .upToDate: return "checkmark.circle.fill"
        case .updated: return "checkmark.seal.fill"
        case .failed: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    /// 徽标后的补充说明（message 或 hint）。
    private var extra: String? {
        if item.isSelfUpdating { return item.hint }
        if let m = item.status.message, !m.isEmpty { return m }
        if let h = item.hint, !h.isEmpty { return h }
        return nil
    }

    /// §16.4：自更新行文案为"由应用自更新"，其余沿用状态标签。
    private var label: String { item.isSelfUpdating ? "由应用自更新" : item.status.label }

    private var tooltip: String {
        var parts = ["状态：\(label)"]
        if let e = extra { parts.append(e) }
        if item.status.isOutdated, let l = item.latest { parts.append("\(item.installed) → \(l)") }
        return parts.joined(separator: "，")
    }

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).imageScale(.small)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(label)
            if showMessage, let extra {
                Text("· \(extra)")
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.caption)
        .foregroundStyle(color)
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tooltip)
    }
}
