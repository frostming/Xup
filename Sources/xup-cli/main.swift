import Foundation

// xup —— Xup 的命令行 / agent 接口。
// 纯配置命令直接读写 ~/Library/Application Support/Xup/config.json；
// 其余命令通过 Unix socket 调用运行中的 Xup（未运行时自动 `open -gj` 拉起）。
// 退出码：0 成功 / 1 失败 / 2 参数错误。

let cliVersion = "0.0.1"

let usage = """
用法：xup [--json] <命令> [参数]

配置（直接读写 config.json，无需 App 运行）
  config path                       打印 config.json 路径
  config get [path]                 读取整个配置或某个字段，如 check.intervalMinutes、apps.0.source
  config set <path> <json-value>    写入字段（按 schema 校验；非 JSON 字面量按字符串处理）
  config unset <path>               删除字段（恢复默认）
  config validate                   校验 config.json
  config schema                     打印 config.schema.json
  track list                        列出关注列表
  track add <kind>:<name>...        加入关注，如 homebrew:node npm:typescript uv:nox plugin:claude/x@mkt
  track remove <kind>:<name>...     取消关注
  apps list                         列出受管应用
  apps add <path> [--restart|--no-restart] [--source <spec>]
                                    --restart（默认）：更新时应用若在运行，自动退出并重新打开
                                    --no-restart：应用在运行就跳过本次更新，等用户关闭后再更新
  apps remove <path>...
  apps set-source <path> <spec>     spec：github:owner/repo[#pattern] | tauri:<url> | electron:<url> | appcast:<url> | auto
  policy list                       每条目的更新方式（manual / auto / autoDownload）与默认值
  policy get <id>                   某条目的更新方式（无记录时为默认值）
  policy set <id>... manual|auto|auto-download [--install-when-idle on|off]
                                    设置更新方式；auto-download 仅应用（Sparkle / electron-updater / 手动配置来源）

运行时（通过控制通道，App 未运行时自动启动）
  status                            总览：上次检查、各来源可更新数、条目摘要
  items [--kind k]                  完整条目列表
  installed <kind>                  本机已安装、可加入关注的清单（homebrew/npm/uv/agent/skill/plugin）
  check [--kind k,...] [--wait]     触发检查；--wait 等待完成并返回结果
  update <id>... | --all [--wait] [--yes]
                                    执行更新；需要 --yes（或配置 agent.allowUpdates=true）；已下载待安装(staged)的应用直接安装
  stage <id>... [--wait]            预下载：下载、校验并暂存应用新版本，不替换、不退出应用
  apps probe-source <path> <spec>   只探测来源的最新版本/下载地址，不下载
  log [--tail N] [--errors]         查看 App 日志
  history [--tail N] [--failed] [--kind k]
                                    更新历史（默认最近 50 条；--json 输出记录数组）
  history clear --yes               清空更新历史
  launch <app-path>                 启动/置前某个应用
  reload-config                     让 App 立即重新加载 config.json

其它
  skill install                     把 SKILL.md 安装到 ~/.agents/skills/xup 与 ~/.claude/skills/xup
  skill show                        打印 SKILL.md
  --json                            所有命令输出 JSON
  --version / --help

id 规则：homebrew:formula/<name>、homebrew:cask/<name>、npm:<pkg>、uv:<tool>、agent:<binary>、skill:<name>、
        plugin:claude/<name@mkt>、app:<path>。关注列表（track）用 <kind>:<name>，homebrew 直接用 token。
环境变量：XUP_APP_PATH 指定要拉起的 Xup.app；XUP_SKILL_PATH 指定 SKILL.md。
"""

// MARK: - 参数

struct Args {
    var positional: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]

    init(_ raw: [String], valueFlags: Set<String>) {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if a == "--" { positional.append(contentsOf: raw[(i + 1)...]); break }
            if a.hasPrefix("--") {
                let body = String(a.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    options[String(body[..<eq])] = String(body[body.index(after: eq)...])
                } else if valueFlags.contains(body), i + 1 < raw.count {
                    options[body] = raw[i + 1]
                    i += 1
                } else {
                    flags.insert(body)
                }
            } else if a.hasPrefix("-"), a.count == 2 {
                flags.insert(String(a.dropFirst()))
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func has(_ f: String) -> Bool { flags.contains(f) }
    subscript(_ i: Int) -> String? { i < positional.count ? positional[i] : nil }
}

// MARK: - 输出辅助

func emit(_ obj: Any, human: () -> String) {
    if jsonMode { out(JSON.pretty(obj)) } else { out(human()) }
}

func fail(_ e: CLIError) -> Never {
    if jsonMode { out(JSON.pretty(["ok": false, "error": e.message])) }
    warn(e.message)
    if e.code == .usage { warn("运行 xup --help 查看用法") }
    exit(e.code.rawValue)
}

func str(_ d: [String: Any], _ k: String) -> String {
    guard let v = d[k] else { return "" }
    return JSON.scalar(v)
}

func shortTime(_ iso: String?) -> String {
    guard let iso, let d = ISO8601DateFormatter.withFraction.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "—" }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: d)
}

extension ISO8601DateFormatter {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

func itemsTable(_ items: [[String: Any]]) -> String {
    table(["ID", "状态", "已安装", "最新", "方式", "说明"], items.map { it in
        [str(it, "id"), str(it, "status"), str(it, "installed"), str(it, "latest").isEmpty ? "—" : str(it, "latest"),
         policyLabel(str(it, "policy")),
         [str(it, "detail"), str(it, "message"), str(it, "hint")].filter { !$0.isEmpty }.joined(separator: " · ")]
    })
}

func policyLabel(_ raw: String) -> String {
    switch raw {
    case "manual": return "手动"
    case "auto": return "空闲自动"
    case "autoDownload": return "自动下载"
    default: return raw
    }
}

/// CLI 输入的策略名 → config 值。
func parsePolicy(_ raw: String) -> String? {
    switch raw.lowercased() {
    case "manual": return "manual"
    case "auto": return "auto"
    case "autodownload", "auto-download", "auto_download": return "autoDownload"
    default: return nil
    }
}

/// homebrew 的三种等价键（token / formula/<token> / cask/<token>）。
func policyAliasKeys(_ id: String) -> [String] {
    guard id.hasPrefix("homebrew:") else { return [id] }
    var suffix = String(id.dropFirst("homebrew:".count))
    if let slash = suffix.firstIndex(of: "/") { suffix = String(suffix[suffix.index(after: slash)...]) }
    return ["homebrew:\(suffix)", "homebrew:formula/\(suffix)", "homebrew:cask/\(suffix)"]
}

// MARK: - 命令

func cmdConfig(_ a: Args) throws {
    switch a[1] {
    case "path":
        emit(["path": Paths.configPath, "exists": ConfigFile.exists, "schema": (ConfigFile.schemaPath as Any?) ?? NSNull()]) { Paths.configPath }
    case "get", nil:
        let cfg = try ConfigFile.load()
        if let path = a[2] {
            guard let v = JSON.get(cfg, path: path) else { throw CLIError("字段不存在：\(path)") }
            if jsonMode { out(JSON.pretty(v)) }
            else if v is [String: Any] || v is [Any] { out(JSON.pretty(v)) }
            else { out(JSON.scalar(v)) }
        } else {
            out(JSON.pretty(cfg))
        }
    case "set":
        guard let path = a[2], let raw = a[3] else { throw usageError("用法：xup config set <path> <json-value>") }
        if path == "$schema" || path == "version" { throw usageError("\(path) 由 Xup 维护，不能修改") }
        var cfg = try ConfigFile.load()
        let value = JSON.parseLoose(raw)
        guard let next = try JSON.set(cfg, path: path, value: value) as? [String: Any] else { throw CLIError("写入失败") }
        cfg = next
        try ConfigFile.save(cfg)
        emit(["ok": true, "path": path, "value": value]) { "\(path) = \(JSON.compact(value))" }
    case "unset":
        guard let path = a[2] else { throw usageError("用法：xup config unset <path>") }
        var cfg = try ConfigFile.load()
        guard JSON.get(cfg, path: path) != nil else { throw CLIError("字段不存在：\(path)") }
        guard let next = JSON.delete(cfg, path: path) as? [String: Any] else { throw CLIError("删除失败") }
        cfg = next
        try ConfigFile.save(cfg)
        emit(["ok": true, "path": path]) { "已删除 \(path)" }
    case "validate":
        let cfg = try ConfigFile.load()
        guard let v = ConfigFile.validator else { throw CLIError("未找到 \(Paths.schemaName)；先启动一次 Xup 以导出 schema") }
        let r = v.validate(cfg, strictUnknown: true)
        emit(["valid": r.errors.isEmpty, "errors": r.errors, "warnings": r.warnings]) {
            r.errors.isEmpty ? "config.json 校验通过" : "校验失败：\n  " + r.errors.joined(separator: "\n  ")
        }
        if !r.errors.isEmpty { exit(ExitCode.failure.rawValue) }
    case "schema":
        guard let p = ConfigFile.schemaPath, let data = FileManager.default.contents(atPath: p) else {
            throw CLIError("未找到 \(Paths.schemaName)；先启动一次 Xup 以导出 schema")
        }
        out(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
    default:
        throw usageError("未知子命令 config \(a[1]!)")
    }
}

func cmdTrack(_ a: Args) throws {
    var cfg = try ConfigFile.load()
    switch a[1] {
    case "list", nil:
        let tracked = cfg["tracked"] as? [String: Any] ?? [:]
        emit(tracked) {
            var rows: [[String]] = []
            for k in ConfigFile.kinds { for n in ConfigFile.trackedList(cfg, kind: k) { rows.append([k, n]) } }
            return rows.isEmpty ? "关注列表为空（xup track add <kind>:<name>）" : table(["来源", "名称"], rows)
        }
    case "add", "remove":
        let tokens = Array(a.positional.dropFirst(2))
        guard !tokens.isEmpty else { throw usageError("用法：xup track \(a[1]!) <kind>:<name>...") }
        var changed: [String: [String]] = [:], unchanged: [String] = []
        for t in tokens {
            let (kind, name) = try ConfigFile.parseTracked(t)
            var list = ConfigFile.trackedList(cfg, kind: kind)
            if a[1] == "add" {
                if list.contains(name) { unchanged.append(t); continue }
                list.append(name)
            } else {
                guard let i = list.firstIndex(of: name) else { unchanged.append(t); continue }
                list.remove(at: i)
            }
            ConfigFile.setTracked(&cfg, kind: kind, names: list)
            changed[kind, default: []].append(name)
        }
        if !changed.isEmpty { try ConfigFile.save(cfg) }
        let verb = a[1] == "add" ? "已加入关注" : "已取消关注"
        emit(["changed": changed, "unchanged": unchanged, "tracked": cfg["tracked"] ?? [:], "appRunning": Client.isRunning]) {
            var lines: [String] = []
            for (k, v) in changed.sorted(by: { $0.key < $1.key }) { lines.append("\(verb)：\(v.map { "\(k):\($0)" }.joined(separator: " "))") }
            if !unchanged.isEmpty { lines.append("无变化：\(unchanged.joined(separator: " "))") }
            if !changed.isEmpty { lines.append(Client.isRunning ? "Xup 会热加载并重新检查。" : "Xup 下次启动时生效；或运行 xup check。") }
            return lines.joined(separator: "\n")
        }
    default:
        throw usageError("未知子命令 track \(a[1]!)")
    }
}

func cmdApps(_ a: Args) throws {
    var cfg = try ConfigFile.load()
    switch a[1] {
    case "list", nil:
        let apps = ConfigFile.apps(cfg)
        emit(apps) {
            apps.isEmpty ? "没有受管应用（xup apps add <path>）" :
                table(["路径", "应用运行时", "来源"], apps.map { [str($0, "path"), ($0["restartAfterUpdate"] as? Bool ?? true) ? "自动退出并重新打开" : "等用户关闭后再更新", ConfigFile.describeSource($0["source"])] })
        }
    case "add":
        guard let raw = a[2] else { throw usageError("用法：xup apps add <path> [--restart|--no-restart] [--source <spec>]") }
        let path = try ConfigFile.normalizeAppPath(raw)
        guard FileManager.default.fileExists(atPath: path) else { throw CLIError("应用不存在：\(path)") }
        var apps = ConfigFile.apps(cfg)
        if apps.contains(where: { ($0["path"] as? String) == path }) { throw CLIError("已在列表中：\(path)") }
        var entry: [String: Any] = ["path": path, "restartAfterUpdate": !a.has("no-restart")]
        if let spec = a.options["source"] { entry["source"] = try ConfigFile.parseSourceSpec(spec) ?? NSNull() }
        apps.append(entry)
        apps.sort { (str($0, "path") as NSString).lastPathComponent.localizedCaseInsensitiveCompare((str($1, "path") as NSString).lastPathComponent) == .orderedAscending }
        cfg["apps"] = apps
        try ConfigFile.save(cfg)
        emit(["added": entry]) { "已添加 \(path)（来源：\(ConfigFile.describeSource(entry["source"]))）" }
    case "remove":
        let raws = Array(a.positional.dropFirst(2))
        guard !raws.isEmpty else { throw usageError("用法：xup apps remove <path>...") }
        var apps = ConfigFile.apps(cfg)
        var removed: [String] = []
        for raw in raws {
            let path = try ConfigFile.normalizeAppPath(raw)
            if let i = apps.firstIndex(where: { ($0["path"] as? String) == path }) { apps.remove(at: i); removed.append(path) }
        }
        guard !removed.isEmpty else { throw CLIError("列表中没有这些应用") }
        cfg["apps"] = apps
        try ConfigFile.save(cfg)
        emit(["removed": removed]) { "已移除：" + removed.joined(separator: " ") }
    case "set-source":
        guard let raw = a[2], let spec = a[3] else { throw usageError("用法：xup apps set-source <path> <spec>") }
        let path = try ConfigFile.normalizeAppPath(raw)
        var apps = ConfigFile.apps(cfg)
        guard let i = apps.firstIndex(where: { ($0["path"] as? String) == path }) else { throw CLIError("不在列表中：\(path)（先 xup apps add）") }
        let source = try ConfigFile.parseSourceSpec(spec)
        apps[i]["source"] = source ?? NSNull()
        cfg["apps"] = apps
        try ConfigFile.save(cfg)
        emit(["path": path, "source": (source as Any?) ?? NSNull()]) { "\(path) 来源 → \(ConfigFile.describeSource(source))" }
    case "probe-source":
        guard let raw = a[2], let spec = a[3] else { throw usageError("用法：xup apps probe-source <path> <spec>") }
        let path = try ConfigFile.normalizeAppPath(raw)
        guard let source = try ConfigFile.parseSourceSpec(spec) else { throw usageError("probe-source 需要具体来源，不能是 auto") }
        let r = try Client.call("probe-source", ["path": path, "source": source])
        emit(r) {
            let d = r as? [String: Any] ?? [:]
            var s = "最新版本 \(str(d, "latest"))"
            if !str(d, "installed").isEmpty { s += "（已安装 \(str(d, "installed"))，\((d["isNewer"] as? Bool) == true ? "可更新" : "无需更新")）" }
            s += "\n下载：" + (str(d, "downloadURL").isEmpty ? "未找到可下载的 macOS 安装包" : str(d, "downloadURL"))
            return s
        }
    default:
        throw usageError("未知子命令 apps \(a[1]!)")
    }
}

// MARK: 更新方式（§19，直接读写 config.json；App 热加载）

func cmdPolicy(_ a: Args) throws {
    var cfg = try ConfigFile.load()
    var policies = cfg["policies"] as? [String: Any] ?? [:]
    let defaultPolicy = (cfg["check"] as? [String: Any])?["defaultPolicy"] as? String ?? "manual"
    func stored(_ id: String) -> String? {
        for k in policyAliasKeys(id) { if let v = policies[k] as? String { return v } }
        return nil
    }
    switch a[1] {
    case "list", nil:
        // 配置里的记录 + 关注列表 + 应用（缺省条目显示默认值）。
        var ids = Set(policies.keys)
        for k in ConfigFile.kinds { for n in ConfigFile.trackedList(cfg, kind: k) { ids.insert("\(k):\(n)") } }
        for app in ConfigFile.apps(cfg) { if let p = app["path"] as? String { ids.insert("app:\(p)") } }
        let apps = ConfigFile.apps(cfg)
        let rows = ids.sorted().map { id -> [String: Any] in
            var d: [String: Any] = ["id": id, "policy": stored(id) ?? defaultPolicy, "inherited": stored(id) == nil]
            if id.hasPrefix("app:"), let app = apps.first(where: { ($0["path"] as? String) == String(id.dropFirst(4)) }) {
                d["installWhenIdle"] = (app["installWhenIdle"] as? Bool) ?? false
            }
            return d
        }
        let idle = (cfg["check"] as? [String: Any])?["idleMinutes"] as? Int ?? 5
        emit(["defaultPolicy": defaultPolicy, "idleMinutes": idle, "items": rows]) {
            var lines = ["默认更新方式（新关注条目）：\(policyLabel(defaultPolicy)) · 空闲判定 \(idle) 分钟"]
            if rows.isEmpty { lines.append("没有关注的条目") } else {
                lines.append(table(["ID", "更新方式", "来源", "空闲未运行时自动安装"], rows.map { r in
                    [str(r, "id"), policyLabel(str(r, "policy")), (r["inherited"] as? Bool) == true ? "默认" : "单独设置",
                     r["installWhenIdle"] == nil ? "" : ((r["installWhenIdle"] as? Bool) == true ? "开" : "关")]
                }))
            }
            return lines.joined(separator: "\n")
        }
    case "get":
        guard let id = a[2] else { throw usageError("用法：xup policy get <id>") }
        let p = stored(id) ?? defaultPolicy
        var d: [String: Any] = ["id": id, "policy": p, "inherited": stored(id) == nil]
        if id.hasPrefix("app:"), let app = ConfigFile.apps(cfg).first(where: { ($0["path"] as? String) == String(id.dropFirst(4)) }) {
            d["installWhenIdle"] = (app["installWhenIdle"] as? Bool) ?? false
        }
        emit(d) { "\(id) → \(policyLabel(p))" + (stored(id) == nil ? "（默认）" : "") + (d["installWhenIdle"] == nil ? "" : " · 空闲未运行时自动安装：\((d["installWhenIdle"] as? Bool) == true ? "开" : "关")") }
    case "set":
        var tokens = Array(a.positional.dropFirst(2))
        guard tokens.count >= 2, let last = tokens.last, let policy = parsePolicy(last) else {
            throw usageError("用法：xup policy set <id>... manual|auto|auto-download [--install-when-idle on|off]")
        }
        tokens.removeLast()
        var installWhenIdle: Bool?
        if let raw = a.options["install-when-idle"] {
            switch raw.lowercased() {
            case "on", "true", "1", "yes": installWhenIdle = true
            case "off", "false", "0", "no": installWhenIdle = false
            default: throw usageError("--install-when-idle 取值 on|off")
            }
        }
        var apps = ConfigFile.apps(cfg)
        var results: [[String: Any]] = []
        for raw in tokens {
            var id = raw
            if id.hasPrefix("brew:") { id = "homebrew:" + id.dropFirst(5) }
            if id.hasPrefix("app:") {
                let path = try ConfigFile.normalizeAppPath(String(id.dropFirst(4)))
                id = "app:\(path)"
                guard let i = apps.firstIndex(where: { ($0["path"] as? String) == path }) else { throw CLIError("不在应用列表中：\(path)（先 xup apps add）") }
                if let on = installWhenIdle { apps[i]["installWhenIdle"] = on }
            } else if policy == "autoDownload" {
                throw CLIError("\(id) 不是应用；auto-download 只适用于 Sparkle / electron-updater / 手动配置来源的应用")
            } else if installWhenIdle != nil {
                throw CLIError("--install-when-idle 只适用于应用（app:<path>）")
            }
            for k in policyAliasKeys(id) { policies[k] = nil }
            policies[id] = policy
            results.append(["id": id, "policy": policy])
        }
        cfg["policies"] = policies
        cfg["apps"] = apps
        try ConfigFile.save(cfg)
        emit(["set": results, "installWhenIdle": (installWhenIdle as Any?) ?? NSNull(), "appRunning": Client.isRunning]) {
            var lines = results.map { "\(str($0, "id")) → \(policyLabel(policy))" }
            if let on = installWhenIdle { lines.append("空闲且应用未运行时自动安装：\(on ? "开" : "关")") }
            if policy == "autoDownload" { lines.append("提示：来源不支持预下载的应用会按“空闲时自动更新”处理（见 xup log）") }
            lines.append(Client.isRunning ? "Xup 已热加载。" : "Xup 下次启动时生效。")
            return lines.joined(separator: "\n")
        }
    default:
        throw usageError("未知子命令 policy \(a[1]!)")
    }
}

func cmdStage(_ a: Args) throws {
    let ids = Array(a.positional.dropFirst(1))
    guard !ids.isEmpty else { throw usageError("用法：xup stage <id>... [--wait]") }
    let r = try Client.call("stage", ["ids": ids, "wait": a.has("wait")])
    emit(r) {
        let d = r as? [String: Any] ?? [:]
        var lines: [String] = []
        if let started = d["started"] as? [String] {
            lines.append(started.isEmpty ? "没有需要预下载的条目" : "已开始后台下载：" + started.joined(separator: " ") + "\n稍后 xup items --kind app 查看是否变为 staged")
        } else if let items = d["items"] as? [[String: Any]] {
            lines.append("已暂存 \((d["staged"] as? [String])?.count ?? 0)，失败 \((d["failed"] as? [String])?.count ?? 0)")
            lines.append(itemsTable(items))
            if let log = d["log"] as? [[String: Any]], !log.isEmpty {
                lines.append("")
                lines.append("日志：")
                for l in log { lines.append("  \(shortTime(l["time"] as? String)) [\(str(l, "source"))]\((l["isError"] as? Bool) == true ? " ERROR" : "") \(str(l, "text"))") }
            }
        } else if let note = d["note"] as? String {
            lines.append(note)
        }
        if let skipped = d["skipped"] as? [String], !skipped.isEmpty { lines.append("跳过（不支持预下载）：" + skipped.joined(separator: " ")) }
        return lines.joined(separator: "\n")
    }
}

func cmdStatus() throws {
    let r = try Client.call("status")
    emit(r) {
        let d = r as? [String: Any] ?? [:]
        let counts = d["counts"] as? [String: Any] ?? [:]
        let byKind = counts["byKind"] as? [String: Any] ?? [:]
        var lines: [String] = []
        lines.append("Xup \(str(d, "version")) · 上次检查 \(shortTime(d["lastChecked"] as? String))" + ((d["isChecking"] as? Bool) == true ? " · 检查中…" : ""))
        var summary = "条目 \(str(counts, "items")) · 可更新 \(str(counts, "outdated"))"
        if let st = counts["staged"] as? Int, st > 0 { summary += " · 待安装 \(st)" }
        summary += " · 可一键更新 \(str(counts, "actionable"))"
        if let pending = d["pendingAuto"] as? [String], !pending.isEmpty { summary += " · \(pending.count) 项将在空闲时自动更新" }
        lines.append(summary)
        let kinds = ["homebrew", "npm", "uv", "agent", "skill", "plugin", "app"]
        lines.append("各来源可更新：" + kinds.map { "\($0) \(str(byKind, $0).isEmpty ? "0" : str(byKind, $0))" }.joined(separator: "  "))
        if let un = d["unavailable"] as? [String], !un.isEmpty { lines.append("本机未安装：" + un.joined(separator: ", ")) }
        if let errs = d["providerErrors"] as? [String: String], !errs.isEmpty {
            for (k, v) in errs.sorted(by: { $0.key < $1.key }) { lines.append("错误 \(k)：\(v)") }
        }
        let items = (d["items"] as? [[String: Any]] ?? []).filter { ["outdated", "staged", "failed", "updating", "updated"].contains(str($0, "status")) }
        if !items.isEmpty {
            lines.append("")
            lines.append(table(["ID", "状态", "已安装", "最新", "方式"], items.map { [str($0, "id"), str($0, "status"), str($0, "installed"), str($0, "latest").isEmpty ? "—" : str($0, "latest"), policyLabel(str($0, "policy"))] }))
        }
        return lines.joined(separator: "\n")
    }
}

func cmdItems(_ a: Args) throws {
    var params: [String: Any] = [:]
    if let k = a.options["kind"] { params["kind"] = k == "brew" ? "homebrew" : k }
    let r = try Client.call("items", params)
    emit(r) {
        let items = r as? [[String: Any]] ?? []
        return items.isEmpty ? "没有条目（先 xup check --wait）" : itemsTable(items)
    }
}

func cmdInstalled(_ a: Args) throws {
    guard let kind = a[1] else { throw usageError("用法：xup installed <kind>（homebrew/npm/uv/agent/skill/plugin）") }
    let r = try Client.call("installed", ["kind": kind == "brew" ? "homebrew" : kind])
    emit(r) {
        let list = r as? [[String: Any]] ?? []
        return list.isEmpty ? "没有找到已安装的条目" :
            table(["名称", "版本", "已关注", "说明"], list.map { [str($0, "name"), str($0, "version"), ($0["tracked"] as? Bool) == true ? "✓" : "", str($0, "detail")] })
    }
}

func cmdCheck(_ a: Args) throws {
    var params: [String: Any] = ["wait": a.has("wait")]
    if let k = a.options["kind"] ?? a.options["kinds"] {
        params["kinds"] = k.split(separator: ",").map { $0 == "brew" ? "homebrew" : String($0) }
    }
    if !a.has("wait") {
        let r = try Client.call("check", params)
        emit(r) { ((r as? [String: Any])?["alreadyChecking"] as? Bool) == true ? "已有检查在进行中，稍后 xup status 查看" : "已开始检查，稍后 xup status 查看" }
        return
    }
    let r = try Client.call("check", params)
    emit(r) {
        let d = r as? [String: Any] ?? [:]
        let counts = d["counts"] as? [String: Any] ?? [:]
        var lines = ["检查完成：可更新 \(str(counts, "outdated"))，可一键更新 \(str(counts, "actionable"))"]
        if let errs = d["providerErrors"] as? [String: String], !errs.isEmpty {
            for (k, v) in errs.sorted(by: { $0.key < $1.key }) { lines.append("错误 \(k)：\(v)") }
        }
        let items = (d["items"] as? [[String: Any]] ?? []).filter { str($0, "status") == "outdated" }
        if !items.isEmpty {
            lines.append(table(["ID", "已安装", "最新", "可一键更新"], items.map { [str($0, "id"), str($0, "installed"), str($0, "latest"), ($0["actionable"] as? Bool) == true ? "是" : "否"] }))
        }
        return lines.joined(separator: "\n")
    }
}

func cmdUpdate(_ a: Args) throws {
    let ids = Array(a.positional.dropFirst(1))
    let all = a.has("all")
    guard all || !ids.isEmpty else { throw usageError("用法：xup update <id>... | --all [--wait] [--yes]") }
    if !a.has("yes") {
        let cfg = (try? ConfigFile.load()) ?? [:]
        let allowed = ((cfg["agent"] as? [String: Any])?["allowUpdates"] as? Bool) ?? false
        if !allowed {
            throw CLIError("更新会修改本机软件，需要显式确认：加 --yes，或在 config.json 设置 agent.allowUpdates=true（xup config set agent.allowUpdates true）")
        }
    }
    var params: [String: Any] = ["wait": a.has("wait")]
    if all { params["all"] = true } else { params["ids"] = ids }
    let r = try Client.call("update", params)
    emit(r) {
        let d = r as? [String: Any] ?? [:]
        var lines: [String] = []
        if let started = d["started"] as? [String] {
            lines.append(started.isEmpty ? "没有可更新的条目" : "已开始更新：" + started.joined(separator: " ") + "\n稍后 xup status / xup log 查看结果")
        } else if let items = d["items"] as? [[String: Any]] {
            lines.append("成功 \((d["succeeded"] as? [String])?.count ?? 0)，失败 \((d["failed"] as? [String])?.count ?? 0)")
            lines.append(itemsTable(items))
            if let log = d["log"] as? [[String: Any]], !log.isEmpty {
                lines.append("")
                lines.append("日志：")
                for l in log { lines.append("  \(shortTime(l["time"] as? String)) [\(str(l, "source"))]\((l["isError"] as? Bool) == true ? " ERROR" : "") \(str(l, "text"))") }
            }
        } else if let note = d["note"] as? String {
            lines.append(note)
        }
        if let skipped = d["skipped"] as? [String], !skipped.isEmpty { lines.append("跳过（不可更新）：" + skipped.joined(separator: " ")) }
        return lines.joined(separator: "\n")
    }
}

func cmdLog(_ a: Args) throws {
    let tail = Int(a.options["tail"] ?? "50") ?? 50
    let r = try Client.call("log", ["tail": tail, "errorsOnly": a.has("errors")])
    emit(r) {
        let lines = r as? [[String: Any]] ?? []
        return lines.isEmpty ? "（无日志）" :
            lines.map { "\(shortTime($0["time"] as? String)) [\(str($0, "source"))]\(($0["isError"] as? Bool) == true ? " ERROR" : "") \(str($0, "text"))" }.joined(separator: "\n")
    }
}

func cmdHistory(_ a: Args) throws {
    if a[1] == "clear" {
        guard a.has("yes") else { throw CLIError("清空历史不可撤销，需要显式确认：xup history clear --yes") }
        let r = try Client.call("history-clear")
        emit(r) { "已清空 \(str(r as? [String: Any] ?? [:], "cleared")) 条更新记录" }
        return
    }
    if let sub = a[1] { throw usageError("未知子命令 history \(sub)") }
    var params: [String: Any] = ["limit": Int(a.options["tail"] ?? "50") ?? 50, "failedOnly": a.has("failed")]
    if let k = a.options["kind"] { params["kind"] = k == "brew" ? "homebrew" : k }
    let r = try Client.call("history", params)
    emit(r) {
        let rows = r as? [[String: Any]] ?? []
        guard !rows.isEmpty else { return a.has("failed") ? "没有失败的更新记录" : "还没有更新记录" }
        let trigger = ["manual": "手动", "cli": "CLI", "scheduled": "定时", "auto": "自动"]
        return table(["时间", "名称", "版本", "结果", "触发"], rows.map { row in
            let to = str(row, "toVersion")
            let version = to.isEmpty ? str(row, "fromVersion") : "\(str(row, "fromVersion")) → \(to)"
            let ok = (row["ok"] as? Bool) == true
            let result = ok ? "成功" : "失败" + (str(row, "error").isEmpty ? "" : "：\(str(row, "error"))")
            return [shortTime(row["time"] as? String), str(row, "name"), version, result, trigger[str(row, "trigger")] ?? str(row, "trigger")]
        })
    }
}

func cmdLaunch(_ a: Args) throws {
    guard let raw = a[1] else { throw usageError("用法：xup launch <app-path>") }
    let path = try ConfigFile.normalizeAppPath(raw)
    let r = try Client.call("launch", ["path": path])
    emit(r) { "已启动 \(path)" }
}

func cmdReloadConfig() throws {
    let r = try Client.call("reload-config", [:], autoLaunch: false)
    emit(r) {
        let d = r as? [String: Any] ?? [:]
        let w = d["warnings"] as? [String] ?? []
        return "已重新加载 \(str(d, "path"))" + (w.isEmpty ? "" : "\n警告：\n  " + w.joined(separator: "\n  "))
    }
}

func cmdSkill(_ a: Args) throws {
    guard let src = Paths.resource("SKILL.md", envOverride: "XUP_SKILL_PATH") else {
        throw CLIError("未找到 SKILL.md（应位于 Xup.app/Contents/Resources/，或用 XUP_SKILL_PATH 指定）")
    }
    switch a[1] {
    case "install", nil:
        let targets = [Paths.home + "/.agents/skills/xup/SKILL.md", Paths.home + "/.claude/skills/xup/SKILL.md"]
        var results: [[String: Any]] = []
        for t in targets {
            let fm = FileManager.default
            let existed = fm.fileExists(atPath: t)
            try? fm.createDirectory(atPath: (t as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if existed { try? fm.removeItem(atPath: t) }
            do { try fm.copyItem(atPath: src, toPath: t) } catch { throw CLIError("写入 \(t) 失败：\(error.localizedDescription)") }
            results.append(["path": t, "overwritten": existed])
        }
        emit(["source": src, "installed": results]) {
            results.map { "\(($0["overwritten"] as? Bool) == true ? "已覆盖" : "已安装") \(Paths.display(str($0, "path")))" }.joined(separator: "\n")
        }
    case "show":
        out(String(decoding: FileManager.default.contents(atPath: src) ?? Data(), as: UTF8.self))
    case "path":
        out(src)
    default:
        throw usageError("未知子命令 skill \(a[1]!)")
    }
}

// MARK: - 入口

var rawArgs = Array(CommandLine.arguments.dropFirst())
if let i = rawArgs.firstIndex(of: "--json") {
    jsonMode = true
    rawArgs.remove(at: i)
}
let args = Args(rawArgs, valueFlags: ["kind", "kinds", "tail", "source", "install-when-idle"])

if args.has("help") || args.has("h") || args[0] == "help" {
    out(usage)
    exit(0)
}
if args.has("version") || args[0] == "version" {
    emit(["cli": cliVersion, "appRunning": Client.isRunning]) { "xup \(cliVersion)" }
    exit(0)
}
do {
    switch args[0] {
    case nil:
        out(usage)
        exit(ExitCode.usage.rawValue)
    case "config": try cmdConfig(args)
    case "track": try cmdTrack(args)
    case "apps": try cmdApps(args)
    case "installed": try cmdInstalled(args)
    case "status": try cmdStatus()
    case "items": try cmdItems(args)
    case "check": try cmdCheck(args)
    case "update": try cmdUpdate(args)
    case "stage": try cmdStage(args)
    case "policy": try cmdPolicy(args)
    case "log": try cmdLog(args)
    case "history": try cmdHistory(args)
    case "launch": try cmdLaunch(args)
    case "reload-config": try cmdReloadConfig()
    case "skill": try cmdSkill(args)
    default:
        throw usageError("未知命令 \(args[0]!)")
    }
} catch let e as CLIError {
    fail(e)
} catch {
    fail(CLIError(error.localizedDescription))
}
exit(0)
