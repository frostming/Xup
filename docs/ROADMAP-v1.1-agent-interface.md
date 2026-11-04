# v1.1 立项：Agent 友好接口（让 agent 能读写 Xup 配置、触发检查/更新）

立项日期：2026-11-04（用户拍板）

## 目标
Claude Code / Codex 等 agent 不需要点 UI，就能：查看与修改关注列表、应用列表与来源配置、全局设置；触发检查与更新并拿到结构化结果。

## 方案
1. **配置落为可读文件（单一事实来源）**
   - `~/Library/Application Support/Xup/config.json`，取代 UserDefaults 中的 `tracked` / `managedApps` / 通用设置（UserDefaults 只留窗口状态等 UI 偏好）。
   - 附 JSON Schema `config.schema.json`（随 app 内置并导出到同目录），字段带中文/英文说明；agent 可直接按 schema 写文件。
   - App 用 `DispatchSource` 监听文件变化，热加载并校验；非法内容不生效并写告警到日志与通知。
   - 首次启动自动迁移现有 UserDefaults 数据。
2. **命令行 `xup`**（内置于 `Xup.app/Contents/MacOS/xup`，`make install` 时软链到 `/usr/local/bin` 或 `~/.local/bin`）
   - 所有子命令支持 `--json`，退出码语义明确（0 成功 / 1 失败 / 2 参数错误）。
   - `xup config get [path]` / `xup config set <path> <value>` / `xup config edit`（按 schema 校验后写入）
   - `xup track list|add|remove <kind>:<name>...`（如 `brew:node`、`npm:typescript`、`uv:nox`、`skill:ui-ux-pro-max`、`plugin:claude/nowledge-mem@nowledge-community`）
   - `xup installed <kind> --json`（列出可勾选的已安装清单，等价"选择软件"Sheet 的数据）
   - `xup apps add <path> [--restart] [--source github:owner/repo[#pattern] | tauri:<url> | electron:<url> | appcast:<url>]` / `xup apps remove|set-source|probe-source`
   - `xup check [--kind ...] --json` / `xup status --json` / `xup update <id>... [--all] --json --wait`
   - `xup log [--tail N] [--errors]`
   - 实现方式：CLI 与 App 通过本机 XPC/Unix socket 通信（App 在运行时执行，CLI 只做封装）；App 未运行时 CLI 自动拉起（`open -gj`）或对纯配置操作直接读写文件。
3. **Agent 发现与引导**
   - 随 app 提供 `SKILL.md`（放 `~/.agents/skills/xup/` 或 `claude plugin` 形式），说明命令、id 规则、schema 位置与典型流程（"把 X 加入关注并更新"）。
   - `xup --help` 与 `xup schema` 输出机器可读说明。
   - 可选（v1.2）：MCP server 模式 `xup mcp`，暴露同样能力为工具。
4. **安全边界**
   - 更新类操作默认需要 `--yes` 或在配置里 `allowAgentUpdates: true`；配置写入会做 schema 校验与备份（`config.json.bak`）。
   - 应用替换类操作在 CLI 触发时同样走"先下载校验、替换前确认无进程"的流程并返回完整日志。

## 验收标准
- agent 仅通过 `xup` 命令完成：添加 brew/npm 关注 → 检查 → 更新 → 读取结果 JSON；为某应用配置 GitHub 来源并 `probe-source` 返回最新版本。
- 直接编辑 `config.json` 后 2 秒内 App 界面同步；写入非法字段时被拒绝且有日志。
- `SKILL.md` 按说明能被 Claude Code 自动采用。

## 预估
配置文件 + 迁移 + 热加载 1 天；CLI（含 XPC）1.5 天；SKILL.md 与文档 0.5 天。
