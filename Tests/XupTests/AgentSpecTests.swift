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
}
