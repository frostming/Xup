---
name: xup
description: 用 `xup` 命令行管理 macOS 更新器 Xup：查看/修改关注列表、受管应用与设置（config.json），触发检查与更新并读取结构化 JSON 结果。当用户提到 Xup、"把 X 加入关注/跟踪"、"检查更新"、"升级 brew/npm/uv 包"、"给某个 .app 配置更新来源"时使用。
---

# Xup CLI（`xup`）

Xup 是菜单栏常驻的统一更新器，只检查/更新用户**关注**的软件（Homebrew、npm 全局、uv tool、agent CLI、skills、插件、/Applications 下的应用）。
`xup` 是随 App 内置的命令行（`Xup.app/Contents/Helpers/xup`，`make install` 后软链到 `~/.local/bin/xup`）。

- **所有命令支持 `--json`**，agent 应始终加 `--json` 并解析输出。
- 退出码：`0` 成功 / `1` 失败 / `2` 参数错误。错误信息在 stderr；`--json` 时 stdout 还会有 `{"ok":false,"error":"…"}`。
- 纯配置命令（`config` / `track` / `apps list|add|remove|set-source`）直接读写 config.json，不需要 App 在运行；运行中的 App 会在 0.5 秒内热加载并自动重新检查。
- 其余命令通过本机 Unix socket 调用 App；App 未运行时会自动用 `open -gj` 拉起（候选路径：`$XUP_APP_PATH` → CLI 所在的 .app → `/Applications/Xup.app`）。

## 配置文件

- 路径：`~/Library/Application Support/Xup/config.json`（`xup config path`）
- Schema：同目录 `config.schema.json`（`xup config schema`），字段均带中英文 `description`
- 每次写入前自动备份为 `config.json.bak`；写入内容会按 schema 校验，类型错误 / 未知字段会被拒绝
- 也可以直接编辑文件；非法内容不会生效，App 日志（`xup log --errors`）会说明原因

结构概览：

```json
{
  "$schema": "./config.schema.json",
  "version": 1,
  "check":    { "intervalMinutes": 360, "notify": true, "autoUpdate": false },
  "homebrew": { "greedy": false },
  "ui":       { "showUpToDate": false, "launchAtLogin": false },
  "electron": { "deltaDownload": true, "keepVersionsPerApp": 1 },
  "agent":    { "allowUpdates": false },
  "tracked":  { "homebrew": ["node"], "npm": [], "uv": ["nox"], "agent": ["claude"], "skill": [], "plugin": [] },
  "apps": [
    { "path": "/Applications/IINA.app", "restartAfterUpdate": true, "source": null },
    { "path": "/Applications/Kaze.app", "restartAfterUpdate": true,
      "source": { "type": "githubReleases", "repo": "owner/repo", "assetPattern": "*arm64*.dmg" } }
  ]
}
```

`source` 的四种形态：`{"type":"githubReleases","repo":"owner/repo","assetPattern":"*.dmg"}`、`{"type":"tauri","url":"https://…/latest.json"}`、`{"type":"electronYML","url":"https://…/latest-mac.yml"}`、`{"type":"appcast","url":"https://…/appcast.xml"}`；`null` 表示自动识别。

## ID 与名称规则

| 来源 (kind) | 条目 id（status/items/update 使用） | 关注名（track 使用：`<kind>:<name>`） |
|---|---|---|
| homebrew | `homebrew:formula/<name>`、`homebrew:cask/<name>` | token，如 `homebrew:node`、`homebrew:iina`（`brew:` 为别名） |
| npm | `npm:<pkg>` | 包名，如 `npm:typescript`、`npm:@openai/codex` |
| uv | `uv:<tool>` | `uv:nox` |
| agent | `agent:<binary>` | `agent:claude`（agents.json 中的 binary） |
| skill | `skill:<name>` | `skill:ui-ux-pro-max` |
| plugin | `plugin:claude/<name@marketplace>`、`plugin:codex/<name@marketplace>` | `plugin:claude/nowledge-mem@nowledge-community` |
| app | `app:/Applications/Foo.app` | 不用 track；用 `xup apps add <path>` |

`xup installed <kind> --json` 列出本机已安装、可加入关注的名称（即关注名），每项含 `name`、`version`、`tracked`、可选 `detail`。

## 命令速查

```
xup config get [path] | set <path> <json> | unset <path> | validate | schema | path
xup track list | add <kind>:<name>... | remove <kind>:<name>...
xup installed <kind>
xup apps list | add <path> [--restart|--no-restart] [--source <spec>] | remove <path>... | set-source <path> <spec> | probe-source <path> <spec>
xup status
xup items [--kind k]
xup check [--kind k,...] [--wait]
xup update <id>... | --all [--wait] [--yes]
xup log [--tail N] [--errors]
xup launch <app-path>
xup reload-config
xup skill install | show | path
```

来源 spec：`github:owner/repo[#assetPattern]`（也接受 GitHub URL）、`tauri:<url>`、`electron:<url>`（目录 URL 自动补 latest-mac.yml）、`appcast:<url>`、`auto`。

## 典型流程

把一个 uv tool 加入关注并检查：

```bash
xup installed uv --json | jq '.[].name'          # 看有哪些可选
xup track add uv:nox                             # 写 config.json，App 自动热加载
xup check --kind uv --wait --json | jq '.items[] | select(.status=="outdated")'
```

更新指定条目（需要用户确认意图；见"安全约定"）：

```bash
xup update homebrew:formula/node uv:nox --wait --yes --json
# 结果含 succeeded / failed / items / log（本次更新期间的 App 日志）
```

给无法自动识别的应用配置 GitHub Releases 来源并验证：

```bash
xup apps add /Applications/Kaze.app --source "github:owner/kaze#*arm64*.dmg"
xup apps probe-source /Applications/Kaze.app "github:owner/kaze#*arm64*.dmg" --json
# {"latest":"1.2.3","downloadURL":"https://github.com/…/Kaze-1.2.3-arm64.dmg","installed":"1.2.0","isNewer":true}
```

修改全局设置：

```bash
xup config get check.intervalMinutes
xup config set check.intervalMinutes 720
xup config set homebrew.greedy true
xup config set apps.0.restartAfterUpdate false   # 应用在运行时：false = 跳过本次更新等用户关闭，true（默认）= 自动退出并重新打开
```

查看状态与日志：

```bash
xup status --json          # lastChecked / isChecking / counts.byKind / items 摘要 / unavailable / providerErrors
xup items --kind homebrew --json
xup log --tail 100 --errors
```

## 安全约定

- `xup update` 会真正修改本机软件（brew upgrade、npm install -g、替换 /Applications 下的应用，可能退出正在运行的应用）。**没有用户明确授权时不要执行**；执行时必须带 `--yes`，或由用户在配置中设置 `agent.allowUpdates: true`。
- 替换应用时 Xup 会先下载校验，再确认进程未运行后替换，必要时弹出管理员授权；`--wait` 返回完整日志，失败原因在 `failed` 与 `log` 中。
- `config set` 只能写 schema 允许的字段；`$schema`、`version` 由 Xup 维护。
- 默认不要改 `check.autoUpdate`、`agent.allowUpdates` 这类放宽安全边界的开关，除非用户要求。
- 只检查而不更新是安全的：`xup check --wait --json` 只读网络，不改本机。
