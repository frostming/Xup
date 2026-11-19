import Foundation

enum ProviderKind: String, CaseIterable, Codable, Identifiable, Hashable {
    case homebrew, npm, uv, agent, app, skill, plugin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .homebrew: return "Homebrew"
        case .npm: return "npm 全局"
        case .uv: return "uv tool"
        case .agent: return "Agents"
        case .app: return "应用"
        case .skill: return "Skills"
        case .plugin: return "插件"
        }
    }

    var symbol: String {
        switch self {
        case .homebrew: return "mug"
        case .npm: return "shippingbox"
        case .uv: return "bolt"
        case .agent: return "cpu"
        case .app: return "macwindow"
        case .skill: return "sparkles"
        case .plugin: return "puzzlepiece.extension"
        }
    }
}

enum ItemStatus: Equatable, Hashable {
    case checking
    case outdated
    case upToDate
    case unknown(String)
    case updating
    case updated
    case failed(String)
    /// §19.4 新版本已在后台下载、校验并暂存，等用户（或空闲自动安装）执行"安装并重启"。关联值为暂存的版本号。
    case staged(String)

    var isOutdated: Bool { self == .outdated }

    var isStaged: Bool {
        if case .staged = self { return true }
        return false
    }

    /// `.staged` 的版本号。
    var stagedVersion: String? {
        if case .staged(let v) = self { return v }
        return nil
    }

    var label: String {
        switch self {
        case .checking: return "检查中"
        case .outdated: return "可更新"
        case .upToDate: return "最新"
        case .unknown: return "未知"
        case .updating: return "更新中"
        case .updated: return "已更新"
        case .failed: return "失败"
        case .staged: return "待安装"
        }
    }

    var message: String? {
        switch self {
        case .unknown(let s), .failed(let s): return s
        case .staged(let v): return "已下载 \(v) · 待安装"
        default: return nil
        }
    }
}

/// §19.1 每条目的更新方式。
enum UpdatePolicy: String, Codable, CaseIterable, Hashable, Identifiable {
    /// 定时检查只标记可更新，用户手动点"更新"。
    case manual
    /// 定时检查发现新版本后，等系统空闲再自动执行。
    case auto
    /// 仅应用：发现新版本立即后台下载并暂存，用户点"安装并重启"时才替换。
    case autoDownload

    var id: String { rawValue }

    /// 菜单 / Picker 选项文字。
    var title: String {
        switch self {
        case .manual: return "手动更新"
        case .auto: return "空闲时自动更新"
        case .autoDownload: return "自动下载，手动重启"
        }
    }

    /// §19.6 策略小标签。
    var shortTag: String {
        switch self {
        case .manual: return "手动"
        case .auto: return "空闲自动"
        case .autoDownload: return "自动下载"
        }
    }

    /// Sheet 选项下的一句说明。
    var explanation: String {
        switch self {
        case .manual: return "只提示，不自动更新。"
        case .auto: return "系统空闲时自动更新。"
        case .autoDownload: return "后台先下载好，点“安装并重启”时再替换。"
        }
    }

    /// CLI 的别名：`auto-download` 也接受。
    init?(cli raw: String) {
        switch raw.lowercased() {
        case "manual": self = .manual
        case "auto": self = .auto
        case "autodownload", "auto-download", "auto_download": self = .autoDownload
        default: return nil
        }
    }
}

struct UpdateItem: Identifiable, Hashable {
    let id: String
    let kind: ProviderKind
    var name: String
    var detail: String?
    var installed: String
    var latest: String?
    var status: ItemStatus
    var canUpdate: Bool
    var hint: String?

    init(kind: ProviderKind, name: String, detail: String? = nil, installed: String, latest: String?,
         status: ItemStatus, canUpdate: Bool = true, hint: String? = nil, idSuffix: String? = nil) {
        self.id = "\(kind.rawValue):\(idSuffix ?? name)"
        self.kind = kind
        self.name = name
        self.detail = detail
        self.installed = installed
        self.latest = latest
        self.status = status
        self.canUpdate = canUpdate
        self.hint = hint
    }

    /// 可一键更新：有新版本（或已暂存待安装）且 Xup 能替用户执行。
    var isActionable: Bool { canUpdate && (status.isOutdated || status.isStaged) }

    /// §19.1 来源是否支持"自动下载，手动重启"（Xup 自己下载替换的类型：Sparkle / electron-updater / 手动配置的四类）。
    /// cask / App Store / 自更新 由 brew、mas 或应用自己一步完成，无法预下载。
    var supportsStaging: Bool {
        guard kind == .app, canUpdate, let d = detail else { return false }
        return d.hasPrefix("Sparkle") || d.hasPrefix("electron-updater") || d.hasPrefix("自定义 · ")
    }

    /// `policies` 字典的键：应用用完整 id；其它来源除了完整 id 还回退到 `<kind>:<关注名>`（homebrew 的 token 不带 formula/cask 前缀）。
    var policyKeys: [String] {
        switch kind {
        case .homebrew:
            // id 形如 homebrew:formula/node；关注名是 token。
            let suffix = String(id.dropFirst(kind.rawValue.count + 1))
            let token = suffix.split(separator: "/", maxSplits: 1).last.map(String.init) ?? suffix
            return [id, "\(kind.rawValue):\(token)"]
        default:
            return [id]
        }
    }
}

struct LogLine: Identifiable, Hashable {
    let id = UUID()
    let time: Date
    let source: String
    let text: String
    let isError: Bool
}

/// 用户手动配置的应用更新来源（优先级高于自动识别）。
enum AppUpdateSource: Codable, Hashable {
    /// GitHub Releases："owner/repo"；assetPattern 为 fnmatch 通配（如 "*arm64*.dmg"），nil 时自动挑选 macOS 安装包。
    case githubReleases(repo: String, assetPattern: String?)
    /// Tauri 更新器 JSON：{version, platforms:{"darwin-aarch64":{url,signature}}}（也兼容顶层 url / download_url）。
    case tauri(url: URL)
    /// electron-updater 的 latest-mac.yml 完整 URL。
    case electronYML(url: URL)
    /// Sparkle appcast。
    case appcast(url: URL)

    // MARK: Codable（显式 `type` 字段，便于 agent 直接读写 config.json）
    //
    // 形态：{"type":"githubReleases","repo":"owner/repo","assetPattern":"*arm64*.dmg"}
    //      {"type":"tauri"|"electronYML"|"appcast","url":"https://…"}
    // 兼容旧数据：Swift 默认编码 {"githubReleases":{"repo":…}} / {"tauri":{"url":…}}。

    enum SourceType: String, Codable, CaseIterable {
        case githubReleases, tauri, electronYML, appcast
    }

    private enum CodingKeys: String, CodingKey {
        case type, repo, assetPattern, url
        // 旧格式的 case 名
        case githubReleases, tauri, electronYML, appcast
    }

    private enum LegacyKeys: String, CodingKey { case repo, assetPattern, url }

    var type: SourceType {
        switch self {
        case .githubReleases: return .githubReleases
        case .tauri: return .tauri
        case .electronYML: return .electronYML
        case .appcast: return .appcast
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let type = try c.decodeIfPresent(SourceType.self, forKey: .type) {
            switch type {
            case .githubReleases:
                self = .githubReleases(repo: try c.decode(String.self, forKey: .repo),
                                       assetPattern: try c.decodeIfPresent(String.self, forKey: .assetPattern))
            case .tauri: self = .tauri(url: try c.decode(URL.self, forKey: .url))
            case .electronYML: self = .electronYML(url: try c.decode(URL.self, forKey: .url))
            case .appcast: self = .appcast(url: try c.decode(URL.self, forKey: .url))
            }
            return
        }
        // 旧格式
        if c.contains(.githubReleases) {
            let n = try c.nestedContainer(keyedBy: LegacyKeys.self, forKey: .githubReleases)
            self = .githubReleases(repo: try n.decode(String.self, forKey: .repo),
                                   assetPattern: try n.decodeIfPresent(String.self, forKey: .assetPattern))
        } else if c.contains(.tauri) {
            self = .tauri(url: try c.nestedContainer(keyedBy: LegacyKeys.self, forKey: .tauri).decode(URL.self, forKey: .url))
        } else if c.contains(.electronYML) {
            self = .electronYML(url: try c.nestedContainer(keyedBy: LegacyKeys.self, forKey: .electronYML).decode(URL.self, forKey: .url))
        } else if c.contains(.appcast) {
            self = .appcast(url: try c.nestedContainer(keyedBy: LegacyKeys.self, forKey: .appcast).decode(URL.self, forKey: .url))
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "source 缺少 type 字段（githubReleases/tauri/electronYML/appcast）"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .githubReleases(let repo, let pattern):
            try c.encode(repo, forKey: .repo)
            try c.encodeIfPresent(pattern, forKey: .assetPattern)
        case .tauri(let url), .electronYML(let url), .appcast(let url):
            try c.encode(url, forKey: .url)
        }
    }

    /// 列表"详情"列的文案。
    var detail: String {
        switch self {
        case .githubReleases(let repo, _): return "自定义 · GitHub \(repo)"
        case .tauri(let url): return "自定义 · Tauri \(url.host ?? "")"
        case .electronYML(let url): return "自定义 · latest-mac.yml \(url.host ?? "")"
        case .appcast(let url): return "自定义 · appcast \(url.host ?? "")"
        }
    }
}

struct ManagedApp: Codable, Identifiable, Hashable {
    var id: String { path }
    var path: String
    var restartAfterUpdate: Bool = true
    /// §19.1 子开关：策略为 autoDownload 时，暂存完成的包在系统空闲且应用未运行时自动安装。默认关。
    var installWhenIdle: Bool = false
    /// 手动配置的更新来源；nil 表示自动识别。旧数据没有该字段，解码时为 nil。
    var source: AppUpdateSource? = nil

    var name: String { (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") }
    /// `policies` 字典与 UpdateItem.id 共用的键。
    var itemID: String { "app:\(path)" }

    init(path: String, restartAfterUpdate: Bool = true, installWhenIdle: Bool = false, source: AppUpdateSource? = nil) {
        self.path = path
        self.restartAfterUpdate = restartAfterUpdate
        self.installWhenIdle = installWhenIdle
        self.source = source
    }

    /// 手写 config.json 时只需 path；其余字段缺省。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        restartAfterUpdate = try c.decodeIfPresent(Bool.self, forKey: .restartAfterUpdate) ?? true
        installWhenIdle = try c.decodeIfPresent(Bool.self, forKey: .installWhenIdle) ?? false
        source = try c.decodeIfPresent(AppUpdateSource.self, forKey: .source)
    }
}

struct AgentSpec: Codable, Identifiable, Hashable {
    var id: String { binary }
    var name: String
    var binary: String
    var npmPackage: String?
    /// GitHub 仓库（owner/repo）：没有 npmPackage 时，用它的 latest release tag 当最新版本。
    var githubRepo: String?
    var versionArgs: [String]?
    /// nil = 未填（加载时用内置规则补）；[] = 明确不要更新命令。
    var updateCommand: [String]?

    var hasUpdateCommand: Bool { !(updateCommand ?? []).isEmpty }

    static let builtin: [AgentSpec] = [
        AgentSpec(name: "Claude Code", binary: "claude", npmPackage: "@anthropic-ai/claude-code", updateCommand: ["claude", "update"]),
        AgentSpec(name: "Codex CLI", binary: "codex", npmPackage: "@openai/codex", updateCommand: ["codex", "update"]),
        AgentSpec(name: "Gemini CLI", binary: "gemini", npmPackage: "@google/gemini-cli"),
        AgentSpec(name: "OpenCode", binary: "opencode", npmPackage: "opencode-ai", updateCommand: ["opencode", "upgrade"]),
        AgentSpec(name: "Amp", binary: "amp", npmPackage: "@sourcegraph/amp", updateCommand: ["amp", "update"]),
        AgentSpec(name: "GitHub Copilot CLI", binary: "copilot", npmPackage: "@github/copilot"),
        AgentSpec(name: "Cursor Agent", binary: "cursor-agent", updateCommand: ["cursor-agent", "update"]),
        AgentSpec(name: "Antigravity CLI", binary: "agy", githubRepo: "google-antigravity/antigravity-cli", updateCommand: ["agy", "update"]),
    ]

    /// 开始记录"已见过的内置 agent"之前的内置列表。没有记录的旧 agents.json 按这批算已见。
    static let legacyBuiltinBinaries: Set<String> = ["claude", "codex", "gemini", "opencode", "amp", "copilot", "cursor-agent"]

    /// 用户还没见过、且 agents.json 里没有同名 binary 的内置 agent，加载时追加到文件末尾。
    /// seen 为 nil 表示旧文件还没有记录。已见过、后来被用户删掉的不会再出现。
    static func unseenBuiltins(in specs: [AgentSpec], seen: Set<String>?, builtin: [AgentSpec] = AgentSpec.builtin) -> [AgentSpec] {
        let seen = seen ?? legacyBuiltinBinaries
        let present = Set(specs.map(\.binary))
        return builtin.filter { !seen.contains($0.binary) && !present.contains($0.binary) }
    }

    /// agents.json 是首次启动时从内置列表复制的，之后内置规则的修正不会自动进去。
    /// 加载时对内置已有的 binary，用内置值补上用户没填（nil）的字段；用户填了的值不动，
    /// 自定义 agent 原样保留，用户删掉的内置 agent 不加回来。
    static func fillingFromBuiltin(_ specs: [AgentSpec], builtin: [AgentSpec] = AgentSpec.builtin) -> [AgentSpec] {
        specs.map { spec in
            guard let base = builtin.first(where: { $0.binary == spec.binary }) else { return spec }
            var out = spec
            out.npmPackage = spec.npmPackage ?? base.npmPackage
            out.githubRepo = spec.githubRepo ?? base.githubRepo
            out.versionArgs = spec.versionArgs ?? base.versionArgs
            out.updateCommand = spec.updateCommand ?? base.updateCommand
            return out
        }
    }
}
