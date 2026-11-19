import XCTest
@testable import Xup

final class AgentSpecTests: XCTestCase {
    private func spec(_ specs: [AgentSpec], _ binary: String) -> AgentSpec? {
        specs.first { $0.binary == binary }
    }

    // MARK: 内置规则

    func testBuiltinCodexCanSelfUpdate() {
        let codex = spec(AgentSpec.builtin, "codex")
        XCTAssertEqual(codex?.updateCommand, ["codex", "update"])
        XCTAssertEqual(codex?.hasUpdateCommand, true)
    }

    /// Antigravity CLI（agy）是原生二进制，没有 npm 包：最新版本看 GitHub release，`agy update` 自更新。
    func testBuiltinAntigravityCLI() {
        let agy = spec(AgentSpec.builtin, "agy")
        XCTAssertEqual(agy?.name, "Antigravity CLI")
        XCTAssertNil(agy?.npmPackage)
        XCTAssertEqual(agy?.githubRepo, "google-antigravity/antigravity-cli")
        XCTAssertEqual(agy?.updateCommand, ["agy", "update"])
    }

    func testDecodesGithubRepoFromAgentsJSON() throws {
        let json = #"[{"name": "Foo", "binary": "foo", "githubRepo": "owner/foo"}]"#
        let specs = try JSONDecoder().decode([AgentSpec].self, from: Data(json.utf8))
        XCTAssertEqual(specs.first?.githubRepo, "owner/foo")
    }

    // MARK: agents.json 与内置规则合并

    /// 旧版本生成的 agents.json 里 codex 没有 updateCommand，加载时应从内置规则补上。
    func testFillsMissingFieldsFromBuiltin() {
        let user = [AgentSpec(name: "Codex CLI", binary: "codex", npmPackage: "@openai/codex")]
        let merged = AgentSpec.fillingFromBuiltin(user)
        XCTAssertEqual(spec(merged, "codex")?.updateCommand, ["codex", "update"])
    }

    func testKeepsUserValues() {
        let user = [AgentSpec(name: "My Codex", binary: "codex", npmPackage: "my-codex",
                              versionArgs: ["version"], updateCommand: ["brew", "upgrade", "codex"])]
        let merged = AgentSpec.fillingFromBuiltin(user)
        XCTAssertEqual(merged, user)
    }

    /// `"updateCommand": []` 表示明确不要更新命令，不应被内置值覆盖。
    func testEmptyUpdateCommandOptsOut() {
        let user = [AgentSpec(name: "Codex CLI", binary: "codex", npmPackage: "@openai/codex", updateCommand: [])]
        let merged = AgentSpec.fillingFromBuiltin(user)
        XCTAssertEqual(spec(merged, "codex")?.updateCommand, [])
        XCTAssertEqual(spec(merged, "codex")?.hasUpdateCommand, false)
    }

    /// 自定义 agent 原样保留；用户删掉的内置 agent 不会被加回来；顺序不变。
    func testCustomAgentsAndRemovalsPreserved() {
        let user = [
            AgentSpec(name: "Foo", binary: "foo"),
            AgentSpec(name: "Claude Code", binary: "claude", npmPackage: "@anthropic-ai/claude-code"),
        ]
        let merged = AgentSpec.fillingFromBuiltin(user)
        XCTAssertEqual(merged.map(\.binary), ["foo", "claude"])
        XCTAssertEqual(spec(merged, "foo"), AgentSpec(name: "Foo", binary: "foo"))
        XCTAssertEqual(spec(merged, "claude")?.updateCommand, ["claude", "update"])
    }

    func testFillsGithubRepoFromBuiltin() {
        let merged = AgentSpec.fillingFromBuiltin([AgentSpec(name: "Antigravity CLI", binary: "agy")])
        XCTAssertEqual(spec(merged, "agy")?.githubRepo, "google-antigravity/antigravity-cli")
    }

    // MARK: 后来新增的内置 agent 进入已有的 agents.json

    /// 旧版本生成的 agents.json 没有"已见过"记录：按最初那批内置 agent 算已见，只追加之后新增的（agy）。
    func testLegacyFileGetsNewlyAddedBuiltins() {
        let user = AgentSpec.builtin.filter { $0.binary != "agy" }
        XCTAssertEqual(AgentSpec.unseenBuiltins(in: user, seen: nil).map(\.binary), ["agy"])
    }

    /// 旧文件里用户删掉的最初内置 agent，仍然不会被加回来。
    func testLegacyRemovalsStayRemoved() {
        let user = [AgentSpec(name: "Claude Code", binary: "claude")]
        XCTAssertEqual(AgentSpec.unseenBuiltins(in: user, seen: nil).map(\.binary), ["agy"])
    }

    /// 已经见过（追加过）的内置 agent，用户删掉后不再加回来。
    func testSeenBuiltinRemovedByUserStaysRemoved() {
        let user = [AgentSpec(name: "Claude Code", binary: "claude")]
        let seen = Set(AgentSpec.builtin.map(\.binary))
        XCTAssertEqual(AgentSpec.unseenBuiltins(in: user, seen: seen), [])
    }

    /// 用户自己写了同名 binary 的 agent 时不重复追加。
    func testUserDefinedSameBinaryNotDuplicated() {
        let user = [AgentSpec(name: "My agy", binary: "agy")]
        XCTAssertEqual(AgentSpec.unseenBuiltins(in: user, seen: nil), [])
    }

    // MARK: 加载 agents.json（AppSettings.loadAgentSpecs）

    @MainActor
    private func makeSettings(agentsJSON: String?) throws -> (AppSettings, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xup-agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let agentsURL = dir.appendingPathComponent("agents.json")
        if let agentsJSON { try Data(agentsJSON.utf8).write(to: agentsURL) }
        let store = ConfigStore(url: dir.appendingPathComponent("config.json"), migrateFrom: nil, watch: false)
        let suite = "dev.fming.xup.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (AppSettings(defaults: defaults, store: store), agentsURL)
    }

    /// agents.json 与 config.json 在同一目录：用临时 config 的测试不会读写真实的 agents.json。
    @MainActor
    func testAgentsJSONLivesNextToConfig() throws {
        let (settings, url) = try makeSettings(agentsJSON: nil)
        XCTAssertEqual(settings.agentSpecsURL, url)
        XCTAssertEqual(settings.loadAgentSpecs(), AgentSpec.builtin)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// 旧 agents.json（没有 agy）：加载后 agy 追加进文件；用户删掉后重新加载不再加回。
    @MainActor
    func testLoadAppendsNewBuiltinOnceThenRespectsRemoval() throws {
        let legacy = #"[{"name": "Claude Code", "binary": "claude", "npmPackage": "@anthropic-ai/claude-code"}]"#
        let (settings, url) = try makeSettings(agentsJSON: legacy)

        XCTAssertEqual(settings.loadAgentSpecs().map(\.binary), ["claude", "agy"])
        let onDisk = try JSONDecoder().decode([AgentSpec].self, from: Data(contentsOf: url))
        XCTAssertEqual(onDisk.map(\.binary), ["claude", "agy"])
        XCTAssertNil(settings.agentSpecsError)

        try Data(legacy.utf8).write(to: url)  // 用户在 agents.json 里删掉 agy
        XCTAssertEqual(settings.loadAgentSpecs().map(\.binary), ["claude"])
    }

    // MARK: 安装方式判断

    /// Homebrew 的 node 装的全局 npm 包在 /opt/homebrew/lib/node_modules 下，归 npm 管。
    func testNpmGlobalUnderHomebrewNodeIsNpm() {
        let path = "/opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js"
        XCTAssertEqual(AgentProvider.managedBy(path: path), .npm)
    }

    /// brew formula 把 npm 包装在 Cellar/<name>/<ver>/libexec/lib/node_modules 下，归 brew 管。
    func testBrewFormulaBundlingNodeModulesIsBrew() {
        let path = "/opt/homebrew/Cellar/gemini-cli/0.20.0/libexec/lib/node_modules/@google/gemini-cli/dist/index.js"
        XCTAssertEqual(AgentProvider.managedBy(path: path), .brew)
    }

    func testCodexStandaloneIsNative() {
        let path = "/Users/someone/.codex/packages/standalone/releases/0.169.1-aarch64-apple-darwin/bin/codex"
        XCTAssertEqual(AgentProvider.managedBy(path: path), .native)
    }

    /// agy 官方安装脚本把二进制直接放在 ~/.local/bin 下。
    func testAgyInLocalBinIsNative() {
        XCTAssertEqual(AgentProvider.managedBy(path: "/Users/someone/.local/bin/agy"), .native)
    }
}
