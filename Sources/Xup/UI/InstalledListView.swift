import SwiftUI

/// §21 "添加要跟踪的 <来源>" Sheet（560×480）：头部 标题 / 说明 / （"全部"分区打开时）来源 Picker + 搜索框；
/// 主体为 `InstalledListView`（本机已安装清单，勾选即关注）；底部 全选 / 清空 / 计数 / 完成。
/// "完成"或关闭 Sheet 后，若期间改过关注列表（`ui.pendingRecheckKinds`）则检查一次。
struct AddWatchSheet: View {
    let request: AddWatchRequest

    @EnvironmentObject private var center: UpdateCenter
    @EnvironmentObject private var ui: UIState
    @Environment(\.dismiss) private var dismiss

    @State private var kind: ProviderKind = .homebrew
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            InstalledListView(kind: kind, query: $query) { dismiss() }
                .id(kind)
        }
        .frame(width: 560, height: 480)
        .onAppear { kind = request.kind }
        .onChange(of: kind) { _, _ in query = "" }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(request.showsPicker ? "添加要跟踪的软件" : "添加要跟踪的 \(request.kind.title)").font(.headline)
                Text("从本机已安装的\(kind.installedNoun)中勾选，勾选即时生效；点“完成”后 Xup 会检查一次新关注的条目。")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if request.showsPicker {
                // "全部"分区：六个来源的分段 Picker；放不下时搜索框换行。
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        sourcePicker
                        Spacer(minLength: 0)
                        searchField
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        sourcePicker
                        searchField
                    }
                }
            } else {
                searchField.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func isUnavailable(_ k: ProviderKind) -> Bool { center.unavailable.contains(k) }

    private var sourcePicker: some View {
        Picker("来源", selection: $kind) {
            ForEach(ProviderKind.pickerOrder) { k in
                Text(k.title)
                    .foregroundStyle(isUnavailable(k) ? .tertiary : .primary)
                    .help(isUnavailable(k) ? "未检测到 \(k.title)" : k.title)
                    .tag(k)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).imageScale(.small)
            TextField("搜索", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).imageScale(.small)
                }
                .buttonStyle(.plain)
                .help("清除")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .frame(minWidth: 160, maxWidth: 240)
    }
}

/// 某来源的本机已安装清单（原 §13.7 `WatchListPane` 的单来源形态）：勾选即关注（300ms 去抖写入），
/// 底部 全选 / 清空 / `已关注 N 项 · 共 M 项` / 完成。四态（加载中 / 为空 / 读取失败 / 不可用）不变。
/// 搜索文本由外部（`AddWatchSheet` 的搜索框）通过 `query` 传入。
struct InstalledListView: View {
    let kind: ProviderKind
    @Binding var query: String
    /// "完成"按钮：由调用方关闭 Sheet；本视图先落盘未提交的勾选。
    let onDone: () -> Void

    @EnvironmentObject private var center: UpdateCenter
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ui: UIState

    private enum LoadState {
        case loading
        case loaded([InstalledEntry])
        case failed(String)
        case unavailable
    }

    @State private var selected: Set<String> = []
    @State private var state: LoadState = .loading
    @State private var loadTask: Task<Void, Never>?
    /// 去抖写入关注列表的任务。
    @State private var commitTask: Task<Void, Never>?

    // MARK: 派生

    private var entries: [InstalledEntry] {
        if case .loaded(let list) = state { return list }
        return []
    }

    private var filtered: [InstalledEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.name.localizedCaseInsensitiveContains(q) || ($0.detail?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var isLoaded: Bool { if case .loaded = state { return true } else { return false } }

    private var countText: String {
        var s = "已关注 \(selected.count) 项"
        if isLoaded {
            s += " · 共 \(entries.count) 项"
            if isSearching { s += "（显示 \(filtered.count) 项）" }
        }
        return s
    }

    // MARK: 视图

    var body: some View {
        VStack(spacing: 0) {
            listArea.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            selected = settings.tracked[kind] ?? []
            ui.hasSeenWatchPicker = true
            load()
        }
        .onChange(of: settings.tracked) { _, t in
            // 外部修改（右键"取消关注"、CLI）同步到勾选；本视图的写入回流时内容一致，无副作用。
            if commitTask == nil { selected = t[kind] ?? [] }
        }
        .onDisappear {
            loadTask?.cancel()
            // 还没落盘的去抖写入立即提交。
            flush()
        }
    }

    @ViewBuilder private var listArea: some View {
        switch state {
        case .loading:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("正在读取 \(kind.title) 已安装列表…").font(.callout).foregroundStyle(.secondary)
                Text(kind.listCommand).font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
            }
        case .unavailable:
            smallEmpty(symbol: "exclamationmark.triangle", title: "未检测到 \(kind.title)",
                       description: "Xup 在 PATH 中找不到对应工具。安装后点击“重新检测”。",
                       button: "重新检测", help: nil) { reload() }
        case .failed(let msg):
            smallEmpty(symbol: "exclamationmark.triangle", title: "读取\(kind.title)失败",
                       description: msg.split(separator: "\n").first.map(String.init) ?? msg,
                       button: "重试", help: msg) { reload() }
        case .loaded(let list):
            if list.isEmpty {
                smallEmpty(symbol: kind.symbol, title: "没有找到已安装的 \(kind.installedNoun)",
                           description: "安装后点击“重新读取”。", button: "重新读取", help: nil) { reload() }
            } else if filtered.isEmpty {
                smallEmpty(symbol: "magnifyingglass", title: "没有匹配“\(query)”的条目",
                           description: nil, button: "清除搜索", help: nil) { query = "" }
            } else {
                List(filtered) { entry in
                    row(entry)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }
                .listStyle(.plain)
                .alternatingRowBackgrounds()
            }
        }
    }

    private func row(_ entry: InstalledEntry) -> some View {
        let on = selected.contains(entry.name)
        return HStack(spacing: 10) {
            Toggle("选择 \(entry.name)", isOn: Binding(get: { on }, set: { set(entry.name, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                if let d = entry.detail, !d.isEmpty {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            // §19.3 (3)：已关注行显示策略小标签（含"手动"），点击弹出菜单修改。
            if on {
                let target = PolicyTarget(kind: kind, name: entry.name, detail: entry.detail)
                Menu {
                    PolicyMenuItems(targets: [target])
                } label: {
                    PolicyTag(policy: settings.policy(for: target.id))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更新方式：点击修改")
            }
            Text(entry.version)
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 110, alignment: .trailing)
        }
        .frame(height: 36)
        .contentShape(Rectangle())
        .onTapGesture { set(entry.name, !on) }
        .contextMenu {
            if on {
                Menu("更新方式") { PolicyMenuItems(targets: [PolicyTarget(kind: kind, name: entry.name, detail: entry.detail)]) }
            }
        }
    }

    private func smallEmpty(symbol: String, title: String, description: String?, button: String,
                            help: String?, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if let description {
                Text(description).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(2)
                    .help(help ?? description)
            }
            Button(action: action) { Label(button, systemImage: button == "清除搜索" ? "xmark.circle" : "arrow.clockwise") }
                .buttonStyle(.bordered)
                .padding(.top, 4)
        }
        .padding(24)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("全选") { select(all: true) }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .disabled(filtered.isEmpty)
            Button("清空") { select(all: false) }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .disabled(filtered.isEmpty)
            Text(countText).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("完成") { flush(); onDone() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help(ui.pendingRecheckKinds.isEmpty ? "关闭" : "关闭并检查一次新关注的条目")
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
    }

    // MARK: 逻辑

    private func set(_ name: String, _ on: Bool) {
        if on { selected.insert(name) } else { selected.remove(name) }
        scheduleCommit()
    }

    /// 全选 / 清空只作用于当前过滤结果。
    private func select(all: Bool) {
        let names = filtered.map(\.name)
        if all { selected.formUnion(names) } else { selected.subtract(names) }
        scheduleCommit()
    }

    /// 勾选即时生效：300ms 去抖后写入 `settings.setTracked`，连续点击只落盘一次。
    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    /// 落盘；有实际变化时记入 `ui.pendingRecheckKinds`，Sheet 关闭时检查一次。
    private func flush() {
        commitTask?.cancel()
        commitTask = nil
        if selected != (settings.tracked[kind] ?? []) {
            settings.setTracked(kind, names: selected)
            ui.pendingRecheckKinds.insert(kind)
        }
    }

    private func load() {
        if let cached = ui.installedCache[kind] {
            state = .loaded(cached)
            return
        }
        if center.unavailable.contains(kind) {
            state = .unavailable
            return
        }
        reload()
    }

    private func reload() {
        loadTask?.cancel()
        ui.installedCache[kind] = nil
        state = .loading
        loadTask = Task {
            do {
                let list = try await center.listInstalled(for: kind)
                guard !Task.isCancelled else { return }
                let sorted = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                ui.installedCache[kind] = sorted
                state = .loaded(sorted)
            } catch {
                guard !Task.isCancelled else { return }
                if case ShellError.notFound = error {
                    state = .unavailable
                } else {
                    state = .failed(error.localizedDescription)
                }
            }
        }
    }
}
