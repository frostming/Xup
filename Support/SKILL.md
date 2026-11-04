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
  "check":    { "intervalMinutes": 360, "notify": true, "defaultPolicy": "manual", "idleMinutes": 5 },
  "homebrew": { "greedy": false },
  "ui":       { "showUpToDate": false, "launchAtLogin": false },
  "electron": { "deltaDownload": true, "keepVersionsPerApp": 1 },
  "agent":    { "allowUpdates": false },
  "tracked":  { "homebrew": ["node"], "npm": [], "uv": ["nox"], "agent": ["claude"], "skill": [], "plugin": [] },
  "apps": [
    { "path": "/Applications/IINA.app", "restartAfterUpdate": true, "installWhenIdle": false, "source": null },
    { "path": "/Applications/Kaze.app", "restartAfterUpdate": true, "installWhenIdle": false,
      "source": { "type": "githubReleases", "repo": "owner/repo", "assetPattern": "*arm64*.dmg" } }
  ],
  "policies": { "homebrew:node": "auto", "uv:nox": "auto", "app:/Applications/IINA.app": "autoDownload" }
}
```

`policies` 是每条目的**更新方式**（见下文），键为条目 id；缺省条目取 `check.defaultPolicy`。旧字段 `check.autoUpdate` 已废弃：App 读到 `true` 会迁移为 `defaultPolicy: "auto"` 并给当时所有条目写 `auto`，然后删除旧键。

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
xup stage <id>... [--wait]
xup policy list | get <id> | set <id>... manual|auto|auto-download [--install-when-idle on|off]
xup log [--tail N] [--errors]
xup history [--tail N] [--failed] [--kind k] | clear --yes
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

## 更新方式（每条目策略）

每个被关注的条目单独选更新方式；全局只有"新关注条目的默认值"（`check.defaultPolicy`，`manual` / `auto`）与空闲阈值（`check.idleMinutes`，1–60 分钟）。

| 值 | 含义 | 适用 |
|---|---|---|
| `manual`（默认） | 定时检查只把条目标为可更新并通知，用户点"更新"才执行 | 所有条目 |
| `auto` | 定时检查发现新版本后，等系统**空闲**（无键鼠输入 ≥ idleMinutes 分钟，或锁屏/屏保）再自动执行；应用遵循 `restartAfterUpdate` | 所有条目 |
| `autoDownload` | 发现新版本立即后台下载、校验并暂存（`~/Library/Caches/dev.fming.xup/staged/<bundleID>/<version>/`），**不替换、不退出应用**；条目状态变为 `staged`，`xup update <id>` / 界面"安装并重启"才替换。子开关 `apps[].installWhenIdle` 打开时，空闲且应用未运行会自动完成安装 | 仅 Sparkle / electron-updater / 手动配置来源的应用；cask / App Store / 自更新读到时按 `auto` 处理并写日志 |

```bash
xup policy list --json                                  # {defaultPolicy, idleMinutes, items:[{id, policy, inherited, installWhenIdle?}]}
xup policy get uv:nox --json
xup policy set uv:nox homebrew:node auto                 # 直接写 config.json，App 热加载
xup policy set app:/Applications/IINA.app auto-download --install-when-idle on
xup config set check.defaultPolicy auto                 # 只影响之后新关注的条目
xup config set check.idleMinutes 10
xup stage app:/Applications/IINA.app --wait --json      # 立即预下载（只下载暂存，不替换、不退出应用）
xup items --kind app --json | jq '.[] | select(.status=="staged")'   # 含 stagedVersion / policy
xup update app:/Applications/IINA.app --wait --yes      # staged 条目直接安装（退出 → 替换 → 重开），不再下载
```

- 只有**定时检查**（含启动首检）会触发 `auto` / `autoDownload` 的自动行为；`xup check` 与界面"检查更新"不触发。
- `xup status --json` 的 `items[].policy` 为生效策略（含降级），`counts.staged` 为待安装数，`pendingAuto` 为正在等空闲的条目 id。
- 取消关注 / 移除应用会同时删除其 `policies` 记录与暂存；暂存超过 30 天或远端版本变化会作废并在下次检查重新下载。
- homebrew 条目的键可写 `homebrew:node`（不区分 formula/cask）或 `homebrew:formula/node`；`brew:` 为别名。

## 更新历史

每次 `update`（无论界面、CLI 还是定时自动更新）成功或失败都会记一条到 `~/Library/Application Support/Xup/history.jsonl`（每行一条 JSON，最多保留 2000 条）。主窗口侧栏"记录 › 更新历史"与下列命令读的是同一份数据：

```bash
xup history --json                       # 最近 50 条，按时间倒序
xup history --tail 200 --failed --json   # 只看失败；--kind homebrew|npm|uv|agent|skill|plugin|app 按来源过滤
xup history clear --yes                  # 清空（不可撤销，必须 --yes）
```

每条记录的字段：`id`、`time`（ISO8601）、`kind`、`itemID`（与 `items` 的 id 一致，可直接用于 `xup update`）、`name`、`detail`（可选）、`fromVersion`、`toVersion`（失败时省略）、`duration`（秒）、`ok`、`error`（失败原因，成功时省略）、`trigger`（`manual` 界面 / `cli` 命令行 / `scheduled` 定时自动更新 / `auto` 启动时自动更新）。

排查"昨天自动更新把什么弄坏了"时：`xup history --failed --json | jq '.[] | {time,itemID,fromVersion,error}'`，再用 `xup update <itemID> --wait --yes --json` 重试。

## 安全约定

- `xup update` 会真正修改本机软件（brew upgrade、npm install -g、替换 /Applications 下的应用，可能退出正在运行的应用）。**没有用户明确授权时不要执行**；执行时必须带 `--yes`，或由用户在配置中设置 `agent.allowUpdates: true`。
- 替换应用时 Xup 会先下载校验，再确认进程未运行后替换，必要时弹出管理员授权；`--wait` 返回完整日志，失败原因在 `failed` 与 `log` 中。
- `config set` 只能写 schema 允许的字段；`$schema`、`version` 由 Xup 维护。
- 默认不要改 `check.defaultPolicy`、`policies` 里的 `auto` / `autoDownload`、`agent.allowUpdates` 这类放宽安全边界的设置，除非用户要求；`xup stage` 只下载不替换，是安全的。
- 只检查而不更新是安全的：`xup check --wait --json` 只读网络，不改本机。
