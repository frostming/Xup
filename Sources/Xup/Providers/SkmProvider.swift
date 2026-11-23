import Foundation

/// skm（github.com/reorx/skm）管理的 skill。
/// 锁文件 ~/.config/skm/skills-lock.yaml；repo 来源的 skill 在 ~/.local/share/skm/skills/<host_owner_repo> 有一份 git 克隆。
/// 检测：在 skm 的克隆里 `git fetch`（与 `skm check-updates` 相同），再看"锁定 commit..远端 HEAD"之间
/// 有没有改动该 skill 目录的提交——只比这个 skill 自己的目录，不受仓库其它目录的提交影响，也不走 GitHub API 限额。
struct SkmProvider: UpdateProvider {
    let kind: ProviderKind = .skill

    static let defaultLockURL = URL(fileURLWithPath: Shell.home).appendingPathComponent(".config/skm/skills-lock.yaml")
    static let defaultStoreURL = URL(fileURLWithPath: Shell.home).appendingPathComponent(".local/share/skm/skills")

    let lockURL: URL
    let storeURL: URL

    init(lockURL: URL = SkmProvider.defaultLockURL, storeURL: URL = SkmProvider.defaultStoreURL) {
        self.lockURL = lockURL
        self.storeURL = storeURL
    }

    struct LockedSkill: Equatable, Sendable {
        enum Origin: Equatable, Sendable {
            case repo(String)
            case local(String)
            /// `source_cmd`：由命令输出的 SKILL.md 生成。
            case dynamic(String)
            case unknown
        }

        let name: String
        let origin: Origin
        let commit: String?
        let skillPath: String
        let linkedTo: [String]
    }

    func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: lockURL.path) && Shell.which("skm") != nil
    }

    // MARK: - 锁文件

    func readLock() throws -> [LockedSkill] {
        try Self.parseLock(String(contentsOf: lockURL, encoding: .utf8))
    }

    struct LockError: LocalizedError {
        let line: Int
        let reason: String
        var errorDescription: String? { "skills-lock.yaml 第 \(line) 行：\(reason)" }
    }

    /// 只覆盖 skm（ruamel.yaml）写出的锁文件形态：顶层 `skills:` 序列，每项是标量字段加 `linked_to` 字符串列表。
    static func parseLock(_ text: String) throws -> [LockedSkill] {
        var raws: [RawSkill] = []
        var inSkills = false
        var itemIndent: Int?
        var listKey: String?

        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            let lineNo = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count

            if indent == 0 {
                inSkills = trimmed.hasPrefix("skills:")
                listKey = nil
                continue
            }
            guard inSkills else { continue }

            if trimmed == "-" || trimmed.hasPrefix("- ") {
                let rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if itemIndent == nil || indent <= itemIndent! {
                    itemIndent = indent
                    raws.append(RawSkill(line: lineNo))
                    listKey = nil
                    if !rest.isEmpty { listKey = try raws[raws.count - 1].assign(rest, line: lineNo) }
                } else {
                    guard let key = listKey, !raws.isEmpty else { throw LockError(line: lineNo, reason: "列表项不属于任何字段") }
                    raws[raws.count - 1].lists[key, default: []].append(scalar(rest) ?? "")
                }
            } else {
                guard !raws.isEmpty else { throw LockError(line: lineNo, reason: "字段不属于任何 skill") }
                listKey = try raws[raws.count - 1].assign(trimmed, line: lineNo)
            }
        }
        return try raws.map { try $0.skill() }
    }

    private struct RawSkill {
        let line: Int
        var scalars: [String: String] = [:]
        var lists: [String: [String]] = [:]

        /// 解析 `key: value`；值为空时返回 key（其后可能跟着该字段的列表项）。
        mutating func assign(_ text: String, line: Int) throws -> String? {
            guard let m = RawSkill.keyValue.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let keyRange = Range(m.range(at: 1), in: text) else {
                throw LockError(line: line, reason: "无法解析 “\(text)”")
            }
            let key = String(text[keyRange])
            let value = Range(m.range(at: 2), in: text).map { String(text[$0]) } ?? ""
            if value.trimmingCharacters(in: .whitespaces) == "[]" {
                lists[key] = []
                return nil
            }
            guard let v = SkmProvider.scalar(value) else { return key }
            scalars[key] = v
            return nil
        }

        func skill() throws -> LockedSkill {
            guard let name = scalars["name"], !name.isEmpty else { throw LockError(line: line, reason: "skill 缺少 name") }
            let origin: LockedSkill.Origin
            if let repo = scalars["repo"] { origin = .repo(repo) }
            else if let path = scalars["local_path"] { origin = .local(path) }
            else if let cmd = scalars["source_cmd"] { origin = .dynamic(cmd) }
            else { origin = .unknown }
            return LockedSkill(name: name, origin: origin, commit: scalars["commit"],
                               skillPath: scalars["skill_path"] ?? ".", linkedTo: lists["linked_to"] ?? [])
        }

        static let keyValue = try! NSRegularExpression(pattern: #"^([A-Za-z_][A-Za-z0-9_]*):(?:\s+(.*))?$"#)
    }

    /// YAML 标量：空 / `~` / `null` 为 nil；支持单引号（'' 转义）与双引号（\" \\ 转义）。
    static func scalar(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s == "~" || s == "null" { return nil }
        if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            var out = ""
            var escaping = false
            for ch in s.dropFirst().dropLast() {
                if escaping { out.append(ch); escaping = false }
                else if ch == "\\" { escaping = true }
                else { out.append(ch) }
            }
            return out
        }
        return s
    }

    /// 与 skm 的 `repo_url_to_dirname` 一致（Python urlparse：hostname 小写；无 host 时为 "None"）。
    static func repoDirName(_ repo: String) -> String {
        var host = "None"
        var path = repo
        if let comps = URLComponents(string: repo), comps.scheme != nil, let h = comps.host, !h.isEmpty {
            host = h.lowercased()
            path = comps.path
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        return "\(host)_\(path.replacingOccurrences(of: "/", with: "_"))"
    }

    /// 关注键与列表名称：GitHub 仓库为 owner/repo，其它仓库为完整地址。
    static func repoKey(_ url: String) -> String {
        if let comps = URLComponents(string: url), comps.host?.lowercased() == "github.com" {
            var path = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path.hasSuffix(".git") { path.removeLast(4) }
            if path.split(separator: "/").count == 2 { return path }
        }
        return url
    }

    /// 同一仓库安装的 skill。skm 一个仓库只有一份克隆、所有 skill 共用一个 commit，
    /// `skm update` 也是整仓库 pull，所以 Xup 以仓库为关注与更新的单位。
    struct RepoGroup: Sendable {
        let key: String
        let url: String
        /// 按锁文件顺序。
        let skills: [LockedSkill]

        /// 列表 detail：该仓库装了哪些 skill。
        var memberList: String { skills.map(\.name).sorted().joined(separator: "、") }
    }

    /// 只含 repo 来源；本地目录与命令生成的 skill 无法检测，不参与。按 key 排序。
    static func groupByRepo(_ skills: [LockedSkill]) -> [RepoGroup] {
        var order: [String] = []
        var urls: [String: String] = [:]
        var members: [String: [LockedSkill]] = [:]
        for s in skills {
            guard case .repo(let url) = s.origin else { continue }
            let key = repoKey(url)
            if members[key] == nil { order.append(key); urls[key] = url }
            members[key, default: []].append(s)
        }
        return order.sorted().map { RepoGroup(key: $0, url: urls[$0]!, skills: members[$0]!) }
    }

    /// 状态徽标后的说明：哪些 skill 有新提交。
    static func changedHint(_ names: [String]) -> String {
        if names.count <= 2 { return names.joined(separator: "、") + " 有新提交" }
        return names.prefix(2).joined(separator: "、") + " 等 \(names.count) 个 skill 有新提交"
    }

    private static func shortSHA(_ commit: String?) -> String? { commit.map { String($0.prefix(7)) } }

    private static func isSHA(_ s: String) -> Bool {
        (7...40).contains(s.count) && s.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    // MARK: - 协议

    func listInstalled(log: @escaping Logger) async throws -> [InstalledEntry] {
        Self.groupByRepo(try readLock()).map {
            InstalledEntry(name: $0.key, detail: $0.memberList, version: Self.shortSHA($0.skills.first?.commit) ?? "?")
        }
    }

    func check(tracked: Set<String>, log: @escaping Logger) async throws -> [UpdateItem] {
        guard !tracked.isEmpty else {
            log("skm: 未选择任何软件，跳过", false)
            return []
        }
        let groups = Self.groupByRepo(try readLock())
        let missing = tracked.subtracting(groups.map(\.key))
        if !missing.isEmpty { log("skm: 关注的 \(missing.sorted().joined(separator: "、")) 不是 skm 锁文件中的仓库", true) }

        let selected = groups.filter { tracked.contains($0.key) }
        guard !selected.isEmpty else { return [] }
        log("skm: 在本地克隆中 git fetch（\(selected.count) 个仓库）", false)
        let items: [UpdateItem] = await withTaskGroup(of: UpdateItem.self) { group in
            for repo in selected {
                group.addTask { await checkRepo(repo, log: log) }
            }
            var out: [UpdateItem] = []
            for await item in group { out.append(item) }
            return out.sorted { $0.name < $1.name }
        }
        log("skm: \(items.filter(\.status.isOutdated).count)/\(items.count) 个仓库可更新", false)
        return items
    }

    private func checkRepo(_ repo: RepoGroup, log: @escaping Logger) async -> UpdateItem {
        let dir = storeURL.appendingPathComponent(Self.repoDirName(repo.url))
        func unknown(_ why: String) -> UpdateItem {
            UpdateItem(kind: .skill, name: repo.key, detail: repo.memberList,
                       installed: Self.shortSHA(repo.skills.first?.commit) ?? "?", latest: nil, status: .unknown(why))
        }

        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) else {
            let shown = dir.path.replacingOccurrences(of: Shell.home, with: "~")
            log("skm: 找不到 \(repo.url) 的本地克隆 \(shown)", true)
            return unknown("skm 的本地克隆不存在，先执行 skm install")
        }
        guard repo.skills.allSatisfy({ $0.commit.map(Self.isSHA) ?? false }) else {
            return unknown("锁文件中没有有效的 commit")
        }
        do {
            try await Shell.runChecked(["env", "GIT_TERMINAL_PROMPT=0", "git", "-C", dir.path, "fetch", "--quiet"], timeout: 120)
        } catch {
            log("skm: \(repo.url) git fetch 失败：\(error.localizedDescription)", true)
            return unknown("git fetch 失败")
        }
        guard let remoteHead = await Self.remoteHead(in: dir) else {
            log("skm: \(repo.url) 无法确定远端 HEAD", true)
            return unknown("无法确定远端 HEAD")
        }
        do {
            return try await compare(repo, in: dir, remoteHead: remoteHead, log: log)
        } catch {
            log("skm: \(repo.key) git 查询失败：\(error.localizedDescription)", true)
            return unknown("git 查询失败")
        }
    }

    /// 只看该仓库**已安装的 skill 目录**在"锁定 commit..远端 HEAD"之间有没有提交；仓库其它目录的提交不算。
    private func compare(_ repo: RepoGroup, in dir: URL, remoteHead: String, log: Logger) async throws -> UpdateItem {
        struct Change { let name: String; let sha: String; let date: Date? }
        var changes: [Change] = []
        for s in repo.skills {
            let commit = s.commit!
            let newer = try await Self.git(["log", "--format=%H%x09%cI", "\(commit)..\(remoteHead)", "--", s.skillPath], in: dir)
                .split(separator: "\n")
            guard let newest = newer.first else { continue }
            let parts = newest.split(separator: "\t", maxSplits: 1).map(String.init)
            let sha = String(parts[0].prefix(7))
            changes.append(Change(name: s.name, sha: sha, date: SkillsProvider.parseISO(parts.count > 1 ? parts[1] : nil)))
            log("skm: \(s.name) 有 \(newer.count) 个新提交（\(commit.prefix(7)) → \(sha)）", false)
        }

        let lockedCommit = repo.skills[0].commit!
        let installed = SkillsProvider.day(SkillsProvider.parseISO(try await Self.git(["show", "-s", "--format=%cI", lockedCommit], in: dir)))
        guard let newest = changes.max(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }) else {
            return UpdateItem(kind: .skill, name: repo.key, detail: repo.memberList, installed: installed, latest: installed, status: .upToDate)
        }
        let newestDay = SkillsProvider.day(newest.date)
        // 同一天的提交用短 SHA 区分，否则"本地更新于"与"远端提交"看起来一样。
        let latest = newestDay == installed ? newest.sha : newestDay
        return UpdateItem(kind: .skill, name: repo.key, detail: repo.memberList, installed: installed, latest: latest,
                          status: .outdated, hint: Self.changedHint(changes.map(\.name).sorted()))
    }

    /// 与 skm 相同：origin/HEAD，退回 origin/main、origin/master。
    private static func remoteHead(in dir: URL) async -> String? {
        for ref in ["origin/HEAD", "origin/main", "origin/master"] {
            if let r = try? await Shell.run(["git", "-C", dir.path, "rev-parse", "--verify", "--quiet", ref], timeout: 30), r.ok {
                let sha = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sha.isEmpty { return sha }
            }
        }
        return nil
    }

    private static func git(_ args: [String], in dir: URL) async throws -> String {
        try await Shell.runChecked(["git", "-C", dir.path] + args, timeout: 60).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct UnknownRepo: LocalizedError {
        let key: String
        var errorDescription: String? { "skm 锁文件中没有仓库 \(key) 的 skill" }
    }

    /// 把该仓库的全部 skill 名交给 skm：它按仓库去重，只 pull 一次并重链全部 skill。
    static func updateCommand(repoKey: String, lock: [LockedSkill]) throws -> [String] {
        guard let repo = groupByRepo(lock).first(where: { $0.key == repoKey }) else { throw UnknownRepo(key: repoKey) }
        return ["skm", "update"] + repo.skills.map(\.name)
    }

    func update(_ item: UpdateItem, log: @escaping Logger) async throws {
        let cmd = try Self.updateCommand(repoKey: item.name, lock: readLock())
        log("$ " + cmd.joined(separator: " "), false)
        try await Shell.runChecked(cmd, timeout: 600, onOutput: log)
    }
}
