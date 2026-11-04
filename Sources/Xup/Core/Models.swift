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

    var isOutdated: Bool { self == .outdated }

    var label: String {
        switch self {
        case .checking: return "检查中"
        case .outdated: return "可更新"
        case .upToDate: return "最新"
        case .unknown: return "未知"
        case .updating: return "更新中"
        case .updated: return "已更新"
        case .failed: return "失败"
        }
    }

    var message: String? {
        switch self {
        case .unknown(let s), .failed(let s): return s
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

    var isActionable: Bool { canUpdate && status.isOutdated }
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
    /// 手动配置的更新来源；nil 表示自动识别。旧数据没有该字段，解码时为 nil。
    var source: AppUpdateSource? = nil

    var name: String { (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") }

    init(path: String, restartAfterUpdate: Bool = true, source: AppUpdateSource? = nil) {
        self.path = path
        self.restartAfterUpdate = restartAfterUpdate
        self.source = source
    }

    /// 手写 config.json 时只需 path；其余字段缺省。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        restartAfterUpdate = try c.decodeIfPresent(Bool.self, forKey: .restartAfterUpdate) ?? true
        source = try c.decodeIfPresent(AppUpdateSource.self, forKey: .source)
    }
}

struct AgentSpec: Codable, Identifiable, Hashable {
    var id: String { binary }
    var name: String
    var binary: String
    var npmPackage: String?
    var versionArgs: [String]?
    var updateCommand: [String]?

    static let builtin: [AgentSpec] = [
        AgentSpec(name: "Claude Code", binary: "claude", npmPackage: "@anthropic-ai/claude-code", updateCommand: ["claude", "update"]),
        AgentSpec(name: "Codex CLI", binary: "codex", npmPackage: "@openai/codex"),
        AgentSpec(name: "Gemini CLI", binary: "gemini", npmPackage: "@google/gemini-cli"),
        AgentSpec(name: "OpenCode", binary: "opencode", npmPackage: "opencode-ai", updateCommand: ["opencode", "upgrade"]),
        AgentSpec(name: "Amp", binary: "amp", npmPackage: "@sourcegraph/amp", updateCommand: ["amp", "update"]),
        AgentSpec(name: "GitHub Copilot CLI", binary: "copilot", npmPackage: "@github/copilot"),
        AgentSpec(name: "Cursor Agent", binary: "cursor-agent", updateCommand: ["cursor-agent", "update"]),
    ]
}
