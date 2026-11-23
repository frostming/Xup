# 产品决策记录

- 2026-11-04 Sparkle 应用：Xup 直接解析 appcast、下载 zip/dmg、校验签名后原地替换，必要时请求管理员权限；失败时提示。
- 2026-11-04 形态：纯菜单栏应用（LSUIElement），不占 Dock；主窗口从菜单栏"打开 Xup"进入。
- 2026-11-04 定时检测默认只通知，不自动更新；设置里可开启自动更新。
- 2026-11-04 关注列表：每个来源只检查/更新用户勾选的软件；关注集合为空的来源不检查。应用来源沿用"添加应用"。
- 2026-11-04 新增来源：Skills（Vercel skills CLI）与插件（Claude Code / Codex 插件），作为两个侧栏分区。
- 2026-11-04 v1 不做：下载百分比、停止按钮。
- 2026-11-04 用户再次确认：Homebrew / npm / uv 一律白名单（界面称"关注"），不勾选的不检测、不更新；无勾选的来源整体跳过（不跑 brew update）。
- 2026-11-04 自更新型应用：自动识别 electron-updater；其余可手动配置来源（GitHub Releases / Tauri JSON / latest-mac.yml / appcast）；都没有时提供"启动应用"让其自更新。
- 2026-11-04 部署目标改为 macOS 26，使系统启用 Liquid Glass 新设计（SwiftPM 会把部署目标写入 SDK 字段）。
- 2026-11-04 v1.1 立项：electron-updater blockmap 增量下载（见 docs/ROADMAP-v1.1-blockmap.md）；v1 维持整包。
- 2026-11-04 v1.1 增加：Agent 友好接口（config.json + JSON Schema + `xup` CLI（--json）+ SKILL.md；MCP 可选 v1.2），见 docs/ROADMAP-v1.1-agent-interface.md。
- 2026-11-04 v1.1 交付（1.1.0）：blockmap 增量下载 + Agent 接口（config.json/schema/热加载、`xup` CLI、SKILL.md）。CLI 目标名 xup-cli、二进制放 Contents/Helpers/xup（避免与 Xup 大小写冲突）。
- 2026-11-04 新增功能：更新历史（history.jsonl，最多 2000 条；主窗口"更新历史"视图、菜单栏面板摘要、`xup history` CLI）。
- 2026-11-04 新增需求：每条目可配更新方式——手动（默认）/ 空闲时自动（无键鼠输入 ≥ N 分钟，默认 5）；应用多一个"自动下载，手动重启"（后台下载校验暂存，用户点"安装并重启"才替换；可选子开关：空闲且应用未运行时自动安装）。全局"自动更新"开关改为"新关注条目的默认更新方式"。
- 2026-11-04 IA 调整：主页面显示所有关注条目及当前版本（默认不隐藏"最新"），工具栏加"全部 | 仅可更新"筛选；每个来源分区加"已关注 | 已安装"分段，"已安装"即原设置 › 软件 的勾选清单；设置 › 应用 列表移除（应用管理全在主界面）；设置窗口只保留"通用"一页（Agents 规则作为其中一节）。
- 2026-11-19 Skills 来源可切换管理器（config `skill.manager`，设置 › Skills）：默认 `skills`（Vercel skills CLI），可选 `skm`。同一时间只读一个管理器，`tracked.skill` 共用。skm 不走 GitHub API：在 skm 自己的克隆里 `git fetch`，按 skill 目录比对锁定 commit 之后的提交；本地目录来源不检测，`source_cmd` 来源标为未知（可手动 `skm update`）。
- 2026-11-19 skm 改为按仓库关注：skm 一个仓库只有一份克隆、`skm update <name>` 会 pull 整个仓库并更新同仓库全部 skill，按 skill 关注会顺带更新没勾选的 skill（违反白名单）。添加列表与主列表一行一个仓库，并列出该仓库装了哪些 skill；只要其中任一 skill 目录有新提交即为可更新，状态写明哪些 skill 变了。本地目录与命令生成（source_cmd）的 skill 不列出（无法检测，命令类不做执行比对）。`tracked.skill` 在 skm 下存仓库键，与 skills CLI 的 skill 名不通用。
