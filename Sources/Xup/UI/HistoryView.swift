import SwiftUI

/// §18 更新历史：按天分组的列表（今天 / 昨天 / 日期），每行 时间 · 来源 · 名称 · 版本 · 耗时 · 结果 · 触发。
struct HistoryView: View {
    @EnvironmentObject private var history: UpdateHistory
    @EnvironmentObject private var center: UpdateCenter
    @EnvironmentObject private var ui: UIState

    @State private var selection: Set<UUID> = []

    private var filtered: [UpdateRecord] {
        UpdateHistory.filter(history.records, failedOnly: ui.historyFailedOnly, query: ui.search)
    }
    private var groups: [UpdateHistory.DayGroup] { UpdateHistory.groupByDay(filtered) }

    var body: some View {
        VStack(spacing: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            statusBar
        }
        .alert("清空更新历史？", isPresented: $ui.historyClearRequested) {
            Button("清空", role: .destructive) { history.clear(); selection = [] }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除全部 \(history.records.count) 条记录，此操作不可撤销。")
        }
    }

    @ViewBuilder private var content: some View {
        if history.records.isEmpty {
            ContentUnavailableView {
                Label("还没有更新记录", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("每次更新成功或失败都会记录在这里。")
            }
        } else if filtered.isEmpty, !ui.search.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView {
                Label("没有匹配“\(ui.search)”的记录", systemImage: "magnifyingglass")
            } actions: {
                Button("清除搜索") { ui.search = "" }.buttonStyle(.bordered)
            }
        } else if filtered.isEmpty {
            ContentUnavailableView {
                Label("没有失败的更新", systemImage: "checkmark.seal.fill")
            } description: {
                Text("最近的更新全部成功。")
            } actions: {
                Button("显示全部") { ui.historyFailedOnly = false }.buttonStyle(.bordered)
            }
        } else {
            VStack(spacing: 0) {
                columnHeader
                Divider()
                list
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    // MARK: 表头 / 列表

    private var columnHeader: some View {
        HStack(spacing: HistoryRow.spacing) {
            Text("时间").frame(width: HistoryRow.timeWidth, alignment: .leading)
            Color.clear.frame(width: HistoryRow.iconWidth)
            Text("名称").frame(maxWidth: .infinity, alignment: .leading)
            Text("版本").frame(width: HistoryRow.versionWidth, alignment: .leading)
            Text("耗时").frame(width: HistoryRow.durationWidth, alignment: .trailing)
            Text("结果").frame(width: HistoryRow.resultWidth, alignment: .leading)
            Text("触发").frame(width: HistoryRow.triggerWidth, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .frame(height: 24)
        .background(.bar)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.records) { record in
                        HistoryRow(record: record).tag(record.id)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(group.title)
                        Text("\(group.records.count) 条").foregroundStyle(.tertiary)
                        let failed = group.records.filter { !$0.ok }.count
                        if failed > 0 { Text("· \(failed) 失败").foregroundStyle(.red) }
                    }
                    .font(.caption.weight(.semibold))
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenu(ids)
        } primaryAction: { ids in
            if ids.count == 1, let r = record(ids.first!) { ui.reveal(record: r, center: center) }
        }
    }

    private func record(_ id: UUID) -> UpdateRecord? { history.records.first { $0.id == id } }

    @ViewBuilder private func contextMenu(_ ids: Set<UUID>) -> some View {
        let selected = ids.compactMap(record).sorted { $0.time > $1.time }
        let errors = selected.compactMap { r -> String? in
            guard let e = r.error, !e.isEmpty else { return nil }
            return selected.count == 1 ? e : "\(r.name)：\(e)"
        }
        Button("复制错误信息") { XupActions.copy(errors.joined(separator: "\n")) }
            .disabled(errors.isEmpty)
        if selected.count == 1, let r = selected.first {
            let exists = center.items.contains { $0.id == r.itemID }
            Button { ui.reveal(record: r, center: center) } label: { Label("在列表中定位", systemImage: "arrow.right.circle") }
                .disabled(!exists)
                .help(exists ? "切到 \(r.kind.title) 分区并选中 \(r.name)" : "该条目已不在当前列表中")
        }
        Divider()
        Button("复制名称") { XupActions.copy(selected.map(\.name).joined(separator: "\n")) }
            .disabled(selected.isEmpty)
        Button("复制版本") { XupActions.copy(selected.map { "\($0.name) \($0.versionText)" }.joined(separator: "\n")) }
            .disabled(selected.isEmpty)
    }

    // MARK: 状态栏

    private var statusBar: some View {
        let failed24h = UpdateHistory.failedCount(history.records, since: Date().addingTimeInterval(-24 * 3600))
        var parts = ["共 \(history.records.count) 条"]
        if ui.historyFailedOnly || !ui.search.isEmpty { parts.append("显示 \(filtered.count) 条") }
        if failed24h > 0 { parts.append("24 小时内 \(failed24h) 次失败") }
        return VStack(spacing: 0) {
            Divider()
            HStack {
                Text(parts.joined(separator: " · ")).foregroundStyle(.secondary)
                Spacer()
                if let last = history.records.last {
                    Text("上次更新 " + XupFormat.relative.string(from: last.time)).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(.bar)
        }
    }
}

/// 一行记录。列宽常量与表头共用；920 宽窗口（侧栏 210）下无需横向滚动。
struct HistoryRow: View {
    let record: UpdateRecord

    static let spacing: CGFloat = 8
    static let timeWidth: CGFloat = 40
    static let iconWidth: CGFloat = 16
    static let versionWidth: CGFloat = 200
    static let durationWidth: CGFloat = 60
    static let resultWidth: CGFloat = 56
    static let triggerWidth: CGFloat = 40

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        HStack(spacing: Self.spacing) {
            Text(Self.time.string(from: record.time))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: Self.timeWidth, alignment: .leading)
                .help(XupFormat.relative.string(from: record.time))

            Image(systemName: record.kind.symbol)
                .foregroundStyle(.secondary)
                .frame(width: Self.iconWidth)
                .help(record.kind.title)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.name).lineLimit(1)
                Text(record.detail ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(record.detail ?? record.name)

            Text(record.versionText)
                .monospacedDigit()
                .foregroundStyle(record.ok ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Self.versionWidth, alignment: .leading)
                .help(record.versionText)

            Text(record.durationText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: Self.durationWidth, alignment: .trailing)

            resultBadge.frame(width: Self.resultWidth, alignment: .leading)

            Text(record.trigger.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
                .frame(width: Self.triggerWidth, alignment: .leading)
                .help("触发方式：\(record.trigger.label)")
        }
        .padding(.vertical, 4)
    }

    /// 结果徽标：沿用 StatusBadge 的 `.updated` / `.failed` 约定（绿 checkmark.seal.fill / 红 xmark.circle.fill）。
    private var resultBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: record.ok ? "checkmark.seal.fill" : "xmark.circle.fill").imageScale(.small)
            Text(record.ok ? "成功" : "失败")
        }
        .font(.caption)
        .foregroundStyle(record.ok ? Color.green : Color.red)
        .help(record.ok ? "更新成功" : (record.error ?? "更新失败"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(record.ok ? "成功" : "失败：\(record.error ?? "")")
    }
}
