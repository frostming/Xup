import Foundation

@MainActor
final class UpdateCenter: ObservableObject {
    static let maxLogLines = 5000

    @Published private(set) var items: [UpdateItem] = []
    @Published private(set) var isChecking = false
    @Published private(set) var updatingIDs: Set<String> = []
    /// §19.4 正在后台下载暂存的应用（不计入"更新中"）。
    @Published private(set) var stagingIDs: Set<String> = []
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var providerErrors: [ProviderKind: String] = [:]
    /// 本机没有该工具的 provider。
    @Published private(set) var unavailable: Set<ProviderKind> = []
    @Published private(set) var lastChecked: Date?

    let settings: AppSettings
    /// §18 更新历史：每次 updateOne 成功/失败都追加一条。
    let history: UpdateHistory
    let brewState = BrewState()

    init(settings: AppSettings, history: UpdateHistory? = nil) {
        self.settings = settings
        self.history = history ?? UpdateHistory()
        self.lastChecked = settings.lastCheckedAt
    }

    // MARK: - Providers

    func makeProviders() -> [UpdateProvider] {
        let greedy = settings.brewGreedy
        return [
            HomebrewProvider(greedy: greedy, brewState: brewState),
            NpmProvider(),
            UvProvider(),
            AgentProvider(specs: settings.loadAgentSpecs()),
            AppsProvider(apps: settings.managedApps, brewState: brewState, greedy: greedy),
            SkillsProvider(),
            PluginProvider(),
        ]
    }

    /// 列出某来源本机已安装、可被关注的条目（供"选择软件" Sheet）。
    func listInstalled(for kind: ProviderKind) async throws -> [InstalledEntry] {
        await Shell.warmUp()
        guard let provider = makeProviders().first(where: { $0.kind == kind }) else { return [] }
        guard provider.isAvailable() else { throw ShellError.notFound(kind.title) }
        return try await provider.listInstalled(log: logger(for: kind))
    }

    /// 可用但关注集合为空的来源（`.app` 除外，它用 managedApps），供 UI 显示空状态。
    var untrackedKinds: Set<ProviderKind> {
        Set(ProviderKind.allCases.filter { kind in
            kind != .app && !unavailable.contains(kind) && (settings.tracked[kind] ?? []).isEmpty
        })
    }

    // MARK: - 应用来源

    /// 只做网络检测（不下载）：解析某来源的最新版本与下载地址，供配置 Sheet 的"测试"按钮调用。
    func probeSource(for app: ManagedApp, source: AppUpdateSource) async throws -> (latest: String, downloadURL: URL?) {
        await Shell.warmUp()
        let r = try await AppSources.resolve(source)
        return (r.latest, r.downloadURL)
    }

    // MARK: - 暂存（§19.4）

    /// 后台预下载：对策略为 autoDownload 的应用条目下载、校验并暂存，不替换、不退出应用。
    /// 成功后条目进入 `.staged(latest)`；失败记日志并把 hint 设为失败原因（状态仍为可更新）。返回成功暂存的 id。
    @discardableResult
    func stage(ids: Set<String>) async -> Set<String> {
        let targets = items.filter { ids.contains($0.id) && $0.kind == .app && $0.status.isOutdated && $0.canUpdate && !stagingIDs.contains($0.id) && !updatingIDs.contains($0.id) }
        guard !targets.isEmpty else { return [] }
        await Shell.warmUp()
        guard let provider = makeProviders().compactMap({ $0 as? AppsProvider }).first else { return [] }
        let log = logger(for: .app)
        var done: Set<String> = []
        for item in targets {
            stagingIDs.insert(item.id)
            defer { stagingIDs.remove(item.id) }
            do {
                let pkg = try await provider.stage(item, log: log)
                if let idx = items.firstIndex(where: { $0.id == item.id }), items[idx].status.isOutdated {
                    items[idx].status = .staged(pkg.version)
                    items[idx].hint = nil
                }
                done.insert(item.id)
            } catch {
                appendLog(source: ProviderKind.app.title, text: "\(item.name) 预下载失败：\(error.localizedDescription)", isError: true)
                if let idx = items.firstIndex(where: { $0.id == item.id }) {
                    items[idx].hint = "预下载失败：\(error.localizedDescription)"
                }
            }
        }
        return done
    }

    /// 已下载待安装的条目数。
    var stagedCount: Int { items.filter { $0.status.isStaged }.count }
    var stagedItems: [UpdateItem] { items.filter { $0.status.isStaged } }

    /// 策略改动后的收尾：不再是 autoDownload 的应用清掉暂存、状态回到"可更新"。
    /// 由界面 `setPolicy` 与 config.json 热加载两条路径共同调用。
    func reconcileStaging() {
        for app in settings.managedApps {
            let id = app.itemID
            let idx = items.firstIndex { $0.id == id }
            let policy = idx.map { settings.policy(for: items[$0]) } ?? settings.policy(for: id)
            guard policy != .autoDownload else { continue }
            let hadStaged = idx.map { items[$0].status.isStaged } ?? false
            if hadStaged || StagingStore.load(bundleID: AppsProvider.facts(for: app)?.bundleID, destination: app.path) != nil {
                AppsProvider.clearStaged(for: app)
                appendLog(source: ProviderKind.app.title, text: "\(app.name) 不再是“自动下载”，已清理暂存")
            }
            if hadStaged, let idx { items[idx].status = .outdated }
        }
    }

    /// 界面 / 控制通道改策略：写配置 + 收尾。返回生效后的策略（可能被降级）。
    func setPolicy(_ policy: UpdatePolicy, for ids: Set<String>) {
        for id in ids { settings.setPolicy(policy, for: id) }
        reconcileStaging()
        appendLog(source: "Xup", text: "已将 \(ids.count) 项设为“\(policy.title)”")
    }

    /// 清空全部暂存（设置 › 通用 "清除"）。
    func clearAllStaged() {
        StagingStore.clearAll()
        for i in items.indices where items[i].status.isStaged { items[i].status = .outdated }
        appendLog(source: ProviderKind.app.title, text: "已清除全部已下载待安装的更新")
    }

    /// 启动或置前应用（"自更新"条目的"启动应用"按钮）。
    func launch(_ app: ManagedApp) async {
        appendLog(source: ProviderKind.app.title, text: "启动 \(app.name)")
        await AppsProvider.launch(app)
    }

    // MARK: - 日志

    func appendLog(source: String, text: String, isError: Bool = false) {
        let line = LogLine(time: Date(), source: source, text: text, isError: isError)
        log.append(line)
        if log.count > Self.maxLogLines {
            log.removeFirst(log.count - Self.maxLogLines)
        }
        LogFile.shared.write(line)
    }

    func clearLog() { log.removeAll() }

    /// 某条日志之后的全部日志（该条已被滚动淘汰时返回全部）。
    func logLines(after id: UUID?) -> [LogLine] {
        guard let id, let idx = log.firstIndex(where: { $0.id == id }) else { return log }
        return Array(log[(idx + 1)...])
    }

    /// 生成可跨线程调用的 Logger，回到主线程追加日志。
    nonisolated private func logger(for kind: ProviderKind) -> Logger {
        let source = kind.title
        return { [weak self] text, isError in
            Task { @MainActor [weak self] in
                self?.appendLog(source: source, text: text, isError: isError)
            }
        }
    }

    // MARK: - 检查

    func checkAll() async {
        await check(kinds: nil)
    }

    /// 等待进行中的检查结束（控制通道 `check --wait` 用）。
    func waitUntilIdle() async {
        while isChecking { try? await Task.sleep(for: .milliseconds(200)) }
    }

    /// 检查指定来源（nil 为全部）。`.app` 依赖 Homebrew 的 cask 信息，只检查 app 时会自动带上 Homebrew。
    /// 已在检查中时直接返回 false。
    @discardableResult
    func check(kinds: Set<ProviderKind>?) async -> Bool {
        guard !isChecking else { return false }
        isChecking = true
        defer { isChecking = false }

        var selected = kinds
        if var k = selected, k.contains(.app), !k.contains(.homebrew) {
            k.insert(.homebrew)
            selected = k
        }
        if let selected {
            appendLog(source: "Xup", text: "开始检查更新（\(selected.map(\.title).sorted().joined(separator: "、"))）…")
        } else {
            appendLog(source: "Xup", text: "开始检查更新…")
        }
        await Shell.warmUp()
        let providers = makeProviders().filter { selected?.contains($0.kind) ?? true }

        // 标记不可用的 provider
        var available: [UpdateProvider] = []
        var missing: Set<ProviderKind> = []
        for p in providers {
            if p.isAvailable() { available.append(p) } else { missing.insert(p.kind) }
        }
        unavailable = missing
        for kind in missing {
            items.removeAll { $0.kind == kind }
            providerErrors[kind] = nil
            appendLog(source: kind.title, text: "本机未安装 \(kind.title)，跳过")
        }

        // Apps provider 会等待 BrewState 就绪；Homebrew 不可用时需要直接 finish 以免死等。
        let brewState = self.brewState
        if missing.contains(.homebrew) {
            await brewState.finish()
        } else {
            await brewState.begin()
        }

        typealias Outcome = (kind: ProviderKind, result: Result<[UpdateItem], Error>)
        await withTaskGroup(of: Outcome.self) { group in
            for provider in available {
                let log = logger(for: provider.kind)
                let tracked = settings.tracked[provider.kind] ?? []
                group.addTask {
                    do {
                        let items = try await provider.check(tracked: tracked, log: log)
                        return (provider.kind, .success(items))
                    } catch {
                        // 如果 Homebrew 失败，确保 BrewState 不会让 Apps 死等。
                        if provider.kind == .homebrew { await brewState.finish() }
                        return (provider.kind, .failure(error))
                    }
                }
            }
            for await outcome in group {
                apply(outcome.kind, outcome.result)
            }
        }

        let now = Date()
        lastChecked = now
        settings.lastCheckedAt = now
        appendLog(source: "Xup", text: "检查完成：\(outdatedCount) 个可更新" + (stagedCount > 0 ? "，\(stagedCount) 个待安装" : ""))
        return true
    }

    private func apply(_ kind: ProviderKind, _ result: Result<[UpdateItem], Error>) {
        items.removeAll { $0.kind == kind }
        switch result {
        case .success(let newItems):
            providerErrors[kind] = nil
            items.append(contentsOf: newItems)
        case .failure(let error):
            let msg = error.localizedDescription
            providerErrors[kind] = msg
            appendLog(source: kind.title, text: "检查失败：\(msg)", isError: true)
        }
    }

    // MARK: - 更新

    /// `trigger` 记入更新历史：界面 .manual（默认）、控制通道 .cli、Scheduler .scheduled / .auto。
    func update(ids: Set<String>, trigger: Trigger = .manual) async {
        let targets = items.filter { ids.contains($0.id) && $0.canUpdate }
        guard !targets.isEmpty else { return }
        await Shell.warmUp()
        let providers = makeProviders()
        let byKind = Dictionary(grouping: targets, by: { $0.kind })

        await withTaskGroup(of: Void.self) { group in
            for (kind, kindItems) in byKind {
                guard let provider = providers.first(where: { $0.kind == kind }) else { continue }
                let log = logger(for: kind)
                group.addTask { @MainActor [weak self] in
                    // 同一 kind 内串行
                    for item in kindItems {
                        guard let self else { return }
                        await self.updateOne(item, provider: provider, log: log, trigger: trigger)
                    }
                }
            }
        }
    }

    private func updateOne(_ item: UpdateItem, provider: UpdateProvider, log: @escaping Logger, trigger: Trigger) async {
        setStatus(item.id, .updating)
        updatingIDs.insert(item.id)
        appendLog(source: item.kind.title, text: (item.status.isStaged ? "安装已下载的 " : "开始更新 ") + "\(item.name) \(item.installed) → \(item.latest ?? "?")")
        let started = Date()
        defer { updatingIDs.remove(item.id) }
        var record = UpdateRecord(time: started, kind: item.kind, itemID: item.id, name: item.name, detail: item.detail,
                                  fromVersion: item.installed, toVersion: nil, duration: 0, ok: false, error: nil, trigger: trigger)
        do {
            try await provider.update(item, log: log)
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx].status = .updated
                if let latest = items[idx].latest { items[idx].installed = latest }
            }
            record.ok = true
            record.toVersion = item.latest
            appendLog(source: item.kind.title, text: "\(item.name) 更新完成")
        } catch {
            let msg = error.localizedDescription
            record.error = msg
            setStatus(item.id, .failed(msg))
            appendLog(source: item.kind.title, text: "\(item.name) 更新失败：\(msg)", isError: true)
        }
        record.duration = Date().timeIntervalSince(started)
        history.append(record)
        if let err = history.lastError { appendLog(source: "Xup", text: err, isError: true) }
    }

    private func setStatus(_ id: String, _ status: ItemStatus) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = status
    }

    func updateAll(trigger: Trigger = .manual) async {
        await update(ids: Set(actionableItems.map(\.id)), trigger: trigger)
    }

    // MARK: - 查询

    var outdatedCount: Int { items.filter { $0.status.isOutdated }.count }

    var actionableItems: [UpdateItem] { items.filter(\.isActionable) }

    func count(for kind: ProviderKind) -> Int {
        items.filter { $0.kind == kind && $0.isActionable }.count
    }

    /// nil 表示全部；根据 showUpToDate 过滤；待安装 → 可更新 在前，其次按名称排序。
    func items(for kind: ProviderKind?) -> [UpdateItem] {
        var list = items
        if let kind { list = list.filter { $0.kind == kind } }
        if !settings.showUpToDate { list = list.filter { $0.status != .upToDate } }
        return list.sorted { a, b in
            if a.status.isStaged != b.status.isStaged { return a.status.isStaged }
            if a.isActionable != b.isActionable { return a.isActionable }
            if a.status.isOutdated != b.status.isOutdated { return a.status.isOutdated }
            let c = a.name.localizedCaseInsensitiveCompare(b.name)
            if c != .orderedSame { return c == .orderedAscending }
            return a.id < b.id
        }
    }
}
