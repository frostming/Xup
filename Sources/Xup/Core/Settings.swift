import Foundation
import ServiceManagement

/// 设置门面：所有用户配置来自 `ConfigStore`（config.json）；UserDefaults 只保留运行状态
/// （`lastCheckedAt`）与界面偏好（`hasSeenWatchPicker`、窗口位置等）。
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    let store: ConfigStore

    private enum Key {
        static let lastCheckedAt = "lastCheckedAt"
    }

    /// 当前配置快照；每次（本地或外部）变化都会整体替换，驱动 SwiftUI 刷新。
    @Published private(set) var config: XupConfig

    @Published var lastCheckedAt: Date? {
        didSet {
            if let d = lastCheckedAt { defaults.set(d, forKey: Key.lastCheckedAt) }
            else { defaults.removeObject(forKey: Key.lastCheckedAt) }
        }
    }

    /// agents.json 读取/解析失败时的错误描述。
    @Published var agentSpecsError: String?
    /// 登录项操作失败时的错误描述。
    @Published var launchAtLoginError: String?
    /// config.json 最近一次加载失败的原因。
    @Published private(set) var configError: String?

    init(defaults: UserDefaults = .standard, store: ConfigStore? = nil) {
        self.defaults = defaults
        let store = store ?? ConfigStore(migrateFrom: defaults)
        self.store = store
        self.config = store.config
        self.configError = store.lastError
        lastCheckedAt = defaults.object(forKey: Key.lastCheckedAt) as? Date

        store.onChange = { [weak self] cfg, source in
            guard let self else { return }
            let old = self.config
            self.applyExternal(cfg)
            self.onExternalChange?(old, cfg, source)
        }

        // 登录项状态以 SMAppService 为准（仅在 .app bundle 内可用）；与配置不一致时以系统为准回写。
        if Self.isRunningInAppBundle {
            let enabled = SMAppService.mainApp.status == .enabled
            if enabled != config.ui.launchAtLogin {
                mutate { $0.ui.launchAtLogin = enabled }
            }
        }
    }

    /// 配置被外部修改并热加载 / 手动重新加载后调用（在 `applyExternal` 之后）：(旧配置, 新配置, 来源)。
    var onExternalChange: ((_ old: XupConfig, _ new: XupConfig, _ source: ConfigStore.Source) -> Void)?

    /// 采用一份来自磁盘的新配置（不回写）。
    func applyExternal(_ cfg: XupConfig) {
        let old = config
        config = cfg
        configError = nil
        if cfg.ui.launchAtLogin != old.ui.launchAtLogin {
            applyLaunchAtLogin(cfg.ui.launchAtLogin)
        }
    }

    /// 修改配置并写盘。
    private func mutate(_ body: (inout XupConfig) -> Void) {
        store.update(body)
        config = store.config
        configError = store.lastError
    }

    // MARK: - 通用开关

    /// 定时检查间隔（分钟）；0 表示关闭定时检查。
    var checkIntervalMinutes: Int {
        get { config.check.intervalMinutes }
        set { mutate { $0.check.intervalMinutes = max(0, newValue) } }
    }
    var brewGreedy: Bool {
        get { config.homebrew.greedy }
        set { mutate { $0.homebrew.greedy = newValue } }
    }
    var notifyOnUpdates: Bool {
        get { config.check.notify }
        set { mutate { $0.check.notify = newValue } }
    }
    var autoUpdate: Bool {
        get { config.check.autoUpdate }
        set { mutate { $0.check.autoUpdate = newValue } }
    }
    var showUpToDate: Bool {
        get { config.ui.showUpToDate }
        set { mutate { $0.ui.showUpToDate = newValue } }
    }
    var launchAtLogin: Bool {
        get { config.ui.launchAtLogin }
        set {
            guard newValue != config.ui.launchAtLogin else { return }
            mutate { $0.ui.launchAtLogin = newValue }
            applyLaunchAtLogin(newValue)
        }
    }
    var agentAllowUpdates: Bool { config.agent.allowUpdates }

    // MARK: - 登录项

    static var isRunningInAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        guard Self.isRunningInAppBundle else { return }
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginError = "设置登录项失败：\(error.localizedDescription)"
            // 回滚到系统实际状态
            let actual = SMAppService.mainApp.status == .enabled
            mutate { $0.ui.launchAtLogin = actual }
        }
    }

    // MARK: - 受管应用

    var managedApps: [ManagedApp] { config.apps }

    /// 添加应用；去重且只接受 .app 包路径。
    func addApps(paths: [String]) {
        var existing = Set(managedApps.map { $0.path })
        var added: [ManagedApp] = []
        for raw in paths {
            let path = URL(fileURLWithPath: raw).standardizedFileURL.path
            guard path.hasSuffix(".app"), !existing.contains(path) else { continue }
            existing.insert(path)
            added.append(ManagedApp(path: path))
        }
        guard !added.isEmpty else { return }
        mutate { cfg in
            cfg.apps = (cfg.apps + added).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    func removeApp(path: String) {
        mutate { $0.apps.removeAll { $0.path == path } }
    }

    func setRestart(path: String, _ restart: Bool) {
        mutate { cfg in
            guard let idx = cfg.apps.firstIndex(where: { $0.path == path }) else { return }
            cfg.apps[idx].restartAfterUpdate = restart
        }
    }

    /// 设置/清除应用的手动更新来源（nil 恢复自动识别）。
    func setSource(path: String, _ source: AppUpdateSource?) {
        mutate { cfg in
            guard let idx = cfg.apps.firstIndex(where: { $0.path == path }) else { return }
            cfg.apps[idx].source = source
        }
    }

    // MARK: - 关注列表

    /// 关注列表：每个来源只检查/更新用户选择的条目（`.app` 不用此集合，沿用 managedApps）。
    var tracked: [ProviderKind: Set<String>] { config.tracked.asDictionary }

    func isTracked(_ kind: ProviderKind, _ name: String) -> Bool {
        config.tracked[kind].contains(name)
    }

    func setTracked(_ kind: ProviderKind, names: Set<String>) {
        mutate { $0.tracked[kind] = names }
    }

    func track(_ kind: ProviderKind, _ name: String) {
        guard !isTracked(kind, name) else { return }
        mutate { $0.tracked[kind].insert(name) }
    }

    func untrack(_ kind: ProviderKind, _ name: String) {
        guard isTracked(kind, name) else { return }
        mutate { $0.tracked[kind].remove(name) }
    }

    // MARK: - 配置文件

    var configURL: URL { store.url }
    var configDisplayPath: String { store.displayPath }

    /// 手动重新加载 config.json；返回错误描述（成功为 nil）。
    @discardableResult
    func reloadConfig() -> String? {
        let err = store.reload()
        config = store.config
        configError = err
        return err
    }

    // MARK: - 支持目录与 agents.json

    /// ~/Library/Application Support/Xup（不存在则创建）
    nonisolated static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Xup", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    nonisolated static var agentSpecsURL: URL { supportDirectory.appendingPathComponent("agents.json") }

    /// 读取 agents.json；不存在时写入内置列表并返回；解析失败时返回内置列表并记录错误。
    func loadAgentSpecs() -> [AgentSpec] {
        let url = Self.agentSpecsURL
        agentSpecsError = nil
        if !FileManager.default.fileExists(atPath: url.path) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            do {
                let data = try encoder.encode(AgentSpec.builtin)
                try data.write(to: url, options: .atomic)
            } catch {
                agentSpecsError = "写入 agents.json 失败：\(error.localizedDescription)"
            }
            return AgentSpec.builtin
        }
        do {
            let data = try Data(contentsOf: url)
            let specs = try JSONDecoder().decode([AgentSpec].self, from: data)
            return specs
        } catch {
            agentSpecsError = "解析 agents.json 失败，已使用内置列表：\(error.localizedDescription)"
            return AgentSpec.builtin
        }
    }
}
