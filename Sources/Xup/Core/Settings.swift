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
    /// §19.5 新关注条目的默认更新方式（manual / auto）。
    var defaultPolicy: UpdatePolicy {
        get { config.check.defaultPolicy }
        set { mutate { $0.check.defaultPolicy = newValue == .autoDownload ? .auto : newValue } }
    }
    /// §19.2 空闲判定阈值（分钟，1–60）。
    var idleMinutes: Int {
        get { config.check.idleMinutes }
        set { mutate { $0.check.idleMinutes = min(60, max(1, newValue)) } }
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

    // MARK: - 更新方式（§19）

    /// 日志出口（降级提示等）；由 AppModel 接到 UpdateCenter。
    var log: ((_ text: String) -> Void)?
    private var loggedDowngrades: Set<String> = []

    /// config.json 里记录的原始策略（不降级）；无记录为 nil。
    func storedPolicy(for itemID: String) -> UpdatePolicy? {
        if let p = config.policies[itemID] { return p }
        // homebrew：`homebrew:formula/node` 回退到关注名形式 `homebrew:node`。
        if itemID.hasPrefix("homebrew:") {
            let suffix = itemID.dropFirst("homebrew:".count)
            if let slash = suffix.firstIndex(of: "/") {
                let token = suffix[suffix.index(after: slash)...]
                if let p = config.policies["homebrew:\(token)"] { return p }
            }
        }
        return nil
    }

    /// 条目的生效策略：无记录取 `defaultPolicy`；`autoDownload` 仅对应用有效，非应用读到时降级为 auto 并记一次日志。
    /// 来源是否支持预下载需要条目信息，见 `policy(for item:)`。
    func policy(for itemID: String) -> UpdatePolicy {
        let p = storedPolicy(for: itemID) ?? defaultPolicy
        if p == .autoDownload, !itemID.hasPrefix("app:") {
            logDowngrade(itemID, reason: "不是应用")
            return .auto
        }
        return p
    }

    /// 条目的生效策略（含"来源不支持预下载"的降级）。
    func policy(for item: UpdateItem) -> UpdatePolicy {
        let p = policy(for: item.id)
        if p == .autoDownload, !item.supportsStaging {
            logDowngrade(item.id, reason: "来源不支持预下载")
            return .auto
        }
        return p
    }

    private func logDowngrade(_ itemID: String, reason: String) {
        guard loggedDowngrades.insert(itemID).inserted else { return }
        log?("\(itemID) 的\(reason)，已按“空闲时自动更新”处理")
    }

    /// 写入策略；传 nil 删除记录（回到默认）。`autoDownload` 只接受 `app:` 前缀的 id。
    func setPolicy(_ policy: UpdatePolicy?, for itemID: String) {
        var value = policy
        if value == .autoDownload, !itemID.hasPrefix("app:") { value = .auto }
        mutate { cfg in
            // 同一 homebrew 条目可能同时存在 formula/cask 形式与 token 形式的键，统一清掉旧键再写。
            for k in Self.aliasKeys(for: itemID) { cfg.policies[k] = nil }
            cfg.policies[itemID] = value
        }
        loggedDowngrades.remove(itemID)
    }

    func setPolicy(_ policy: UpdatePolicy?, for itemIDs: some Sequence<String>) {
        for id in itemIDs { setPolicy(policy, for: id) }
    }

    /// 应用的 `installWhenIdle` 子开关。
    func installWhenIdle(path: String) -> Bool {
        managedApps.first { $0.path == path }?.installWhenIdle ?? false
    }

    func setInstallWhenIdle(path: String, _ on: Bool) {
        mutate { cfg in
            guard let idx = cfg.apps.firstIndex(where: { $0.path == path }) else { return }
            cfg.apps[idx].installWhenIdle = on
        }
    }

    /// 某 id 的所有等价键（homebrew 的 formula/cask/token 三种）。
    nonisolated static func aliasKeys(for itemID: String) -> [String] {
        guard itemID.hasPrefix("homebrew:") else { return [itemID] }
        var suffix = String(itemID.dropFirst("homebrew:".count))
        if let slash = suffix.firstIndex(of: "/") { suffix = String(suffix[suffix.index(after: slash)...]) }
        return ["homebrew:\(suffix)", "homebrew:formula/\(suffix)", "homebrew:cask/\(suffix)"]
    }

    /// 取消关注 / 移除应用时删除对应的 policies 键。
    private func removePolicies(for itemIDs: [String], in cfg: inout XupConfig) {
        for id in itemIDs { for k in Self.aliasKeys(for: id) { cfg.policies[k] = nil } }
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
        mutate { cfg in
            cfg.apps.removeAll { $0.path == path }
            removePolicies(for: ["app:\(path)"], in: &cfg)
        }
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

    /// 新关注条目不写 policies 记录（自然继承 defaultPolicy）；被取消关注的条目删除记录。
    func setTracked(_ kind: ProviderKind, names: Set<String>) {
        mutate { cfg in
            let removed = cfg.tracked[kind].subtracting(names)
            cfg.tracked[kind] = names
            removePolicies(for: removed.map { "\(kind.rawValue):\($0)" }, in: &cfg)
        }
    }

    func track(_ kind: ProviderKind, _ name: String) {
        guard !isTracked(kind, name) else { return }
        mutate { $0.tracked[kind].insert(name) }
    }

    func untrack(_ kind: ProviderKind, _ name: String) {
        guard isTracked(kind, name) else { return }
        mutate { cfg in
            cfg.tracked[kind].remove(name)
            removePolicies(for: ["\(kind.rawValue):\(name)"], in: &cfg)
        }
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
