import XCTest
@testable import Xup

final class ConfigTests: XCTestCase {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xup-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func json(_ s: String) -> Data { Data(s.utf8) }

    // MARK: 编解码往返

    func testRoundTripWithAllSourceTypes() throws {
        var cfg = XupConfig()
        cfg.check.intervalMinutes = 720
        cfg.check.autoUpdate = true
        cfg.homebrew.greedy = true
        cfg.electron.deltaDownload = false
        cfg.electron.keepVersionsPerApp = 3
        cfg.agent.allowUpdates = true
        cfg.tracked[.homebrew] = ["node", "iina"]
        cfg.tracked[.plugin] = ["claude/foo@bar"]
        cfg.apps = [
            ManagedApp(path: "/Applications/A.app", restartAfterUpdate: true, source: nil),
            ManagedApp(path: "/Applications/B.app", restartAfterUpdate: false, source: .githubReleases(repo: "owner/repo", assetPattern: "*arm64*.dmg")),
            ManagedApp(path: "/Applications/C.app", source: .tauri(url: URL(string: "https://example.com/latest.json")!)),
            ManagedApp(path: "/Applications/D.app", source: .electronYML(url: URL(string: "https://example.com/latest-mac.yml")!)),
            ManagedApp(path: "/Applications/E.app", source: .appcast(url: URL(string: "https://example.com/appcast.xml")!)),
        ]

        let data = try cfg.encoded()
        let (decoded, warnings) = try ConfigStore.parse(data)
        XCTAssertEqual(decoded, cfg)
        XCTAssertTrue(warnings.isEmpty, "不应有警告：\(warnings)")

        // 文件形态：source 带显式 type 字段，$schema 在顶层
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["$schema"] as? String, "./config.schema.json")
        XCTAssertEqual(obj["version"] as? Int, 1)
        let apps = try XCTUnwrap(obj["apps"] as? [[String: Any]])
        XCTAssertEqual((apps[1]["source"] as? [String: Any])?["type"] as? String, "githubReleases")
        XCTAssertEqual((apps[1]["source"] as? [String: Any])?["repo"] as? String, "owner/repo")
        XCTAssertEqual((apps[2]["source"] as? [String: Any])?["type"] as? String, "tauri")
        XCTAssertEqual((apps[3]["source"] as? [String: Any])?["type"] as? String, "electronYML")
        XCTAssertEqual((apps[4]["source"] as? [String: Any])?["type"] as? String, "appcast")
        XCTAssertNil(apps[0]["source"], "source 为 nil 时省略字段")
        let tracked = try XCTUnwrap(obj["tracked"] as? [String: [String]])
        XCTAssertEqual(tracked["homebrew"], ["iina", "node"], "关注列表写出时排序")
    }

    func testLegacySourceEncodingStillDecodes() throws {
        // v1.0 UserDefaults 里 Swift 默认的 enum 编码
        let legacy = json(#"[{"path":"/Applications/X.app","restartAfterUpdate":true,"source":{"githubReleases":{"repo":"a/b","assetPattern":null}}},{"path":"/Applications/Y.app","source":{"appcast":{"url":"https://e.com/a.xml"}}}]"#)
        let apps = try JSONDecoder().decode([ManagedApp].self, from: legacy)
        XCTAssertEqual(apps[0].source, .githubReleases(repo: "a/b", assetPattern: nil))
        XCTAssertEqual(apps[1].source, .appcast(url: URL(string: "https://e.com/a.xml")!))
    }

    func testPartialFileUsesDefaults() throws {
        let (cfg, warnings) = try ConfigStore.parse(json(#"{"version":1,"check":{"intervalMinutes":15},"tracked":{"uv":["nox"]}}"#))
        XCTAssertEqual(cfg.check.intervalMinutes, 15)
        XCTAssertTrue(cfg.check.notify)
        XCTAssertTrue(cfg.electron.deltaDownload)
        XCTAssertEqual(cfg.electron.keepVersionsPerApp, 1)
        XCTAssertEqual(cfg.tracked[.uv], ["nox"])
        XCTAssertTrue(warnings.isEmpty)
    }

    // MARK: 校验

    func testTypeErrorIsRejected() {
        XCTAssertThrowsError(try ConfigStore.parse(json(#"{"version":1,"check":{"intervalMinutes":"360"}}"#))) { error in
            guard case ConfigError.invalid(let errs) = error else { return XCTFail("应为 ConfigError.invalid，实际 \(error)") }
            XCTAssertTrue(errs.contains { $0.contains("check.intervalMinutes") }, "\(errs)")
        }
        XCTAssertThrowsError(try ConfigStore.parse(json(#"{"version":1,"apps":[{"path":"/Applications/A.app","source":{"type":"githubReleases"}}]}"#)))
        XCTAssertThrowsError(try ConfigStore.parse(json(#"{"version":1,"apps":[{"path":"/Applications/A.app","source":{"type":"bogus","url":"https://x"}}]}"#)))
        XCTAssertThrowsError(try ConfigStore.parse(json(#"{"version":1,"tracked":{"npm":"typescript"}}"#)))
        XCTAssertThrowsError(try ConfigStore.parse(json("not json")))
    }

    func testUnknownFieldIsWarningOnly() throws {
        let (cfg, warnings) = try ConfigStore.parse(json(#"{"version":1,"check":{"interval":5,"notify":false},"bogus":true}"#))
        XCTAssertFalse(cfg.check.notify)
        XCTAssertEqual(cfg.check.intervalMinutes, 360)
        XCTAssertEqual(warnings.count, 2, "\(warnings)")
        XCTAssertTrue(warnings.contains { $0.contains("check.interval") })
        XCTAssertTrue(warnings.contains { $0.contains("bogus") })
    }

    func testEmbeddedSchemaMatchesSupportFile() throws {
        // Support/config.schema.json 是事实来源；App 内嵌一份以便无资源时也能校验/导出。
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fileData = try Data(contentsOf: root.appendingPathComponent("Support/config.schema.json"))
        let a = try JSONSerialization.jsonObject(with: fileData) as? NSDictionary
        let b = try JSONSerialization.jsonObject(with: Data(ConfigSchema.json.utf8)) as? NSDictionary
        XCTAssertEqual(a, b, "ConfigStore.swift 内嵌的 schema 与 Support/config.schema.json 不一致")
    }

    // MARK: 迁移与存储

    @MainActor
    func testMigrationFromUserDefaults() throws {
        let suite = "dev.fming.xup.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(60, forKey: "checkIntervalMinutes")
        defaults.set(true, forKey: "brewGreedy")
        defaults.set(false, forKey: "notifyOnUpdates")
        defaults.set(true, forKey: "showUpToDate")
        defaults.set(try JSONEncoder().encode(["homebrew": ["node"], "uv": ["nox", "ruff"]]), forKey: "tracked")
        defaults.set(try JSONEncoder().encode([ManagedApp(path: "/Applications/IINA.app", restartAfterUpdate: false,
                                                          source: .githubReleases(repo: "iina/iina", assetPattern: nil))]), forKey: "managedApps")

        let dir = try tempDir()
        let url = dir.appendingPathComponent("config.json")
        let store = ConfigStore(url: url, migrateFrom: defaults, watch: false)
        XCTAssertEqual(store.config.check.intervalMinutes, 60)
        XCTAssertTrue(store.config.homebrew.greedy)
        XCTAssertFalse(store.config.check.notify)
        XCTAssertTrue(store.config.ui.showUpToDate)
        XCTAssertEqual(store.config.tracked[.homebrew], ["node"])
        XCTAssertEqual(store.config.tracked[.uv], ["nox", "ruff"])
        XCTAssertEqual(store.config.apps.first?.source, .githubReleases(repo: "iina/iina", assetPattern: nil))
        XCTAssertFalse(store.config.apps.first?.restartAfterUpdate ?? true)

        // 文件已写出且可被重新加载；schema 同目录导出
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.schema.json").path))
        let reloaded = ConfigStore(url: url, migrateFrom: nil, watch: false)
        XCTAssertEqual(reloaded.config, store.config)
    }

    @MainActor
    func testUpdateWritesBackupAndInvalidFileKeepsOldConfig() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("config.json")
        let store = ConfigStore(url: url, migrateFrom: nil, watch: false)
        store.update { $0.check.intervalMinutes = 15 }
        store.update { $0.tracked[.npm] = ["typescript"] }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
        let bak = try ConfigStore.parse(Data(contentsOf: url.appendingPathExtension("bak"))).0
        XCTAssertEqual(bak.check.intervalMinutes, 15)
        XCTAssertEqual(bak.tracked[.npm], [])

        // 外部写入非法内容 → reload 失败，保留旧配置
        try json(#"{"version":1,"check":{"notify":"yes"}}"#).write(to: url)
        let err = store.reload(source: .external)
        XCTAssertNotNil(err)
        XCTAssertEqual(store.config.tracked[.npm], ["typescript"])
        XCTAssertNotNil(store.lastError)

        // 外部写入合法内容 → 生效并回调
        var fired: XupConfig?
        store.onChange = { cfg, _ in fired = cfg }
        try json(#"{"version":1,"check":{"intervalMinutes":5},"tracked":{"uv":["nox"]}}"#).write(to: url)
        XCTAssertNil(store.reload(source: .external))
        XCTAssertEqual(fired?.check.intervalMinutes, 5)
        XCTAssertEqual(store.config.tracked[.uv], ["nox"])
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testAppSettingsFacade() throws {
        let dir = try tempDir()
        let store = ConfigStore(url: dir.appendingPathComponent("config.json"), migrateFrom: nil, watch: false)
        let suite = "dev.fming.xup.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, store: store)

        settings.track(.uv, "nox")
        settings.addApps(paths: ["/Applications/Foo.app", "/tmp/not-an-app"])
        settings.setSource(path: "/Applications/Foo.app", .appcast(url: URL(string: "https://e.com/a.xml")!))
        settings.checkIntervalMinutes = 30
        XCTAssertEqual(store.config.tracked[.uv], ["nox"])
        XCTAssertEqual(store.config.apps.map(\.path), ["/Applications/Foo.app"])
        XCTAssertEqual(store.config.apps.first?.source, .appcast(url: URL(string: "https://e.com/a.xml")!))
        XCTAssertEqual(store.config.check.intervalMinutes, 30)
        XCTAssertEqual(settings.tracked, [.uv: ["nox"]])

        settings.untrack(.uv, "nox")
        settings.removeApp(path: "/Applications/Foo.app")
        XCTAssertTrue(settings.tracked.isEmpty)
        XCTAssertTrue(settings.managedApps.isEmpty)
    }
}
