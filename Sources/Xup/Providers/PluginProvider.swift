import Foundation

/// Claude Code 与 Codex 的插件（marketplace 安装）。
/// id 后缀 / 关注键："claude/<name@mkt>" 或 "codex/<name@mkt>"。
struct PluginProvider: UpdateProvider {
    let kind: ProviderKind = .plugin

    enum Host: String, Sendable { case claude, codex }

    struct Installed: Sendable {
        let host: Host
        let selector: String        // name@mkt
        let version: String?        // 已安装版本
        var name: String { String(selector.split(separator: "@", maxSplits: 1).first ?? Substring(selector)) }
        var marketplace: String { selector.split(separator: "@", maxSplits: 1).count == 2 ? String(selector.split(separator: "@", maxSplits: 1)[1]) : "" }
        var key: String { "\(host.rawValue)/\(selector)" }
        var detail: String { "\(host == .claude ? "Claude" : "Codex") · \(marketplace)" }
    }

    static let claudeDir = URL(fileURLWithPath: Shell.home).appendingPathComponent(".claude/plugins")
    static let codexCacheDir = URL(fileURLWithPath: Shell.home).appendingPathComponent(".codex/plugins/cache")

    private var hasClaude: Bool { Shell.which("claude") != nil }
    private var hasCodex: Bool { Shell.which("codex") != nil }

    func isAvailable() -> Bool { hasClaude || hasCodex }

    static func split(key: String) -> (Host, String)? {
        let parts = key.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let host = Host(rawValue: String(parts[0])) else { return nil }
        return (host, String(parts[1]))
    }

    // MARK: - Claude

    /// ~/.claude/plugins/installed_plugins.json → {"plugins": {"name@mkt": [{scope, installPath, version}]}}
    static func readClaudeInstalled() -> [Installed] {
        let url = claudeDir.appendingPathComponent("installed_plugins.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any] else { return [] }
        return plugins.compactMap { (selector, raw) in
            let entries = raw as? [[String: Any]] ?? []
            // 优先 user scope，否则第一条。
            let e = entries.first { ($0["scope"] as? String) == "user" } ?? entries.first
            return Installed(host: .claude, selector: selector, version: e?["version"] as? String)
        }.sorted { $0.selector < $1.selector }
    }

    /// ~/.claude/plugins/known_marketplaces.json → {mkt: {installLocation}}
    static func readClaudeMarketplaces() -> [String: String] {
        let url = claudeDir.appendingPathComponent("known_marketplaces.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (name, raw) in root {
            if let d = raw as? [String: Any], let loc = d["installLocation"] as? String { out[name] = loc }
        }
        return out
    }

    /// <installLocation>/.claude-plugin/marketplace.json → plugins[].{name, version}
    static func readMarketplaceVersions(installLocation: String) -> [String: String?] {
        let url = URL(fileURLWithPath: installLocation).appendingPathComponent(".claude-plugin/marketplace.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [[String: Any]] else { return [:] }
        var out: [String: String?] = [:]
        for p in plugins {
            guard let name = p["name"] as? String else { continue }
            out[name] = p["version"] as? String
        }
        return out
    }

    private func checkClaude(_ targets: [Installed], log: @escaping Logger) async -> [UpdateItem] {
        guard !targets.isEmpty else { return [] }
        guard hasClaude else {
            return targets.map { UpdateItem(kind: .plugin, name: $0.name, detail: $0.detail, installed: $0.version ?? "?", latest: nil,
                                            status: .unknown("本机未安装 claude"), canUpdate: false, idSuffix: $0.key) }
        }
        let marketplaces = Self.readClaudeMarketplaces()
        var versionsByMarket: [String: [String: String?]] = [:]
        for mkt in Set(targets.map(\.marketplace)).sorted() {
            log("$ claude plugin marketplace update \(mkt)", false)
            if let r = try? await Shell.run(["claude", "plugin", "marketplace", "update", mkt], timeout: 300), !r.ok {
                log("marketplace \(mkt) 刷新失败，使用本地快照", true)
            }
            if let loc = marketplaces[mkt] { versionsByMarket[mkt] = Self.readMarketplaceVersions(installLocation: loc) }
        }
        return targets.map { p in
            let installed = p.version ?? "?"
            guard let table = versionsByMarket[p.marketplace] else {
                return UpdateItem(kind: .plugin, name: p.name, detail: p.detail, installed: installed, latest: nil,
                                  status: .unknown("未找到 marketplace \(p.marketplace) 的本地副本"), idSuffix: p.key)
            }
            guard let entry = table[p.name] else {
                return UpdateItem(kind: .plugin, name: p.name, detail: p.detail, installed: installed, latest: nil,
                                  status: .unknown("marketplace 中已没有该插件"), idSuffix: p.key)
            }
            guard let latest = entry, !latest.isEmpty else {
                return UpdateItem(kind: .plugin, name: p.name, detail: p.detail, installed: installed, latest: nil,
                                  status: .unknown("marketplace 未声明版本号"), idSuffix: p.key)
            }
            guard p.version != nil else {
                return UpdateItem(kind: .plugin, name: p.name, detail: p.detail, installed: installed, latest: latest,
                                  status: .unknown("无法读取已安装版本"), idSuffix: p.key)
            }
            let status: ItemStatus = VersionCompare.isNewer(latest, than: installed) ? .outdated : .upToDate
            return UpdateItem(kind: .plugin, name: p.name, detail: p.detail, installed: installed, latest: latest, status: status, idSuffix: p.key)
        }
    }

    // MARK: - Codex

    /// 解析 `codex plugin list` 的表格，返回 (selector, status, version)。
    /// 表头形如 "PLUGIN   STATUS   VERSION   SOURCE"，按表头列起点切分各行。
    static func parseCodexList(_ text: String) -> [(selector: String, status: String, version: String)] {
        var out: [(String, String, String)] = []
        var cols: [(name: String, start: Int)] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = Shell.stripANSI(rawLine)
            let chars = Array(line)
            if line.hasPrefix("PLUGIN") {
                cols = []
                for col in ["PLUGIN", "STATUS", "VERSION", "SOURCE"] {
                    if let r = line.range(of: col) { cols.append((col, line.distance(from: line.startIndex, to: r.lowerBound))) }
                }
                continue
            }
            guard cols.count >= 3, !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            func field(_ i: Int) -> String {
                let start = cols[i].start
                let end = i + 1 < cols.count ? cols[i + 1].start : chars.count
                guard start < chars.count else { return "" }
                return String(chars[start..<min(end, chars.count)]).trimmingCharacters(in: .whitespaces)
            }
            let selector = field(0)
            guard selector.contains("@") else { continue }   // 跳过 "Marketplace `x`" 等非数据行
            out.append((selector, field(1), field(2)))
        }
        return out
    }

    /// ~/.codex/plugins/cache/<mkt>/<plugin>/<version>/ 下最大的版本目录名。
    static func codexCachedVersion(marketplace: String, plugin: String) -> String? {
        let dir = codexCacheDir.appendingPathComponent(marketplace).appendingPathComponent(plugin)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let versions = names.filter { !$0.hasPrefix(".") }
        return versions.max { VersionCompare.compare($0, $1) == .orderedAscending }
    }

    private func codexInstalledRows(log: @escaping Logger) async throws -> [(selector: String, status: String, version: String)] {
        let r = try await Shell.runChecked(["codex", "plugin", "list"], timeout: 120)
        return Self.parseCodexList(r.stdout).filter { row in
            let s = row.status.lowercased()
            return s.contains("installed") && !s.contains("not installed")
        }
    }

    private func checkCodex(_ keys: Set<String>, log: @escaping Logger) async -> [UpdateItem] {
        guard !keys.isEmpty else { return [] }
        func unknown(_ selector: String, _ msg: String, canUpdate: Bool = false) -> UpdateItem {
            let p = Installed(host: .codex, selector: selector, version: nil)
            return UpdateItem(kind: .plugin, name: p.name, detail: p.detail, installed: "?", latest: nil, status: .unknown(msg), canUpdate: canUpdate, idSuffix: p.key)
        }
        guard hasCodex else { return keys.sorted().map { unknown($0, "本机未安装 codex") } }

        log("$ codex plugin marketplace upgrade", false)
        if let r = try? await Shell.run(["codex", "plugin", "marketplace", "upgrade"], timeout: 300), !r.ok {
            log("codex marketplace 刷新失败，使用本地快照", true)
        }
        let rows: [(selector: String, status: String, version: String)]
        do { rows = try await codexInstalledRows(log: log) } catch {
            return keys.sorted().map { unknown($0, "codex plugin list 失败: \(error.localizedDescription)") }
        }
        let byselector = Dictionary(rows.map { ($0.selector, $0) }, uniquingKeysWith: { a, _ in a })
        let hint = "Codex 暂无升级命令；可在终端执行 codex plugin add <plugin@mkt> 重新安装"
        return keys.sorted().map { selector in
            let bare = Installed(host: .codex, selector: selector, version: nil)
            let p = Installed(host: .codex, selector: selector,
                              version: Self.codexCachedVersion(marketplace: bare.marketplace, plugin: bare.name))
            guard let row = byselector[selector] else {
                return UpdateItem(kind: .plugin, name: p.name, detail: p.detail, installed: p.version ?? "?", latest: nil,
                                  status: .unknown("codex plugin list 中未见该插件（可能已卸载）"), canUpdate: false, hint: hint, idSuffix: p.key)
            }
            let latest = row.version.isEmpty ? nil : row.version
            guard let installed = p.version else {
                return UpdateItem(kind: .plugin, name: p.name, detail: p.detail, installed: "?", latest: latest,
                                  status: .unknown("本地缓存中找不到已安装版本"), canUpdate: false, hint: hint, idSuffix: p.key)
            }
            guard let latest else {
                return UpdateItem(kind: .plugin, name: p.name, detail: p.detail, installed: installed, latest: nil,
                                  status: .unknown("marketplace 未给出版本号"), canUpdate: false, hint: hint, idSuffix: p.key)
            }
            let status: ItemStatus = VersionCompare.isNewer(latest, than: installed) ? .outdated : .upToDate
            return UpdateItem(kind: .plugin, name: p.name, detail: p.detail, installed: installed, latest: latest, status: status,
                              canUpdate: false, hint: hint, idSuffix: p.key)
        }
    }

    // MARK: - 协议

    func listInstalled(log: @escaping Logger) async throws -> [InstalledEntry] {
        var out: [InstalledEntry] = []
        if hasClaude {
            out += Self.readClaudeInstalled().map { InstalledEntry(name: $0.key, detail: $0.detail, version: $0.version ?? "?") }
        }
        if hasCodex {
            if let rows = try? await codexInstalledRows(log: log) {
                for row in rows {
                    let p = Installed(host: .codex, selector: row.selector, version: nil)
                    let v = Self.codexCachedVersion(marketplace: p.marketplace, plugin: p.name) ?? row.version
                    out.append(InstalledEntry(name: p.key, detail: p.detail, version: v.isEmpty ? "?" : v))
                }
            } else {
                log("codex plugin list 失败，Codex 插件列表为空", true)
            }
        }
        return out.sorted { $0.name < $1.name }
    }

    func check(tracked: Set<String>, log: @escaping Logger) async throws -> [UpdateItem] {
        guard !tracked.isEmpty else {
            log("插件: 未选择任何软件，跳过", false)
            return []
        }
        var claudeSet: Set<String> = []
        var codexSet: Set<String> = []
        for key in tracked {
            guard let (host, selector) = Self.split(key: key) else { continue }
            if host == .claude { claudeSet.insert(selector) } else { codexSet.insert(selector) }
        }
        let claudeSelectors = claudeSet, codexSelectors = codexSet
        let claudeTargets = Self.readClaudeInstalled().filter { claudeSelectors.contains($0.selector) }
        let missing = claudeSelectors.subtracting(claudeTargets.map(\.selector))
        if !missing.isEmpty { log("Claude 插件 \(missing.sorted().joined(separator: "、")) 已不在 installed_plugins.json 中", true) }

        async let c = checkClaude(claudeTargets, log: log)
        async let x = checkCodex(codexSelectors, log: log)
        let items = (await c + x).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        log("插件: \(items.filter(\.status.isOutdated).count)/\(items.count) 个可更新", false)
        return items
    }

    func update(_ item: UpdateItem, log: @escaping Logger) async throws {
        let key = String(item.id.dropFirst("\(kind.rawValue):".count))
        guard let (host, selector) = Self.split(key: key) else { throw ShellError.failed(item.name, 1, "无法识别插件来源") }
        switch host {
        case .claude:
            let cmd = ["claude", "plugin", "update", "-y", selector]
            log("$ " + cmd.joined(separator: " "), false)
            try await Shell.runChecked(cmd, timeout: 600, onOutput: log)
        case .codex:
            // `codex plugin add --help` 没有 --force/升级语义，不自动执行。
            throw ShellError.failed(item.name, 1, "Codex 暂无升级命令，请在终端执行 codex plugin add \(selector)")
        }
    }
}
