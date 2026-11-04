import SwiftUI

/// §13.7 设置 › 软件：原"选择软件…"Sheet 的主体并入设置窗口。分段 Picker + 搜索，每段独立加载并缓存；
/// 勾选即时写入关注列表（300ms 去抖），底部"立即检查"触发一次检查。
struct WatchListPane: View {
    @EnvironmentObject private var center: UpdateCenter
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ui: UIState

    private enum LoadState {
        case loading
        case loaded([InstalledEntry])
        case failed(String)
        case unavailable
    }

    @State private var segment: ProviderKind = .homebrew
    @State private var query = ""
    @State private var selections: [ProviderKind: Set<String>] = [:]
    @State private var states: [ProviderKind: LoadState] = [:]
    @State private var loadTasks: [ProviderKind: Task<Void, Never>] = [:]
    /// 去抖写入关注列表的任务（按分段）。
    @State private var commitTasks: [ProviderKind: Task<Void, Never>] = [:]
    @FocusState private var searchFocused: Bool

    // MARK: 派生

    private var entries: [InstalledEntry] {
        if case .loaded(let list)? = states[segment] { return list }
        return []
    }

    private var filtered: [InstalledEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.name.localizedCaseInsensitiveContains(q) || ($0.detail?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var selected: Set<String> { selections[segment] ?? [] }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var isLoaded: Bool { if case .loaded? = states[segment] { return true } else { return false } }
    private var isUnavailable: Bool { if case .unavailable? = states[segment] { return true } else { return false } }

    private var countText: String {
        var s = "已关注 \(selected.count) 项"
        if isLoaded {
            s += " · 共 \(entries.count) 项"
            if isSearching { s += "（显示 \(filtered.count) 项）" }
        }
        return s
    }

    private func isUnavailable(_ kind: ProviderKind) -> Bool {
        if case .unavailable? = states[kind] { return true }
        return center.unavailable.contains(kind)
    }

    // MARK: 视图

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            listArea.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            segment = ui.pickerKind
            selections = settings.tracked
            ui.hasSeenWatchPicker = true
            load(segment)
        }
        .onChange(of: ui.pickerKind) { _, k in
            // 其它入口（工具栏 / 空状态）在设置窗口已打开时再次定位分段。
            segment = k
        }
        .onChange(of: segment) { _, k in
            load(k)
        }
        .onChange(of: settings.tracked) { _, t in
            // 外部修改（右键"取消关注"、CLI）同步到勾选；本视图的写入回流时内容一致，无副作用。
            for kind in ProviderKind.pickerOrder where commitTasks[kind] == nil {
                selections[kind] = t[kind] ?? []
            }
        }
        .onDisappear {
            loadTasks.values.forEach { $0.cancel() }
            // 还没落盘的去抖写入立即提交。
            for kind in commitTasks.keys { flush(kind) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("选择要跟踪的软件").font(.headline)
                Text("只有勾选的条目会被检查和更新。勾选即时生效；改完可点“立即检查”。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // 分段控件保持固有宽度；放不下时搜索框换到下一行。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    segmentPicker
                    Spacer(minLength: 0)
                    searchField
                }
                VStack(alignment: .leading, spacing: 8) {
                    segmentPicker
                    searchField
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var segmentPicker: some View {
        Picker("来源", selection: $segment) {
            ForEach(ProviderKind.pickerOrder) { kind in
                Text(kind.title)
                    .foregroundStyle(isUnavailable(kind) ? .tertiary : .primary)
                    .help(isUnavailable(kind) ? "未检测到 \(kind.title)" : kind.title)
                    .tag(kind)
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
                .focused($searchFocused)
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

    @ViewBuilder private var listArea: some View {
        switch states[segment] {
        case .loading?, nil:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("正在读取 \(segment.title) 已安装列表…").font(.callout).foregroundStyle(.secondary)
                Text(segment.listCommand).font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
            }
        case .unavailable?:
            smallEmpty(symbol: "exclamationmark.triangle", title: "未检测到 \(segment.title)",
                       description: "Xup 在 PATH 中找不到对应工具。安装后点击“重新检测”。",
                       button: "重新检测", help: nil) { reload(segment) }
        case .failed(let msg)?:
            smallEmpty(symbol: "exclamationmark.triangle", title: "读取\(segment.title)失败",
                       description: msg.split(separator: "\n").first.map(String.init) ?? msg,
                       button: "重试", help: msg) { reload(segment) }
        case .loaded(let list)?:
            if list.isEmpty {
                smallEmpty(symbol: segment.symbol, title: "没有找到已安装的 \(segment.installedNoun)",
                           description: "安装后点击“重新读取”。", button: "重新读取", help: nil) { reload(segment) }
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
            Text(entry.version)
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 110, alignment: .trailing)
        }
        .frame(height: 36)
        .contentShape(Rectangle())
        .onTapGesture { set(entry.name, !on) }
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
            if center.isChecking {
                ProgressView().controlSize(.small)
                Text("正在检查…").font(.caption).foregroundStyle(.secondary)
            }
            Button("立即检查") { checkNow() }
                .buttonStyle(.borderedProminent)
                .disabled(center.isChecking || settings.tracked.values.allSatisfy(\.isEmpty))
                .help("按当前关注列表检查一次更新")
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
    }

    // MARK: 逻辑

    private func set(_ name: String, _ on: Bool) {
        var s = selections[segment] ?? []
        if on { s.insert(name) } else { s.remove(name) }
        selections[segment] = s
        scheduleCommit(segment)
    }

    /// 全选 / 清空只作用于当前过滤结果。
    private func select(all: Bool) {
        var s = selections[segment] ?? []
        let names = filtered.map(\.name)
        if all { s.formUnion(names) } else { s.subtract(names) }
        selections[segment] = s
        scheduleCommit(segment)
    }

    /// 勾选即时生效：300ms 去抖后写入 `settings.setTracked`，连续点击只落盘一次。
    private func scheduleCommit(_ kind: ProviderKind) {
        commitTasks[kind]?.cancel()
        commitTasks[kind] = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            flush(kind)
        }
    }

    private func flush(_ kind: ProviderKind) {
        commitTasks[kind]?.cancel()
        commitTasks[kind] = nil
        let names = selections[kind] ?? []
        if names != (settings.tracked[kind] ?? []) {
            settings.setTracked(kind, names: names)
        }
    }

    private func checkNow() {
        for kind in commitTasks.keys { flush(kind) }
        ui.check(center: center)
    }

    private func load(_ kind: ProviderKind) {
        guard states[kind] == nil else { return }
        if center.unavailable.contains(kind) {
            states[kind] = .unavailable
            return
        }
        reload(kind)
    }

    private func reload(_ kind: ProviderKind) {
        loadTasks[kind]?.cancel()
        states[kind] = .loading
        loadTasks[kind] = Task {
            do {
                let list = try await center.listInstalled(for: kind)
                guard !Task.isCancelled else { return }
                states[kind] = .loaded(list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
            } catch {
                guard !Task.isCancelled else { return }
                if case ShellError.notFound = error {
                    states[kind] = .unavailable
                } else {
                    states[kind] = .failed(error.localizedDescription)
                }
            }
        }
    }
}
