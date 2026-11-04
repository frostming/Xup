import AppKit
import SwiftUI

/// §7 设置窗口：四 Tab 统一 620×520（§13.7 "软件"Tab 为原"选择软件…"Sheet，需要这个尺寸；其余 Tab 为可滚动 Form）。
/// Tab 选择由 `UIState.settingsTab` 驱动，便于主窗口 / 菜单栏入口直接定位到某个 Tab。
struct SettingsView: View {
    @EnvironmentObject private var ui: UIState

    static let tabSize = CGSize(width: 620, height: 520)

    var body: some View {
        TabView(selection: $ui.settingsTab) {
            GeneralSettings()
                .frame(width: Self.tabSize.width, height: Self.tabSize.height)
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            WatchListPane()
                .frame(width: Self.tabSize.width, height: Self.tabSize.height)
                .tabItem { Label("软件", systemImage: "checklist") }
                .tag(SettingsTab.watch)
            AgentsSettings()
                .frame(width: Self.tabSize.width, height: Self.tabSize.height)
                .tabItem { Label("Agents", systemImage: "cpu") }
                .tag(SettingsTab.agents)
            AppsSettings()
                .frame(width: Self.tabSize.width, height: Self.tabSize.height)
                .tabItem { Label("应用", systemImage: "macwindow") }
                .tag(SettingsTab.apps)
        }
        .background(WindowSnapshotHook("settings", delay: 1.5))
    }
}

// MARK: - 通用

struct GeneralSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var center: UpdateCenter
    @EnvironmentObject private var ui: UIState
    @Environment(\.openWindow) private var openWindow
    @State private var stagedSize: Int64 = 0

    private var trackedCount: Int {
        settings.tracked.values.reduce(0) { $0 + $1.count } + settings.managedApps.count
    }

    /// 默认策略为手动且没有任何条目是自动时，空闲判定行置灰（仍可改）。
    private var idleRowDimmed: Bool {
        settings.defaultPolicy == .manual && !settings.config.policies.values.contains { $0 != .manual }
    }

    private enum Interval: Hashable {
        case preset(Int), custom
    }

    private static let presets: [(Int, String)] = [
        (15, "15 分钟"), (60, "1 小时"), (360, "6 小时"), (720, "12 小时"), (1440, "每天"),
    ]

    private var isCustom: Bool {
        settings.checkIntervalMinutes != 0 && !Self.presets.contains { $0.0 == settings.checkIntervalMinutes }
    }

    private var intervalChoice: Binding<Interval> {
        Binding(
            get: { isCustom ? .custom : .preset(settings.checkIntervalMinutes) },
            set: { choice in
                switch choice {
                case .preset(let m): settings.checkIntervalMinutes = m
                case .custom: if !isCustom { settings.checkIntervalMinutes = 30 }
                }
            }
        )
    }

    private var customMinutes: Binding<Int> {
        Binding(
            get: { settings.checkIntervalMinutes },
            set: { settings.checkIntervalMinutes = max(5, $0) }
        )
    }

    var body: some View {
        Form {
            Section("检查") {
                Picker("检查间隔", selection: intervalChoice) {
                    ForEach(Self.presets, id: \.0) { m, title in
                        Text(title).tag(Interval.preset(m))
                    }
                    Text("自定义…").tag(Interval.custom)
                    Divider()
                    Text("关闭").tag(Interval.preset(0))
                }
                if isCustom {
                    HStack {
                        Text("每")
                        TextField("", value: customMinutes, format: .number)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                            .labelsHidden()
                        Stepper("", value: customMinutes, in: 5...(60 * 24 * 7), step: 5).labelsHidden()
                        Text("分钟检查一次（最小 5）").foregroundStyle(.secondary)
                    }
                }
                Toggle("发现更新时通知", isOn: $settings.notifyOnUpdates)

                // §19.5 两项：新关注条目的默认更新方式 + 空闲判定。
                Picker("新关注条目的默认更新方式", selection: $settings.defaultPolicy) {
                    Text(UpdatePolicy.manual.title).tag(UpdatePolicy.manual)
                    Text(UpdatePolicy.auto.title).tag(UpdatePolicy.auto)
                }
                .pickerStyle(.menu)
                Text("只影响之后新关注的条目；已有条目保留各自的更新方式，可在列表右键“更新方式”中逐条修改。")
                    .font(.footnote).foregroundStyle(.secondary)

                HStack {
                    Text("空闲判定")
                    Spacer()
                    Text("无操作")
                    TextField("", value: $settings.idleMinutes, format: .number)
                        .frame(width: 44)
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                    Stepper("", value: $settings.idleMinutes, in: 1...60).labelsHidden()
                    Text("分钟后视为空闲")
                }
                .foregroundStyle(idleRowDimmed ? .secondary : .primary)
                Text("“空闲时自动更新”的条目会等到这么久没有键盘鼠标输入后才开始更新；锁屏与屏幕保护视为空闲。")
                    .font(.footnote).foregroundStyle(.secondary)

                if center.stagedCount > 0 {
                    LabeledContent("已下载待安装的更新") {
                        HStack(spacing: 8) {
                            Text("\(center.stagedCount) 项 · \(ByteCountFormatter.string(fromByteCount: stagedSize, countStyle: .file))")
                                .foregroundStyle(.secondary)
                            Button("清除") { center.clearAllStaged(); stagedSize = 0 }
                                .controlSize(.small)
                                .help("删除已下载暂存的安装包；下次定时检查会重新下载")
                        }
                    }
                    .onAppear { stagedSize = StagingStore.totalSize() }
                }
            }

            Section("Homebrew") {
                Toggle("包含自动更新的 cask (--greedy)", isOn: $settings.brewGreedy)
                Text("检查会把自带更新机制的应用（如 Chrome）也列为可更新。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("显示") {
                Toggle("显示已是最新的条目", isOn: $settings.showUpToDate)
                Toggle("登录时启动", isOn: $settings.launchAtLogin)
                    .disabled(!AppSettings.isRunningInAppBundle)
                if !AppSettings.isRunningInAppBundle {
                    Text("仅在打包为 .app 运行时可用。").font(.footnote).foregroundStyle(.secondary)
                }
                if let err = settings.launchAtLoginError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.red)
                }
            }

            Section("配置文件") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(settings.configDisplayPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    HStack {
                        Button { XupActions.revealInFinder(settings.configURL.path) } label: {
                            Label("在 Finder 中显示", systemImage: "folder")
                        }
                        Button { settings.reloadConfig() } label: {
                            Label("重新加载", systemImage: "arrow.clockwise")
                        }
                    }
                    if let err = settings.configError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.red)
                    } else {
                        Text("可直接编辑此文件或使用 `xup` 命令行，保存后 Xup 会自动热加载；格式见同目录的 config.schema.json。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                LabeledContent("跟踪的软件", value: "\(trackedCount) 项")
                Button {
                    ui.selectWatchTab(kind: ui.sidebar?.kind)
                } label: {
                    Label("选择软件…", systemImage: "checklist")
                }
                .help("切换到“软件”Tab，勾选要跟踪的条目")
                LabeledContent("版本", value: XupFormat.appVersion)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Agents

struct AgentsSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var specs: [AgentSpec] = []
    @State private var selected: AgentSpec.ID?
    @State private var confirmReset = false

    private var displayPath: String {
        AppSettings.agentSpecsURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var body: some View {
        Form {
            Section {
                Text("Xup 内置了 Claude Code、Codex CLI、Gemini CLI、OpenCode、Amp、GitHub Copilot CLI、Cursor Agent 的检测规则。你可以编辑 agents.json 来增删 agent 或修改更新命令。")
                    .font(.callout)
                if let err = settings.agentSpecsError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.red)
                }
                Table(specs, selection: $selected) {
                    TableColumn("名称") { s in Text(s.name) }.width(min: 90)
                    TableColumn("二进制") { s in Text(s.binary).font(.system(.caption, design: .monospaced)) }.width(90)
                    TableColumn("npm 包") { s in
                        Text(s.npmPackage ?? "—").font(.system(.caption, design: .monospaced)).foregroundStyle(s.npmPackage == nil ? .secondary : .primary)
                    }.width(min: 110)
                    TableColumn("更新命令") { s in
                        if let cmd = s.updateCommand, !cmd.isEmpty {
                            Text(cmd.joined(separator: " ")).font(.system(.caption, design: .monospaced))
                        } else {
                            Text("— · 仅检测版本").font(.caption).foregroundStyle(.secondary)
                        }
                    }.width(min: 120)
                }
                .frame(height: 220)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button { XupActions.revealInFinder(AppSettings.agentSpecsURL.path) } label: {
                            Label("在 Finder 中显示", systemImage: "folder")
                        }
                        Button { NSWorkspace.shared.open(AppSettings.agentSpecsURL) } label: {
                            Label("用默认编辑器打开", systemImage: "square.and.pencil")
                        }
                        Button { reload() } label: {
                            Label("重新加载", systemImage: "arrow.clockwise")
                        }
                    }
                    HStack {
                        Text(displayPath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                        Button("恢复默认", role: .destructive) { confirmReset = true }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { reload() }
        .alert("恢复默认 agents.json？", isPresented: $confirmReset) {
            Button("恢复默认", role: .destructive) { resetToDefault() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将覆盖你对 agents.json 的修改，恢复为内置的检测规则。")
        }
    }

    private func reload() {
        specs = settings.loadAgentSpecs()
    }

    private func resetToDefault() {
        try? FileManager.default.removeItem(at: AppSettings.agentSpecsURL)
        reload()
    }
}

// MARK: - 应用

struct AppsSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var center: UpdateCenter
    @EnvironmentObject private var ui: UIState
    @State private var selected: Set<String> = []
    /// 设置窗口自己的 Sheet 状态（与主窗口的 ui.sourceSheetApp 分开，避免两处同时弹出）。
    @State private var sourceSheetApp: ManagedApp?

    var body: some View {
        // 不放在 Form(.grouped) 里：Form 本身是滚动视图，内嵌固定高度的 List 会出现"滚不动、没有滚动条、末行被裁"的问题。
        // 这里让 List 占满剩余高度并原生滚动，脚注固定在下方。
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if settings.managedApps.isEmpty {
                    ContentUnavailableView("还没有跟踪的应用", systemImage: "macwindow.badge.plus")
                } else {
                    List(settings.managedApps, selection: $selected) { app in
                        appRow(app)
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .onDeleteCommand { removeSelected() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))

            HStack(spacing: 0) {
                Button { add() } label: { Image(systemName: "plus").frame(width: 20, height: 20) }
                    .help("添加应用…")
                Divider().frame(height: 14)
                Button { removeSelected() } label: { Image(systemName: "minus").frame(width: 20, height: 20) }
                    .disabled(selected.isEmpty)
                    .help("移除选中的应用")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 6) {
                Text("Xup 会自动识别应用来自 Homebrew、Sparkle、electron-updater 还是 App Store，并用对应方式更新；识别不了的应用可点击行尾 › 手动配置 GitHub Releases、Tauri、electron-updater 或 Sparkle 来源。")
                Text(AppRunningPolicy.explanation)
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(20)
        .sheet(item: $sourceSheetApp) { app in
            AppSourceSheet(app: app)
        }
    }

    private func appRow(_ app: ManagedApp) -> some View {
        let item = center.items.first { $0.id == "app:\(app.path)" }
        let selfUpdating = item?.isSelfUpdating ?? false
        return HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).lineLimit(1)
                Text(app.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            sourceTag(app: app, item: item)
                .lineLimit(1)
                .fixedSize()
            // §17 / §19.3：更新方式 + 运行时策略 只读简述，如"空闲自动 · 运行中自动重开"；修改在"配置应用…"Sheet 里。
            if !selfUpdating {
                let running = AppRunningPolicy(restartAfterUpdate: app.restartAfterUpdate)
                let update = item.map { settings.policy(for: $0) } ?? settings.policy(for: app.itemID)
                Text("\(update.shortTag) · \(running.shortTag)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
                    .help("更新方式：\(update.title)" + (update == .autoDownload && app.installWhenIdle ? "（空闲且未运行时自动安装）" : "") + "；应用正在运行时：" + running.tooltip)
            }
            Button { sourceSheetApp = app } label: {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("配置应用…")
        }
        .tag(app.path)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { sourceSheetApp = app }
    }

    /// §16.5 来源标签三种样式：普通灰胶囊 / 自定义 accent / 自更新虚线。
    @ViewBuilder private func sourceTag(app: ManagedApp, item: UpdateItem?) -> some View {
        if let source = app.source {
            Label(source.tagText, systemImage: "slider.horizontal.3")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.10), in: Capsule())
                .help(source.tooltip)
        } else if item?.isSelfUpdating ?? false {
            Label("自更新", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2])).foregroundStyle(.tertiary))
                .help("无法识别且未配置：点击配置更新来源")
        } else {
            Text(appSourceTag(detail: item?.detail))
                .font(.caption)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: Capsule())
        }
    }

    private func add() {
        XupActions.chooseApps { paths in
            settings.addApps(paths: paths)
            ui.check(center: center)
        }
    }

    private func removeSelected() {
        for p in selected { settings.removeApp(path: p) }
        selected = []
        ui.check(center: center)
    }
}
