import Foundation

/// 非 brew / 非 App Store 的应用更新来源解析：给定来源 → 最新版本 + 下载地址。
/// 只做网络检测，不下载安装包；供 AppsProvider（检查/更新）与配置 Sheet 的"测试"按钮复用。
enum AppSources {
    struct Resolved: Sendable {
        var latest: String
        var downloadURL: URL?
        /// downloadURL 为 nil 时给用户的提示。
        var hint: String?
        /// 来源给出的安装包校验值/大小（目前只有 electron-updater 的 latest-mac.yml 提供），供增量下载校验。
        var sha512: String?
        var size: Int?
    }

    enum SourceError: LocalizedError {
        case emptyResponse(String)
        case malformed(String)
        case noVersion(String)

        var errorDescription: String? {
            switch self {
            case .emptyResponse(let what): return "\(what) 返回空内容"
            case .malformed(let what): return "\(what) 格式无法解析"
            case .noVersion(let what): return "\(what) 中没有版本号"
            }
        }
    }

    static let noMacAssetHint = "未找到可下载的 macOS 安装包"

    static func resolve(_ source: AppUpdateSource) async throws -> Resolved {
        switch source {
        case .githubReleases(let repo, let pattern): return try await resolveGitHub(repo: repo, assetPattern: pattern)
        case .tauri(let url): return try await resolveTauri(url)
        case .electronYML(let url): return try await resolveElectron(url)
        case .appcast(let url): return try await resolveAppcast(url)
        }
    }

    // MARK: - HTTP

    private static func fetch(_ url: URL, accept: String, headers: [String: String] = [:]) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Xup/1.0 (macOS update helper)", forHTTPHeaderField: "User-Agent")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw NSError(domain: "Xup", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) \(url.host ?? "")"])
        }
        return data
    }

    /// 相对文件名（可能含空格）拼到 base 所在目录。
    static func fileURL(_ name: String, relativeTo base: URL) -> URL? {
        if let u = URL(string: name, relativeTo: base) { return u.absoluteURL }
        guard let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: enc, relativeTo: base)?.absoluteURL
    }

    private static func stripV(_ v: String) -> String {
        var s = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    /// 去掉 YAML 标量两侧的引号。
    private static func unquote(_ v: String) -> String {
        let s = v.trimmingCharacters(in: .whitespaces)
        if s.count >= 2, let f = s.first, let l = s.last, f == l, f == "\"" || f == "'" {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    // MARK: - electron-updater

    /// 读取 Contents/Resources/app-update.yml，得到 latest-mac.yml（或 <channel>-mac.yml）的 URL；非 electron-updater 应用返回 nil。
    static func electronFeedURL(appPath: String) -> URL? {
        let yml = (appPath as NSString).appendingPathComponent("Contents/Resources/app-update.yml")
        guard let text = try? String(contentsOfFile: yml, encoding: .utf8) else { return nil }
        return electronFeedURL(appUpdateYML: text)
    }

    /// app-update.yml 的顶层键值（provider / url / channel / updaterCacheDirName …）。
    static func parseAppUpdateYML(_ text: String) -> [String: String] {
        var kv: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = String(raw).replacingOccurrences(of: "\r", with: "")
            guard !line.hasPrefix(" "), !line.hasPrefix("#"), let c = line.firstIndex(of: ":") else { continue }
            let key = line[..<c].trimmingCharacters(in: .whitespaces)
            let val = unquote(String(line[line.index(after: c)...]))
            if !val.isEmpty { kv[key] = val }
        }
        return kv
    }

    /// app-update.yml 里的 `updaterCacheDirName`（应用自身 electron-updater 的缓存目录名，位于 ~/Library/Caches 下）。
    static func electronUpdaterCacheDirName(appPath: String) -> String? {
        let yml = (appPath as NSString).appendingPathComponent("Contents/Resources/app-update.yml")
        guard let text = try? String(contentsOfFile: yml, encoding: .utf8) else { return nil }
        return parseAppUpdateYML(text)["updaterCacheDirName"]
    }

    static func electronFeedURL(appUpdateYML text: String) -> URL? {
        let kv = parseAppUpdateYML(text)
        let channel = kv["channel"].map { $0.isEmpty ? "latest" : $0 } ?? "latest"
        let file = "\(channel)-mac.yml"
        switch kv["provider"]?.lowercased() {
        case "generic":
            guard let base = kv["url"] else { return nil }
            let joined = base.hasSuffix("/") ? base + file : base + "/" + file
            return URL(string: joined)
        case "github":
            guard let owner = kv["owner"], let repo = kv["repo"] else { return nil }
            let host = kv["host"] ?? "github.com"
            return URL(string: "https://\(host)/\(owner)/\(repo)/releases/latest/download/\(file)")
        default:
            return nil
        }
    }

    struct ElectronFile: Equatable, Sendable {
        var url: String
        var sha512: String?
        var size: Int?
    }

    struct ElectronRelease: Sendable {
        var version: String
        var files: [ElectronFile]
        var path: String?
    }

    /// 解析 electron-builder 生成的 latest-mac.yml（只认 version / files / path 三个字段）。
    static func parseLatestMacYML(_ text: String) throws -> ElectronRelease {
        var version: String?
        var path: String?
        var files: [ElectronFile] = []
        var inFiles = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "\r", with: "")
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") && !line.hasPrefix("-") {
                // 顶层键
                guard let c = line.firstIndex(of: ":") else { continue }
                let key = line[..<c].trimmingCharacters(in: .whitespaces)
                let val = unquote(String(line[line.index(after: c)...]))
                inFiles = (key == "files")
                switch key {
                case "version": version = val
                case "path": path = val
                default: break
                }
                continue
            }
            guard inFiles else { continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- ") {
                let body = String(t.dropFirst(2))
                guard let c = body.firstIndex(of: ":") else { continue }
                let key = body[..<c].trimmingCharacters(in: .whitespaces)
                let val = unquote(String(body[body.index(after: c)...]))
                guard key == "url" else { continue }
                files.append(ElectronFile(url: val))
            } else if !files.isEmpty, let c = t.firstIndex(of: ":") {
                let key = t[..<c].trimmingCharacters(in: .whitespaces)
                let val = unquote(String(t[t.index(after: c)...]))
                switch key {
                case "sha512": files[files.count - 1].sha512 = val
                case "size": files[files.count - 1].size = Int(val)
                case "url": files[files.count - 1].url = val
                default: break
                }
            }
        }
        guard let v = version, !v.isEmpty else { throw SourceError.noVersion("latest-mac.yml") }
        return ElectronRelease(version: v, files: files, path: path)
    }

    /// 选 arm64 的 zip/dmg：文件名含 arm64 优先，其次不含 x64/intel 的；同级 zip 优先于 dmg。
    static func pickElectronFile(_ release: ElectronRelease) -> String? {
        var names = release.files.map(\.url)
        if names.isEmpty, let p = release.path { names = [p] }
        let candidates = names.filter { n in
            let l = n.lowercased()
            return l.hasSuffix(".zip") || l.hasSuffix(".dmg")
        }
        func rank(_ n: String) -> Int {
            let l = n.lowercased()
            let ext = l.hasSuffix(".zip") ? 0 : 1
            if l.contains("arm64") || l.contains("aarch64") { return 0 + ext }
            if l.contains("universal") { return 10 + ext }
            if l.contains("x64") || l.contains("x86") || l.contains("intel") || l.contains("amd64") { return 30 + ext }
            return 20 + ext
        }
        return candidates.min { rank($0) < rank($1) }
    }

    static func resolveElectron(_ ymlURL: URL) async throws -> Resolved {
        let data = try await fetch(ymlURL, accept: "text/yaml, text/plain, */*")
        guard !data.isEmpty else { throw SourceError.emptyResponse("latest-mac.yml") }
        let release = try parseLatestMacYML(String(decoding: data, as: UTF8.self))
        let picked = pickElectronFile(release)
        let file = picked.flatMap { fileURL($0, relativeTo: ymlURL) }
        let meta = picked.flatMap { name in release.files.first { $0.url == name } }
        return Resolved(latest: stripV(release.version), downloadURL: file, hint: file == nil ? noMacAssetHint : nil,
                        sha512: meta?.sha512, size: meta?.size)
    }

    // MARK: - GitHub Releases

    private actor TokenCache {
        private var cached: String??
        func token() async -> String? {
            if let c = cached { return c }
            var t: String? = nil
            if let env = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !env.isEmpty { t = env }
            else if Shell.which("gh") != nil, let r = try? await Shell.run(["gh", "auth", "token"], timeout: 10), r.ok {
                let s = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { t = s }
            }
            cached = .some(t)
            return t
        }
    }
    private static let tokenCache = TokenCache()

    /// GITHUB_TOKEN 或 `gh auth token`；都没有时返回 nil（匿名访问，限速 60 次/小时）。
    static func githubToken() async -> String? { await tokenCache.token() }

    /// fnmatch 通配匹配（忽略大小写）。
    static func fnmatch(_ pattern: String, _ name: String) -> Bool {
        Darwin.fnmatch(pattern, name, FNM_CASEFOLD) == 0
    }

    /// 从资产名里挑 macOS 安装包：有 pattern 用通配；否则 arm64 → aarch64 → universal → mac/darwin/macos/osx
    /// → 无任何平台/架构标记的 dmg/zip（多半是 universal 包）；只考虑 dmg/zip/tar.gz/tgz，排除 linux/windows 与明确的 Intel 包。
    static func pickGitHubAsset(names: [String], pattern: String?) -> String? {
        if let pattern, !pattern.isEmpty {
            return names.first { fnmatch(pattern, $0) }
        }
        let candidates = names.filter { n in
            let l = n.lowercased()
            let okExt = l.hasSuffix(".dmg") || l.hasSuffix(".zip") || l.hasSuffix(".tar.gz") || l.hasSuffix(".tgz") || l.hasSuffix(".app.tar.gz")
            let bad = l.contains("linux") || l.contains("windows") || l.contains("win32") || l.contains("win64") || l.contains("-win") || l.contains("_win")
            return okExt && !bad
        }
        func extRank(_ l: String) -> Int { l.hasSuffix(".dmg") ? 0 : (l.hasSuffix(".zip") ? 1 : 2) }
        func rank(_ n: String) -> Int? {
            let l = n.lowercased()
            let tier: Int
            if l.contains("arm64") { tier = 0 }
            else if l.contains("aarch64") { tier = 1 }
            else if l.contains("universal") { tier = 2 }
            else if l.contains("mac") || l.contains("darwin") || l.contains("osx") { tier = 3 }
            else if l.contains("x64") || l.contains("x86") || l.contains("intel") || l.contains("amd64") { return nil }
            else if l.hasSuffix(".dmg") || l.hasSuffix(".zip") { tier = 4 }
            else { return nil }
            return tier * 10 + extRank(l)
        }
        let ranked = candidates.compactMap { n in rank(n).map { (n, $0) } }
        return ranked.min { $0.1 < $1.1 }?.0
    }

    static func resolveGitHub(repo: String, assetPattern: String?) async throws -> Resolved {
        let r = repo.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard r.split(separator: "/").count == 2, let url = URL(string: "https://api.github.com/repos/\(r)/releases/latest") else {
            throw SourceError.malformed("仓库名（应为 owner/repo）")
        }
        var headers = ["X-GitHub-Api-Version": "2022-11-28"]
        if let token = await githubToken() { headers["Authorization"] = "Bearer \(token)" }
        let data = try await fetch(url, accept: "application/vnd.github+json", headers: headers)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SourceError.malformed("GitHub API 响应") }
        guard let tag = json["tag_name"] as? String, !tag.isEmpty else { throw SourceError.noVersion("GitHub release") }
        let assets = (json["assets"] as? [[String: Any]] ?? []).compactMap { a -> (String, URL)? in
            guard let n = a["name"] as? String, let u = (a["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return (n, u)
        }
        let chosen = pickGitHubAsset(names: assets.map(\.0), pattern: assetPattern)
        let dl = assets.first { $0.0 == chosen }?.1
        return Resolved(latest: stripV(tag), downloadURL: dl, hint: dl == nil ? noMacAssetHint : nil)
    }

    // MARK: - Tauri

    static func resolveTauri(_ url: URL) async throws -> Resolved {
        let data = try await fetch(url, accept: "application/json")
        guard !data.isEmpty else { throw SourceError.emptyResponse("Tauri 更新接口（可能表示已是最新）") }
        return try parseTauri(try JSONSerialization.jsonObject(with: data))
    }

    /// Tauri 更新器 JSON：{version, platforms:{"darwin-aarch64":{url,signature}}}；也兼容顶层 url / download_url。
    static func parseTauri(_ json: Any) throws -> Resolved {
        guard let root = json as? [String: Any] else { throw SourceError.malformed("Tauri 更新 JSON") }
        guard let version = root["version"] as? String, !version.isEmpty else { throw SourceError.noVersion("Tauri 更新 JSON") }
        var urlString: String?
        if let platforms = root["platforms"] as? [String: Any] {
            let keys = ["darwin-aarch64", "darwin-universal"] + platforms.keys.filter { $0.hasPrefix("darwin") }.sorted()
            for k in keys {
                if let p = platforms[k] as? [String: Any], let u = p["url"] as? String, !u.isEmpty { urlString = u; break }
            }
        }
        if urlString == nil { urlString = (root["url"] as? String) ?? (root["download_url"] as? String) }
        let dl = urlString.flatMap(URL.init(string:))
        return Resolved(latest: stripV(version), downloadURL: dl, hint: dl == nil ? noMacAssetHint : nil)
    }

    // MARK: - Sparkle appcast

    static func resolveAppcast(_ url: URL) async throws -> Resolved {
        let items = try await AppcastParser.fetch(url)
        guard let newest = AppcastParser.newest(in: items) else { throw SourceError.noVersion("appcast") }
        return Resolved(latest: newest.displayVersion, downloadURL: newest.enclosureURL,
                        hint: newest.enclosureURL == nil ? "appcast 无下载地址，请在应用内更新" : nil)
    }
}
