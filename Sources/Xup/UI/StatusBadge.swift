import SwiftUI

/// §3 状态徽标：symbol + 文字，颜色语义统一。
struct StatusBadge: View {
    let item: UpdateItem
    var showMessage = true
    /// §19.4 正在后台预下载（尚未 staged）：仍是橙色"可更新"，补一句"后台下载中…"（v1 无百分比）。
    var isStaging = false

    private var color: Color {
        if item.isSelfUpdating { return .secondary }
        switch item.status {
        case .outdated: return item.canUpdate ? .orange : .secondary
        case .upToDate, .updated: return .green
        case .failed: return .red
        case .updating: return .accentColor
        case .checking, .unknown: return .secondary
        // systemBlue：与 accent 默认同色但语义独立，用户改 accent 也保持蓝。
        case .staged: return .blue
        }
    }

    private var symbol: String? {
        if item.isSelfUpdating { return "arrow.triangle.2.circlepath" }
        switch item.status {
        case .checking, .updating: return nil
        case .outdated:
            if isStaging { return nil }
            if item.canUpdate { return "arrow.up.circle.fill" }
            return (item.hint ?? "").contains("pin") ? "pin.fill" : "arrow.up.circle"
        case .upToDate: return "checkmark.circle.fill"
        case .updated: return "checkmark.seal.fill"
        case .failed: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle"
        case .staged: return "arrow.down.circle.fill"
        }
    }

    /// 徽标后的补充说明（message 或 hint）。
    private var extra: String? {
        if item.isSelfUpdating { return item.hint }
        if item.status.isStaged { return nil }  // 文案已并入 label
        if isStaging, item.status.isOutdated { return "后台下载中…" }
        if let m = item.status.message, !m.isEmpty { return m }
        if let h = item.hint, !h.isEmpty { return h }
        return nil
    }

    /// §16.4：自更新行文案为"由应用自更新"；§19.4 待安装行为"已下载 1.5.0 · 待安装"；其余沿用状态标签。
    private var label: String {
        if item.isSelfUpdating { return "由应用自更新" }
        if let v = item.status.stagedVersion { return "已下载 \(v) · 待安装" }
        return item.status.label
    }

    private var tooltip: String {
        var parts = ["状态：\(label)"]
        if let e = extra { parts.append(e) }
        if item.status.isOutdated || item.status.isStaged, let l = item.latest { parts.append("\(item.installed) → \(l)") }
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
