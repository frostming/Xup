import AppKit
import SwiftUI

/// 侧栏分区。
enum SidebarItem: Hashable {
    case all
    case kind(ProviderKind)
    /// §18 "记录 › 更新历史"。
    case history

    var kind: ProviderKind? {
        if case .kind(let k) = self { return k }
        return nil
    }

    var title: String {
        switch self {
        case .all: return "全部"
        case .kind(let k): return k.title
        case .history: return "更新历史"
        }
    }
}

/// 设置窗口的 Tab（§13.7：原"选择软件…"Sheet 并入为"软件"Tab）。
enum SettingsTab: Hashable {
    case general, watch, agents, apps
}

/// 一轮由界面发起的更新。
struct UpdateBatch: Equatable {
    let ids: Set<String>
    let startedAt = Date()
}

/// 跨窗口共享的界面状态（菜单栏面板、主窗口、设置共用）。
@MainActor
final class UIState: ObservableObject {
    @Published var sidebar: SidebarItem? = .all
    /// Table 行选择。
    @Published var selection: Set<String> = []
    /// 复选框勾选。
    @Published var checked: Set<String> = []
    @Published var search = ""
    @Published var showLog = false
    @Published var logErrorsOnly = false
    /// 请求日志面板滚动到某一行。
    @Published var logScrollTarget: UUID?
    /// 当前由界面发起、尚未结束的更新批次。
    @Published var batch: UpdateBatch?
    /// 批次结束后短暂显示的汇总（失败数 > 0 时红色）。
    @Published var completion: (text: String, failed: Bool)?
    /// 设置窗口当前 Tab；"软件"Tab 默认定位的来源分段。
    @Published var settingsTab: SettingsTab = .general
    @Published var pickerKind: ProviderKind = .homebrew
    /// §16.3 "配置更新来源" Sheet 的目标应用（nil 为关闭）。
    @Published var sourceSheetApp: ManagedApp?
    /// §18 更新历史：筛选"仅失败"；工具栏"清空历史"请求（由 HistoryView 弹二次确认）。
    @Published var historyFailedOnly = false
    @Published var historyClearRequested = false
    /// 首次启动（从未检查过）时自动打开一次主窗口。
    let openMainWindowOnLaunch: Bool
    /// 调试：`XUP_DEBUG_OPEN_WINDOW=1` 启动即打开主窗口。
    let debugOpenWindow: Bool
    /// 调试：启动后自动打开设置窗口。
    var debugOpenSettings = false
    /// 主窗口是否由用户/首启逻辑明确请求打开；未请求而被系统自动恢复的窗口会被关闭。
    var mainWindowRequested = false

    init() {
        let d = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment
        debugOpenWindow = env["XUP_DEBUG_OPEN_WINDOW"] == "1"
        openMainWindowOnLaunch = debugOpenWindow
            || d.object(forKey: "lastCheckedAt") == nil
            || (!d.bool(forKey: Self.hasSeenWatchPickerKey) && ConfigStore.quickTrackedIsEmpty())
        // 调试：`XUP_DEBUG_SIDEBAR=<ProviderKind.rawValue>` 指定启动时选中的分区。
        if let raw = env["XUP_DEBUG_SIDEBAR"] {
            if raw == "history" { sidebar = .history } else if let k = ProviderKind(rawValue: raw) { sidebar = .kind(k) }
        }
        // 调试：`XUP_DEBUG_SETTINGS=watch:plugin` 启动后自动打开设置窗口到指定 Tab（watch 可带来源分段）。
        if let raw = env["XUP_DEBUG_SETTINGS"] {
            let parts = raw.split(separator: ":").map(String.init)
            switch parts.first {
            case "general": settingsTab = .general
            case "watch": settingsTab = .watch
            case "agents": settingsTab = .agents
            case "apps": settingsTab = .apps
            default: break
            }
            if parts.count > 1, let k = ProviderKind(rawValue: parts[1]) { pickerKind = k }
            debugOpenSettings = true
        }
        NSLog("[Xup] UIState init, openMainWindowOnLaunch=\(openMainWindowOnLaunch) debug=\(debugOpenWindow)")
    }

    /// 打开"配置更新来源" Sheet。
    func presentSourceSheet(for app: ManagedApp) {
        sourceSheetApp = app
    }

    // MARK: - 关注列表 / 首启引导

    static let hasSeenWatchPickerKey = "hasSeenWatchPicker"

    var hasSeenWatchPicker: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasSeenWatchPickerKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasSeenWatchPickerKey) }
    }

    /// `tracked` 全空且从未打开过"软件"Tab → 首启引导（主窗口欢迎态）。
    func needsOnboarding(_ settings: AppSettings) -> Bool {
        settings.tracked.values.allSatisfy(\.isEmpty) && !hasSeenWatchPicker
    }

    /// 把设置窗口切到"软件"Tab 并定位分段；`kind` 为 nil 或 .app 时默认 Homebrew。
    /// 真正打开设置窗口需由视图用 `@Environment(\.openSettings)` 完成（先 `XupActions.activate()`）。
    func selectWatchTab(kind: ProviderKind?) {
        pickerKind = (kind == nil || kind == .app) ? .homebrew : kind!
        settingsTab = .watch
    }

    // MARK: - 动作

    func check(center: UpdateCenter) {
        guard !center.isChecking else { return }
        showLog = true
        Task { await center.checkAll() }
    }

    /// 更新给定 id 中可操作（或失败后可重试）的条目。
    func update(ids: Set<String>, center: UpdateCenter) {
        let targets = Set(center.items.filter { ids.contains($0.id) && $0.canUpdate && ($0.isActionable || $0.isFailed) }.map(\.id))
        guard !targets.isEmpty else { return }
        showLog = true
        checked.subtract(targets)
        batch = UpdateBatch(ids: targets)
        completion = nil
        Task { [weak self] in
            await center.update(ids: targets)
            guard let self else { return }
            let done = center.items.filter { targets.contains($0.id) }
            let ok = done.filter { $0.status == .updated }.count
            let failed = done.filter(\.isFailed).count
            self.batch = nil
            self.completion = ("完成：\(ok) 成功，\(failed) 失败", failed > 0)
            if !NSApp.isActive {
                Notifier.notify(title: "Xup：更新完成", body: "\(ok) 成功，\(failed) 失败")
            }
            try? await Task.sleep(for: .seconds(3))
            if self.batch == nil { self.completion = nil }
        }
    }

    /// 状态栏闪一行提示（3 秒），如 §19.3 "已将 3 项设为“空闲时自动更新”"。
    func flash(_ text: String) {
        completion = (text, false)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.batch == nil, self.completion?.text == text else { return }
            self.completion = nil
        }
    }

    func updateAll(center: UpdateCenter, kind: ProviderKind?) {
        update(ids: Set(center.items(for: kind).filter(\.isActionable).map(\.id)), center: center)
    }

    /// 从菜单栏面板点击某条：打开主窗口并选中该行。
    func reveal(_ item: UpdateItem) {
        sidebar = .all
        search = ""
        selection = [item.id]
    }

    /// §18 从历史记录"在列表中定位"：切到对应来源分区并选中该条目（条目已不存在时不做任何事）。
    func reveal(record: UpdateRecord, center: UpdateCenter) {
        guard center.items.contains(where: { $0.id == record.itemID }) else { return }
        sidebar = .kind(record.kind)
        search = ""
        selection = [record.itemID]
    }

    /// 批次进度：(已完成数, 总数, 当前条目名)。
    func progress(center: UpdateCenter) -> (done: Int, total: Int, current: String?)? {
        guard let batch else { return nil }
        let items = center.items.filter { batch.ids.contains($0.id) }
        let done = items.filter { $0.status == .updated || $0.isFailed }.count
        let current = items.first { center.updatingIDs.contains($0.id) }?.name
        return (done, batch.ids.count, current)
    }
}

// MARK: - 模型扩展（仅界面层使用）

extension UpdateItem {
    var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    /// 默认排序权重：待安装 → 可更新 → 失败 → 未知 → 更新中 → 已更新 → 最新。
    var statusRank: Int {
        switch status {
        case .staged: return 0
        case .outdated: return canUpdate ? 1 : 2
        case .failed: return 3
        case .unknown: return 4
        case .checking: return 5
        case .updating: return 6
        case .updated: return 7
        case .upToDate: return 8
        }
    }

    var latestText: String { latest ?? "—" }

    /// 关注集合中的键：agent 为 binary、plugin 为 "claude/<name@mkt>"（均存于 id 后缀）；其余为 name。
    var trackedKey: String {
        switch kind {
        case .agent, .plugin: return String(id.dropFirst(kind.rawValue.count + 1))
        default: return name
        }
    }

    /// 可在 Finder 中显示的路径（应用包或 agent 二进制）。
    var filePath: String? {
        switch kind {
        case .app:
            let prefix = "app:"
            return id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : nil
        case .agent:
            guard let d = detail, d.hasPrefix("/") || d.hasPrefix("~") else { return nil }
            return (d as NSString).expandingTildeInPath
        default:
            return nil
        }
    }

    /// 应用条目对应的 ManagedApp 路径。
    var appPath: String? { kind == .app ? filePath : nil }

    /// §16.4 "由应用自更新"：无法识别来源且未手动配置的应用。
    var isSelfUpdating: Bool { kind == .app && detail == AppsProvider.selfUpdateDetail }
}

extension ProviderKind {
    /// 侧栏固定顺序（§2.2）：Homebrew · npm 全局 · uv tool · Agents · Skills · 插件 · 应用。
    static let sidebarOrder: [ProviderKind] = [.homebrew, .npm, .uv, .agent, .skill, .plugin, .app]
    /// 设置 › 软件 的分段（不含应用）。
    static let pickerOrder: [ProviderKind] = [.homebrew, .npm, .uv, .agent, .skill, .plugin]

    /// §6.9 / §13 文案中的"本机已安装的 ×× "。
    var installedNoun: String {
        switch self {
        case .homebrew: return "Homebrew 包"
        case .npm: return "npm 全局包"
        case .uv: return "uv tool"
        case .agent: return "agent"
        case .skill: return "skill"
        case .plugin: return "Claude Code 与 Codex 插件"
        case .app: return "应用"
        }
    }

    /// 设置 › 软件 加载态显示的命令。
    var listCommand: String {
        switch self {
        case .homebrew: return "$ brew list --versions"
        case .npm: return "$ npm ls -g --depth=0 --json"
        case .uv: return "$ uv tool list"
        case .agent: return "$ which claude codex gemini …"
        case .skill: return "~/.agents/.skill-lock.json"
        case .plugin: return "~/.claude/plugins · ~/.codex/plugins"
        case .app: return ""
        }
    }
}

enum XupFormat {
    static let relative: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func lastChecked(_ date: Date?) -> String {
        guard let date else { return "尚未检查" }
        return "上次检查 " + relative.string(from: date)
    }

    static func nextCheck(interval minutes: Int, last: Date?) -> String {
        guard minutes > 0 else { return "已关闭定时检查" }
        let next = (last ?? Date()).addingTimeInterval(TimeInterval(minutes * 60))
        return "下次自动检查 " + relative.string(from: next)
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
