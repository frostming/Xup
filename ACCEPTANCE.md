# Xup 验收清单

## A. 设计稿（design/）
- [x] DESIGN.md 覆盖：主窗口、菜单栏面板、设置、状态（空/检查中/全部最新/失败）
- [x] 全部控件在 SwiftUI macOS 14 上可直接实现（NavigationSplitView / Table / MenuBarExtra(.window) / Settings TabView）
- [x] 状态徽标颜色与 SF Symbol 明确；ProviderKind 图标明确
- [x] 浅色/深色两套
- [x] HTML mockups 4 个可打开，与 DESIGN.md 一致

## B. 核心层
- [x] `swift build` 零错误
- [x] `scripts/build-app.sh` 产出可运行的 build/Xup.app
- [x] UpdateCenter：并发检查、同 kind 串行更新、日志上限、错误落到 providerErrors
- [x] Homebrew 不可用时 Apps provider 不死等
- [x] Settings 持久化；agents.json 首次生成
- [x] Scheduler：间隔可配、通知去重、autoUpdate 可选

## C. UI（按设计稿）
- [x] 侧栏角标、列表多选、更新选中/全部更新、日志面板
- [ ] 应用分区：添加应用、重启开关、移除
- [x] 菜单栏面板：数量、摘要、操作按钮
- [ ] 设置三个 Tab 全部绑定真实设置

## D. 真机验收（本机）
- [x] 检查更新：brew/npm/uv/agents 均列出真实结果
- [x] 添加 IINA.app（Sparkle）后能识别版本与最新版（1.3.4 → 1.5.0）
- [ ] 添加 OrbStack.app（brew cask）识别为 cask
- [x] 实际更新一个低风险条目成功：uv tool nox 2025.11.12 → 2026.10.20
- [x] 更新后重启流程：IINA 运行中 → 退出 → 下载 dmg → 校验签名 → 替换 → 自动重启（10:53–10:54）
- [ ] 通知在 .app 内可弹出

## E. 验收过程中发现并修复的缺陷（主代理）
- MenuBarExtra label 使用 TimelineView/opacity/胶囊背景 → 状态栏按钮无限刷新，主线程卡死（已改为纯 Image/Label）。
- `Shell.stripANSI` 正则在原始字符串里 `\u{1B}` 未转义 → brew 彩色输出触发 `try!` 崩溃（已改为预编译正则）。
- PATH 探测用 `$SHELL -ilc`：宿主 $SHELL 为 bash 且非交互不加载 .zshrc，结果选中 /usr/local/bin 的 Intel brew；已改为读取账户登录 shell（getpwuid）+ 显式 source rc，并把 /opt/homebrew/bin 置于最前、探测移出主线程。
- 表格列总宽超出 920 窗口 → 调整列宽。

## F. 新增需求（2026-11-04 用户提出）
- [x] 关注列表：只检查/更新用户选择的软件（日志确认未关注来源全部跳过）
- [x] Skills 来源（Vercel skills CLI，~/.agents/.skill-lock.json）——Sheet 可读取 32 项；检测逻辑已实现，未做真实更新
- [x] 插件来源（Claude Code 插件 / Codex 插件）——列表解析已验证；Codex 仅检测

## G. 待查/后续
- act：首次真机测试中 `brew upgrade --formula act` 后 act 从 Cellar 消失（0.2.96 bottle 已下载但未安装），已手动 `brew install act` 恢复。当时日志未持久化，原因未明；现已把日志写入 ~/Library/Logs/Xup/xup.log，下次复现可查。
- Sparkle appcast 含 delta enclosure 时取错下载地址（已修：跳过 sparkle:deltaFrom）。
- 应用更新失败后未重新拉起被我们退出的应用（已修：defer 重启）。
- [x] 应用自更新来源：electron-updater 自动识别 + 手动配置 + "启动应用"兜底
- [x] 真机验证 Alma（electron-updater，0.4.421 下载替换成功，见 H 节）；Nowledge Mem 仅做了来源探测（Tauri 端点解析 0.10.113），未做真实更新

## H. Alma（electron-updater）真机测试复盘（2026-11-04 11:16–11:35）
- 识别与下载替换成功：0.4.414 → 0.4.421，zip 413 MB，7 分钟；签名校验通过。
- 问题 1：terminate 15s 超时后 forceTerminate，但下载期间 Alma 被再次启动（pid 15004），替换时该进程仍在运行；随后 LaunchServices 残留其注册（lsappinfo 显示 !signalled），Alma 任何启动都 100ms 内退出 0（改 bundle id 可运行 → 证实）。用户从 Finder 启动后残留被顶掉，恢复正常。
- 问题 2：更新后"重新启动"用 try? 吞错，无日志。
- 处理：已从 Alma 自身缓存恢复 0.4.414；0.4.421 完整包保存在 /tmp/Alma-0.4.421.app；加固任务进行中（先下载后退出、替换前二次确认、重启重试与日志、幽灵注册检测）。
- 附带发现：Alma 自己的 electron-updater 今早也是整包下载（缓存里 alma-0.4.414-mac-arm64.zip 413 MB），并非增量。

## I. 加固后回归（2026-11-04 11:37）
- Typora 1.14.10 → 1.14.15（Sparkle，运行中）：先下载 15.2 MB（2.3s）→ 挂载 → 校验签名 → 暂存 → 替换前退出（terminate 0.3s 完成）→ 替换 0.2s → 重启并确认新 pid 存活。总用时 7 秒，应用离线窗口不到 1 秒。
- 白名单：uv 2 项、npm 1 项、brew 1 项按预期只检查关注项。

## J. v1.1 验收（2026-11-04 12:20）
### blockmap 增量下载
- [x] 单元测试 16 个（gzip/blockmap 解析、差分计划、Range 合并、拼装、回退、缓存）全部通过
- [x] 真实增量：Alma 0.4.414（应用自身缓存作基准）→ 0.4.422：复用 339.8 MB，下载 54.6 MB（14%），17.4 秒，sha512 与 feed 一致并经 shasum 复核；整包 413.5 MB 约 7 分钟
- [ ] App 内端到端（需用户同意再次更新正在使用的 Alma）
### Agent 接口
- [x] config.json + schema + 热加载 + 从 UserDefaults 迁移（9 个单元测试）
- [x] `xup status/track/installed/check/config/apps probe-source` 端到端通过；App 由 CLI 自动拉起
- [x] 非法字段、类型错误、未带 --yes 的 update 均被拒绝（exit 1）
- [x] SKILL.md 已安装到 ~/.agents/skills/xup 与 ~/.claude/skills/xup
- [x] 目标名 Xup/xup 大小写冲突：CLI 目标改名 xup-cli，二进制放 Contents/Helpers/xup
