import XCTest
@testable import Xup

/// §19 更新方式：策略默认 / 继承 / 降级、autoUpdate 迁移、暂存元数据校验、Scheduler "待空闲"集合的生成与作废。
@MainActor
final class PolicyTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xup-policy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeSettings(json: String? = nil) throws -> AppSettings {
        let url = tmp.appendingPathComponent("config.json")
        if let json { try Data(json.utf8).write(to: url) }
        let store = ConfigStore(url: url, migrateFrom: nil, watch: false)
        let suite = "dev.fming.xup.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppSettings(defaults: defaults, store: store)
    }

    private func item(_ kind: ProviderKind, _ name: String, detail: String? = nil, status: ItemStatus = .outdated,
                      canUpdate: Bool = true, idSuffix: String? = nil, latest: String? = "2.0") -> UpdateItem {
        UpdateItem(kind: kind, name: name, detail: detail, installed: "1.0", latest: latest, status: status, canUpdate: canUpdate, idSuffix: idSuffix)
    }

    // MARK: 策略默认 / 继承 / 降级

    func testPolicyDefaultsInheritAndDowngrade() throws {
        let s = try makeSettings()
        var logs: [String] = []
        s.log = { logs.append($0) }

        // 无记录 → 默认 manual；改默认后未记录的条目跟着变，已记录的不变。
        XCTAssertEqual(s.policy(for: "npm:typescript"), .manual)
        s.setPolicy(.auto, for: "uv:nox")
        s.defaultPolicy = .auto
        XCTAssertEqual(s.policy(for: "npm:typescript"), .auto)
        XCTAssertEqual(s.policy(for: "uv:nox"), .auto)
        s.defaultPolicy = .autoDownload  // 默认值只允许 manual/auto
        XCTAssertEqual(s.defaultPolicy, .auto)
        s.defaultPolicy = .manual
        XCTAssertEqual(s.policy(for: "npm:typescript"), .manual)
        XCTAssertEqual(s.policy(for: "uv:nox"), .auto, "已有记录不随默认值回溯")

        // homebrew：token 形式的记录对 formula/cask 形式的 id 生效。
        s.setPolicy(.auto, for: "homebrew:node")
        XCTAssertEqual(s.policy(for: "homebrew:formula/node"), .auto)
        XCTAssertEqual(s.policy(for: "homebrew:cask/node"), .auto)
        XCTAssertEqual(s.policy(for: "homebrew:formula/other"), .manual)
        // 用 formula 形式改写后，token 形式的旧键被清掉。
        s.setPolicy(.manual, for: "homebrew:formula/node")
        XCTAssertNil(s.config.policies["homebrew:node"])
        XCTAssertEqual(s.policy(for: "homebrew:formula/node"), .manual)

        // 非应用写 autoDownload → 存为 auto。
        s.setPolicy(.autoDownload, for: "npm:typescript")
        XCTAssertEqual(s.config.policies["npm:typescript"], .auto)

        // 配置里直接出现非应用的 autoDownload → 读取时降级为 auto，日志只记一次。
        s.store.update { $0.policies["uv:pdm"] = .autoDownload }
        s.applyExternal(s.store.config)
        XCTAssertEqual(s.policy(for: "uv:pdm"), .auto)
        XCTAssertEqual(s.policy(for: "uv:pdm"), .auto)
        XCTAssertEqual(logs.filter { $0.contains("uv:pdm") }.count, 1)

        // 应用：来源不支持预下载（cask）→ 降级为 auto；Sparkle 支持 → 保持。
        s.addApps(paths: ["/Applications/Cask.app", "/Applications/Sparkle.app"])
        s.setPolicy(.autoDownload, for: "app:/Applications/Cask.app")
        s.setPolicy(.autoDownload, for: "app:/Applications/Sparkle.app")
        let cask = item(.app, "Cask", detail: "Homebrew cask cask", idSuffix: "/Applications/Cask.app")
        let sparkle = item(.app, "Sparkle", detail: "Sparkle · example.com", idSuffix: "/Applications/Sparkle.app")
        XCTAssertFalse(cask.supportsStaging)
        XCTAssertTrue(sparkle.supportsStaging)
        XCTAssertEqual(s.policy(for: cask), .auto)
        XCTAssertEqual(s.policy(for: sparkle), .autoDownload)
        XCTAssertEqual(s.policy(for: "app:/Applications/Cask.app"), .autoDownload, "不带条目信息时无法判断来源，原样返回")
        XCTAssertTrue(logs.contains { $0.contains("Cask.app") && $0.contains("不支持预下载") })

        // installWhenIdle 子开关
        XCTAssertFalse(s.installWhenIdle(path: "/Applications/Sparkle.app"))
        s.setInstallWhenIdle(path: "/Applications/Sparkle.app", true)
        XCTAssertTrue(s.installWhenIdle(path: "/Applications/Sparkle.app"))

        // 取消关注 / 移除应用 → 删除记录
        s.track(.uv, "nox")
        s.untrack(.uv, "nox")
        XCTAssertNil(s.config.policies["uv:nox"])
        s.removeApp(path: "/Applications/Sparkle.app")
        XCTAssertNil(s.config.policies["app:/Applications/Sparkle.app"])
        // 新关注不写记录
        s.track(.npm, "eslint")
        XCTAssertNil(s.config.policies["npm:eslint"])
    }

    // MARK: 迁移

    func testLegacyAutoUpdateMigratesToPolicies() throws {
        let json = #"""
        {"version":1,"check":{"intervalMinutes":60,"autoUpdate":true},
         "tracked":{"homebrew":["node"],"uv":["nox"]},
         "apps":[{"path":"/Applications/IINA.app"}],
         "policies":{"uv:nox":"manual"}}
        """#
        let (cfg, warnings) = try ConfigStore.parse(Data(json.utf8))
        XCTAssertEqual(cfg.check.defaultPolicy, .auto)
        XCTAssertEqual(cfg.check.intervalMinutes, 60)
        XCTAssertEqual(cfg.policies["homebrew:node"], .auto)
        XCTAssertEqual(cfg.policies["app:/Applications/IINA.app"], .auto)
        XCTAssertEqual(cfg.policies["uv:nox"], .manual, "已有记录不被迁移覆盖")
        XCTAssertFalse(warnings.contains { $0.contains("未知字段 check.autoUpdate") })
        XCTAssertTrue(warnings.contains { $0.contains("已迁移") })

        // autoUpdate=false → 保持 manual，不写 policies
        let (cfg2, _) = try ConfigStore.parse(Data(#"{"version":1,"check":{"autoUpdate":false},"tracked":{"uv":["nox"]}}"#.utf8))
        XCTAssertEqual(cfg2.check.defaultPolicy, .manual)
        XCTAssertTrue(cfg2.policies.isEmpty)

        // ConfigStore 加载后回写：旧键消失，新字段落盘
        let url = tmp.appendingPathComponent("config.json")
        try Data(json.utf8).write(to: url)
        let store = ConfigStore(url: url, migrateFrom: nil, watch: false)
        XCTAssertEqual(store.config.check.defaultPolicy, .auto)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let check = try XCTUnwrap(obj["check"] as? [String: Any])
        XCTAssertNil(check["autoUpdate"])
        XCTAssertEqual(check["defaultPolicy"] as? String, "auto")
        XCTAssertEqual(check["idleMinutes"] as? Int, 5)
        XCTAssertEqual((obj["policies"] as? [String: String])?["homebrew:node"], "auto")
        // 再次加载无警告、内容一致
        let (again, w2) = try ConfigStore.parse(Data(contentsOf: url))
        XCTAssertEqual(again.check, store.config.check)
        XCTAssertEqual(again.policies, store.config.policies)
        XCTAssertEqual(again.apps, store.config.apps)
        XCTAssertTrue(w2.isEmpty, "\(w2)")

        // schema：defaultPolicy 不接受 autoDownload；idleMinutes 1–60；policies 值受限
        XCTAssertThrowsError(try ConfigStore.parse(Data(#"{"version":1,"check":{"defaultPolicy":"autoDownload"}}"#.utf8)))
        XCTAssertThrowsError(try ConfigStore.parse(Data(#"{"version":1,"check":{"idleMinutes":0}}"#.utf8)))
        XCTAssertThrowsError(try ConfigStore.parse(Data(#"{"version":1,"check":{"idleMinutes":61}}"#.utf8)))
        XCTAssertThrowsError(try ConfigStore.parse(Data(#"{"version":1,"policies":{"uv:nox":"sometimes"}}"#.utf8)))
        XCTAssertNoThrow(try ConfigStore.parse(Data(#"{"version":1,"policies":{"app:/Applications/A.app":"autoDownload"},"apps":[{"path":"/Applications/A.app","installWhenIdle":true}]}"#.utf8)))
    }

    // MARK: 暂存元数据校验

    func testStagedPackageValidation() throws {
        StagingStore.rootURL = tmp.appendingPathComponent("staged")
        defer { StagingStore.rootURL = tmp.appendingPathComponent("staged-unused") }
        let dest = "/Applications/Demo.app"
        let bundleID = "dev.example.demo"

        func makeApp(version: String) throws -> StagedPackage {
            let dir = StagingStore.directory(bundleID: bundleID, destination: dest, version: version)
            let app = dir.appendingPathComponent("Demo.app")
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version, "CFBundleVersion": "100"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            // ISO8601 只保留到秒，构造整秒时间以便往返比较。
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            return StagedPackage(appPath: app.path, destination: dest, version: version, build: "100", bundleID: bundleID,
                                 sourceURL: "https://example.com/demo.zip", sha256: "abc", archiveSize: 1, stagedAt: now)
        }

        // 保存 → 读取 → 有效
        let pkg = try makeApp(version: "2.0")
        try StagingStore.save(pkg)
        XCTAssertEqual(StagingStore.load(bundleID: bundleID, destination: dest), pkg)
        XCTAssertNil(StagingStore.validate(pkg, latest: "2.0"))
        XCTAssertNotNil(StagingStore.validPackage(bundleID: bundleID, destination: dest, latest: "2.0"))

        // 版本不符 → 作废并删除
        var reason: StagingStore.Invalid?
        XCTAssertNil(StagingStore.validPackage(bundleID: bundleID, destination: dest, latest: "2.1") { _, why in reason = why })
        XCTAssertEqual(reason, .versionMismatch(staged: "2.0", latest: "2.1"))
        XCTAssertNil(StagingStore.load(bundleID: bundleID, destination: dest), "失效后应删除暂存")

        // 过期（31 天）→ 作废
        var old = try makeApp(version: "2.0")
        old.stagedAt = Date().addingTimeInterval(-31 * 86400)
        try StagingStore.save(old)
        XCTAssertEqual(StagingStore.validate(old, latest: "2.0"), .expired(days: 31))
        XCTAssertNil(StagingStore.validPackage(bundleID: bundleID, destination: dest, latest: "2.0"))
        XCTAssertNil(StagingStore.load(bundleID: bundleID, destination: dest))

        // 文件被删 → missing
        let gone = try makeApp(version: "2.0")
        try StagingStore.save(gone)
        try FileManager.default.removeItem(at: gone.appURL)
        XCTAssertEqual(StagingStore.validate(gone, latest: "2.0"), .missing)

        // 每应用只保留一份：保存 3.0 后 2.0 目录消失
        let v3 = try makeApp(version: "3.0")
        try StagingStore.save(v3)
        let dirs = try FileManager.default.contentsOfDirectory(atPath: StagingStore.directory(bundleID: bundleID, destination: dest).path)
        XCTAssertEqual(dirs, ["3.0"])
        XCTAssertEqual(StagingStore.all().count, 1)

        // 包内版本与记录不符 → bundleMismatch
        var lie = v3
        lie.version = "3.5"
        XCTAssertEqual(StagingStore.validate(lie, latest: "3.5"), .bundleMismatch(expected: "3.5", actual: "3.0"))

        // AppsProvider.applyStagedState：有效暂存 → .staged；无新版本 → 清理
        let app = ManagedApp(path: dest)
        var outdated = item(.app, "Demo", detail: "Sparkle · example.com", idSuffix: dest, latest: "3.0")
        // facts(for:) 读不到 /Applications/Demo.app，bundleID 为 nil → 目录键落到 destination；这里按同样的键再存一份。
        let pkgByDest = StagedPackage(appPath: v3.appPath, destination: dest, version: "3.0", build: "100", bundleID: nil,
                                      sourceURL: v3.sourceURL, sha256: nil, archiveSize: nil, stagedAt: Date())
        var byDest = pkgByDest
        let destDir = StagingStore.directory(bundleID: nil, destination: dest, version: "3.0")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: v3.appURL, to: destDir.appendingPathComponent("Demo.app"))
        byDest.appPath = destDir.appendingPathComponent("Demo.app").path
        try StagingStore.save(byDest)
        outdated = AppsProvider.applyStagedState(outdated, app: app) { _, _ in }
        XCTAssertEqual(outdated.status, .staged("3.0"))
        XCTAssertTrue(outdated.isActionable)
        let upToDate = item(.app, "Demo", detail: "Sparkle · example.com", status: .upToDate, idSuffix: dest, latest: "3.0")
        _ = AppsProvider.applyStagedState(upToDate, app: app) { _, _ in }
        XCTAssertNil(StagingStore.load(bundleID: nil, destination: dest), "已无新版本时清理暂存")
    }

    // MARK: Scheduler "待空闲"集合

    func testSchedulerPendingSetIsReplacedOnNextCheck() async throws {
        let s = try makeSettings()
        s.idleMinutes = 5
        let center = UpdateCenter(settings: s, history: UpdateHistory(url: tmp.appendingPathComponent("history.jsonl")))
        var idle = FixedIdle(seconds: 0)
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let probe = IdleProbe()
        let scheduler = Scheduler(settings: s, center: center, idle: probe, now: { clock })
        probe.state = idle

        var items = [
            item(.homebrew, "node", detail: "formula", idSuffix: "formula/node"),
            item(.npm, "typescript"),
            item(.uv, "nox"),
            item(.app, "Cask", detail: "Homebrew cask cask", idSuffix: "/Applications/Cask.app"),
        ]
        s.setPolicy(.auto, for: "homebrew:formula/node")
        s.setPolicy(.auto, for: "npm:typescript")
        s.setPolicy(.auto, for: "app:/Applications/Cask.app")
        var ran: [(Set<String>, Trigger)] = []
        var staged: [Set<String>] = []
        scheduler.itemsSource = { items }
        scheduler.runUpdate = { ids, trigger in ran.append((ids, trigger)) }
        scheduler.runStage = { ids in staged.append(ids); return [] }

        // 不空闲：集合生成，不执行
        await scheduler.evaluateAutomation(trigger: .scheduled)
        XCTAssertEqual(scheduler.pendingAutoIDs, ["homebrew:formula/node", "npm:typescript", "app:/Applications/Cask.app"])
        XCTAssertEqual(scheduler.pendingSince, clock)
        XCTAssertTrue(ran.isEmpty)
        XCTAssertTrue(staged.isEmpty, "没有 autoDownload 的应用")

        // 5 分钟后复查仍不空闲：不执行
        clock = clock.addingTimeInterval(300)
        await scheduler.recheckPending()
        XCTAssertTrue(ran.isEmpty)
        XCTAssertEqual(scheduler.pendingAutoIDs.count, 3)

        // 下一轮定时检查：node 已被用户更新、typescript 改回手动、nox 改为自动 → 集合重新生成，旧集合作废（不累积）
        items[0].status = .upToDate
        s.setPolicy(.manual, for: "npm:typescript")
        s.setPolicy(.auto, for: "uv:nox")
        clock = clock.addingTimeInterval(3600)
        await scheduler.evaluateAutomation(trigger: .scheduled)
        XCTAssertEqual(scheduler.pendingAutoIDs, ["uv:nox", "app:/Applications/Cask.app"])
        XCTAssertEqual(scheduler.pendingSince, clock)
        XCTAssertTrue(ran.isEmpty)

        // 变为空闲（阈值 5 分钟 = 300 秒）：复查时立即执行，trigger 为 scheduled，集合清空
        idle.seconds = 301
        probe.state = idle
        await scheduler.recheckPending()
        XCTAssertEqual(ran.count, 1)
        XCTAssertEqual(ran.first?.0, ["uv:nox", "app:/Applications/Cask.app"])
        XCTAssertEqual(ran.first?.1, .scheduled)
        XCTAssertTrue(scheduler.pendingAutoIDs.isEmpty)
        XCTAssertNil(scheduler.pendingSince)

        // 锁屏视为空闲：阈值未到也执行
        items[2].status = .outdated
        probe.state = FixedIdle(seconds: 10, locked: true)
        await scheduler.evaluateAutomation(trigger: .auto)
        XCTAssertEqual(ran.count, 2)
        XCTAssertEqual(ran.last?.1, .auto)

        // autoDownload 的 Sparkle 应用：立即预下载（不需空闲）；cask 应用上的 autoDownload 降级为 auto 进待空闲集合
        probe.state = FixedIdle(seconds: 0)
        s.addApps(paths: ["/Applications/Sparkle.app"])
        s.setPolicy(.autoDownload, for: "app:/Applications/Sparkle.app")
        s.setPolicy(.autoDownload, for: "app:/Applications/Cask.app")
        items.append(item(.app, "Sparkle", detail: "Sparkle · example.com", idSuffix: "/Applications/Sparkle.app"))
        await scheduler.evaluateAutomation(trigger: .scheduled)
        // 预下载在独立 Task 里，稍等让它跑完
        for _ in 0..<50 where staged.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(staged, [["app:/Applications/Sparkle.app"]])
        XCTAssertEqual(scheduler.pendingAutoIDs, ["uv:nox", "app:/Applications/Cask.app"])

        // installWhenIdle：已暂存 + 开关开 + 空闲 + 未运行 → 自动安装；应用在运行则跳过
        items[items.count - 1].status = .staged("2.0")
        s.setInstallWhenIdle(path: "/Applications/Sparkle.app", true)
        var running = true
        scheduler.isAppRunning = { _ in running }
        probe.state = FixedIdle(seconds: 600)
        ran.removeAll()
        await scheduler.recheckPending()
        XCTAssertFalse(ran.contains { $0.0.contains("app:/Applications/Sparkle.app") }, "应用运行中本轮跳过")
        running = false
        await scheduler.recheckPending()
        XCTAssertTrue(ran.contains { $0.0 == ["app:/Applications/Sparkle.app"] })
    }
}

/// 可在测试中途改状态的空闲判定。
private final class IdleProbe: IdleChecking, @unchecked Sendable {
    var state = FixedIdle(seconds: 0)
    func secondsSinceLastInput() -> TimeInterval { state.seconds }
    func isScreenLocked() -> Bool { state.locked }
}
