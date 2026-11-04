import AppKit
import SwiftUI

/// §2.4 列表。
struct ItemTable: View {
    let items: [UpdateItem]
    let kind: ProviderKind?
    let onUpdate: (Set<String>) -> Void
    let onRemoveApps: (Set<String>) -> Void
    let onUntrack: (Set<String>) -> Void

    @EnvironmentObject private var center: UpdateCenter
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ui: UIState
    @State private var sortOrder: [KeyPathComparator<UpdateItem>] = []
    @State private var hintPopoverID: String?

    private var sorted: [UpdateItem] {
        guard let first = sortOrder.first else { return items }
        var list = items.sorted(using: sortOrder)
        // 除非显式按名称排序，可更新项永远在前。
        if first.keyPath != \UpdateItem.name {
            let head = list.filter(\.isActionable)
            let tail = list.filter { !$0.isActionable }
            list = head + tail
        }
        return list
    }

    var body: some View {
        Table(sorted, selection: $ui.selection, sortOrder: $sortOrder) {
            // 复选框与名称合并为一列：避免两列之间出现表头分隔线（UI-POLISH 2）。
            TableColumn("名称", value: \.name) { item in
                nameCell(item)
            }
            .width(min: 200)

            TableColumn(kind == .skill ? "本地更新于" : "已安装", value: \.installed) { item in
                Text(item.installed).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            .width(96)

            TableColumn(kind == .skill ? "远端提交" : "最新", value: \.latestText) { item in
                Text(item.latestText)
                    .monospacedDigit()
                    .fontWeight(item.status.isOutdated ? .medium : .regular)
                    .foregroundStyle(item.status.isOutdated ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            .width(96)

            TableColumn("状态", value: \.statusRank) { item in
                StatusBadge(item: withRunningPolicyHint(item))
            }
            .width(150)

            TableColumn("操作") { item in
                actionCell(item)
            }
            .width(84)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(ids)
        } primaryAction: { ids in
            // 双击：可更新则更新
            onUpdate(ids)
        }
        .onDeleteCommand {
            if kind == .app { onRemoveApps(ui.selection) } else if kind != nil { onUntrack(ui.selection) }
        }
    }

    // MARK: 单元格

    @ViewBuilder private func checkCell(_ item: UpdateItem) -> some View {
        if item.isActionable {
            Toggle("选择 \(item.name)", isOn: Binding(
                get: { ui.checked.contains(item.id) },
                set: { on in if on { ui.checked.insert(item.id) } else { ui.checked.remove(item.id) } }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
        } else {
            Color.clear
        }
    }

    private func nameCell(_ item: UpdateItem) -> some View {
        HStack(spacing: 8) {
            checkCell(item).frame(width: 16, height: 16)
            if kind == nil {
                Image(systemName: item.kind.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .help(item.kind.title)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                Text(item.detail ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 4)
        .help(item.detail ?? item.name)
    }

    @ViewBuilder private func actionCell(_ item: UpdateItem) -> some View {
        HStack(spacing: 6) {
            switch item.status {
            case .outdated where item.canUpdate:
                Button("更新") { onUpdate([item.id]) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(center.isChecking || !center.updatingIDs.isEmpty)
            case .outdated:
                Button {
                    hintPopoverID = item.id
                } label: {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(item.hint ?? "Xup 无法替你更新此条目")
                .popover(isPresented: Binding(get: { hintPopoverID == item.id }, set: { if !$0 { hintPopoverID = nil } })) {
                    Text(item.hint ?? "Xup 无法替你更新此条目").padding(12).frame(maxWidth: 260)
                }
            case .updating:
                ProgressView().controlSize(.mini)
            case .failed:
                Button { onUpdate([item.id]) } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .help("重试")
                    .disabled(!center.updatingIDs.isEmpty)
                Button {
                    ui.showLog = true
                    ui.logErrorsOnly = false
                    ui.logScrollTarget = center.log.last { $0.isError && $0.source == item.kind.title }?.id
                } label: { Image(systemName: "terminal") }
                    .buttonStyle(.borderless)
                    .help("查看日志")
            case .unknown where item.isSelfUpdating:
                // §16.4 自更新行：主操作为"启动应用"。
                if let app = managedApp(for: item) {
                    Button { Task { await center.launch(app) } } label: { Label("启动应用", systemImage: "play.fill") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("启动 \(item.name)，让它自己检查更新；若已在运行则置前")
                }
            default:
                EmptyView()
            }
        }
    }

    /// 非自更新的应用行对应的"运行中处理方式"；其它分区返回 nil。
    private func runningPolicy(for item: UpdateItem) -> AppRunningPolicy? {
        guard item.kind == .app, !item.isSelfUpdating, let app = managedApp(for: item) else { return nil }
        return AppRunningPolicy(restartAfterUpdate: app.restartAfterUpdate)
    }

    /// §17：策略为"等我关闭后再更新"、应用正在运行且有新版本时，状态列补一句提示。
    private func withRunningPolicyHint(_ item: UpdateItem) -> UpdateItem {
        guard item.status.isOutdated, item.canUpdate, runningPolicy(for: item) == .waitForQuit,
              let path = item.appPath, AppRunningPolicy.isRunning(appPath: path) else { return item }
        var copy = item
        copy.hint = AppRunningPolicy.skippedWhileRunningHint
        return copy
    }

    /// 应用条目对应的 ManagedApp（path = id 去掉 "app:" 前缀）。
    private func managedApp(for item: UpdateItem) -> ManagedApp? {
        guard let path = item.appPath else { return nil }
        return settings.managedApps.first { $0.path == path }
    }

    // MARK: 右键菜单

    @ViewBuilder private func contextMenu(_ ids: Set<String>) -> some View {
        let selected = items.filter { ids.contains($0.id) }
        let updatable = selected.filter { $0.canUpdate && ($0.isActionable || $0.isFailed) }
        Button("更新") { onUpdate(Set(updatable.map(\.id))) }
            .disabled(updatable.isEmpty || !center.updatingIDs.isEmpty)
        if selected.count == 1, let single = selected.first, let app = managedApp(for: single) {
            // §16.3 / §16.4 / §17：应用行的"启动应用"（仅自更新行）与"配置应用…"（运行时策略 + 更新来源）。
            if single.isSelfUpdating {
                Button { Task { await center.launch(app) } } label: { Label("启动应用", systemImage: "play.circle") }
            }
            Button { ui.presentSourceSheet(for: app) } label: { Label("配置应用…", systemImage: "slider.horizontal.3") }
        }
        if selected.count == 1, let path = selected.first?.filePath {
            Button("在 Finder 中显示") { XupActions.revealInFinder(path) }
        }
        Divider()
        Button("复制名称") { XupActions.copy(selected.map(\.name).joined(separator: "\n")) }
            .disabled(selected.isEmpty)
        Button("复制版本") {
            XupActions.copy(selected.map { "\($0.name) \($0.installed)" + ($0.latest.map { " → \($0)" } ?? "") }.joined(separator: "\n"))
        }
        .disabled(selected.isEmpty)
        if !selected.isEmpty, selected.allSatisfy({ $0.kind == .app }) {
            Divider()
            Button("移除", role: .destructive) { onRemoveApps(ids) }
        } else if !selected.isEmpty, !selected.contains(where: { $0.kind == .app }) {
            Divider()
            Button { onUntrack(ids) } label: { Label("取消关注", systemImage: "eye.slash") }
        }
    }
}
