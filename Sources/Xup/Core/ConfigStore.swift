import Foundation

// MARK: - 配置模型（config.json 的 Swift 形态）

/// `~/Library/Application Support/Xup/config.json` 的结构；字段说明见 Support/config.schema.json。
struct XupConfig: Codable, Equatable {
    static let currentVersion = 1
    static let schemaReference = "./config.schema.json"

    struct Check: Codable, Equatable {
        var intervalMinutes: Int = 360
        var notify: Bool = true
        var autoUpdate: Bool = false
    }

    struct Homebrew: Codable, Equatable {
        var greedy: Bool = false
    }

    struct UI: Codable, Equatable {
        var showUpToDate: Bool = false
        var launchAtLogin: Bool = false
    }

    struct Electron: Codable, Equatable {
        var deltaDownload: Bool = true
        var keepVersionsPerApp: Int = 1
    }

    struct Agent: Codable, Equatable {
        var allowUpdates: Bool = false
    }

    /// 关注列表（`.app` 不在此处，见 `apps`）。文件里每个来源是排好序的字符串数组。
    struct Tracked: Codable, Equatable {
        var homebrew: [String] = []
        var npm: [String] = []
        var uv: [String] = []
        var agent: [String] = []
        var skill: [String] = []
        var plugin: [String] = []

        subscript(kind: ProviderKind) -> Set<String> {
            get {
                switch kind {
                case .homebrew: return Set(homebrew)
                case .npm: return Set(npm)
                case .uv: return Set(uv)
                case .agent: return Set(agent)
                case .skill: return Set(skill)
                case .plugin: return Set(plugin)
                case .app: return []
                }
            }
            set {
                let list = newValue.sorted()
                switch kind {
                case .homebrew: homebrew = list
                case .npm: npm = list
                case .uv: uv = list
                case .agent: agent = list
                case .skill: skill = list
                case .plugin: plugin = list
                case .app: break
                }
            }
        }

        var asDictionary: [ProviderKind: Set<String>] {
            var d: [ProviderKind: Set<String>] = [:]
            for kind in ProviderKind.allCases where kind != .app {
                let s = self[kind]
                if !s.isEmpty { d[kind] = s }
            }
            return d
        }
    }

    var schema: String? = schemaReference
    var version: Int = currentVersion
    var check = Check()
    var homebrew = Homebrew()
    var ui = UI()
    var electron = Electron()
    var agent = Agent()
    var tracked = Tracked()
    var apps: [ManagedApp] = []

    private enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case version, check, homebrew, ui, electron, agent, tracked, apps
    }

    init() {}

    /// 缺省字段一律取默认值，方便手写只含部分字段的 config.json。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(String.self, forKey: .schema)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        check = try c.decodeIfPresent(Check.self, forKey: .check) ?? Check()
        homebrew = try c.decodeIfPresent(Homebrew.self, forKey: .homebrew) ?? Homebrew()
        ui = try c.decodeIfPresent(UI.self, forKey: .ui) ?? UI()
        electron = try c.decodeIfPresent(Electron.self, forKey: .electron) ?? Electron()
        agent = try c.decodeIfPresent(Agent.self, forKey: .agent) ?? Agent()
        tracked = try c.decodeIfPresent(Tracked.self, forKey: .tracked) ?? Tracked()
        apps = try c.decodeIfPresent([ManagedApp].self, forKey: .apps) ?? []
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    func encoded() throws -> Data {
        var copy = self
        copy.schema = Self.schemaReference
        copy.version = Self.currentVersion
        return try Self.encoder().encode(copy)
    }
}

extension XupConfig.Check {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 360
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? true
        autoUpdate = try c.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? false
    }
}

extension XupConfig.Homebrew {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        greedy = try c.decodeIfPresent(Bool.self, forKey: .greedy) ?? false
    }
}

extension XupConfig.UI {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showUpToDate = try c.decodeIfPresent(Bool.self, forKey: .showUpToDate) ?? false
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
    }
}

extension XupConfig.Electron {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deltaDownload = try c.decodeIfPresent(Bool.self, forKey: .deltaDownload) ?? true
        keepVersionsPerApp = try c.decodeIfPresent(Int.self, forKey: .keepVersionsPerApp) ?? 1
    }
}

extension XupConfig.Agent {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowUpdates = try c.decodeIfPresent(Bool.self, forKey: .allowUpdates) ?? false
    }
}

extension XupConfig.Tracked {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        homebrew = try c.decodeIfPresent([String].self, forKey: .homebrew) ?? []
        npm = try c.decodeIfPresent([String].self, forKey: .npm) ?? []
        uv = try c.decodeIfPresent([String].self, forKey: .uv) ?? []
        agent = try c.decodeIfPresent([String].self, forKey: .agent) ?? []
        skill = try c.decodeIfPresent([String].self, forKey: .skill) ?? []
        plugin = try c.decodeIfPresent([String].self, forKey: .plugin) ?? []
    }
}

// MARK: - 校验

enum ConfigError: LocalizedError {
    case notJSON(String)
    case invalid([String])
    case io(String)

    var errorDescription: String? {
        switch self {
        case .notJSON(let s): return "config.json 不是合法 JSON：\(s)"
        case .invalid(let errs): return "config.json 校验失败：" + errs.joined(separator: "；")
        case .io(let s): return s
        }
    }
}

/// 覆盖 config.schema.json 用到的 JSON Schema 子集：type / const / enum / properties / required /
/// additionalProperties / items / minimum / pattern / oneOf / $ref(#/$defs/x)。
/// 未知字段（additionalProperties:false）作为 **警告** 返回，其余不符作为 **错误**。
struct ConfigSchemaValidator {
    let schema: [String: Any]

    init?(schemaData: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: schemaData) as? [String: Any] else { return nil }
        schema = obj
    }

    struct Report {
        var errors: [String] = []
        var warnings: [String] = []
    }

    func validate(_ value: Any) -> Report {
        var r = Report()
        walk(value, schema, path: "", report: &r)
        return r
    }

    private func resolve(_ s: [String: Any]) -> [String: Any] {
        guard let ref = s["$ref"] as? String, ref.hasPrefix("#/") else { return s }
        var cur: Any = schema
        for comp in ref.dropFirst(2).split(separator: "/") {
            guard let d = cur as? [String: Any], let next = d[String(comp)] else { return s }
            cur = next
        }
        return cur as? [String: Any] ?? s
    }

    private static func typeName(_ v: Any) -> String {
        if v is NSNull { return "null" }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return "boolean" }
            return n.doubleValue == n.doubleValue.rounded() && !(n.stringValue.contains(".")) ? "integer" : "number"
        }
        if v is String { return "string" }
        if v is [Any] { return "array" }
        if v is [String: Any] { return "object" }
        return "unknown"
    }

    private static func matches(type want: String, actual: String) -> Bool {
        want == actual || (want == "number" && actual == "integer")
    }

    private func walk(_ value: Any, _ raw: [String: Any], path: String, report: inout Report) {
        let s = resolve(raw)
        let here = path.isEmpty ? "(root)" : path
        let actual = Self.typeName(value)

        if let t = s["type"] {
            let wants = (t as? [String]) ?? [(t as? String) ?? ""]
            if !wants.contains(where: { Self.matches(type: $0, actual: actual) }) {
                report.errors.append("\(here) 应为 \(wants.joined(separator: "|"))，实际为 \(actual)")
                return
            }
        }
        if let c = s["const"] {
            if !Self.equal(value, c) { report.errors.append("\(here) 必须等于 \(Self.describe(c))") }
        }
        if let e = s["enum"] as? [Any] {
            if !e.contains(where: { Self.equal(value, $0) }) {
                report.errors.append("\(here) 必须是 \(e.map(Self.describe).joined(separator: " / ")) 之一")
            }
        }
        if let options = s["oneOf"] as? [[String: Any]] {
            // 选择第一个无错误的分支；都失败时给出最接近的（错误最少的）分支信息。
            var best: Report?
            for opt in options {
                var sub = Report()
                walk(value, opt, path: path, report: &sub)
                if sub.errors.isEmpty {
                    report.warnings.append(contentsOf: sub.warnings)
                    best = nil
                    break
                }
                if best == nil || sub.errors.count < best!.errors.count { best = sub }
            }
            if let best {
                report.errors.append(contentsOf: best.errors)
            }
        }
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            if let min = (s["minimum"] as? NSNumber)?.doubleValue, n.doubleValue < min {
                report.errors.append("\(here) 不能小于 \(Int(min))")
            }
        }
        if let str = value as? String, let pattern = s["pattern"] as? String,
           let re = try? NSRegularExpression(pattern: pattern) {
            if re.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)) == nil {
                report.errors.append("\(here) 不符合格式 \(pattern)")
            }
        }
        if let dict = value as? [String: Any] {
            let props = s["properties"] as? [String: Any] ?? [:]
            for req in s["required"] as? [String] ?? [] where dict[req] == nil {
                report.errors.append("\(here) 缺少必填字段 \(req)")
            }
            for (k, v) in dict {
                let child = path.isEmpty ? k : "\(path).\(k)"
                if let ps = props[k] as? [String: Any] {
                    walk(v, ps, path: child, report: &report)
                } else if let ap = s["additionalProperties"] as? Bool, ap == false {
                    report.warnings.append("未知字段 \(child)（已忽略）")
                }
            }
        }
        if let arr = value as? [Any], let items = s["items"] as? [String: Any] {
            for (i, v) in arr.enumerated() {
                walk(v, items, path: "\(path)[\(i)]", report: &report)
            }
        }
    }

    private static func equal(_ a: Any, _ b: Any) -> Bool {
        if let x = a as? NSNumber, let y = b as? NSNumber { return x == y }
        if let x = a as? String, let y = b as? String { return x == y }
        if a is NSNull, b is NSNull { return true }
        return false
    }

    private static func describe(_ v: Any) -> String {
        if let s = v as? String { return "\"\(s)\"" }
        return "\(v)"
    }
}

// MARK: - ConfigStore

/// config.json 的加载/保存/校验/监听。所有 API 在主线程使用；文件监听回调自行切回主线程。
@MainActor
final class ConfigStore {
    enum Source { case initial, migrated, local, external, reload }

    nonisolated static let fileName = "config.json"
    nonisolated static let schemaFileName = "config.schema.json"

    let url: URL
    var backupURL: URL { url.appendingPathExtension("bak") }
    var schemaURL: URL { url.deletingLastPathComponent().appendingPathComponent(Self.schemaFileName) }

    private(set) var config: XupConfig
    /// 最近一次加载失败的原因（供设置界面显示）；成功后清空。
    private(set) var lastError: String?
    private(set) var lastWarnings: [String] = []

    /// 配置被外部修改并成功热加载 / `reload()` 成功后调用。
    var onChange: ((XupConfig, Source) -> Void)?
    /// electron 相关设置：由 AppModel 接到 DeltaDownloadPolicy（见 AppModel.init）。
    var onElectronSettings: ((_ deltaDownload: Bool, _ keepVersionsPerApp: Int) -> Void)? {
        didSet { onElectronSettings?(config.electron.deltaDownload, config.electron.keepVersionsPerApp) }
    }
    /// 日志出口；接上之前的消息先缓存在 `pendingLogs`。
    var log: ((_ text: String, _ isError: Bool) -> Void)? {
        didSet {
            guard let log else { return }
            pendingLogs.forEach { log($0.0, $0.1) }
            pendingLogs.removeAll()
        }
    }
    private var pendingLogs: [(String, Bool)] = []

    private var lastWritten: Data?
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?
    private let watchQueue = DispatchQueue(label: "dev.fming.xup.config-watch")

    nonisolated static var defaultURL: URL { AppSettings.supportDirectory.appendingPathComponent(fileName) }

    /// 加载 config.json；不存在时从 UserDefaults 迁移并写出文件。
    init(url: URL = ConfigStore.defaultURL, migrateFrom defaults: UserDefaults? = .standard, watch: Bool = true) {
        self.url = url
        self.config = XupConfig()
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: url) {
            do {
                let (cfg, warnings) = try Self.parse(data)
                config = cfg
                lastWarnings = warnings
                lastWritten = data
                warnings.forEach { emit("配置警告：\($0)", false) }
                emit("已加载 \(displayPath)", false)
            } catch {
                lastError = error.localizedDescription
                emit("\(error.localizedDescription)；已使用默认配置（文件未改动）", true)
            }
        } else {
            var cfg = XupConfig()
            var migrated = false
            if let defaults {
                migrated = Self.migrate(from: defaults, into: &cfg)
            }
            config = cfg
            do {
                try write(cfg)
                emit(migrated ? "已从 UserDefaults 迁移设置到 \(displayPath)" : "已创建默认配置 \(displayPath)", false)
            } catch {
                emit("写入 \(displayPath) 失败：\(error.localizedDescription)", true)
            }
        }
        exportSchemaIfNeeded()
        if watch { startWatching() }
    }

    var displayPath: String { url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    private func emit(_ text: String, _ isError: Bool) {
        if let log { log(text, isError) } else { pendingLogs.append((text, isError)) }
    }

    // MARK: 解析

    /// 解析并校验；类型错误抛 `ConfigError.invalid`，未知字段作为警告返回。
    nonisolated static func parse(_ data: Data) throws -> (XupConfig, warnings: [String]) {
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ConfigError.notJSON(error.localizedDescription)
        }
        var warnings: [String] = []
        if let validator = ConfigSchemaValidator(schemaData: Data(ConfigSchema.json.utf8)) {
            let report = validator.validate(obj)
            if !report.errors.isEmpty { throw ConfigError.invalid(report.errors) }
            warnings = report.warnings
        }
        do {
            let cfg = try JSONDecoder().decode(XupConfig.self, from: data)
            if cfg.version > XupConfig.currentVersion {
                warnings.append("version=\(cfg.version) 高于本版本支持的 \(XupConfig.currentVersion)")
            }
            return (cfg, warnings)
        } catch {
            throw ConfigError.invalid([error.localizedDescription])
        }
    }

    // MARK: 迁移

    private enum LegacyKey {
        static let checkIntervalMinutes = "checkIntervalMinutes"
        static let brewGreedy = "brewGreedy"
        static let notifyOnUpdates = "notifyOnUpdates"
        static let autoUpdate = "autoUpdate"
        static let showUpToDate = "showUpToDate"
        static let launchAtLogin = "launchAtLogin"
        static let managedApps = "managedApps"
        static let tracked = "tracked"
    }

    /// 把 v1.0 存在 UserDefaults 的设置搬进 config；返回是否找到了任何旧数据。
    @discardableResult
    nonisolated static func migrate(from d: UserDefaults, into cfg: inout XupConfig) -> Bool {
        var found = false
        if d.object(forKey: LegacyKey.checkIntervalMinutes) != nil { cfg.check.intervalMinutes = d.integer(forKey: LegacyKey.checkIntervalMinutes); found = true }
        if d.object(forKey: LegacyKey.notifyOnUpdates) != nil { cfg.check.notify = d.bool(forKey: LegacyKey.notifyOnUpdates); found = true }
        if d.object(forKey: LegacyKey.autoUpdate) != nil { cfg.check.autoUpdate = d.bool(forKey: LegacyKey.autoUpdate); found = true }
        if d.object(forKey: LegacyKey.brewGreedy) != nil { cfg.homebrew.greedy = d.bool(forKey: LegacyKey.brewGreedy); found = true }
        if d.object(forKey: LegacyKey.showUpToDate) != nil { cfg.ui.showUpToDate = d.bool(forKey: LegacyKey.showUpToDate); found = true }
        if d.object(forKey: LegacyKey.launchAtLogin) != nil { cfg.ui.launchAtLogin = d.bool(forKey: LegacyKey.launchAtLogin); found = true }
        if let data = d.data(forKey: LegacyKey.managedApps),
           let apps = try? JSONDecoder().decode([ManagedApp].self, from: data) {
            cfg.apps = apps
            found = true
        }
        if let data = d.data(forKey: LegacyKey.tracked),
           let raw = try? JSONDecoder().decode([String: [String]].self, from: data) {
            for (k, v) in raw {
                if let kind = ProviderKind(rawValue: k) { cfg.tracked[kind] = Set(v) }
            }
            found = true
        }
        return found
    }

    // MARK: 保存

    /// 修改并立即写盘（原子写，写前备份 config.json.bak）。
    func update(_ mutate: (inout XupConfig) -> Void) {
        var next = config
        mutate(&next)
        guard next != config else { return }
        config = next
        do {
            try write(next)
        } catch {
            emit("写入 \(displayPath) 失败：\(error.localizedDescription)", true)
        }
        onElectronSettings?(next.electron.deltaDownload, next.electron.keepVersionsPerApp)
    }

    private func write(_ cfg: XupConfig) throws {
        let data = try cfg.encoded()
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: url, to: backupURL)
        }
        try data.write(to: url, options: .atomic)
        lastWritten = data
        lastError = nil
    }

    /// 把内置 schema 导出到 config.json 同目录（内容有变化时覆盖）。
    func exportSchemaIfNeeded() {
        let data = Data(ConfigSchema.json.utf8)
        if let existing = try? Data(contentsOf: schemaURL), existing == data { return }
        do {
            try data.write(to: schemaURL, options: .atomic)
        } catch {
            emit("导出 \(Self.schemaFileName) 失败：\(error.localizedDescription)", true)
        }
    }

    // MARK: 重新加载

    /// 从磁盘重新读取；成功时发布 `onChange`。返回错误描述（成功为 nil）。
    @discardableResult
    func reload(source: Source = .reload) -> String? {
        guard let data = try? Data(contentsOf: url) else {
            lastError = "找不到 \(displayPath)"
            emit(lastError!, true)
            return lastError
        }
        do {
            let (cfg, warnings) = try Self.parse(data)
            lastWritten = data
            lastWarnings = warnings
            lastError = nil
            warnings.forEach { emit("配置警告：\($0)", false) }
            if cfg != config {
                config = cfg
                emit(source == .external ? "检测到 \(displayPath) 被修改，已热加载" : "已重新加载 \(displayPath)", false)
                onElectronSettings?(cfg.electron.deltaDownload, cfg.electron.keepVersionsPerApp)
                onChange?(cfg, source)
            } else if source == .reload {
                emit("已重新加载 \(displayPath)（无变化）", false)
            }
            return nil
        } catch {
            lastError = error.localizedDescription
            emit("\(error.localizedDescription)；保留当前配置", true)
            return lastError
        }
    }

    // MARK: 文件监听

    private func startWatching() {
        let dirPath = url.deletingLastPathComponent().path
        let fd = open(dirPath, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: watchQueue)
            src.setEventHandler { [weak self] in self?.scheduleReload() }
            src.setCancelHandler { close(fd) }
            src.resume()
            dirSource = src
        }
        watchFile()
    }

    /// 单独监听文件本身，捕获原地写入；文件被替换后需要重新打开。
    private func watchFile() {
        fileSource?.cancel()
        fileSource = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete, .attrib], queue: watchQueue)
        src.setEventHandler { [weak self] in self?.scheduleReload() }
        src.setCancelHandler { close(fd) }
        src.resume()
        fileSource = src
    }

    nonisolated private func scheduleReload() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.watchFile()
                guard let data = try? Data(contentsOf: self.url) else { return }
                if data == self.lastWritten { return }  // 自己写的
                self.reload(source: .external)
            }
            self.debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500), execute: work)
        }
    }

    /// 轻量读取：只看 tracked 是否全空（UIState 启动时用，不需要完整 store）。
    nonisolated static func quickTrackedIsEmpty(url: URL = ConfigStore.defaultURL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
        let tracked = obj["tracked"] as? [String: Any] ?? [:]
        return tracked.values.allSatisfy { ($0 as? [Any])?.isEmpty ?? true }
    }
}

// MARK: - 内置 schema（与 Support/config.schema.json 保持一致，由 ConfigTests 校验）

enum ConfigSchema {
    static let json = #"""
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/fming/Xup/blob/main/Support/config.schema.json",
  "title": "Xup config",
  "description": "Xup 的全部配置（单一事实来源）。文件位于 ~/Library/Application Support/Xup/config.json；App 运行时会监听并热加载（约 0.5 秒）。Xup settings: the single source of truth, hot-reloaded by the running app.",
  "type": "object",
  "additionalProperties": false,
  "required": ["version"],
  "properties": {
    "$schema": {
      "type": "string",
      "description": "指向本 schema 的相对路径（App 自动写入）。Path to this schema, written by the app."
    },
    "version": {
      "type": "integer",
      "const": 1,
      "description": "配置格式版本，目前固定为 1。Config format version (currently 1)."
    },
    "check": {
      "type": "object",
      "additionalProperties": false,
      "description": "定时检查相关设置。Scheduled check settings.",
      "properties": {
        "intervalMinutes": {
          "type": "integer",
          "minimum": 0,
          "default": 360,
          "description": "定时检查间隔（分钟），0 表示关闭定时检查；界面最小 5。Minutes between scheduled checks; 0 disables."
        },
        "notify": {
          "type": "boolean",
          "default": true,
          "description": "发现更新时发送系统通知。Post a notification when updates are found."
        },
        "autoUpdate": {
          "type": "boolean",
          "default": false,
          "description": "定时检查发现更新后自动执行更新（可能退出正在使用的应用）。Automatically install updates found by scheduled checks."
        }
      }
    },
    "homebrew": {
      "type": "object",
      "additionalProperties": false,
      "description": "Homebrew 来源设置。Homebrew provider settings.",
      "properties": {
        "greedy": {
          "type": "boolean",
          "default": false,
          "description": "brew outdated/upgrade 加 --greedy，把自带更新机制的 cask 也列为可更新。Pass --greedy to include auto-updating casks."
        }
      }
    },
    "ui": {
      "type": "object",
      "additionalProperties": false,
      "description": "界面与系统集成。UI and system integration.",
      "properties": {
        "showUpToDate": {
          "type": "boolean",
          "default": false,
          "description": "列表中显示已是最新的条目。Show up-to-date items in lists."
        },
        "launchAtLogin": {
          "type": "boolean",
          "default": false,
          "description": "登录时启动 Xup（仅打包为 .app 时生效）。Launch Xup at login (app bundle only)."
        }
      }
    },
    "electron": {
      "type": "object",
      "additionalProperties": false,
      "description": "electron-updater 应用的下载策略。Download policy for electron-updater apps.",
      "properties": {
        "deltaDownload": {
          "type": "boolean",
          "default": true,
          "description": "使用 blockmap 增量下载（只下载变化的块）。Use blockmap delta downloads."
        },
        "keepVersionsPerApp": {
          "type": "integer",
          "minimum": 0,
          "default": 1,
          "description": "每个应用在缓存中保留的旧版本安装包数量（供增量下载复用）。Old installer versions kept per app for delta reuse."
        }
      }
    },
    "agent": {
      "type": "object",
      "additionalProperties": false,
      "description": "agent / CLI 相关的安全边界。Safety switches for agents using the xup CLI.",
      "properties": {
        "allowUpdates": {
          "type": "boolean",
          "default": false,
          "description": "为 true 时 `xup update` 不再要求 --yes。When true, `xup update` does not require --yes."
        }
      }
    },
    "tracked": {
      "type": "object",
      "additionalProperties": false,
      "description": "关注列表：每个来源只检查/更新这里列出的条目（应用见 apps）。Watch lists per provider; only listed items are checked/updated.",
      "properties": {
        "homebrew": {
          "type": "array",
          "items": { "type": "string" },
          "description": "Homebrew formula / cask 的 token，如 \"node\"、\"iina\"。Homebrew tokens."
        },
        "npm": {
          "type": "array",
          "items": { "type": "string" },
          "description": "npm 全局包名，如 \"typescript\"、\"@openai/codex\"。Global npm package names."
        },
        "uv": {
          "type": "array",
          "items": { "type": "string" },
          "description": "uv tool 名，如 \"nox\"。uv tool names."
        },
        "agent": {
          "type": "array",
          "items": { "type": "string" },
          "description": "agent 可执行名（agents.json 中的 binary），如 \"claude\"、\"codex\"。Agent binaries."
        },
        "skill": {
          "type": "array",
          "items": { "type": "string" },
          "description": "Vercel skills CLI 安装的 skill 名。Skill names from ~/.agents/.skill-lock.json."
        },
        "plugin": {
          "type": "array",
          "items": { "type": "string" },
          "description": "插件键：\"claude/<name@marketplace>\" 或 \"codex/<name@marketplace>\"。Plugin keys."
        }
      }
    },
    "apps": {
      "type": "array",
      "description": "受管应用列表。Managed .app bundles.",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["path"],
        "properties": {
          "path": {
            "type": "string",
            "pattern": "\\.app$",
            "description": "应用包的绝对路径，如 /Applications/IINA.app。Absolute path to the .app bundle."
          },
          "restartAfterUpdate": {
            "type": "boolean",
            "default": true,
            "description": "更新完成后重新启动该应用。Relaunch the app after updating."
          },
          "source": {
            "description": "手动指定的更新来源；null 或省略表示自动识别（Homebrew cask > Sparkle > electron-updater > App Store）。Manual update source; null = auto-detect.",
            "oneOf": [
              { "type": "null" },
              { "$ref": "#/$defs/githubReleases" },
              { "$ref": "#/$defs/tauri" },
              { "$ref": "#/$defs/electronYML" },
              { "$ref": "#/$defs/appcast" }
            ]
          }
        }
      }
    }
  },
  "$defs": {
    "githubReleases": {
      "type": "object",
      "additionalProperties": false,
      "required": ["type", "repo"],
      "description": "GitHub Releases 最新 Release。Latest GitHub release.",
      "properties": {
        "type": { "const": "githubReleases" },
        "repo": {
          "type": "string",
          "pattern": "^[\\w.-]+/[\\w.-]+$",
          "description": "owner/repo"
        },
        "assetPattern": {
          "type": ["string", "null"],
          "description": "资源文件名通配（fnmatch），如 \"*arm64*.dmg\"；省略时自动选择匹配本机架构的 .dmg/.zip。Asset name glob."
        }
      }
    },
    "tauri": {
      "type": "object",
      "additionalProperties": false,
      "required": ["type", "url"],
      "description": "Tauri 更新器 JSON。Tauri updater JSON endpoint.",
      "properties": {
        "type": { "const": "tauri" },
        "url": { "type": "string", "format": "uri", "description": "完整 JSON 地址。Full URL of the updater JSON." }
      }
    },
    "electronYML": {
      "type": "object",
      "additionalProperties": false,
      "required": ["type", "url"],
      "description": "electron-updater 的 latest-mac.yml。electron-updater feed.",
      "properties": {
        "type": { "const": "electronYML" },
        "url": { "type": "string", "format": "uri", "description": "latest-mac.yml 的完整 URL。Full URL of latest-mac.yml." }
      }
    },
    "appcast": {
      "type": "object",
      "additionalProperties": false,
      "required": ["type", "url"],
      "description": "Sparkle appcast。Sparkle appcast feed.",
      "properties": {
        "type": { "const": "appcast" },
        "url": { "type": "string", "format": "uri", "description": "appcast.xml 的完整 URL。Full URL of the appcast." }
      }
    }
  }
}
"""#
}
