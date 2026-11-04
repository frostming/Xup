# Xup

macOS 菜单栏常驻的统一更新器。只检查、只更新你**关注**（白名单）的软件：

| 来源 | 检测 | 更新 |
|---|---|---|
| Homebrew | `brew update` + `brew outdated --json=v2`（可选 `--greedy`） | `brew upgrade --formula/--cask <name>` |
| npm 全局 | `npm outdated -g --json` | `npm install -g <name>@latest` |
| uv tool | `uv tool list` + PyPI JSON | `uv tool upgrade <name>` |
| Agents（claude / codex / gemini / opencode / amp / copilot / cursor-agent…） | `<bin> --version` 对比 npm registry；表在 `~/Library/Application Support/Xup/agents.json` 可自行扩展 | 各自的自更新命令（如 `claude update`），由 brew/npm/uv 安装的归入对应来源 |
| Skills（Vercel `skills` CLI） | `~/.agents/.skill-lock.json` + GitHub 该目录是否有新提交 | `npx skills update <name> -g -y` |
| 插件 | Claude Code：`installed_plugins.json` 对比 marketplace；Codex：`codex plugin list` | `claude plugin update -y <name@mkt>`；Codex 暂只检测 |
| 应用（/Applications） | 手动配置来源 > Homebrew cask > Sparkle appcast > electron-updater (`app-update.yml`) > App Store(`mas`) > 由应用自更新 | cask：brew；Sparkle / electron / 自定义：下载 zip/dmg/tar，校验签名后原地替换，必要时请求管理员权限；每个应用可选"运行中处理方式"：自动退出并重新打开（默认）/ 等用户关闭后再更新（`restartAfterUpdate`） |

手动来源支持：GitHub Releases（owner/repo，可选资源名通配）、Tauri 更新 JSON、electron-updater `latest-mac.yml`、Sparkle appcast。

主窗口默认列出**所有已关注的条目及当前版本**（工具栏 `全部 | 仅可更新` 可切换，对应 `ui.showUpToDate`）。添加关注与"应用"分区一致：工具栏 `+`（⇧⌘N）弹出"添加要跟踪的 <来源>"Sheet，列出本机该来源全部已安装软件，勾选即关注（"全部"分区的 `+` 多一个来源切换），点"完成"后自动检查一次；移除用右键"取消关注"或 ⌫。设置窗口只剩 通用（含 Agents 检测规则一节）。

其它：定时检查（间隔可配，默认 6 小时）、发现更新发系统通知、开机启动、纯菜单栏应用（不占 Dock）、**更新历史**（每次更新的成功/失败、版本、耗时、触发方式，侧栏"记录 › 更新历史"，`xup history`）。

**更新方式（每条目）**：每个被关注的条目单独选 `手动更新`（默认）/ `空闲时自动更新`（定时检查发现新版本后等无键鼠输入 N 分钟或锁屏再自动执行）/ 仅应用的 `自动下载，手动重启`（立即后台下载校验并暂存到 `~/Library/Caches/dev.fming.xup/staged/`，列表显示蓝色"已下载 1.5.0 · 待安装"，点"安装并重启"才替换；可选子开关"空闲且应用未运行时自动安装"）。全局只保留"新关注条目的默认更新方式"与"空闲判定"阈值；表格右键"更新方式"、应用配置 Sheet、"添加…"Sheet 已关注行的行尾标签、`xup policy` 都可改。

## 构建与安装

要求：macOS 26+（Liquid Glass 风格），Xcode 26+/Swift 6.x。

```bash
make app        # swift build -c release + 组装 build/Xup.app（ad-hoc 签名）
make run        # 打开 build/Xup.app
make install    # 拷贝到 /Applications
```

没有 .xcodeproj；纯 SwiftPM 工程，`swift build` 即可编译。

## 目录

- `Sources/Xup/Core/` — 模型、Shell 执行器（登录 shell PATH 探测）、UpdateCenter（并发检查 / 按来源串行更新 / 预下载暂存）、Settings（门面，含每条目更新方式）、ConfigStore（config.json 加载/校验/热加载/迁移）、ControlServer（Unix socket 控制通道）、Scheduler（定时检查 + 空闲自动更新调度）、IdleMonitor（空闲判定）、日志文件
- `Sources/xup-cli/` — 独立的 `xup` 命令行（不链接 App 代码）
- `Support/` — Info.plist、`config.schema.json`、面向 agent 的 `SKILL.md`
- `Sources/Xup/Providers/` — 各来源实现；`Sparkle.swift` 含 appcast 解析与 AppInstaller（`prepare` 暂存 / `apply` 替换）；`Staging.swift` 为持久暂存目录与元数据校验；`AppSources.swift` 含 electron / GitHub / Tauri / appcast 的版本与下载地址解析
- `Sources/Xup/UI/` — 主窗口、"添加要跟踪的软件"Sheet（`AddWatchSheet` / `InstalledListView`）、菜单栏面板、设置（通用（含 Agents 检测规则一节））、应用来源配置 Sheet
- `design/` — 设计规范 `DESIGN.md` 与 HTML 原型；`ACCEPTANCE.md`、`DECISIONS.md` 为验收与决策记录

## Agent 接口（v1.1）

Claude Code / Codex 等 agent 不必点界面即可管理 Xup：

- **配置文件即事实来源**：`~/Library/Application Support/Xup/config.json`（关注列表、应用列表与来源、全部开关），同目录有 `config.schema.json`（JSON Schema 2020-12，字段带说明）。App 监听文件变化，0.5 秒内热加载并校验；非法内容不生效，原因写入日志，写入前自动备份 `config.json.bak`。首次启动自动把 v1.0 的 UserDefaults 迁移进来。
- **命令行 `xup`**：内置于 `Xup.app/Contents/Helpers/xup`，`make install` 时软链到 `~/.local/bin/xup`（`make uninstall-cli` 移除）。全部子命令支持 `--json`，退出码 0/1/2。

```bash
xup config get check.intervalMinutes      # 直接读写 config.json（按 schema 校验）
xup config set check.intervalMinutes 720
xup track add homebrew:node uv:nox        # 关注名：<kind>:<name>，homebrew 用 token
xup installed npm --json                  # 本机已安装、可加入关注的清单
xup apps add /Applications/Kaze.app --source "github:owner/kaze#*arm64*.dmg"
xup apps probe-source /Applications/Kaze.app "github:owner/kaze" --json
xup status --json                         # 上次检查、各来源可更新数、条目摘要
xup check --kind uv --wait --json         # 触发检查并等待结果
xup update uv:nox --wait --yes --json     # 更新需 --yes（或 config agent.allowUpdates=true）；staged 的应用直接安装
xup policy set uv:nox auto                # 更新方式：manual / auto / auto-download（仅应用，可加 --install-when-idle on）
xup policy list --json                    # 每条目的生效策略与默认值
xup stage app:/Applications/IINA.app --wait  # 预下载暂存，不替换、不退出应用
xup log --tail 50 --errors
xup history --tail 20 --failed --json     # 更新历史（时间、from→to、结果、触发方式）；xup history clear --yes 清空
xup skill install                         # 安装 SKILL.md 到 ~/.agents/skills/xup 与 ~/.claude/skills/xup
```

运行时命令通过 Unix socket `~/Library/Application Support/Xup/control.sock`（0600，每行一个 JSON 请求/响应）调用 App；App 未运行时 CLI 自动 `open -gj` 拉起（`XUP_APP_PATH` 可指定）。条目 id 形如 `homebrew:formula/node`、`homebrew:cask/iina`、`npm:typescript`、`uv:nox`、`agent:claude`、`skill:<name>`、`plugin:claude/<name@mkt>`、`app:/Applications/Foo.app`。完整说明见 `Support/SKILL.md`。

## 排查

- 日志：`~/Library/Logs/Xup/xup.log`（界面日志面板的持久化副本）
- 更新历史：`~/Library/Application Support/Xup/history.jsonl`（每行一条 JSON，最多保留 2000 条；主窗口"更新历史"与 `xup history` 读取同一文件）
- 配置：`~/Library/Application Support/Xup/config.json`（schema 同目录；`xup config validate` 可校验）；UserDefaults 域 `dev.fming.xup` 只剩 `lastCheckedAt`、`hasSeenWatchPicker` 与窗口状态。旧字段 `check.autoUpdate` 会在首次加载时迁移为 `check.defaultPolicy` + `policies`
- 暂存的应用新版本：`~/Library/Caches/dev.fming.xup/staged/<bundleID>/<version>/`（设置 › 通用 可一键清除）
- 调试环境变量：`XUP_DEBUG_OPEN_WINDOW=1` 启动即开主窗口；`XUP_DEBUG_SIDEBAR=<kind|history>` 指定启动时的分区；`XUP_DEBUG_UPDATE=<id,...>` 首次检查后自动更新指定条目（id 形如 `uv:nox`、`homebrew:formula/act`、`app:/Applications/IINA.app`）
