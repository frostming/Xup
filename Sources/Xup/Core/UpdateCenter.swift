import Foundation

@MainActor
final class UpdateCenter: ObservableObject {
    static let maxLogLines = 5000

    @Published private(set) var items: [UpdateItem] = []
    @Published private(set) var isChecking = false
    @Published private(set) var updatingIDs: Set<String> = []
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var providerErrors: [ProviderKind: String] = [:]
    /// 本机没有该工具的 provider。
    @Published private(set) var unavailable: Set<ProviderKind> = []
    @Published private(set) var lastChecked: Date?

    let settings: AppSettings
    let brewState = BrewState()

    init(settings: AppSettings) {
        self.settings = settings
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
        appendLog(source: "Xup", text: "检查完成：\(outdatedCount) 个可更新")
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

    func update(ids: Set<String>) async {
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
                        await self.updateOne(item, provider: provider, log: log)
                    }
                }
            }
        }
    }

    private func updateOne(_ item: UpdateItem, provider: UpdateProvider, log: @escaping Logger) async {
        setStatus(item.id, .updating)
        updatingIDs.insert(item.id)
        appendLog(source: item.kind.title, text: "开始更新 \(item.name) \(item.installed) → \(item.latest ?? "?")")
        defer { updatingIDs.remove(item.id) }
        do {
            try await provider.update(item, log: log)
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx].status = .updated
                if let latest = items[idx].latest { items[idx].installed = latest }
            }
            appendLog(source: item.kind.title, text: "\(item.name) 更新完成")
        } catch {
            let msg = error.localizedDescription
            setStatus(item.id, .failed(msg))
            appendLog(source: item.kind.title, text: "\(item.name) 更新失败：\(msg)", isError: true)
        }
    }

    private func setStatus(_ id: String, _ status: ItemStatus) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = status
    }

    func updateAll() async {
        await update(ids: Set(actionableItems.map(\.id)))
    }

    // MARK: - 查询

    var outdatedCount: Int { items.filter { $0.status.isOutdated }.count }

    var actionableItems: [UpdateItem] { items.filter(\.isActionable) }

    func count(for kind: ProviderKind) -> Int {
        items.filter { $0.kind == kind && $0.isActionable }.count
    }

    /// nil 表示全部；根据 showUpToDate 过滤；可更新在前，其次按名称排序。
    func items(for kind: ProviderKind?) -> [UpdateItem] {
        var list = items
        if let kind { list = list.filter { $0.kind == kind } }
        if !settings.showUpToDate { list = list.filter { $0.status != .upToDate } }
        return list.sorted { a, b in
            if a.isActionable != b.isActionable { return a.isActionable }
            if a.status.isOutdated != b.status.isOutdated { return a.status.isOutdated }
            let c = a.name.localizedCaseInsensitiveCompare(b.name)
            if c != .orderedSame { return c == .orderedAscending }
            return a.id < b.id
        }
    }
}
