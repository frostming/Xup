import AppKit
import SwiftUI

/// §2 主窗口：NavigationSplitView 侧栏 + 内容。
struct MainWindow: View {
    @EnvironmentObject private var ui: UIState
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var debugOpenSettings

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            DetailView()
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(WindowSnapshotHook("main"))
        .sheet(item: $ui.sourceSheetApp) { app in
            AppSourceSheet(app: app)
        }
        .onAppear {
            if ui.debugOpenSettings {
                ui.debugOpenSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { XupActions.activate(); debugOpenSettings() }
            }
            NSLog("[Xup] MainWindow appeared, requested=\(ui.mainWindowRequested)")
            // 纯菜单栏应用：macOS 14 上随启动自动打开的主窗口若非明确请求（非首次启动），立即关闭。
            if !ui.mainWindowRequested && !ui.openMainWindowOnLaunch {
                dismissWindow(id: XupActions.mainWindowID)
                return
            }
            ui.mainWindowRequested = true
            if ui.openMainWindowOnLaunch { XupActions.activate() }
            // §13.7 首启引导不再自动弹 Sheet：欢迎态主按钮引导用户打开 设置 › 软件。
        }
    }
}

// MARK: - 侧栏

struct SidebarView: View {
    @EnvironmentObject private var center: UpdateCenter
    @EnvironmentObject private var ui: UIState

    var body: some View {
        List(selection: $ui.sidebar) {
            Label("全部", systemImage: "square.grid.2x2")
                .badge(center.actionableItems.count)
                .tag(SidebarItem.all)
            Section("来源") {
                ForEach(ProviderKind.sidebarOrder) { kind in
                    sidebarRow(kind).tag(SidebarItem.kind(kind))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
    }

    @ViewBuilder private func sidebarRow(_ kind: ProviderKind) -> some View {
        let unavailable = center.unavailable.contains(kind)
        let untracked = center.untrackedKinds.contains(kind)
        let error = center.providerErrors[kind]
        HStack {
            Label(kind.title, systemImage: kind.symbol)
                .foregroundStyle(unavailable ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            Spacer()
            if unavailable {
                Text("未安装").font(.caption).foregroundStyle(.tertiary)
            } else if untracked {
                EmptyView()
            } else if center.isChecking {
                ProgressView().controlSize(.mini)
            } else if let error {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .help(error)
            }
        }
        .badge(unavailable || untracked || center.isChecking ? 0 : center.count(for: kind))
        .help(unavailable ? "未检测到 \(kind.title)" : untracked ? "未选择要跟踪的软件" : kind.title)
    }
}

// MARK: - 内容区

struct DetailView: View {
    @EnvironmentObject private var center: UpdateCenter
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ui: UIState
    @Environment(\.openSettings) private var openSettings

    @State private var pendingConfirm: PendingUpdate?

    struct PendingUpdate: Identifiable {
        let id = UUID()
        let ids: Set<String>
        let message: String
        let button: String
    }

    private var kind: ProviderKind? { ui.sidebar?.kind }
    /// 只显示仍在关注集合中的条目（取消关注后无需重新检查即可消失）。
    private var baseItems: [UpdateItem] {
        center.items(for: kind).filter { $0.kind == .app || settings.isTracked($0.kind, $0.trackedKey) }
    }
    private var items: [UpdateItem] {
        let q = ui.search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return baseItems }
        return baseItems.filter {
            $0.name.localizedCaseInsensitiveContains(q) || ($0.detail?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }
    private var actionableInView: [UpdateItem] { baseItems.filter(\.isActionable) }
    /// "更新选中"的目标：复选框 ∪ 行选择 中的可操作项。
    private var selectedActionable: Set<String> {
        let chosen = ui.checked.union(ui.selection)
        return Set(items.filter { chosen.contains($0.id) && $0.isActionable }.map(\.id))
    }
    private var isUpdating: Bool { !center.updatingIDs.isEmpty || ui.batch != nil }
    private var busy: Bool { center.isChecking || isUpdating }

    private var subtitle: String {
        let n = actionableInView.count
        let name = ui.sidebar?.title ?? "全部"
        return n > 0 ? "\(name) · \(n) 个可更新" : name
    }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                StatusBarView(kind: kind, visibleItems: items)
            }
            .frame(minHeight: 160)
            if ui.showLog {
                LogPanel()
                    .frame(minHeight: 72, idealHeight: 160)
            }
        }
        .navigationTitle("Xup")
        .navigationSubtitle(subtitle)
        .searchable(text: $ui.search, placement: .toolbar, prompt: "搜索名称或来源")
        .toolbar { toolbar }
        .background(shortcutButtons)
        .onChange(of: center.isChecking) { _, checking in if checking { ui.showLog = true } }
        .onChange(of: center.updatingIDs.isEmpty) { _, empty in if !empty { ui.showLog = true } }
        .onChange(of: ui.sidebar) { _, _ in ui.selection = [] }
        .alert(item: $pendingConfirm) { p in
            Alert(title: Text("确认更新"), message: Text(p.message),
                  primaryButton: .default(Text(p.button)) { ui.update(ids: p.ids, center: center) },
                  secondaryButton: .cancel(Text("取消")))
        }
    }

    // MARK: 内容分派

    private var nothingTracked: Bool {
        settings.tracked.values.allSatisfy(\.isEmpty) && settings.managedApps.isEmpty
    }
    private var trackedCount: Int {
        settings.tracked.values.reduce(0) { $0 + $1.count } + settings.managedApps.count
    }

    @ViewBuilder private var content: some View {
        if let kind, center.unavailable.contains(kind) {
            EmptyStates.Unavailable(kind: kind) { ui.check(center: center) }
        } else if kind == .app, settings.managedApps.isEmpty {
            EmptyStates.NoApps(addApps: addApps)
        } else if let kind, center.untrackedKinds.contains(kind) {
            EmptyStates.Untracked(kind: kind) { openWatchList(kind: kind) }
        } else if kind == nil, allSourcesUnavailable, settings.managedApps.isEmpty {
            EmptyStates.NoSources(addApps: addApps)
        } else if kind == nil, nothingTracked {
            EmptyStates.Welcome(pick: { openWatchList(kind: nil) }, addApps: addApps)
        } else if center.isChecking, baseItems.isEmpty {
            EmptyStates.Checking(sources: ProviderKind.sidebarOrder.filter { !center.unavailable.contains($0) && !center.untrackedKinds.contains($0) }.map(\.title))
        } else if center.lastChecked == nil, center.items.isEmpty {
            EmptyStates.Ready(count: trackedCount) { ui.check(center: center) }
        } else if let kind, let err = center.providerErrors[kind], baseItems.isEmpty {
            EmptyStates.ProviderFailed(kind: kind, message: err) { ui.check(center: center) }
        } else if items.isEmpty, !ui.search.isEmpty {
            EmptyStates.NoResults(query: ui.search, clear: { ui.search = "" }, pick: { openWatchList(kind: kind) })
        } else if items.isEmpty {
            EmptyStates.AllUpToDate(total: center.items.filter { kind == nil || $0.kind == kind }.count,
                                    lastChecked: center.lastChecked) { ui.check(center: center) }
        } else {
            ItemTable(items: items, kind: kind, onUpdate: requestUpdate, onRemoveApps: removeApps, onUntrack: untrack)
                .padding(.leading, 8)
                .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    /// §13.7：所有"选择软件…"入口都打开 设置 › 软件 并定位到对应来源分段。
    private func openWatchList(kind: ProviderKind?) {
        ui.selectWatchTab(kind: kind)
        XupActions.activate()
        openSettings()
    }

    private var allSourcesUnavailable: Bool {
        ProviderKind.pickerOrder.allSatisfy { center.unavailable.contains($0) }
    }

    // MARK: 工具栏

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if center.isChecking {
                ProgressView().controlSize(.small).help("正在检查更新…")
            } else {
                Button { ui.check(center: center) } label: { Label("检查更新", systemImage: "arrow.clockwise") }
                    .help("检查更新 (⌘R)")
                    .disabled(busy)
                    .keyboardShortcut("r", modifiers: .command)
            }

            Button { requestUpdate(selectedActionable) } label: {
                Label(selectedActionable.isEmpty ? "更新选中" : "更新选中 (\(selectedActionable.count))",
                      systemImage: "arrow.down.circle")
            }
            .help("更新勾选的条目 (⌘U)")
            .disabled(busy || selectedActionable.isEmpty)
            .keyboardShortcut("u", modifiers: .command)

            Button { requestUpdate(Set(actionableInView.map(\.id))) } label: {
                Label("全部更新", systemImage: "arrow.down.to.line")
            }
            .help("更新当前分区的全部可更新项 (⇧⌘U)")
            .disabled(busy || actionableInView.isEmpty)
            .keyboardShortcut("u", modifiers: [.command, .shift])

            if kind == .app {
                Button(action: addApps) { Label("添加应用…", systemImage: "plus") }
                    .help("添加应用… (⌘N)")
                    .keyboardShortcut("n", modifiers: .command)
            } else {
                Button { openWatchList(kind: kind) } label: { Label("选择软件…", systemImage: "checklist") }
                    .help("在设置 › 软件中选择要跟踪的软件 (⇧⌘N)")
                    .disabled(isUpdating)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            Toggle(isOn: $ui.showLog) { Label("日志", systemImage: "terminal") }
                .help("显示/隐藏日志 (⌥⌘L)")
                .keyboardShortcut("l", modifiers: [.command, .option])
        }
    }

    /// 不占空间的快捷键载体：⌘1…8 切换分区。
    private var shortcutButtons: some View {
        Group {
            Button("") { ui.sidebar = .all }.keyboardShortcut("1", modifiers: .command)
            ForEach(Array(ProviderKind.sidebarOrder.enumerated()), id: \.offset) { i, k in
                Button("") { ui.sidebar = .kind(k) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 2)")), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: 动作

    private func requestUpdate(_ ids: Set<String>) {
        let targets = center.items.filter { ids.contains($0.id) && $0.canUpdate && ($0.isActionable || $0.isFailed) }
        guard !targets.isEmpty else { return }
        let running = XupActions.runningApps(among: targets)
        var messages: [String] = []
        if targets.count > 5 {
            var m = "将更新 \(targets.count) 个条目，可能需要几分钟。"
            if settings.brewGreedy, targets.contains(where: { $0.kind == .homebrew }) { m += "（包含自动更新的 cask）" }
            messages.append(m)
        }
        if !running.isEmpty {
            messages.append("以下应用正在运行，更新时将被退出：\(running.joined(separator: "、"))。继续？")
        }
        if messages.isEmpty {
            ui.update(ids: Set(targets.map(\.id)), center: center)
        } else {
            pendingConfirm = PendingUpdate(ids: Set(targets.map(\.id)), message: messages.joined(separator: "\n\n"),
                                           button: running.isEmpty ? "全部更新" : "更新并重启")
        }
    }

    private func addApps() {
        XupActions.chooseApps { paths in
            settings.addApps(paths: paths)
            ui.sidebar = .kind(.app)
            ui.check(center: center)
        }
    }

    /// 取消关注：从关注集合移除；列表由 `baseItems` 按 `isTracked` 过滤立即消失。
    private func untrack(_ ids: Set<String>) {
        let targets = center.items.filter { ids.contains($0.id) && $0.kind != .app }
        guard !targets.isEmpty else { return }
        for t in targets { settings.untrack(t.kind, t.trackedKey) }
        ui.selection.subtract(ids)
        ui.checked.subtract(ids)
    }

    private func removeApps(_ ids: Set<String>) {
        let paths = center.items.filter { ids.contains($0.id) }.compactMap(\.appPath)
        guard !paths.isEmpty else { return }
        for p in paths { settings.removeApp(path: p) }
        ui.selection.subtract(ids)
        ui.checked.subtract(ids)
        ui.check(center: center)
    }
}

// MARK: - 状态栏

struct StatusBarView: View {
    let kind: ProviderKind?
    let visibleItems: [UpdateItem]
    @EnvironmentObject private var center: UpdateCenter
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ui: UIState

    private var scoped: [UpdateItem] { center.items.filter { kind == nil || $0.kind == kind } }
    private var actionable: [UpdateItem] { visibleItems.filter(\.isActionable) }

    private var stats: String {
        if let kind, kind != .app, center.untrackedKinds.contains(kind) { return "未跟踪任何 \(kind.installedNoun)" }
        var parts = ["共 \(scoped.count) 项"]
        let outdated = scoped.filter { $0.status.isOutdated }.count
        if outdated > 0 { parts.append("\(outdated) 个可更新") }
        let failed = scoped.filter(\.isFailed).count
        if failed > 0 { parts.append("\(failed) 个失败") }
        if kind == .app {
            let selfUpdating = scoped.filter(\.isSelfUpdating).count
            if selfUpdating > 0 { parts.append("\(selfUpdating) 个由应用自更新") }
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Text(stats).foregroundStyle(.secondary)
                Spacer()
                middle
                Spacer()
                Text(center.isChecking ? "正在检查…" : XupFormat.lastChecked(center.lastChecked))
                    .foregroundStyle(.secondary)
                    .help(XupFormat.nextCheck(interval: settings.checkIntervalMinutes, last: center.lastChecked))
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(.bar)
            Divider()
        }
    }

    @ViewBuilder private var middle: some View {
        if let p = ui.progress(center: center) {
            HStack(spacing: 8) {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).frame(width: 120)
                Text("正在更新 \(p.current ?? "…") (\(min(p.done + 1, p.total))/\(p.total))")
            }
        } else if !center.updatingIDs.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在自动更新 \(center.items.first { center.updatingIDs.contains($0.id) }?.name ?? "")")
            }
        } else if let c = ui.completion {
            Text(c.text).foregroundStyle(c.failed ? .red : .secondary)
        } else if center.isChecking {
            Text("正在检查 " + ProviderKind.sidebarOrder.filter { !center.unavailable.contains($0) && !center.untrackedKinds.contains($0) }.map(\.title).joined(separator: "、") + "…")
                .foregroundStyle(.secondary)
        }
    }
}
