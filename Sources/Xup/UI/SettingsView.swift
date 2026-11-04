import AppKit
import SwiftUI

/// §7 设置窗口：宽 520，三 Tab。
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("通用", systemImage: "gearshape") }
            AgentsSettings()
                .tabItem { Label("Agents", systemImage: "cpu") }
            AppsSettings()
                .tabItem { Label("应用", systemImage: "macwindow") }
        }
        .frame(width: 520)
        .background(WindowSnapshotHook("settings", delay: 1.5))
    }
}

// MARK: - 通用

struct GeneralSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ui: UIState
    @Environment(\.openWindow) private var openWindow

    private var trackedCount: Int {
        settings.tracked.values.reduce(0) { $0 + $1.count } + settings.managedApps.count
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
                Toggle("发现更新时自动更新", isOn: $settings.autoUpdate)
                Text("关闭时，定时检查只会通知你；开启后发现更新会直接执行，应用分区仍遵循“更新后重启”开关。")
                    .font(.footnote).foregroundStyle(.secondary)
                if settings.autoUpdate {
                    Label("自动更新可能在你使用某个应用时将其退出。", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.secondary)
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
                    ui.mainWindowRequested = true
                    openWindow(id: XupActions.mainWindowID)
                    XupActions.activate()
                    ui.presentWatchPicker(kind: ui.sidebar?.kind)
                } label: {
                    Label("选择软件…", systemImage: "checklist")
                }
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
        Form {
            Section {
                if settings.managedApps.isEmpty {
                    ContentUnavailableView("还没有跟踪的应用", systemImage: "macwindow.badge.plus")
                        .frame(height: 220)
                } else {
                    List(settings.managedApps, selection: $selected) { app in
                        appRow(app)
                    }
                    .frame(height: 260)
                    .onDeleteCommand { removeSelected() }
                }
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
                Text("Xup 会自动识别应用来自 Homebrew、Sparkle、electron-updater 还是 App Store，并用对应方式更新；识别不了的应用可点击行尾 › 手动配置 GitHub Releases、Tauri、electron-updater 或 Sparkle 来源。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
                Text(app.name)
                Text(app.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            sourceTag(app: app, item: item)
            Toggle("更新后重启", isOn: Binding(
                get: { app.restartAfterUpdate },
                set: { settings.setRestart(path: app.path, $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(selfUpdating)
            .help(selfUpdating ? "由应用自更新，Xup 不替它更新" : "更新后重启")
            Button { sourceSheetApp = app } label: {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("配置更新来源…")
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
