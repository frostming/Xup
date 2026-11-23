import XCTest
@testable import Xup

/// Skills 来源可切换管理器：默认 Vercel `skills` CLI，可选 skm（~/.config/skm/skills-lock.yaml）。
final class SkmTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xup-skm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: 配置 skill.manager

    func testSkillManagerDefaultsToSkillsCLI() throws {
        XCTAssertEqual(XupConfig().skill.manager, .skills)
        let (cfg, warnings) = try ConfigStore.parse(Data(#"{"version":1}"#.utf8))
        XCTAssertEqual(cfg.skill.manager, .skills, "缺省时用 Vercel skills CLI")
        XCTAssertTrue(warnings.isEmpty)
    }

    func testSkillManagerSkmRoundTrips() throws {
        let (cfg, warnings) = try ConfigStore.parse(Data(#"{"version":1,"skill":{"manager":"skm"}}"#.utf8))
        XCTAssertEqual(cfg.skill.manager, .skm)
        XCTAssertTrue(warnings.isEmpty, "skill.manager 是已知字段：\(warnings)")

        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: cfg.encoded()) as? [String: Any])
        XCTAssertEqual((obj["skill"] as? [String: Any])?["manager"] as? String, "skm")
        XCTAssertEqual(try ConfigStore.parse(cfg.encoded()).0.skill, cfg.skill)
    }

    func testUnknownSkillManagerIsRejected() {
        XCTAssertThrowsError(try ConfigStore.parse(Data(#"{"version":1,"skill":{"manager":"brew"}}"#.utf8))) { error in
            guard case ConfigError.invalid(let errs) = error else { return XCTFail("应为 ConfigError.invalid，实际 \(error)") }
            XCTAssertTrue(errs.contains { $0.contains("skill.manager") }, "\(errs)")
        }
    }

    @MainActor
    func testProviderFollowsSkillManagerSetting() throws {
        let store = ConfigStore(url: tmp.appendingPathComponent("config.json"), migrateFrom: nil, watch: false)
        let suite = "dev.fming.xup.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, store: store)
        let center = UpdateCenter(settings: settings, history: UpdateHistory(url: tmp.appendingPathComponent("history.jsonl")))

        func skillProvider() -> UpdateProvider? { center.makeProviders().first { $0.kind == .skill } }

        XCTAssertTrue(skillProvider() is SkillsProvider, "默认是 Vercel skills CLI")
        settings.skillManager = .skm
        XCTAssertTrue(skillProvider() is SkmProvider)
        XCTAssertEqual(store.config.skill.manager, .skm, "切换后写入 config.json")
        settings.skillManager = .skills
        XCTAssertTrue(skillProvider() is SkillsProvider)
    }

    // MARK: skm 锁文件

    private let sampleLock = """
    skills:
      - name: grill-me
        repo: https://github.com/mattpocock/skills
        local_path:
        source_cmd:
        commit: c55ee46073ed923f86ce59a5eb3b6d895095d1b7
        skill_path: skills/productivity/grill-me
        linked_to:
          - ~/.agents/skills/grill-me
          - ~/.claude/skills/grill-me
      - name: hnread
        repo:
        local_path: ~/Code/scripts
        source_cmd:
        commit:
        skill_path: skills/hnread
        linked_to:
          - ~/.agents/skills/hnread
      - name: tinyhost
        repo:
        local_path:
        source_cmd: 'tinyhost skill --name ''x'''
        commit:
        skill_path: .
        linked_to: []
      - name: "quoted: name"
        repo: git@github.com:reorx/skm.git
        local_path:
        source_cmd:
        commit: abc1234
        skill_path: skills/q
        linked_to:
          - ~/.agents/skills/q
      - name: grilling
        repo: https://github.com/mattpocock/skills
        local_path:
        source_cmd:
        commit: c55ee46073ed923f86ce59a5eb3b6d895095d1b7
        skill_path: skills/productivity/grilling
        linked_to:
          - ~/.agents/skills/grilling

    """

    func testParseSkmLock() throws {
        let skills = try SkmProvider.parseLock(sampleLock)
        XCTAssertEqual(skills.map(\.name), ["grill-me", "hnread", "tinyhost", "quoted: name", "grilling"])

        let grill = skills[0]
        XCTAssertEqual(grill.origin, .repo("https://github.com/mattpocock/skills"))
        XCTAssertEqual(grill.commit, "c55ee46073ed923f86ce59a5eb3b6d895095d1b7")
        XCTAssertEqual(grill.skillPath, "skills/productivity/grill-me")
        XCTAssertEqual(grill.linkedTo, ["~/.agents/skills/grill-me", "~/.claude/skills/grill-me"])

        XCTAssertEqual(skills[1].origin, .local("~/Code/scripts"))
        XCTAssertNil(skills[1].commit)
        XCTAssertEqual(skills[2].origin, .dynamic("tinyhost skill --name 'x'"), "单引号标量：'' 还原为 '")
        XCTAssertEqual(skills[2].linkedTo, [])
        XCTAssertEqual(skills[3].origin, .repo("git@github.com:reorx/skm.git"))
    }

    func testParseEmptyOrMissingSkills() throws {
        XCTAssertEqual(try SkmProvider.parseLock(""), [])
        XCTAssertEqual(try SkmProvider.parseLock("skills: []\n"), [])
    }

    /// 与 skm 的 `repo_url_to_dirname`（Python urlparse）一致。
    func testRepoDirNameMatchesSkm() {
        XCTAssertEqual(SkmProvider.repoDirName("https://github.com/mattpocock/skills"), "github.com_mattpocock_skills")
        XCTAssertEqual(SkmProvider.repoDirName("https://github.com/firecrawl/cli.git"), "github.com_firecrawl_cli")
        XCTAssertEqual(SkmProvider.repoDirName("https://gitlab.com/a/b/c/"), "gitlab.com_a_b_c")
        XCTAssertEqual(SkmProvider.repoDirName("git@github.com:reorx/skm.git"), "None_git@github.com:reorx_skm")
    }

    /// 关注键：GitHub 仓库为 owner/repo，其它为完整地址。
    func testRepoKey() {
        XCTAssertEqual(SkmProvider.repoKey("https://github.com/mattpocock/skills"), "mattpocock/skills")
        XCTAssertEqual(SkmProvider.repoKey("https://github.com/firecrawl/cli.git"), "firecrawl/cli")
        XCTAssertEqual(SkmProvider.repoKey("https://gitlab.com/a/b"), "https://gitlab.com/a/b")
        XCTAssertEqual(SkmProvider.repoKey("git@github.com:reorx/skm.git"), "git@github.com:reorx/skm.git")
    }

    /// skm 更新的最小单位是仓库（一个克隆、所有 skill 共用一个 commit），所以按仓库列出；
    /// 本地目录与命令生成的 skill 无法检测，不列出。
    func testListInstalledGroupsByRepoAndHidesLocalAndCommand() async throws {
        let lockURL = tmp.appendingPathComponent("skills-lock.yaml")
        try sampleLock.write(to: lockURL, atomically: true, encoding: .utf8)
        let provider = SkmProvider(lockURL: lockURL, storeURL: tmp.appendingPathComponent("store"))
        let entries = try await provider.listInstalled(log: { _, _ in })
        XCTAssertEqual(entries.map(\.name), ["git@github.com:reorx/skm.git", "mattpocock/skills"])
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        XCTAssertEqual(byName["mattpocock/skills"]?.detail, "grill-me、grilling", "列出该仓库装了哪些 skill")
        XCTAssertEqual(byName["mattpocock/skills"]?.version, "c55ee46")
        XCTAssertEqual(byName["git@github.com:reorx/skm.git"]?.detail, "quoted: name")
    }

    // MARK: skm 检查（真实 git 仓库）

    @discardableResult
    private func git(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else { throw NSError(domain: "git", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed"]) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitFile(_ path: String, _ content: String, in repo: URL) throws -> String {
        let file = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "-A"], in: repo)
        try git(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "change \(path)"], in: repo)
        return try git(["rev-parse", "HEAD"], in: repo)
    }

    /// 上游（remote）→ skm 的 store 克隆 → 锁文件记录克隆时的 commit；之后上游只改了 skill a 的目录。
    func testCheckIsPerRepoAndOnlyCountsInstalledSkillPaths() async throws {
        let remote = tmp.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: remote)
        _ = try commitFile("skills/a/SKILL.md", "a1", in: remote)
        _ = try commitFile("skills/b/SKILL.md", "b1", in: remote)
        let locked = try commitFile("README.md", "r1", in: remote)

        let store = tmp.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try git(["clone", "-q", remote.path, "github.com_acme_skills"], in: store)
        try git(["clone", "-q", remote.path, "github.com_acme_other"], in: store)

        // 上游新提交：a 的目录变了；随后另一个提交只改仓库其它文件。
        let aChange = try commitFile("skills/a/SKILL.md", "a2", in: remote)
        _ = try commitFile("README.md", "r2", in: remote)

        let lock = """
        skills:
          - name: a
            repo: https://github.com/acme/skills
            commit: \(locked)
            skill_path: skills/a
            linked_to: []
          - name: b
            repo: https://github.com/acme/skills
            commit: \(locked)
            skill_path: skills/b
            linked_to: []
          - name: mine
            local_path: ~/Code/scripts
            skill_path: skills/mine
            linked_to: []
          - name: dyn
            source_cmd: tinyhost skill
            skill_path: .
            linked_to: []
          - name: gone
            repo: https://github.com/acme/not-cloned
            commit: \(locked)
            skill_path: skills/gone
            linked_to: []
          - name: b2
            repo: https://github.com/acme/other
            commit: \(locked)
            skill_path: skills/b
            linked_to: []
        """
        let lockURL = tmp.appendingPathComponent("skills-lock.yaml")
        try lock.write(to: lockURL, atomically: true, encoding: .utf8)

        let provider = SkmProvider(lockURL: lockURL, storeURL: store)
        let logs = LogSink()
        let items = try await provider.check(tracked: ["acme/skills", "acme/other", "acme/not-cloned", "uninstalled"], log: logs.logger)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })

        XCTAssertEqual(Set(byName.keys), ["acme/skills", "acme/other", "acme/not-cloned"], "锁文件里没有的关注项不出现在列表中")

        let repo = try XCTUnwrap(byName["acme/skills"])
        XCTAssertEqual(repo.status, .outdated, "仓库里 a 的目录有新提交")
        XCTAssertEqual(repo.id, "skill:acme/skills")
        XCTAssertEqual(repo.detail, "a、b", "列出该仓库装了哪些 skill")
        XCTAssertEqual(repo.hint, "a 有新提交", "说明是哪个 skill 变了")
        XCTAssertTrue(repo.canUpdate)
        // 同一天提交：日期相同时"远端提交"显示短 SHA 以便区分。
        XCTAssertEqual(repo.latest, String(aChange.prefix(7)))

        let other = try XCTUnwrap(byName["acme/other"])
        XCTAssertEqual(other.status, .upToDate, "该仓库装的只有 skills/b，上游没改它（只改了 a 与 README）")
        XCTAssertNil(other.hint)

        let gone = try XCTUnwrap(byName["acme/not-cloned"])
        guard case .unknown = gone.status else { return XCTFail("没有本地克隆的仓库应为 unknown，实际 \(gone.status)") }

        XCTAssertTrue(logs.lines.contains { $0.contains("uninstalled") }, "关注了但未在 skm 中安装的仓库要记日志：\(logs.lines)")
    }

    func testChangedHint() {
        XCTAssertEqual(SkmProvider.changedHint(["a"]), "a 有新提交")
        XCTAssertEqual(SkmProvider.changedHint(["a", "b"]), "a、b 有新提交")
        XCTAssertEqual(SkmProvider.changedHint(["a", "b", "c"]), "a、b 等 3 个 skill 有新提交")
    }

    /// 一次更新整个仓库：把该仓库的全部 skill 名交给 skm（它按仓库去重，只 pull 一次）。
    func testUpdateCommandCoversAllSkillsOfRepo() throws {
        let skills = try SkmProvider.parseLock(sampleLock)
        XCTAssertEqual(try SkmProvider.updateCommand(repoKey: "mattpocock/skills", lock: skills), ["skm", "update", "grill-me", "grilling"])
        XCTAssertThrowsError(try SkmProvider.updateCommand(repoKey: "acme/missing", lock: skills))
    }
}

private final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
    var logger: Logger {
        { [self] text, _ in lock.lock(); _lines.append(text); lock.unlock() }
    }
}
