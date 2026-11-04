import Foundation

/// 通过 `npx skills` 安装的 Agent Skills（~/.agents/.skill-lock.json）。
/// 只能对 GitHub 来源做"自安装以来上游是否有新 commit"的检测。
struct SkillsProvider: UpdateProvider {
    let kind: ProviderKind = .skill

    static let lockURL = URL(fileURLWithPath: Shell.home).appendingPathComponent(".agents/.skill-lock.json")

    struct LockedSkill: Sendable {
        let name: String
        let source: String
        let sourceType: String
        let skillPath: String
        let installedAt: Date?
        let updatedAt: Date?
        let updatedAtRaw: String?

        /// GitHub API 的 `path` 参数：skillPath 去掉文件名。
        var skillDirectory: String {
            let dir = (skillPath as NSString).deletingLastPathComponent
            return dir == "." ? "" : dir
        }
    }

    func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: Self.lockURL.path) && Shell.which("npx") != nil
    }

    // MARK: - 锁文件

    static func readLock() throws -> [LockedSkill] {
        let data = try Data(contentsOf: lockURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let skills = root["skills"] as? [String: Any] else { return [] }
        return skills.compactMap { (name, raw) in
            guard let d = raw as? [String: Any] else { return nil }
            let updated = d["updatedAt"] as? String
            return LockedSkill(name: name,
                               source: d["source"] as? String ?? "",
                               sourceType: d["sourceType"] as? String ?? "",
                               skillPath: d["skillPath"] as? String ?? "",
                               installedAt: parseISO(d["installedAt"] as? String),
                               updatedAt: parseISO(updated),
                               updatedAtRaw: updated)
        }.sorted { $0.name < $1.name }
    }

    nonisolated(unsafe) private static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parseISO(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFraction.date(from: s) ?? isoPlain.date(from: s)
    }

    static func day(_ d: Date?) -> String { d.map { dayFormatter.string(from: $0) } ?? "?" }

    // MARK: - 协议

    func listInstalled(log: @escaping Logger) async throws -> [InstalledEntry] {
        try Self.readLock().map { InstalledEntry(name: $0.name, detail: $0.source, version: Self.day($0.updatedAt ?? $0.installedAt)) }
    }

    func check(tracked: Set<String>, log: @escaping Logger) async throws -> [UpdateItem] {
        guard !tracked.isEmpty else {
            log("Skills: 未选择任何软件，跳过", false)
            return []
        }
        let skills = try Self.readLock().filter { tracked.contains($0.name) }
        let token = await githubToken()
        if token == nil { log("Skills: 未找到 GitHub token，使用匿名额度（60 次/小时）", false) }
        log("Skills: 查询 GitHub 上游提交（\(skills.count) 个）", false)
        let items: [UpdateItem] = await withTaskGroup(of: UpdateItem.self) { group in
            for s in skills {
                group.addTask { await checkOne(s, token: token) }
            }
            var out: [UpdateItem] = []
            for await i in group { out.append(i) }
            return out.sorted { $0.name < $1.name }
        }
        log("Skills: \(items.filter(\.status.isOutdated).count)/\(items.count) 个可更新", false)
        return items
    }

    private func checkOne(_ s: LockedSkill, token: String?) async -> UpdateItem {
        let installed = Self.day(s.updatedAt ?? s.installedAt)
        guard s.sourceType == "github", !s.source.isEmpty else {
            return UpdateItem(kind: .skill, name: s.name, detail: s.source.isEmpty ? s.sourceType : s.source, installed: installed, latest: nil,
                              status: .unknown("仅支持 GitHub 来源的检测"), canUpdate: true)
        }
        var comps = URLComponents(string: "https://api.github.com/repos/\(s.source)/commits")!
        var q = [URLQueryItem(name: "per_page", value: "1")]
        if !s.skillDirectory.isEmpty { q.append(URLQueryItem(name: "path", value: s.skillDirectory)) }
        if let since = s.updatedAtRaw ?? s.updatedAt.map({ Self.isoPlain.string(from: $0) }) {
            q.append(URLQueryItem(name: "since", value: since))
        }
        comps.queryItems = q
        var headers = ["X-GitHub-Api-Version": "2022-11-28", "Accept": "application/vnd.github+json"]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        do {
            let json = try await Shell.fetchJSON(comps.url!, headers: headers)
            let commits = json as? [[String: Any]] ?? []
            guard let newest = commits.first else {
                return UpdateItem(kind: .skill, name: s.name, detail: s.source, installed: installed, latest: installed, status: .upToDate)
            }
            let date = Self.parseISO(((newest["commit"] as? [String: Any])?["committer"] as? [String: Any])?["date"] as? String
                                     ?? ((newest["commit"] as? [String: Any])?["author"] as? [String: Any])?["date"] as? String)
            let sha = (newest["sha"] as? String).map { String($0.prefix(7)) }
            let latest = date.map(Self.day) ?? sha ?? "新提交"
            return UpdateItem(kind: .skill, name: s.name, detail: s.source, installed: installed, latest: latest, status: .outdated)
        } catch {
            let code = (error as NSError).code
            if code == 403 || code == 429 {
                return UpdateItem(kind: .skill, name: s.name, detail: s.source, installed: installed, latest: nil, status: .unknown("GitHub API 限额"))
            }
            return UpdateItem(kind: .skill, name: s.name, detail: s.source, installed: installed, latest: nil,
                              status: .unknown("GitHub 查询失败: \(error.localizedDescription)"))
        }
    }

    /// 环境变量 GITHUB_TOKEN，否则 `gh auth token`；都没有则匿名。
    private func githubToken() async -> String? {
        if let t = Shell.environment["GITHUB_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        if let r = try? await Shell.run(["gh", "auth", "token"], timeout: 15), r.ok {
            let t = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return nil
    }

    func update(_ item: UpdateItem, log: @escaping Logger) async throws {
        // 已用 `npx -y skills@latest update --help` 确认：update [skills...]，-g 全局，-y 跳过范围询问。
        let cmd = ["npx", "-y", "skills@latest", "update", item.name, "-g", "-y"]
        log("$ " + cmd.joined(separator: " "), false)
        try await Shell.runChecked(cmd, timeout: 600, onOutput: log)
    }
}
