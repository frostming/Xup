import AppKit
import Foundation

struct AppsProvider: UpdateProvider {
    let kind: ProviderKind = .app
    let apps: [ManagedApp]
    let brewState: BrewState
    let greedy: Bool

    func isAvailable() -> Bool { true }

    enum Source: Equatable {
        case cask(String)
        case sparkle(URL)
        case mas(String?)   // adam id when known
        case unknown
    }

    struct BundleFacts {
        let name: String
        let bundleID: String?
        let shortVersion: String
        let build: String?
        let feedURL: URL?
        let hasMASReceipt: Bool
    }

    static func facts(for app: ManagedApp) -> BundleFacts? {
        let url = URL(fileURLWithPath: app.path)
        // 不用 Bundle(url:)：NSBundle 会按路径缓存 Info.plist，应用被替换后同一进程内读到的仍是旧版本号。
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        let short = info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "?"
        let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:))
        let receipt = FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path)
        return BundleFacts(name: app.name, bundleID: info["CFBundleIdentifier"] as? String, shortVersion: short, build: info["CFBundleVersion"] as? String, feedURL: feed, hasMASReceipt: receipt)
    }

    /// 应用的"选择"即 managedApps，这里返回它们以便统一展示。
    func listInstalled(log: @escaping Logger) async throws -> [InstalledEntry] {
        apps.map { app in
            InstalledEntry(name: app.path, detail: app.name, version: Self.facts(for: app)?.shortVersion ?? "?")
        }
    }

    /// `tracked` 被忽略：managedApps 即用户的选择。
    func check(tracked: Set<String>, log: @escaping Logger) async throws -> [UpdateItem] {
        guard !apps.isEmpty else { return [] }
        await brewState.waitUntilReady()
        // Homebrew 分区没有关注项时 BrewState 为空；若应用里有 cask 装的 app，这里自行补齐 cask 信息。
        if await brewState.installedCasks.isEmpty, Shell.which("brew") != nil {
            await populateBrewState(log: log)
        }
        let masAvailable = Shell.which("mas") != nil
        var masOutdated: [String: (String, String, String)] = [:] // name → (id, installed, latest)
        if masAvailable, apps.contains(where: { (Self.facts(for: $0)?.hasMASReceipt) == true }) {
            if let r = try? await Shell.run(["mas", "outdated"], timeout: 120) {
                // "497799835 Xcode (14.0 -> 14.1)"
                let re = try! NSRegularExpression(pattern: #"^(\d+)\s+(.+?)\s+\((.+?) -> (.+?)\)"#)
                for line in r.stdout.split(separator: "\n") {
                    let s = String(line)
                    if let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges == 5 {
                        let g = { (i: Int) in String(s[Range(m.range(at: i), in: s)!]) }
                        masOutdated[g(2)] = (g(1), g(3), g(4))
                    }
                }
            }
        }

        var items: [UpdateItem] = []
        for app in apps {
            let item = await checkOne(app, masAvailable: masAvailable, masOutdated: masOutdated, log: log)
            items.append(Self.applyStagedState(item, app: app, log: log))
        }
        let staged = items.filter(\.status.isStaged).count
        log("应用: \(items.filter(\.status.isOutdated).count)/\(items.count) 个可更新" + (staged > 0 ? "，\(staged) 个已下载待安装" : ""), false)
        return items
    }

    /// §19.4：有新版本且存在**有效**暂存（版本 == latest、文件在、≤ 30 天）→ `.staged(version)`；
    /// 暂存无效（版本变了 / 过期 / 文件没了）→ 删除并记日志，条目保持"可更新"，下次定时检查重新下载。
    /// 没有新版本但仍有暂存（用户已自行更新）→ 清理。
    static func applyStagedState(_ item: UpdateItem, app: ManagedApp, log: @escaping Logger) -> UpdateItem {
        let bundleID = facts(for: app)?.bundleID
        guard StagingStore.load(bundleID: bundleID, destination: app.path) != nil else { return item }
        guard item.status.isOutdated, item.canUpdate, item.supportsStaging, let latest = item.latest else {
            StagingStore.clear(bundleID: bundleID, destination: app.path)
            log("\(item.name)：已无新版本或来源不支持预下载，清理暂存", false)
            return item
        }
        let pkg = StagingStore.validPackage(bundleID: bundleID, destination: app.path, latest: latest) { pkg, why in
            log("\(item.name)：暂存的 \(pkg.version) 已失效（\(why.localizedDescription)），将重新下载", false)
        }
        guard pkg != nil else {
            var copy = item
            copy.hint = "暂存包已失效，将重新下载"
            return copy
        }
        var copy = item
        copy.status = .staged(latest)
        return copy
    }

    /// 仅为识别 cask 应用而执行的轻量 Homebrew 查询（不含 formula）。
    private func populateBrewState(log: @escaping Logger) async {
        guard let info = try? await Shell.runChecked(["brew", "info", "--cask", "--json=v2", "--installed"], timeout: 300),
              let j = try? JSONSerialization.jsonObject(with: Data(info.stdout.utf8)) else { return }
        let installed = BrewJSON.parseInstalledCasks(j)
        let appFiles = Set(apps.map { ($0.path as NSString).lastPathComponent })
        guard installed.contains(where: { !$0.appNames.isEmpty && !Set($0.appNames).isDisjoint(with: appFiles) }) else { return }
        log("应用: 有 Homebrew cask 安装的应用，执行 brew update 以检查 cask 版本", false)
        _ = try? await Shell.run(["brew", "update"], timeout: 600, onOutput: log)
        var args = ["brew", "outdated", "--cask", "--json=v2"]
        if greedy { args.append("--greedy") }
        var outdated: [String: (installed: String, current: String)] = [:]
        if let r = try? await Shell.runChecked(args, timeout: 600),
           let root = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any] {
            for c in root["casks"] as? [[String: Any]] ?? [] {
                guard let name = c["name"] as? String else { continue }
                let inst = (c["installed_versions"] as? [String])?.joined(separator: ", ") ?? "?"
                let cur = c["current_version"] as? String ?? "?"
                if inst != cur { outdated[name] = (inst, cur) }
            }
        }
        await brewState.publish(installed: installed, outdated: outdated)
    }

    private func checkOne(_ app: ManagedApp, masAvailable: Bool, masOutdated: [String: (String, String, String)], log: @escaping Logger) async -> UpdateItem {
        guard let f = Self.facts(for: app) else {
            return UpdateItem(kind: .app, name: app.name, detail: app.path, installed: "?", latest: nil,
                              status: .unknown("无法读取应用包"), canUpdate: false, idSuffix: app.path)
        }
        // 0. 手动配置的来源优先
        if let source = app.source {
            return await resolvedItem(app: app, facts: f, detail: source.detail, log: log) { try await AppSources.resolve(source) }
        }
        let appFile = (app.path as NSString).lastPathComponent
        // 1. Homebrew cask
        if let cask = await brewState.cask(forApp: appFile) {
            let outdated = await brewState.outdatedCasks[cask.token]
            let latest = outdated?.current ?? cask.currentVersion
            let status: ItemStatus = outdated != nil ? .outdated : .upToDate
            return UpdateItem(kind: .app, name: f.name, detail: "Homebrew cask \(cask.token)", installed: f.shortVersion,
                              latest: latest, status: status, idSuffix: app.path)
        }
        // 2. Sparkle
        if let feed = f.feedURL {
            do {
                let items = try await AppcastParser.fetch(feed)
                guard let newest = AppcastParser.newest(in: items) else {
                    return UpdateItem(kind: .app, name: f.name, detail: "Sparkle", installed: f.shortVersion, latest: nil,
                                      status: .unknown("appcast 为空"), canUpdate: false, idSuffix: app.path)
                }
                var outdated = false
                if let ls = newest.shortVersion {
                    let c = VersionCompare.compare(ls, f.shortVersion)
                    if c == .orderedDescending { outdated = true }
                    else if c == .orderedSame, let lb = newest.build, let ib = f.build, VersionCompare.isNewer(lb, than: ib) { outdated = true }
                } else if let lb = newest.build, let ib = f.build {
                    outdated = VersionCompare.isNewer(lb, than: ib)
                }
                let canDownload = newest.enclosureURL != nil
                return UpdateItem(kind: .app, name: f.name, detail: "Sparkle · \(feed.host ?? "")", installed: f.shortVersion,
                                  latest: newest.displayVersion, status: outdated ? .outdated : .upToDate,
                                  canUpdate: canDownload, hint: canDownload ? nil : "appcast 无下载地址，请在应用内更新", idSuffix: app.path)
            } catch {
                return UpdateItem(kind: .app, name: f.name, detail: "Sparkle", installed: f.shortVersion, latest: nil,
                                  status: .unknown("appcast 获取失败: \(error.localizedDescription)"), canUpdate: false, idSuffix: app.path)
            }
        }
        // 3. electron-updater（Contents/Resources/app-update.yml）
        if let yml = AppSources.electronFeedURL(appPath: app.path) {
            return await resolvedItem(app: app, facts: f, detail: "electron-updater · \(yml.host ?? "")", log: log) { try await AppSources.resolveElectron(yml) }
        }
        // 4. Mac App Store
        if f.hasMASReceipt {
            if let o = masOutdated[f.name] {
                return UpdateItem(kind: .app, name: f.name, detail: "App Store (mas \(o.0))", installed: o.1, latest: o.2, status: .outdated, idSuffix: app.path)
            }
            if masAvailable {
                return UpdateItem(kind: .app, name: f.name, detail: "App Store", installed: f.shortVersion, latest: f.shortVersion, status: .upToDate, idSuffix: app.path)
            }
            return UpdateItem(kind: .app, name: f.name, detail: "App Store", installed: f.shortVersion, latest: nil,
                              status: .unknown("未安装 mas（brew install mas）"), canUpdate: false, hint: "可在 App Store 中更新", idSuffix: app.path)
        }
        // 5. 无法识别：视为应用自更新
        return UpdateItem(kind: .app, name: f.name, detail: Self.selfUpdateDetail, installed: f.shortVersion, latest: nil,
                          status: .unknown("由应用自更新"), canUpdate: false,
                          hint: "在应用内检查更新，或右键配置更新来源", idSuffix: app.path)
    }

    static let selfUpdateDetail = "自更新"

    /// 把"最新版本 + 下载地址"的解析结果转成列表条目；解析失败时标为未知。
    private func resolvedItem(app: ManagedApp, facts f: BundleFacts, detail: String, log: @escaping Logger,
                              _ resolve: () async throws -> AppSources.Resolved) async -> UpdateItem {
        do {
            let r = try await resolve()
            let outdated = VersionCompare.isNewer(r.latest, than: f.shortVersion)
            let canDownload = r.downloadURL != nil
            return UpdateItem(kind: .app, name: f.name, detail: detail, installed: f.shortVersion, latest: r.latest,
                              status: outdated ? .outdated : .upToDate, canUpdate: canDownload,
                              hint: canDownload ? nil : (r.hint ?? AppSources.noMacAssetHint), idSuffix: app.path)
        } catch {
            return UpdateItem(kind: .app, name: f.name, detail: detail, installed: f.shortVersion, latest: nil,
                              status: .unknown("来源检查失败: \(error.localizedDescription)"), canUpdate: false, idSuffix: app.path)
        }
    }

    /// 启动或置前该应用（供 UI 的"启动应用"按钮调用）。
    @MainActor
    static func launch(_ app: ManagedApp) async {
        let url = URL(fileURLWithPath: app.path).standardizedFileURL
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL.path == url.path }) {
            running.activate()
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }

    func update(_ item: UpdateItem, log: @escaping Logger) async throws {
        let path = String(item.id.dropFirst("app:".count))
        guard let app = apps.first(where: { $0.path == path }), let f = Self.facts(for: app) else {
            throw ShellError.failed(item.name, 1, "应用不存在")
        }
        let name = f.name, bundleID = f.bundleID
        let state = QuitState()
        let started = Date()

        /// 查询该应用的存活进程并退出它们。`abortIfNoRestart`：策略为"等我关闭后再更新"（restartAfterUpdate = false）时抛错（替换前复查用），
        /// 否则仅跳过退出（brew / mas 分支由命令自行处理）。
        let quitIfRunning: @Sendable (_ stage: String, _ abortIfNoRestart: Bool) async throws -> Void = { stage, abortIfNoRestart in
            let procs = await MainActor.run { Self.runningProcesses(appPath: app.path, bundleID: bundleID) }
            let live = await MainActor.run { Self.liveProcesses(procs, name: name, log: log) }
            guard !live.isEmpty else {
                log("\(stage)：\(name) 未在运行", false)
                return
            }
            guard app.restartAfterUpdate else {
                if abortIfNoRestart {
                    throw ShellError.failed(name, 1, "应用运行中，按设置暂不更新；关闭后再更新，或在\"配置应用…\"里改为自动退出并重新打开")
                }
                log("\(stage)：\(name) 正在运行（\(live.count) 个进程），按设置\"等我关闭后再更新\"，不主动退出", false)
                return
            }
            state.markQuit(pids: await MainActor.run { live.map(\.processIdentifier) })
            try await quit(live, name: name, log: log)
            await Self.killStrayProcesses(inside: app.path, name: name, log: log)
        }

        do {
            if case .staged(let v) = item.status {
                try await installStaged(item, version: v, app: app, facts: f, log: log, quitIfRunning: quitIfRunning)
            } else {
                try await performUpdate(item, app: app, facts: f, log: log, quitIfRunning: quitIfRunning)
            }
            log("\(name) 更新完成，总用时 \(Self.fmt(Date().timeIntervalSince(started)))", false)
        } catch {
            log("\(name) 更新失败（用时 \(Self.fmt(Date().timeIntervalSince(started)))）: \(error.localizedDescription)", true)
            // 只要是我们退出的应用，失败也要尝试拉起。
            if state.didQuit { await relaunch(app: app, name: name, bundleID: bundleID, quitPIDs: state.quitPIDs, log: log) }
            throw error
        }
        if state.didQuit { await relaunch(app: app, name: name, bundleID: bundleID, quitPIDs: state.quitPIDs, log: log) }
    }

    /// 可预下载的来源解析结果：下载地址 + 是否按 electron 增量流程下载。
    struct Download {
        let url: URL
        let resolved: AppSources.Resolved?
        let isElectron: Bool
    }

    enum StageError: LocalizedError {
        case unsupported(String)
        case notFound

        var errorDescription: String? {
            switch self {
            case .unsupported(let what): return "该应用由 \(what) 执行安装，不支持预下载"
            case .notFound: return "应用不存在"
            }
        }
    }

    /// 解析 Sparkle / electron-updater / 自定义来源的下载地址；cask / mas / 自更新返回 nil（不可预下载）。
    private func resolveDownload(_ item: UpdateItem, app: ManagedApp, facts f: BundleFacts) async throws -> Download? {
        let detail = item.detail ?? ""
        if let source = app.source {
            let r = try await AppSources.resolve(source)
            guard let url = r.downloadURL else { throw ShellError.failed(item.name, 1, r.hint ?? AppSources.noMacAssetHint) }
            if case .electronYML = source { return Download(url: url, resolved: r, isElectron: true) }
            return Download(url: url, resolved: r, isElectron: false)
        }
        if detail.hasPrefix("Sparkle"), let feed = f.feedURL {
            let items = try await AppcastParser.fetch(feed)
            guard let newest = AppcastParser.newest(in: items), let url = newest.enclosureURL else {
                throw ShellError.failed(item.name, 1, "appcast 无下载地址")
            }
            return Download(url: url, resolved: nil, isElectron: false)
        }
        if detail.hasPrefix("electron-updater"), let yml = AppSources.electronFeedURL(appPath: app.path) {
            let r = try await AppSources.resolveElectron(yml)
            guard let url = r.downloadURL else { throw ShellError.failed(item.name, 1, r.hint ?? AppSources.noMacAssetHint) }
            return Download(url: url, resolved: r, isElectron: true)
        }
        return nil
    }

    /// 按来源执行更新。Sparkle / electron / 自定义来源：先下载解压校验，`beforeReplace` 钩子里再退出应用（缩短应用离线窗口）。
    /// Homebrew cask / mas：命令本身会操作应用包，保持先退出再执行。
    private func performUpdate(_ item: UpdateItem, app: ManagedApp, facts f: BundleFacts, log: @escaping Logger,
                               quitIfRunning: @escaping @Sendable (_ stage: String, _ abortIfNoRestart: Bool) async throws -> Void) async throws {
        let detail = item.detail ?? ""
        let beforeReplace: @Sendable () async throws -> Void = { try await quitIfRunning("替换前检查", true) }

        if let dl = try await resolveDownload(item, app: app, facts: f) {
            if dl.isElectron, let r = dl.resolved {
                try await installElectron(from: dl.url, resolved: r, app: app, facts: f, log: log, beforeReplace: beforeReplace)
            } else {
                try await AppInstaller.install(from: dl.url, into: app.path, expectedBundleID: f.bundleID, log: log, beforeReplace: beforeReplace)
            }
        } else if detail.hasPrefix("Homebrew cask ") {
            let token = String(detail.dropFirst("Homebrew cask ".count))
            try await quitIfRunning("brew upgrade 前", false)
            var cmd = ["brew", "upgrade", "--cask"]
            if greedy { cmd.append("--greedy") }
            cmd.append(token)
            log("$ " + cmd.joined(separator: " "), false)
            try await Shell.runChecked(cmd, timeout: 1800, onOutput: log)
        } else if detail.hasPrefix("App Store (mas "), let id = detail.split(separator: " ").last?.dropLast() {
            try await quitIfRunning("mas upgrade 前", false)
            let cmd = ["mas", "upgrade", String(id)]
            log("$ " + cmd.joined(separator: " "), false)
            try await Shell.runChecked(cmd, timeout: 1800, onOutput: log)
        } else {
            throw ShellError.failed(item.name, 1, "此来源不支持自动更新")
        }
    }

    /// §19.4 "安装并重启"：对已暂存的包直接 `apply`（退出 → 替换 → 重开），不再下载。
    /// 暂存在此刻被发现失效时回退到正常下载流程。
    private func installStaged(_ item: UpdateItem, version: String, app: ManagedApp, facts f: BundleFacts, log: @escaping Logger,
                               quitIfRunning: @escaping @Sendable (_ stage: String, _ abortIfNoRestart: Bool) async throws -> Void) async throws {
        let pkg = StagingStore.validPackage(bundleID: f.bundleID, destination: app.path, latest: version) { pkg, why in
            log("\(item.name)：暂存的 \(pkg.version) 已失效（\(why.localizedDescription)），改为重新下载", true)
        }
        guard let pkg else {
            try await performUpdate(item, app: app, facts: f, log: log, quitIfRunning: quitIfRunning)
            return
        }
        log("安装已暂存的 \(item.name) \(pkg.version)（\(pkg.appPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))）", false)
        try await AppInstaller.apply(staged: pkg, beforeReplace: { try await quitIfRunning("替换前检查", true) }, log: log)
        StagingStore.clear(bundleID: f.bundleID, destination: app.path)
    }

    /// §19.1 "自动下载，手动重启"：后台下载 → 校验 → 解压到持久暂存目录，不替换、不退出应用。
    /// 仅 Sparkle / electron-updater / 手动配置来源可用；cask / mas / 自更新抛 `StageError.unsupported`。
    func stage(_ item: UpdateItem, log: @escaping Logger) async throws -> StagedPackage {
        let path = String(item.id.dropFirst("app:".count))
        guard let app = apps.first(where: { $0.path == path }), let f = Self.facts(for: app) else { throw StageError.notFound }
        let detail = item.detail ?? ""
        guard item.supportsStaging else {
            if detail.hasPrefix("Homebrew cask") { throw StageError.unsupported("Homebrew") }
            if detail.hasPrefix("App Store") { throw StageError.unsupported("App Store") }
            throw StageError.unsupported("应用自身")
        }
        guard let dl = try await resolveDownload(item, app: app, facts: f) else { throw StageError.unsupported("其它方式") }
        let started = Date()
        log("后台下载 \(f.name) \(item.latest ?? "?")（不替换、不退出应用）", false)
        let dir = StagingStore.directory(bundleID: f.bundleID, destination: app.path, version: item.latest ?? "unknown")
        // 旧版本的暂存先清掉（远端出现更高版本 → 丢弃旧暂存）。
        StagingStore.clear(bundleID: f.bundleID, destination: app.path)
        var pkg: StagedPackage
        if dl.isElectron, let r = dl.resolved, DeltaDownloadPolicy.isEnabled, dl.url.pathExtension.lowercased() == "zip" {
            let session = ElectronDeltaSession(bundleID: f.bundleID, expectedSHA512: r.sha512, expectedSize: r.size,
                                               updaterCacheDirName: AppSources.electronUpdaterCacheDirName(appPath: app.path))
            defer { session.cleanup() }
            pkg = try await AppInstaller.prepare(from: dl.url, into: app.path, expectedBundleID: f.bundleID, stagingDir: dir,
                                                 download: { u, l in try await session.download(u, log: l) }, log: log)
            session.commit(log: log)
        } else {
            pkg = try await AppInstaller.prepare(from: dl.url, into: app.path, expectedBundleID: f.bundleID, stagingDir: dir, log: log)
        }
        if let latest = item.latest, pkg.version != latest, VersionCompare.compare(pkg.version, latest) == .orderedSame {
            pkg.version = latest  // 等价写法（如 1.5 与 1.5.0）统一成列表显示的版本
        }
        try StagingStore.save(pkg)
        log("\(f.name) \(pkg.version) 已下载并校验，待安装（用时 \(Self.fmt(Date().timeIntervalSince(started)))）", false)
        return pkg
    }

    /// 清理某应用的暂存（改回其它策略 / 移除应用时）。
    static func clearStaged(for app: ManagedApp) {
        StagingStore.clear(bundleID: facts(for: app)?.bundleID, destination: app.path)
    }

    /// electron-updater 来源：zip 且开关打开时走 blockmap 增量下载（失败自动回退整包），成功后缓存新包作为下次基准。
    private func installElectron(from url: URL, resolved r: AppSources.Resolved, app: ManagedApp, facts f: BundleFacts,
                                 log: @escaping Logger, beforeReplace: @escaping @Sendable () async throws -> Void) async throws {
        guard DeltaDownloadPolicy.isEnabled, url.pathExtension.lowercased() == "zip" else {
            try await AppInstaller.install(from: url, into: app.path, expectedBundleID: f.bundleID, log: log, beforeReplace: beforeReplace)
            return
        }
        let session = ElectronDeltaSession(bundleID: f.bundleID, expectedSHA512: r.sha512, expectedSize: r.size,
                                           updaterCacheDirName: AppSources.electronUpdaterCacheDirName(appPath: app.path))
        defer { session.cleanup() }
        try await AppInstaller.install(from: url, into: app.path, expectedBundleID: f.bundleID, log: log, beforeReplace: beforeReplace,
                                       download: { u, l in try await session.download(u, log: l) })
        session.commit(log: log)
    }

    // MARK: - 进程收集 / 幽灵注册检测

    /// 记录"我们是否退出过该应用"，供更新结束后决定是否重启。
    private final class QuitState: @unchecked Sendable {
        private let lock = NSLock()
        private var _didQuit = false
        private var _pids: Set<pid_t> = []
        var didQuit: Bool { lock.lock(); defer { lock.unlock() }; return _didQuit }
        var quitPIDs: Set<pid_t> { lock.lock(); defer { lock.unlock() }; return _pids }
        func markQuit(pids: [pid_t]) { lock.lock(); _didQuit = true; _pids.formUnion(pids); lock.unlock() }
    }

    /// 该应用相关的全部进程：`runningApplications(withBundleIdentifier:)` ∪ bundleURL/executableURL 位于该 .app 之下的进程（含 Helper）。
    /// 按 pid 去重；不过滤幽灵注册，由 `liveProcesses` 处理。
    @MainActor
    static func runningProcesses(appPath: String, bundleID: String?) -> [NSRunningApplication] {
        let root = URL(fileURLWithPath: appPath).standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var seen = Set<pid_t>()
        var out: [NSRunningApplication] = []
        func add(_ a: NSRunningApplication) {
            guard seen.insert(a.processIdentifier).inserted else { return }
            out.append(a)
        }
        if let id = bundleID {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach(add)
        }
        for a in NSWorkspace.shared.runningApplications {
            let paths = [a.bundleURL, a.executableURL].compactMap { $0?.standardizedFileURL.path }
            if paths.contains(where: { $0 == root || $0.hasPrefix(prefix) }) { add(a) }
        }
        return out
    }

    /// pid 对应的进程是否真实存在：`kill(pid, 0)` 返回 ESRCH 即不存在（EPERM 等仍视为存在）。
    static func processExists(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    /// `NSRunningApplication` 存在但进程已不在 → LaunchServices 幽灵注册，记 ERROR 并剔除；返回真实存活的进程。
    @MainActor
    static func liveProcesses(_ procs: [NSRunningApplication], name: String, log: @escaping Logger) -> [NSRunningApplication] {
        var live: [NSRunningApplication] = []
        for p in procs {
            if p.isTerminated { continue }
            let pid = p.processIdentifier
            if processExists(pid) {
                live.append(p)
            } else {
                log("错误: LaunchServices 残留了已退出进程 pid \(pid) 的注册（\(name)，\(describe(p))），新实例可能无法启动；可注销重登或执行 sudo launchctl kickstart -k system/com.apple.coreservices.launchservicesd 清理", true)
            }
        }
        return live
    }

    @MainActor
    static func describe(_ p: NSRunningApplication) -> String {
        let exe = p.executableURL?.lastPathComponent ?? p.localizedName ?? "?"
        return "\(exe) pid \(p.processIdentifier)"
    }

    static func fmt(_ t: TimeInterval) -> String {
        t >= 60 ? String(format: "%d 分 %.0f 秒", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) : String(format: "%.1f 秒", t)
    }

    // MARK: - 退出 / 重启

    /// 退出进程集合：`terminate()` 等最多 15 秒，再 `forceTerminate()` 等最多 5 秒；每步记录结果。
    /// 等待时把"进程已不存在但 isTerminated 仍为 false"的幽灵注册视为已退出，并记 ERROR。
    /// 仍有真实存活进程时抛错，避免在应用运行中替换包。
    private func quit(_ procs: [NSRunningApplication], name: String, log: @escaping Logger) async throws {
        let t0 = Date()
        let list = await MainActor.run { procs.map(Self.describe).joined(separator: ", ") }
        log("退出 \(name)：\(procs.count) 个进程 [\(list)]", false)

        await MainActor.run {
            for p in procs {
                let ok = p.terminate()
                log("terminate \(Self.describe(p)) → \(ok ? "已发送" : "发送失败")", !ok)
            }
        }
        if try await waitUntilGone(procs, timeout: 15) {
            log("\(name) 已退出，用时 \(Self.fmt(Date().timeIntervalSince(t0)))", false)
            await reportGhosts(procs, name: name, log: log)
            return
        }

        let alive = await MainActor.run { procs.filter { !$0.isTerminated && Self.processExists($0.processIdentifier) } }
        let aliveList = await MainActor.run { alive.map(Self.describe).joined(separator: ", ") }
        log("优雅退出超时（15 秒），强制结束仍存活的 \(alive.count) 个进程 [\(aliveList)]", true)
        await MainActor.run {
            for p in alive {
                let ok = p.forceTerminate()
                log("forceTerminate \(Self.describe(p)) → \(ok ? "已发送" : "发送失败")", !ok)
            }
        }
        if try await waitUntilGone(procs, timeout: 5) {
            log("\(name) 已强制结束，用时 \(Self.fmt(Date().timeIntervalSince(t0)))", false)
            await reportGhosts(procs, name: name, log: log)
            return
        }

        let remaining = await MainActor.run { procs.filter { !$0.isTerminated && Self.processExists($0.processIdentifier) }.map(Self.describe) }
        log("错误: 强制结束后仍有进程存活 [\(remaining.joined(separator: ", "))]", true)
        throw ShellError.failed(name, 1, "无法结束应用进程: \(remaining.joined(separator: ", "))")
    }

    /// 轮询直到所有进程 `isTerminated` 或进程已不存在；超时返回 false。
    private func waitUntilGone(_ procs: [NSRunningApplication], timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let alive = await MainActor.run { procs.contains { !$0.isTerminated && Self.processExists($0.processIdentifier) } }
            if !alive { return true }
            if Date() >= deadline { return false }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    /// 退出完成后检查：进程已死但 `isTerminated` 仍为 false 的，即 LaunchServices 残留注册。
    private func reportGhosts(_ procs: [NSRunningApplication], name: String, log: @escaping Logger) async {
        await MainActor.run {
            for p in procs where !p.isTerminated && !Self.processExists(p.processIdentifier) {
                log("错误: LaunchServices 残留了已退出进程 pid \(p.processIdentifier) 的注册（\(name)，\(Self.describe(p))），新实例可能无法启动；可注销重登或执行 sudo launchctl kickstart -k system/com.apple.coreservices.launchservicesd 清理", true)
            }
        }
    }

    /// 重新启动应用：最多 3 次、间隔 2 秒；每次启动后等 3 秒确认出现了 pid 存活的新实例。失败只记日志，不抛错。
    /// 清理可执行文件位于该 .app 内、但不属于 NSRunningApplication 的遗留进程
    /// （如 Electron 的 chrome_crashpad_handler、应用自带的 CLI 子进程）。它们在主进程退出后
    /// 被 launchd 过继，LaunchServices 会把它们算作应用的 subordinate 进程而残留旧注册。
    static func killStrayProcesses(inside appPath: String, name: String, log: @escaping Logger) async {
        let root = URL(fileURLWithPath: appPath).standardizedFileURL.path + "/"
        guard let r = try? await Shell.run(["/bin/ps", "-axo", "pid=,comm="], timeout: 15) else { return }
        var pids: [(pid_t, String)] = []
        for line in r.stdout.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let sp = t.firstIndex(of: " "), let pid = pid_t(t[..<sp]) else { continue }
            let comm = t[t.index(after: sp)...].trimmingCharacters(in: .whitespaces)
            if comm.hasPrefix(root), pid != getpid() { pids.append((pid, String(comm))) }
        }
        guard !pids.isEmpty else { return }
        log("清理 \(name) 遗留子进程：" + pids.map { "\($0.0) \(($0.1 as NSString).lastPathComponent)" }.joined(separator: ", "), false)
        for (pid, _) in pids { kill(pid, SIGTERM) }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        for (pid, comm) in pids where kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
            log("强制结束遗留子进程 \(pid) \((comm as NSString).lastPathComponent)", false)
        }
    }

    private func relaunch(app: ManagedApp, name: String, bundleID: String?, quitPIDs: Set<pid_t>, log: @escaping Logger) async {
        let url = URL(fileURLWithPath: app.path)
        for attempt in 1...3 {
            log("重新启动 \(name)（第 \(attempt)/3 次）", false)
            do {
                if attempt == 1 {
                    let cfg = NSWorkspace.OpenConfiguration()
                    cfg.activates = false
                    let ra = try await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
                    let pid = await MainActor.run { ra.processIdentifier }
                    log("openApplication 返回 pid \(pid)，等待 3 秒确认", false)
                } else {
                    // 第 2 次起改走 Finder 的打开路径：应用退出后若 LaunchServices 残留了旧注册
                    // （其派生子进程被 launchd 过继，LS 视为仍在运行），open/NSWorkspace 启动的新进程
                    // 会在 100ms 内静默退出，而 Finder 的打开能成功并清掉旧注册。
                    log("改用 Finder 打开 \(name)（绕过 LaunchServices 残留注册）", false)
                    let posix = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    try await Shell.runChecked(["/usr/bin/osascript", "-e", "tell application \"Finder\" to open POSIX file \"\(posix)\""], timeout: 30)
                    log("Finder 已发出打开请求，等待 3 秒确认", false)
                }
                try await Task.sleep(nanoseconds: 3_000_000_000)
                let procs = await MainActor.run { Self.runningProcesses(appPath: app.path, bundleID: bundleID) }
                let live = await MainActor.run { Self.liveProcesses(procs, name: name, log: log) }
                let main = await MainActor.run {
                    live.filter { bundleID == nil || $0.bundleIdentifier == bundleID || $0.bundleURL?.standardizedFileURL.path == url.standardizedFileURL.path }
                }
                if let instance = await MainActor.run(body: { main.first(where: { !quitPIDs.contains($0.processIdentifier) }) ?? main.first }) {
                    let desc = await MainActor.run { Self.describe(instance) }
                    log("\(name) 已重新运行（\(desc)）", false)
                    return
                }
                log("错误: 重启后未检测到运行实例（\(name)，第 \(attempt)/3 次；进程在启动后 3 秒内退出或未能启动）", true)
            } catch {
                log("错误: 重新启动 \(name) 失败（第 \(attempt)/3 次）: \(error.localizedDescription)", true)
            }
            if attempt < 3 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        }
        log("错误: \(name) 重启 3 次均未成功，请手动启动；若立即退出，可能是 LaunchServices 残留注册所致（见上方日志）", true)
    }
}
