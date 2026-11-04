import Foundation

/// 路径与环境。
enum Paths {
    static let home = NSHomeDirectory()
    static let supportDir = home + "/Library/Application Support/Xup"
    static let configPath = supportDir + "/config.json"
    static let backupPath = configPath + ".bak"
    static let socketPath = supportDir + "/control.sock"
    static let schemaName = "config.schema.json"

    static var executableURL: URL { URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath() }

    /// CLI 若位于 Xup.app/Contents/Helpers/（或 MacOS/）内，返回该 .app 路径。
    static var ownBundle: String? {
        let p = executableURL.path
        guard let r = p.range(of: "/Contents/Helpers/") ?? p.range(of: "/Contents/MacOS/") else { return nil }
        let app = String(p[..<r.lowerBound])
        return app.hasSuffix(".app") ? app : nil
    }

    /// 候选 App 路径：XUP_APP_PATH → 自身所在 bundle → /Applications/Xup.app → ./build/Xup.app。
    static var appCandidates: [String] {
        var list: [String] = []
        if let env = ProcessInfo.processInfo.environment["XUP_APP_PATH"], !env.isEmpty { list.append(env) }
        if let own = ownBundle { list.append(own) }
        list.append("/Applications/Xup.app")
        list.append(FileManager.default.currentDirectoryPath + "/build/Xup.app")
        return list
    }

    static var appPath: String? {
        appCandidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// 查找资源文件（schema / SKILL.md）：自身 bundle 的 Resources → 支持目录 → 候选 App 的 Resources。
    static func resource(_ name: String, envOverride: String? = nil) -> String? {
        var candidates: [String] = []
        if let env = envOverride, let v = ProcessInfo.processInfo.environment[env], !v.isEmpty { candidates.append(v) }
        candidates.append(executableURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/\(name)").path)
        candidates.append(supportDir + "/" + name)
        for app in appCandidates { candidates.append(app + "/Contents/Resources/" + name) }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    static func display(_ path: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// config.json 的读写（纯文件操作，不依赖 App 运行）。
enum ConfigFile {
    static let kinds = ["homebrew", "npm", "uv", "agent", "skill", "plugin"]

    static func defaultConfig() -> [String: Any] {
        [
            "$schema": "./config.schema.json",
            "version": 1,
            "check": ["intervalMinutes": 360, "notify": true, "autoUpdate": false],
            "homebrew": ["greedy": false],
            "ui": ["showUpToDate": false, "launchAtLogin": false],
            "electron": ["deltaDownload": true, "keepVersionsPerApp": 1],
            "agent": ["allowUpdates": false],
            "tracked": Dictionary(uniqueKeysWithValues: kinds.map { ($0, [String]()) }),
            "apps": [[String: Any]](),
        ]
    }

    static var exists: Bool { FileManager.default.fileExists(atPath: Paths.configPath) }

    /// 读取；不存在时返回默认配置（不写盘）。
    static func load() throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: Paths.configPath) else { return defaultConfig() }
        do {
            guard let obj = try JSON.parse(data) as? [String: Any] else { throw CLIError("config.json 顶层必须是对象") }
            return obj
        } catch let e as CLIError {
            throw e
        } catch {
            throw CLIError("config.json 不是合法 JSON：\(error.localizedDescription)")
        }
    }

    static var validator: SchemaValidator? {
        guard let path = Paths.resource(Paths.schemaName), let data = FileManager.default.contents(atPath: path) else { return nil }
        return SchemaValidator(data: data)
    }

    static var schemaPath: String? { Paths.resource(Paths.schemaName) }

    /// 校验；找不到 schema 时打印警告并放行。
    static func validate(_ obj: Any) throws {
        guard let v = validator else {
            warn("未找到 \(Paths.schemaName)（启动一次 Xup 会导出到 \(Paths.display(Paths.supportDir))），跳过校验")
            return
        }
        let r = v.validate(obj, strictUnknown: true)
        if !r.errors.isEmpty {
            throw CLIError("配置校验失败，未写入：\n  " + r.errors.joined(separator: "\n  "))
        }
    }

    /// 校验 → 备份 → 原子写入。
    static func save(_ obj: [String: Any]) throws {
        var cfg = obj
        cfg["$schema"] = cfg["$schema"] ?? "./config.schema.json"
        cfg["version"] = cfg["version"] ?? 1
        try validate(cfg)
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Paths.supportDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: Paths.configPath) {
            try? fm.removeItem(atPath: Paths.backupPath)
            try? fm.copyItem(atPath: Paths.configPath, toPath: Paths.backupPath)
        }
        let data = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        do {
            try data.write(to: URL(fileURLWithPath: Paths.configPath), options: .atomic)
        } catch {
            throw CLIError("写入 \(Paths.configPath) 失败：\(error.localizedDescription)")
        }
    }

    // MARK: 关注列表

    static func normalizeKind(_ raw: String) throws -> String {
        let k = raw == "brew" ? "homebrew" : raw
        guard kinds.contains(k) else {
            throw usageError("未知来源 \(raw)；可用：\(kinds.joined(separator: ", "))（brew 是 homebrew 的别名；应用请用 xup apps）")
        }
        return k
    }

    /// 解析 `<kind>:<name>`。
    static func parseTracked(_ token: String) throws -> (kind: String, name: String) {
        guard let idx = token.firstIndex(of: ":") else {
            throw usageError("格式应为 <kind>:<name>，如 homebrew:node、npm:typescript、uv:nox、plugin:claude/foo@bar：\(token)")
        }
        let kind = try normalizeKind(String(token[..<idx]))
        let name = String(token[token.index(after: idx)...])
        guard !name.isEmpty else { throw usageError("名称不能为空：\(token)") }
        return (kind, name)
    }

    static func trackedList(_ cfg: [String: Any], kind: String) -> [String] {
        ((cfg["tracked"] as? [String: Any])?[kind] as? [String]) ?? []
    }

    static func setTracked(_ cfg: inout [String: Any], kind: String, names: [String]) {
        var tracked = cfg["tracked"] as? [String: Any] ?? [:]
        tracked[kind] = Array(Set(names)).sorted()
        cfg["tracked"] = tracked
    }

    // MARK: 应用

    static func normalizeAppPath(_ raw: String) throws -> String {
        var p = (raw as NSString).expandingTildeInPath
        if !p.hasPrefix("/") { p = FileManager.default.currentDirectoryPath + "/" + p }
        p = URL(fileURLWithPath: p).standardizedFileURL.path
        guard p.hasSuffix(".app") else { throw usageError("必须是 .app 包路径：\(raw)") }
        return p
    }

    static func apps(_ cfg: [String: Any]) -> [[String: Any]] {
        cfg["apps"] as? [[String: Any]] ?? []
    }

    /// 解析来源 spec：github:owner/repo[#pattern] | tauri:<url> | electron:<url> | appcast:<url> | auto（返回 nil）。
    static func parseSourceSpec(_ spec: String) throws -> [String: Any]? {
        let s = spec.trimmingCharacters(in: .whitespaces)
        if s == "auto" || s == "null" || s == "none" { return nil }
        if s.hasPrefix("github:") || s.hasPrefix("https://github.com/") || s.hasPrefix("gh:") {
            var rest = s
            for prefix in ["github:", "gh:"] where rest.hasPrefix(prefix) { rest = String(rest.dropFirst(prefix.count)) }
            var pattern: String?
            if let hash = rest.firstIndex(of: "#") {
                pattern = String(rest[rest.index(after: hash)...])
                rest = String(rest[..<hash])
            }
            if let r = rest.range(of: "github.com/") {
                rest = String(rest[r.upperBound...])
            }
            let parts = rest.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { throw usageError("GitHub 来源格式应为 github:owner/repo[#assetPattern]：\(spec)") }
            var repo = "\(parts[0])/\(parts[1])"
            if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
            var d: [String: Any] = ["type": "githubReleases", "repo": repo]
            if let pattern, !pattern.isEmpty { d["assetPattern"] = pattern }
            return d
        }
        for (prefix, type) in [("tauri:", "tauri"), ("electron:", "electronYML"), ("appcast:", "appcast")] where s.hasPrefix(prefix) {
            var url = String(s.dropFirst(prefix.count))
            guard let scheme = URL(string: url)?.scheme?.lowercased(), scheme == "http" || scheme == "https", URL(string: url)?.host != nil else {
                throw usageError("\(type) 来源必须是完整的 http(s) URL：\(spec)")
            }
            if type == "electronYML", !url.lowercased().hasSuffix(".yml"), !url.lowercased().hasSuffix(".yaml") {
                if !url.hasSuffix("/") { url += "/" }
                url += "latest-mac.yml"
            }
            return ["type": type, "url": url]
        }
        throw usageError("无法识别的来源 spec：\(spec)（支持 github:owner/repo[#pattern]、tauri:<url>、electron:<url>、appcast:<url>、auto）")
    }

    static func describeSource(_ src: Any?) -> String {
        guard let d = src as? [String: Any], let type = d["type"] as? String else { return "auto" }
        switch type {
        case "githubReleases":
            let repo = d["repo"] as? String ?? "?"
            if let p = d["assetPattern"] as? String { return "github:\(repo)#\(p)" }
            return "github:\(repo)"
        case "tauri": return "tauri:\(d["url"] as? String ?? "?")"
        case "electronYML": return "electron:\(d["url"] as? String ?? "?")"
        case "appcast": return "appcast:\(d["url"] as? String ?? "?")"
        default: return JSON.compact(d)
        }
    }
}

// MARK: - 输出

var jsonMode = false

func warn(_ s: String) {
    FileHandle.standardError.write(Data(("xup: " + s + "\n").utf8))
}

func out(_ s: String) {
    print(s)
}

/// 中英文混排时的显示宽度（CJK 算 2）。
func displayWidth(_ s: String) -> Int {
    s.unicodeScalars.reduce(0) { acc, u in
        let v = u.value
        let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
            || (0xFFE0...0xFFE6).contains(v) || (0x20000...0x3FFFD).contains(v)
        return acc + (wide ? 2 : 1)
    }
}

func pad(_ s: String, _ width: Int) -> String {
    let w = displayWidth(s)
    return w >= width ? s : s + String(repeating: " ", count: width - w)
}

/// 简单表格：列宽取最大，列间两个空格。
func table(_ headers: [String], _ rows: [[String]]) -> String {
    guard !rows.isEmpty else { return "" }
    var widths = headers.map(displayWidth)
    for r in rows {
        for (i, c) in r.enumerated() where i < widths.count { widths[i] = max(widths[i], displayWidth(c)) }
    }
    var lines: [String] = []
    lines.append(zip(headers, widths).map { pad($0, $1) }.joined(separator: "  ").trimmingCharacters(in: .whitespaces))
    lines.append(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
    for r in rows {
        lines.append(zip(r, widths).map { pad($0, $1) }.joined(separator: "  ").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
    }
    return lines.joined(separator: "\n")
}
