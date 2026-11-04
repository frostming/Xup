# Xup 设计规范

> 目标平台：macOS 14+，SwiftUI 原生。本文档中的尺寸单位为 pt，字体用 SwiftUI 语义字体，颜色用系统语义色。所有文案为简体中文。配套静态原型见 `mockups/`（浅/深色可切换，仅供开发对照，不代表像素级实现）。

---

## 0. 设计原则

1. **像系统自带工具一样安静**：Xup 常驻菜单栏，绝大多数时间用户不打开主窗口。界面只用系统色、系统控件、SF Symbols，不做任何自定义渐变/阴影/卡片。
2. **状态一眼可读**：每行一个状态徽标（颜色 + 符号 + 文字），颜色语义全局统一（橙 = 待处理，绿 = 已完成/正常，红 = 出错，灰 = 不确定）。
3. **可操作性显式化**：不能更新的条目（pinned、无更新命令、来源不可识别）不是"藏起来"，而是以灰色 + `hint` 说明原因，并禁用其更新操作。
4. **日志不打扰、但随手可见**：日志区默认折叠为一条状态行；运行命令时自动展开，可拖拽高度，可手动关闭。

---

## 1. 信息架构

```
Xup (MenuBarExtra, .window 样式)
├── 菜单栏面板（MenuBarPanel）
│   ├── 摘要：N 个可更新 · 上次检查时间
│   ├── 前 5 条可更新项（点击 → 打开主窗口并选中该项）
│   └── 操作：检查更新 / 全部更新 / 打开 Xup / 设置… / 退出
│
├── 主窗口（MainWindow）  NavigationSplitView
│   ├── 侧栏（Sidebar）
│   │   ├── 全部                        badge: 总可更新数
│   │   └── 来源（每个来源各有一个"关注集合"，只检查/更新被关注的条目，见 §13）
│   │       ├── Homebrew   (mug)                    badge
│   │       ├── npm 全局   (shippingbox)            badge
│   │       ├── uv tool    (bolt)                   badge
│   │       ├── Agents     (cpu)                    badge
│   │       ├── Skills     (sparkles)               badge   ← 新增，§14.1
│   │       ├── 插件       (puzzlepiece.extension)  badge   ← 新增，§14.2
│   │       └── 应用       (macwindow)              badge
│   ├── 内容（Detail）
│   │   ├── 工具栏：检查更新 · 更新选中 · 全部更新 · [选择软件… | 添加应用…] · 搜索 · 日志开关
│   │   ├── 列表（Table，多选）
│   │   ├── 状态栏（一行，.caption）
│   │   └── 日志面板（VSplitView 下半区，可折叠）
│   ├── 选择软件… Sheet（WatchPickerSheet，560×480，§13）
│   └── 空状态 / 首次启动 / 关注集合为空 / 无可用来源 覆盖视图（ContentUnavailableView）
│
└── 设置窗口（Settings, TabView）
    ├── 通用  (gear)
    ├── Agents (cpu)
    └── 应用  (macwindow)
```

### 数据 → 界面映射（对应 `Models.swift`）

| 模型字段 | 界面呈现 |
|---|---|
| `ProviderKind.title / symbol` | 侧栏行文字与图标；列表行的来源列（仅在"全部"视图显示）。新增 `skill`（Skills · `sparkles`）与 `plugin`（插件 · `puzzlepiece.extension`） |
| `WatchList[kind]: Set<String>` | 每个来源的关注集合（§13）。只有集合内的条目会出现在列表、被检查与更新；集合为空 → 该来源不检查，显示 §6.9 空状态 |
| `UpdateItem.name` | 行主标题 `.body` |
| `UpdateItem.detail` | 行副标题 `.caption` `.secondary`（如 `formula` / `cask` / `Sparkle · iina.io` / `~/.npm-global/bin/claude`） |
| `installed` / `latest` | 版本列，等宽数字 `.monospacedDigit()`；latest 为 nil 显示 `—` |
| `status` | 状态徽标（见 §3） |
| `status.message` | 徽标后灰色说明文字；悬停显示完整 tooltip（`.help()`） |
| `canUpdate == false` | 行内更新按钮禁用；全选/全部更新时自动跳过 |
| `hint` | 状态文字后以 `·` 分隔追加，`.caption` `.tertiary`，如 `已 pin，跳过` |
| `isActionable` | 决定是否被"全部更新"和复选框计入 |
| `ManagedApp.restartAfterUpdate` | 界面上呈现为"应用运行时…"二选一（§17）：右键子菜单 / 设置 › 应用 的 Picker |
| `LogLine` | 日志面板一行：时间 · 来源 tag · 文本；`isError` 为红色 |

---

## 2. 主窗口

### 2.1 窗口

- 默认尺寸 **920 × 640**，最小 **760 × 480**。`.windowResizability(.contentMinSize)`。
- 标题栏：`navigationTitle("Xup")`，副标题 `navigationSubtitle` 显示当前分区名与计数（如"Homebrew · 3 个可更新"）。
- 工具栏样式 `.toolbar(.unified)`；侧栏开关按钮由 NavigationSplitView 自带。
- **Xup 是纯菜单栏应用**（Info.plist `LSUIElement = YES`，不占 Dock、无 ⌘Tab 条目）。主窗口唯一入口是菜单栏面板的"打开 Xup"（以及通知点击、面板中点击某条目）。关闭主窗口不会退出 App，菜单栏图标与定时检查继续运行；退出只能通过面板的"退出 Xup"或 ⌘Q。
- 因为没有 Dock，主窗口不需要考虑 Dock 角标、Dock 菜单等场景；首次启动时应自动打开主窗口一次（显示 §6.1 欢迎态），之后由用户按需打开。打开主窗口时调用 `NSApp.activate(ignoringOtherApps: true)` 使其前置。

### 2.2 侧栏（NavigationSplitView sidebar）

- 宽度：`navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)`。
- `List(selection:)` + `.listStyle(.sidebar)`，Section 标题"来源"。
- 行：`Label(kind.title, systemImage: kind.symbol)`，右侧 `.badge(outdatedCount)`（count 为 0 时不显示）。
- "全部"行放在 Section 之外，图标 `square.grid.2x2`。
- 不可用来源（`isAvailable() == false`，如未安装 uv）：仍显示但 `.foregroundStyle(.tertiary)`，无 badge，悬停提示"未检测到 uv"。点击后内容区显示该来源的"不可用"空状态（§6.3）。
- 正在检查某来源时，该行 badge 位置显示 `ProgressView().controlSize(.mini)`。
- 来源顺序固定：Homebrew · npm 全局 · uv tool · Agents · Skills · 插件 · 应用（`⌘1…8`，`⌘1` 为"全部"）。
- **关注集合为空**的来源（§13）：正常颜色显示，无 badge，悬停提示"未选择要跟踪的软件"；点击后内容区显示 §6.9 空状态。与"不可用"（灰色）区分：可用但未选择 ≠ 未安装。
- Skills 不可用判定：`~/.agents/.skill-lock.json` 不存在且 PATH 中无 `skills`；插件不可用判定：PATH 中既无 `claude` 也无 `codex`。

### 2.3 工具栏（内容区）

从左到右（`ToolbarItemGroup(placement: .primaryAction)`）：

| 按钮 | Symbol | 说明 |
|---|---|---|
| 检查更新 | `arrow.clockwise` | 检查中变为 `ProgressView().controlSize(.small)` + 禁用；`⌘R` |
| 更新选中 | `arrow.down.circle` | 选中集合中 `isActionable` 数量为 0 时禁用；标题动态为"更新选中 (3)"；`⌘U` |
| 全部更新 | `arrow.down.to.line` | 当前分区无可更新项时禁用；`⇧⌘U`；点击前若 > 5 项弹确认 Alert |
| 添加应用… | `plus` | **仅在"应用"分区显示**；打开 NSOpenPanel（`/Applications`，仅 `.app`，多选）；`⌘N` |
| 添加 <来源>… | `plus` | ~~"选择软件…" `checklist`，打开 §13 的 Sheet~~ → **§21**：在"全部"与除"应用"外的所有来源分区显示，与"添加应用…"互斥占同一位置；tooltip "添加 Homebrew…"（"全部"为"添加软件…"）；弹出 §21.2 的 `AddWatchSheet`（"全部"时带来源 Picker）；`⇧⌘N`。更新进行中禁用 |
| 搜索 | `.searchable(text:placement: .toolbar)` | 过滤 name / detail |
| 日志 | `terminal` | `Toggle` 样式按钮，控制日志面板显隐；`⌥⌘L` |

更新中（任一条目 `.updating`）时："检查更新 / 更新选中 / 全部更新"均禁用，工具栏右侧出现"停止"按钮（`stop.circle`，红色 destructive）。

### 2.4 列表（Table）

使用 `Table(items, selection: $selection)`，多选，`.tableStyle(.inset(alternatesRowBackgrounds: true))`。行高约 **40**（两行文字）。

| 列 | 宽度 | 内容 |
|---|---|---|
| ☐ | 24 | `Toggle(isOn:)` `.toggleStyle(.checkbox)`，仅 `isActionable` 可勾选，否则隐藏（留白） |
| 名称 | 弹性，min 200 | 上：`name` `.body`；下：`detail` `.caption` `.secondary`，单行截断（`.truncationMode(.middle)` 适合路径）。"全部"视图下名称前增加 16pt 的来源 symbol（`.secondary`） |
| 已安装 | 110 | `installed`，`.body.monospacedDigit()`，`.secondary` |
| 最新 | 110 | `latest ?? "—"`；当 `status == .outdated` 时 `.primary` 且 `.fontWeight(.medium)`，否则 `.secondary` |
| 状态 | 160 | 状态徽标 §3 + message/hint |
| 操作 | 84 | 悬停或选中时显示：`更新` 按钮（`.buttonStyle(.bordered)` `.controlSize(.small)`），不可更新时为灰色 `信息` 图标 `info.circle`（点击显示 Popover 说明 hint）。应用分区额外有"更新后重启"Toggle（`.toggleStyle(.switch)` `.controlSize(.mini)`） |

- 表头可点击排序：默认按状态（**待安装** → 可更新 → 失败 → 未知 → 更新中 → 已更新 → 最新）再按名称（§19.4）。
- 列表排序可切换，但**可更新项永远在"最新"项之前**（除非用户显式按名称排序）。
- "显示已是最新的条目"关闭时（设置项），`.upToDate` 行隐藏，状态栏仍统计。
- 右键菜单（`contextMenu`）：更新 / 在 Finder 中显示（应用、Agent 的二进制路径；Skills 为 `~/.agents/skills/<name>`）/ 复制名称 / 复制版本 / **取消关注**（`eye.slash`，非应用分区；从关注集合移除并立即从列表消失，支持 ⌘Z）/ （应用）移除。"取消关注"与"移除"语义等价，只是应用分区沿用旧文案。
- 应用分区右键菜单额外有 **启动应用**（`play.circle`）与 **配置更新来源…**（`slider.horizontal.3`），见 §16。
- 双击行：若可更新则更新该项，否则无动作。
- 空选择 + 点击"更新选中"：等价于提示"请先勾选要更新的条目"（按钮本身应为禁用，不会发生）。

### 2.5 状态栏

列表与日志面板之间的一条 28pt 高 bar，`.background(.bar)`，上下 `Divider`：

- 左：`.caption` `.secondary`：`共 24 项 · 3 个可更新 · 1 个失败`。
- 中：检查/更新进行时显示 `ProgressView(value:)` 线性进度（宽 120）+ "正在更新 iina (2/3)"。
- 右：`上次检查 今天 09:12` / `正在检查…`，下一次自动检查时间作为 tooltip。

### 2.6 日志面板（VSplitView 下部）

- `VSplitView { 列表+状态栏 ; 日志 }`，日志默认高度 **160**，最小 **72**，最大不超过窗口 60%。
- 折叠态（默认 App 启动时）：只显示状态栏，日志高度 0；工具栏 `terminal` 按钮点亮时展开。开始"检查/更新"时自动展开（可在设置关闭"运行时自动显示日志"——v1 固定自动展开）。
- 头部 24pt：左侧 `Label("日志", systemImage: "terminal")` `.caption`；右侧小按钮：`仅显示错误` 过滤 Toggle（`exclamationmark.triangle`）、`清空`（`trash`）、`复制全部`（`doc.on.doc`）。
- 正文：`ScrollViewReader + LazyVStack`，`.font(.system(.caption, design: .monospaced))`，背景 `Color(nsColor: .textBackgroundColor)`，自动滚到底部（用户向上滚动后停止跟随，出现"跳到底部"浮动按钮 `arrow.down.to.line.compact`）。
- 每行：`09:12:03` `.tertiary` · `[brew]` 来源 tag（`.secondary`，等宽，右对齐宽 72）· 文本 `.primary`；`isError` 整行 `Color.red`。
- 命令开始行用 `$ brew upgrade iina` 前缀并加粗（由 provider 的 Logger 输出约定）。

---

## 3. 状态徽标（StatusBadge）

统一组件：`HStack(spacing: 4) { Image(systemName:) ; Text(label) }`，`.font(.caption)`，`.imageScale(.small)`。颜色同时作用于图标与文字。

| `ItemStatus` | Symbol | 颜色 | 文字 | 说明 |
|---|---|---|---|---|
| `.checking` | `ProgressView().controlSize(.mini)` | `.secondary` | 检查中 | 不用 symbol，用系统小菊花 |
| `.outdated` | `arrow.up.circle.fill` | `Color.orange` | 可更新 | 橙色 = "需要你处理"；不用蓝色，避免与选中态/accent 混淆 |
| `.outdated` 且 `!canUpdate` | `pin.fill`（pinned）或 `arrow.up.circle`（空心） | `.secondary` | 可更新 · hint | 灰色空心表示"有新版但 Xup 不能替你更新" |
| `.upToDate` | `checkmark.circle.fill` | `Color.green` | 最新 | |
| `.unknown(msg)` | `questionmark.circle` | `.secondary` | 未知 · msg | msg 截断，tooltip 完整 |
| `.updating` | `ProgressView().controlSize(.mini)` | `Color.accentColor` | 更新中 | 行背景加 `Color.accentColor.opacity(0.06)` |
| `.updated` | `checkmark.seal.fill` | `Color.green` | 已更新 | 下次检查后自然变为"最新"；与"最新"区分 symbol 以便用户看到这轮成果 |
| `.failed(msg)` | `xmark.circle.fill` | `Color.red` | 失败 · msg | 行末出现"重试"按钮（`arrow.counterclockwise`）与"查看日志"（跳到日志中对应行） |
| `.staged(version)` **（§19 新增）** | `arrow.down.circle.fill` | `Color.blue` | 已下载 1.5.0 · 待安装 | 仅应用、策略为"自动下载，手动重启"时出现：新版本已在后台下载并校验完成，等用户点"安装并重启"。蓝色 = "已为你准备好，一键即可"；与橙色"可更新"区分，避免用户以为还要等下载 |

角标/计数一律只统计 `isActionable` 的条目（即 `canUpdate && (outdated || staged)`）。"待安装"计入角标与"全部更新"。

---

## 4. 交互流程

### 4.1 检查 → 选中 → 更新 → 日志 → 完成

1. **触发检查**：工具栏"检查更新" / 菜单栏面板 / 定时器 / 启动时自动。定时器触发的检查**默认只更新角标并通知**，不执行更新（除非设置中开启"自动更新"）。
   - 所有来源并行检查；每个来源各自把行置为 `.checking`（首次检查时列表为空，显示 §6.2 的"检查中"占位）。
   - 侧栏对应行 badge 位置显示 mini 菊花；状态栏显示"正在检查 Homebrew、npm…"。
   - 日志面板自动展开，流式输出 `$ brew outdated --json=v2` 等。
2. **结果呈现**：可更新行以橙色徽标排到顶部；`latest` 加粗；侧栏 badge、菜单栏角标、Dock（如显示）同步更新；若设置开启"发现更新时通知"，发送一条 `UNNotification`："发现 3 个更新：iina、node、claude"（点击通知打开主窗口）。
3. **选择**：用户勾选若干行复选框（或 ⌘A 全选可操作项）。"更新选中 (n)" 按钮计数随之变化。也可直接用行内"更新"按钮更新单项。
4. **更新**：
   - 被选行依次（同一来源串行，不同来源并行）变为 `.updating`，行内按钮替换为 mini 菊花；状态栏显示线性进度与当前项名。
   - 日志实时滚动。应用分区若 `restartAfterUpdate` 为开：更新完成后 `kill` 并重新 `open` 该 App，日志中记录"已重启 IINA"。
   - **Sparkle 应用由 Xup 直接下载替换**，过程较长，状态列的"更新中"文字后追加阶段文案（`.caption .secondary`），状态栏与菜单栏面板同步显示：
     `下载中 48%`（有 Content-Length 时显示百分比，否则显示已下载 MB）→ `校验中`（校验 appcast 的 EdDSA 签名 / 文件长度）→ `解压中`（dmg 挂载或 zip 解压）→ `替换中`（退出应用、替换 /Applications/x.app）→ `重启中`（若开启"更新后重启"）。
     行内 mini 菊花在"下载中"阶段换成 `ProgressView(value:)` 环形确定进度（`.progressViewStyle(.circular)` 12pt）。任一阶段失败 → `.failed("校验失败：签名不匹配")` 等，原 app 保持不变。
5. **完成**：
   - 成功行 → `.updated`（绿 `checkmark.seal.fill`），版本列 `installed` 更新为新值。
   - 失败行 → `.failed(msg)` 红色，并保留在顶部；状态栏文案"完成：2 成功，1 失败"，失败数 > 0 时状态栏文字 `Color.red`。
   - 若窗口不在前台，发送通知"更新完成：2 成功，1 失败"。
   - 全部完成 3 秒后状态栏恢复为"上次检查 …"。

### 4.2 应用分区：添加与"更新后重启"

- 点击"添加应用…"（工具栏 `plus`）或空状态按钮 → `NSOpenPanel`：`directoryURL = /Applications`，`allowedContentTypes = [.application]`，允许多选，提示文字"选择要让 Xup 跟踪更新的应用"。
- 添加后立即对新增项运行一次 `check`，期间显示 `.checking`。
- 识别结果写在 `detail`：`Homebrew cask iina` / `Sparkle · iina.io` / `electron-updater · updates.alma.now` / `自定义 · GitHub owner/repo` / `App Store` / 原路径（不可识别）。~~不可识别时状态为 `未知 · 无法识别更新来源`~~ → **已改**：不可识别且未手动配置时状态为灰色 `由应用自更新`，操作列提供"启动应用"，详见 §16。
- 每行右侧"更新后重启"Toggle（mini switch）；默认开。关闭后更新完成只替换 bundle，不自动启动。正在运行的 App 更新前会在确认 Alert 中列出："以下应用正在运行，更新时将被退出：IINA、Raycast。继续？"（按钮：更新并重启 / 取消）。
- 移除：行右键"移除"或选中后按 ⌫（删除键）；不弹确认，支持 ⌘Z 撤销（`UndoManager`）；设置 › 应用 中也有 `−` 按钮。

### 4.3 全部更新

- 点击 → 若可操作项 ≤ 5 直接开始；否则 Alert："将更新 12 个条目，可能需要几分钟。"（按钮：全部更新 / 取消）。
- Homebrew 来源内部顺序：先 formula 后 cask；`--greedy` 由设置决定（Alert 中若 greedy 开启，附注"包含自动更新的 cask"）。

### 4.4 键盘

`⌘R` 检查更新 · `⌘U` 更新选中 · `⇧⌘U` 全部更新 · `⌘N` 添加应用（应用分区） · `⇧⌘N` 选择软件…（其他分区） · `⌥⌘L` 日志 · `⌘F` 搜索 · `⌘,` 设置 · `⌫` 移除应用 / 取消关注 · `⌘1…8` 切换侧栏分区。

---

## 5. 菜单栏（MenuBarExtra）

### 5.1 状态栏图标

- 正常：`arrow.up.circle`（template 图标，随菜单栏深浅自动反色）。
- 有可更新项：`arrow.up.circle.fill` + 右上角数字角标（用 NSStatusItem 自绘：白字、橙底 `systemOrange` 的圆角胶囊，字号 9pt 粗体；数量 > 99 显示 `99+`）。SwiftUI `MenuBarExtra` 的 label 中可用 `Image(nsImage:)` 绘制合成图。
- 检查/更新中：图标替换为 `arrow.triangle.2.circlepath`，并以 0.8s 周期在 `.secondary`/`.primary` 间淡入淡出（不旋转，避免菜单栏噪音）。
- 有失败：`exclamationmark.circle` 角标红底。

### 5.2 面板（`MenuBarExtra(... ) { Panel }.menuBarExtraStyle(.window)`）

宽 **320**，高度自适应（最多约 420）。内边距 12。

```
┌──────────────────────────────────────┐
│ ⬆︎ 3 个可更新                 [⟳]   │  ← .headline + .secondary 小字"上次检查 09:12"；右侧刷新图标按钮
│   上次检查 今天 09:12                 │
├──────────────────────────────────────┤
│ 🍺 iina            1.3.9 → 1.4.0    │  ← 行高 32：来源 symbol(.secondary) · name(.body) · 版本 .caption .secondary，箭头 →
│ 📦 node            22.1.0 → 22.3.0  │
│ 🧠 Claude Code     1.0.3 → 1.0.5    │
│   还有 2 项…                          │  ← .caption .secondary，仅超出 5 项时显示；点击打开主窗口
├──────────────────────────────────────┤
│ [ 打开 Xup ]      [ 全部更新 ]        │  ← 两个等宽按钮并排：打开 Xup = .borderedProminent（面板是主入口，始终显示）；
│                                      │     全部更新 = .bordered；无可更新时整行只剩"打开 Xup"占满宽
├──────────────────────────────────────┤
│ 检查更新                     ⌘R      │  ← 菜单式按钮（plain button，悬停高亮 accent）
│ 设置…                        ⌘,      │
│ 退出 Xup                     ⌘Q      │
└──────────────────────────────────────┘
```

- 行可点击：打开主窗口并选中该行（滚动到可见）。
- 全部最新时：顶部为绿色 `checkmark.circle.fill` + "全部已是最新"，列表区省略，只留按钮区。
- 检查中：顶部 `ProgressView` + "正在检查更新…"，列表显示上次结果（变灰 `.secondary`）。
- 更新中：顶部 "正在更新 iina (1/3)" + 线性进度条；"全部更新"按钮替换为"停止"（`.bordered`，红字）。
- 有失败：摘要行追加红色 "· 1 个失败"。
- 面板不显示日志；"打开 Xup" 会带日志面板展开。
- **面板是产品的主要入口**（应用不在 Dock 中），因此"打开 Xup"必须在每个面板状态下都可见且为唯一的 prominent 按钮；"全部更新"在有可更新项时以 `.bordered` 并排出现，更新中变为"停止"。

---

## 6. 空状态与特殊状态（`ContentUnavailableView`）

统一样式：居中，`systemImage` 48pt `.secondary`，标题 `.title3`，描述 `.body` `.secondary`，下方一个按钮（`.bordered`）。

| 场景 | Symbol | 标题 | 描述 | 操作 |
|---|---|---|---|---|
| 6.1 首次启动（从未选择任何软件） | `arrow.up.circle` | 欢迎使用 Xup | 先选择要让 Xup 跟踪的软件。Xup 只会检查和更新你勾选的条目。 | **选择软件…**（`.borderedProminent`）+ 次级链接"添加应用…"。首次打开主窗口时自动弹出 §13 Sheet（见 §13.5） |
| 6.1b 已选择但从未检查 | `arrow.up.circle` | 准备就绪 | 已跟踪 12 个条目。点击"检查更新"开始。 | **检查更新**（`.borderedProminent`） |
| 6.2 检查中（无结果缓存） | `ProgressView().controlSize(.large)` | 正在检查更新… | 正在查询 Homebrew、npm、uv、Agents… | 无（可在日志看进度） |
| 6.3 来源不可用 | `exclamationmark.triangle` | 未检测到 uv | Xup 在 PATH 中找不到 `uv`。安装后重新检查即可。 | "安装说明"（打开 docs 链接）/ "重新检测" |
| 6.4 全部最新（某分区或全部） | `checkmark.circle` 绿 | 全部已是最新 | 24 个条目均为最新版本。上次检查 今天 09:12 | "再次检查" |
| 6.5 应用分区为空 | `macwindow.badge.plus` | 还没有跟踪的应用 | 添加 /Applications 中的应用，Xup 会自动识别它来自 Homebrew、Sparkle 还是 App Store。 | **添加应用…** |
| 6.6 搜索无结果 | `magnifyingglass` | 没有匹配"xxx"的条目 | — | "清除搜索" |
| 6.7 无任何可用来源 | `questionmark.folder` | 没有可用的更新来源 | 未检测到 Homebrew、npm、uv、skills CLI、Claude Code / Codex 或已知的 CLI agent。你仍可以在"应用"中添加 App。 | "添加应用…" |
| 6.9 关注集合为空（某来源） | 该来源的 symbol（如 `puzzlepiece.extension`） | 还没有选择要跟踪的软件 | 从本机已安装的 {Homebrew 包 / npm 全局包 / uv tool / agent / skill / Claude Code 与 Codex 插件} 中勾选要让 Xup 检查更新的条目。 | **选择软件…**（`.borderedProminent`，打开 Sheet 并定位到该来源分段）。状态栏显示"未跟踪任何 {来源}" |
| 6.8 更新失败（行级，非整页） | 行内红徽标 + 状态栏红字 | — | — | 行内"重试"，日志自动滚到错误行 |

注意 6.4 "全部最新"仅当"显示已是最新的条目"关闭时才作为整页空状态出现；开启时列表仍显示绿色行。

---

## 7. 设置（Settings scene，TabView）

> §21（2026-11-04）：设置窗口只剩 **通用 / Agents** 两个 Tab；§7.3"应用"与 §13.7"软件"Tab 已移入主窗口。

窗口固定宽 **520**，内容用 `Form` + `.formStyle(.grouped)`。Tab 图标：

| Tab | Symbol |
|---|---|
| 通用 | `gearshape` |
| Agents | `cpu` |
| 应用 | `macwindow` |

### 7.1 通用

**Section「检查」**
- `Picker("检查间隔")`：15 分钟 / 1 小时 / 6 小时 / 12 小时 / 每天 / 自定义…；选"自定义"后出现 `Stepper` + `TextField` "每 __ 分钟"（最小 5）。
- `Toggle("发现更新时通知")`
- ~~`Toggle("发现更新时自动更新")`~~ → **已改为（§19.5）**：`Picker("新关注条目的默认更新方式")`，两项 **手动更新** / **空闲时自动更新**，默认"手动更新"。脚注：`只影响之后新关注的条目；已有条目保留各自的更新方式，可在列表右键"更新方式"中逐条修改。`
- `Stepper("空闲判定")`：`无操作 __ 分钟后视为空闲`，范围 1–60，默认 **5**。脚注：`"空闲时自动更新"的条目会等到这么久没有键盘鼠标输入后才开始更新。锁屏与屏幕保护视为空闲。`

**Section「Homebrew」**
- `Toggle("包含自动更新的 cask (--greedy)")` 脚注：`检查会把自带更新机制的应用（如 Chrome）也列为可更新。`

**Section「显示」**
- `Toggle("显示已是最新的条目")`
- `Toggle("登录时启动")`（`SMAppService`）

**Section 底部**：`LabeledContent("版本", value: "1.0 (12)")`、`Button("检查 Xup 自身更新")`（可选）。

### 7.2 Agents

- 顶部说明 `.callout`：`Xup 内置了 Claude Code、Codex CLI、Gemini CLI、OpenCode、Amp、GitHub Copilot CLI、Cursor Agent 的检测规则。你可以编辑 agents.json 来增删 agent 或修改更新命令。`
- `Table` 只读列表（名称 / 二进制 / npm 包 / 更新命令），行高 28，`.caption` 等宽显示命令；没有更新命令的行显示 `—` 并在 hint 列显示"仅检测版本"。
- 底部按钮行：`在 Finder 中显示`（`folder`）· `用默认编辑器打开`（`square.and.pencil`）· `重新加载`（`arrow.clockwise`）· 右侧 `恢复默认`（destructive，需确认）。
- 文件路径以 `.caption .secondary` 等宽显示：`~/Library/Application Support/Xup/agents.json`。
- 解析失败时顶部显示红色 `Label("agents.json 解析失败：第 12 行 …", systemImage: "exclamationmark.triangle.fill")`，列表退回内置规则。

### 7.3 应用

- `List` 列：图标（`NSWorkspace.shared.icon(forFile:)` 20pt）· 名称 + 路径（`.caption .secondary`）· 来源 tag（`Homebrew cask` / `Sparkle` / `electron-updater` / `App Store` / `自定义 · GitHub` / `自更新`，样式见 §16.5）· `Toggle("更新后重启")` mini switch · `chevron.right`。**点击整行打开 §16.3 的"配置更新来源"Sheet**。
- 底部 `+ / −` 按钮组（`.buttonStyle(.borderless)`, 与 Finder 偏好一致）；`+` 打开 NSOpenPanel；`−` 删除选中（可撤销）。
- 空状态：`macwindow.badge.plus` "还没有跟踪的应用"。
- 脚注：`Xup 会用 Homebrew、应用自带的 Sparkle appcast / electron-updater 清单、mas 或你手动配置的来源来更新这些应用。无法识别且未配置的应用标为"自更新"，Xup 只显示版本并提供"启动应用"。点击任一行可配置更新来源。`

---

## 8. 字体与颜色速查

| 用途 | SwiftUI |
|---|---|
| 行标题 / 版本 | `.body`；版本 `.monospacedDigit()` |
| 行副标题、状态文字、状态栏、日志 | `.caption`；日志 `.system(.caption, design: .monospaced)` |
| 空状态标题 / 面板摘要 | `.title3` / `.headline` |
| 设置说明脚注 | `.footnote`（Form 自动） |
| 主文字 / 次要 / 第三级 | `.primary` / `.secondary` / `.tertiary` |
| 可更新 | `Color.orange` |
| 成功 / 最新 / 已更新 | `Color.green` |
| 失败 / 停止 / 移除 | `Color.red` |
| 更新中、选中、主按钮 | `Color.accentColor` |
| 列表背景 | 系统（Table 自带）；日志 `Color(nsColor: .textBackgroundColor)` |
| 状态栏 / 面板分隔 | `.background(.bar)` + `Divider()` |

---

## 9. SF Symbol 清单

**来源（ProviderKind.symbol）**：Homebrew `mug` · npm 全局 `shippingbox` · uv tool `bolt` · Agents `cpu` · **Skills `sparkles`** · **插件 `puzzlepiece.extension`** · 应用 `macwindow` · 全部 `square.grid.2x2`

**状态**：可更新 `arrow.up.circle.fill` · **已下载，待安装 `arrow.down.circle.fill`（蓝，§19）** · 不可更新的可更新 `arrow.up.circle` / pinned `pin.fill` · 最新 `checkmark.circle.fill` · 已更新 `checkmark.seal.fill` · 失败 `xmark.circle.fill` · 未知 `questionmark.circle` · 警告 `exclamationmark.triangle.fill` · 由 claude.ai 同步（只读）`icloud` · **由应用自更新（只读）`arrow.triangle.2.circlepath`**（与菜单栏"工作中"图标同名但语境不同：前者灰色静态在状态列，后者在状态栏图标，不会同屏混淆）

**操作**：检查更新 `arrow.clockwise` · 更新选中 `arrow.down.circle` · 全部更新 `arrow.down.to.line` · 停止 `stop.circle` · 重试 `arrow.counterclockwise` · 添加 `plus` · **选择软件… `checklist`** · **取消关注 `eye.slash`** · 清除搜索 `xmark.circle` · 移除 `minus` / `trash` · 日志 `terminal` · 复制 `doc.on.doc` · 在 Finder 中显示 `folder` · 编辑 `square.and.pencil` · 信息 `info.circle` · 搜索 `magnifyingglass` · 跳到底部 `arrow.down.to.line.compact` · 重启 `arrow.triangle.2.circlepath` · 打开窗口 `macwindow` · 设置 `gearshape` · 退出 `power` · **启动应用 `play.fill`（行内按钮）/ `play.circle`（右键菜单）** · **配置更新来源… `slider.horizontal.3`** · **URL 字段前缀 `link`** · **设置行进入 `chevron.right`** · **测试结果 `checkmark.circle.fill` / `xmark.circle.fill` / 未测试 `info.circle`**

**菜单栏图标**：空闲 `arrow.up.circle` · 有更新 `arrow.up.circle.fill`（+角标） · 工作中 `arrow.triangle.2.circlepath` · 失败 `exclamationmark.circle`

**空状态**：首次 `arrow.up.circle` · 不可用 `exclamationmark.triangle` · 全部最新 `checkmark.circle` · 应用为空 `macwindow.badge.plus` · 关注集合为空 = 该来源 symbol · 无结果 `magnifyingglass` · 无来源 `questionmark.folder`

**设置 Tab**：`gearshape` · `cpu` · `macwindow`

**来源标签（设置 › 应用，§16.5）**：自定义 `slider.horizontal.3` · 自更新 `arrow.triangle.2.circlepath`；其余标签纯文字无 symbol

**更新方式（§19）**：右键子菜单入口 `clock.arrow.circlepath` · 手动更新 `hand.raised` · 空闲时自动更新 `moon.zzz` · 自动下载，手动重启 `arrow.down.circle.dotted` · 当前选中项 `checkmark` · 安装并重启 `arrow.down.circle.fill`（与状态同 symbol，按钮内不再带图标，仅文字）· 通知：自动更新完成 `checkmark.seal.fill` / 已下载待安装 `arrow.down.circle.fill` / 失败 `xmark.circle.fill`。策略小标签纯文字无 symbol

---

## 10. 可访问性与细节

- 所有徽标颜色都伴随 symbol 与文字，不单靠颜色传达状态。
- 复选框、Toggle、按钮使用系统控件，天然支持 VoiceOver；`StatusBadge` 加 `.accessibilityLabel("状态：可更新，1.3.9 到 1.4.0")`。
- 支持"减弱动态效果"：菜单栏工作中图标淡入淡出在 `accessibilityReduceMotion` 时改为静态 `.secondary`。
- 版本列使用 `.monospacedDigit()` 保证对齐；路径类 detail 用 `.truncationMode(.middle)`。
- 深色模式无需额外适配：全部使用语义色。原型中的深色样式仅为示意。

---

## 11. 补充决策（2026-11-04）

- **纯菜单栏应用**：`LSUIElement = YES`，无 Dock 图标。菜单栏面板是主入口，"打开 Xup"为面板中唯一 prominent 按钮且在所有状态下可见；主窗口关闭后应用继续运行。见 §2.1、§5.2。
- **Sparkle 直接替换**：Xup 自行下载 appcast 中的包并替换 .app，更新过程显示"下载中 n% → 校验中 → 解压中 → 替换中 → 重启中"阶段文案。见 §4.1 步骤 4。
- **定时检查默认只通知**："自动更新"开关默认关闭；定时发现更新 → 角标 + 通知，用户从面板或主窗口手动触发更新。见 §4.1、§7.1。

## 12. 验收批注（主代理，2026-11-04）
- 通过。以下两点 v1 降级实现：
  1. Sparkle 下载进度百分比 → v1 仅显示阶段文案（下载中 / 校验中 / 替换中 / 重启中），不显示百分比与进度环。
  2. 更新中的"停止"按钮 → v1 不提供（核心层暂无取消通道），按钮位置保持"全部更新"禁用态。
- Agents 设置页"恢复默认"按钮在 520 宽下溢出，开发时放到第二行或改为菜单项。

---

## 13. 关注列表与"选择软件…"Sheet（2026-11-04 新增）

> 原型：`mockups/picker.html`。目标：Xup 只检查、只更新用户明确选择的软件，而不是机器上全部已安装的东西。

### 13.1 关注集合（WatchList）

- 每个来源（Homebrew、npm 全局、uv tool、Agents、Skills、插件）各有一个**关注集合** `Set<String>`，key 为该来源内的唯一标识（brew 为 formula/cask 名；npm 为包名；uv 为 tool 名；Agents 为 agent id；Skills 为 skill name；插件为 `name@marketplace`）。
- "应用"来源沿用"添加应用…"（NSOpenPanel）：被添加的 App 列表就是它的关注集合，不进入 Sheet 的分段控件。
- **只有被关注的条目**才会：出现在列表 · 被"检查更新"查询 · 被"全部更新"/角标/通知计入。未关注的已安装软件对 Xup 完全不可见。
- 某来源关注集合为空 → 该来源**不执行检查**（不跑 `brew outdated` 等），侧栏无 badge，内容区显示 §6.9 空状态。
- 持久化：`~/Library/Application Support/Xup/watchlist.json`，形如 `{"brew":["node","iina"],"npm":["typescript"],"skill":["ui-ux-pro-max"],"plugin":["ui-ux-pro-max@claude-plugins-official"]}`。文件缺失或损坏 → 全部视为空集（等同首次启动）。
- 关注的条目若在本机已卸载：仍留在列表，状态 `未知 · 本机已卸载`，`canUpdate = false`，右键"取消关注"可清理；Xup 不自动移除（避免临时 PATH 问题导致静默丢失）。
- 右键菜单"取消关注"（`eye.slash`）：立即从集合移除、行消失、`UndoManager` 支持 ⌘Z；选中行按 ⌫ 等价。

### 13.2 Sheet 规格（WatchPickerSheet）

`.sheet(isPresented:)`，固定 **560 × 480**（`.frame(width:height:)`，不可缩放），结构自上而下：

| 区域 | 高度 | 内容 |
|---|---|---|
| 头部 | ~86 | 标题 `.headline`"选择要跟踪的软件"；说明 `.caption .secondary`"只有勾选的条目会被检查和更新。之后可随时在工具栏'选择软件…'中修改。"；下一行：**来源 Picker**（`Picker` `.pickerStyle(.segmented)`，6 段：Homebrew · npm 全局 · uv tool · Agents · Skills · 插件，**纯文字**不带 symbol——560 宽下带图标会挤掉搜索框）+ 右侧**搜索框**（`TextField` `.textFieldStyle(.roundedBorder)`，占满剩余宽度，占位"搜索"，有内容时右侧 `xmark.circle` 清除）。不可用来源的分段 `.disabled(true)` 并 tooltip"未检测到 uv" |
| 列表 | 弹性 | `List` `.listStyle(.plain)`，行高 **36**，交替行背景。每行：`Toggle` checkbox（14pt）· 名称 `.body` + detail `.caption .secondary`（竖排两行）· 可选 `tag`（灰底胶囊，见 13.3）· **已安装版本** `.callout .monospacedDigit() .secondary` 右对齐宽 110。点击整行切换勾选；`空格` 切换当前焦点行 |
| 底部 | 48 | 左：`全选` `清空`（`.buttonStyle(.plain)` accent 文字）· `已选 N 项 · 共 M 项` `.caption .secondary`；右：`取消`（`.bordered`，Esc）· `完成`（`.borderedProminent`，Return） |

交互细节：

- 分段切换**不丢失**其他分段的勾选；"完成"一次性把 6 个来源的集合写入 `watchlist.json`，然后对**新增关注**的条目立即执行一次检查（已关注的不重复查）。"取消"丢弃全部改动。
- `全选` / `清空` 只作用于**当前搜索过滤结果**；"已选 N 项"统计当前分段全部勾选数，不受搜索影响。有搜索时计数追加"（显示 K 项）"。
- 打开 Sheet 时默认分段 = 当前侧栏分区；在"全部"分区打开时为 Homebrew；从 §6.9 空状态按钮打开时定位到该来源。
- 列表排序：已勾选的**不**置顶（保持安装清单原序 / 字母序），避免勾选时行跳动。
- "完成"后若关注总数仍为 0：Sheet 关闭，主窗口回到 6.1 欢迎态；不弹警告。

### 13.3 各分段的数据来源与行文案

| 分段 | 已安装清单来源 | detail 示例 | 版本列 | 备注 |
|---|---|---|---|---|
| Homebrew | `brew list --versions`（formula）+ `brew list --cask --versions` | `formula` / `cask` | `22.1.0` | 被 pin 的 formula 仍可勾选，列表中会显示"已 pin，跳过" |
| npm 全局 | `npm ls -g --depth=0 --json` | `npm -g` / `npm -g · 随 Node 安装`（npm、corepack） | `5.5.4` | 同时被 Agents 规则匹配的包（如 `@anthropic-ai/claude-code`）追加灰色 tag `Agents`，提示会双重显示；勾选不互斥 |
| uv tool | `uv tool list` | `uv tool` | `0.4.2` | |
| Agents | `agents.json` 规则中**已检测到**的 agent | 二进制路径 `~/.npm-global/bin/claude` | `1.0.3` | 未安装的 agent 不出现 |
| Skills | `~/.agents/.skill-lock.json` 的 `skills` 字典 | `source`（`vercel-labs/agent-skills`）；本地安装为 `local · ~/.agents/skills/<name>` | `更新于 10-28`（`updatedAt` 短日期） | 见 §14.1 |
| 插件 | `claude plugin list --json` + Codex 插件目录 | `Claude · claude-plugins-official` / `Codex · openai-plugins` | `0.7.32` / 短 SHA `a1f3c9e` / `—` | claude.ai 同步的插件：行 `.disabled`、checkbox 灰显、tag `由 claude.ai 同步`（`icloud`），不可勾选；见 §14.2 |

### 13.4 加载中与为空

- **加载中**：列表区居中 `ProgressView().controlSize(.large)` + "正在读取 Homebrew 已安装列表…" `.callout .secondary` + 正在执行的命令 `.caption .tertiary` 等宽（`$ brew list --versions`）。底部 全选/清空/完成 禁用，取消可用。每个分段独立加载并缓存到 Sheet 关闭；切到已加载的分段无等待。
- **为空**（该来源可用但没装任何东西）：`ContentUnavailableView` 小号样式（symbol 32pt，标题 `.headline`）："没有找到已安装的 uv tool" / "用 `uv tool install` 安装后，点击'重新读取'。" + `.bordered` 按钮"重新读取"（`arrow.clockwise`）。
- **读取失败**（命令非零退出 / JSON 解析失败）：同为空样式，symbol `exclamationmark.triangle`，标题"读取 npm 全局包失败"，描述为 stderr 首行（截断，tooltip 完整），按钮"重试"。
- **搜索无结果**：复用 6.6 文案，按钮"清除搜索"。

### 13.5 首启引导

1. 首次启动（`watchlist.json` 不存在）→ 自动打开主窗口（§2.1 已有规则）→ 内容区显示 6.1 欢迎态 → **延迟 0.3s 自动 present Sheet**（让窗口先完成出现动画），默认分段 Homebrew。
2. 用户"完成"且关注数 > 0 → 关闭 Sheet → 自动开始检查新增关注项 → 列表出现 `.checking` 行；状态栏"正在检查…"。
3. 用户"取消"或关注数为 0 → 停留在 6.1 欢迎态，主按钮"选择软件…"；不再自动弹出（写入 `hasSeenWatchPicker = true`）。
4. 菜单栏面板在未选择任何软件时：摘要行显示"还没有选择要跟踪的软件"（`.secondary`），列表区省略，按钮区只有"打开 Xup"；"检查更新"菜单项禁用。
5. 定时检查遇到全部关注集合为空 → 直接跳过，不写日志、不通知。

### 13.6 对其他界面的影响

- **菜单栏面板**：不变。面板只呈现已关注条目的可更新结果。
- **设置**：不新增 Tab。"通用"底部追加 `LabeledContent("跟踪的软件", value: "24 项")` + `Button("选择软件…")`，方便从设置进入。
- **状态栏**：分区视图左侧文案追加跟踪比例，如 `共 5 项 · 2 个可更新 · 跟踪 5 / 12 个已安装 skill`，让用户知道还有未关注的条目。"全部"视图不显示比例。
- **搜索**：主窗口搜索只过滤已关注条目；搜不到时 6.6 空状态的描述追加一行链接"在'选择软件…'中查找已安装但未跟踪的条目"。

### 13.7 Sheet 并入设置窗口（2026-11-04 变更）

> **已被 §21 取代（2026-11-04）**：设置窗口不再有"软件"Tab，`WatchListPane` 重构为单来源的 `InstalledListView(kind:)`，作为主窗口工具栏"+"弹出的 `AddWatchSheet` 的主体。以下保留为历史记录；其中"勾选即时生效 / 300ms 去抖 / 四态 / 策略小标签"等规格仍然有效，只是落点变了。

- "选择软件…"不再是主窗口的 Sheet，而是**设置窗口的"软件"Tab**（symbol `checklist`，位于"通用"之后、"Agents"之前；视图 `WatchListPane`，文件 `WatchListPane.swift`）。内容即原 §13.2 主体：来源分段控件 + 搜索框 + 已安装清单（checkbox · 名称 · detail · 版本）+ 底部 全选 / 清空 / `已关注 N 项 · 共 M 项`；每段独立加载并缓存，四态（加载中 / 为空 / 读取失败 / 不可用）不变。设置窗口四个 Tab 统一 **620 × 520**（`SettingsView.tabSize`，各 Tab 根视图 `.frame(width:height:)`，避免 TabView 按内容宽度居中后溢出裁切）；该 Tab 根布局 `.frame(maxWidth: .infinity, maxHeight: .infinity)`，头部 `.padding(.horizontal, 20)`，分段控件 `.fixedSize()` 与搜索框（`minWidth 160, maxWidth 240`）同一行、放不下时用 `ViewThatFits` 换行；列表行左右内边距 16，底部工具条与列表同宽。
- **勾选即时生效**：切换 checkbox / 全选 / 清空 后 300ms 去抖写入 `settings.setTracked(kind, names:)`；没有"取消 / 完成"按钮。底部右侧 **`立即检查`**（`.borderedProminent`）调用 `center.checkAll()`，检查中禁用并在左侧显示进度与"正在检查…"。外部改动（右键"取消关注"、CLI）会同步回勾选。
- 入口全部改为打开设置的"软件"Tab 并定位到对应来源分段：主窗口工具栏"选择软件…"（⇧⌘N）、§6.9 空状态按钮、§6.6 搜索无结果链接、设置 › 通用 的"选择软件…"按钮。实现：`UIState.settingsTab: SettingsTab`（`general / watch / agents / apps`）与 `UIState.pickerKind` 两个发布属性，`SettingsView` 的 `TabView(selection:)` 绑定 `settingsTab`；视图内先 `XupActions.activate()` 再 `@Environment(\.openSettings)`。
- 首启引导（§13.5）：`tracked` 全空且 `hasSeenWatchPicker == false` 时**不再自动弹 Sheet**；主窗口欢迎态改为标题"先选择要跟踪的软件"，描述"Xup 只会检查和更新你勾选的条目。在 设置 › 软件 中勾选，勾选即时生效。"，主按钮 `打开设置 › 软件…`。"软件"Tab 首次出现时写 `hasSeenWatchPicker = true`。
- `.sheet(isPresented: $ui.showWatchPicker)` 挂载与 `showWatchPicker / watchPickerKind / presentWatchPicker / checkAfterCurrent / onboardingAttempted` 一并删除。§13.6 "设置：不新增 Tab"作废。

---

## 14. Skills 与插件来源（2026-11-04 新增）

两者都是普通 `ProviderKind`，遵守 §3 状态徽标、§13 关注集合与全部已有交互；本节只写差异。原型：`mockups/main.html` 末尾"Skills 分区"、`mockups/picker.html` 2.2 / 2.3。

### 14.1 Skills（`ProviderKind.skill`，侧栏"Skills"，`sparkles`）

**数据**：Vercel `skills` CLI 的锁文件 `~/.agents/.skill-lock.json`。每项：`name`、`source`（GitHub `owner/repo` 或带子目录 `owner/repo/path`）、`updatedAt`（ISO 时间）。本地安装（无 `source` 或 `source` 非 GitHub）的 skill 也列出但不可检查。

**最新性判定**：对 `source` 对应的 GitHub 目录调用 `GET /repos/{owner}/{repo}/commits?path={dir}&since={updatedAt}&per_page=10`；返回非空 → `.outdated`，`status.message = "远端有 N 个新提交"`（N ≥ 10 显示"10+ 个"）；空 → `.upToDate`。请求失败 / 403 限流 → `.unknown("GitHub 请求限流，稍后重试")`。多个 skill 同仓库时合并为一次请求（按目录过滤）。可选在设置 › 通用加 `SecureField("GitHub Token（可选，提高限额）")`，v1 不做。

**更新命令**：`npx skills update <name> -g -y`（日志 tag `[skills]`）。成功后重新读取锁文件刷新 `updatedAt`，行变为 `.updated`。

**表格差异**（Skills 分区）：

| 列 | 表头 | 内容 |
|---|---|---|
| 名称 | 名称 | `name` `.body`；detail = `source`（如 `vercel-labs/agent-skills`），本地为 `local · ~/.agents/skills/<name>` |
| 已安装 | **本地更新于** | `updatedAt` 短日期 `10-28`（同年省略年份；跨年 `2025-12-30`），`.monospacedDigit()` |
| 最新 | **远端提交** | 最新远端提交日期；有新提交时 `.primary .medium`；无 source 或请求失败为 `—` |
| 状态 | 状态 | `可更新 · 远端有 3 个新提交` / `最新` / `已更新` / `未知 · 本地安装，无 GitHub source` / `未知 · GitHub 请求限流，稍后重试` / `失败 · npx 退出码 1` |

"全部"视图下这两列仍叫"已安装 / 最新"，Skills 行照样显示日期——日期与版本号在等宽数字下对齐良好，不另加列。

右键"在 Finder 中显示"打开 `~/.agents/skills/<name>`；新增"在 GitHub 中打开"（`safari`，仅有 source 时）。

**菜单栏面板**：行显示 `✦ ui-ux-pro-max   10-21 → 11-02`，版本位置用日期。

**不可用**：锁文件不存在且 PATH 无 `skills` → 6.3 文案"未检测到 skills CLI / 用 `npx skills add <owner/repo>` 安装第一个 skill 后重新检测。"

### 14.2 插件（`ProviderKind.plugin`，侧栏"插件"，`puzzlepiece.extension`）

**数据**：

- **Claude Code 插件**：`claude plugin list --json`（或读 `~/.claude/plugins/installed_plugins.json`）。标识 `name@marketplace`，有语义化版本（`0.7.32`）。来自 claude.ai 账户同步的插件带 `source = "claude.ai"`（或等价字段）。
- **Codex 插件**：Codex 插件目录中的 marketplace 清单。标识 `name@marketplace`，无语义化版本时用 marketplace 仓库的短 commit SHA（7 位）作为"版本"；读不到则 `—`。

**最新性判定**：Claude 插件比较本地版本与 marketplace 清单中的版本；Codex 插件比较本地 SHA 与 marketplace 远端 HEAD。claude.ai 同步的插件不检查。

**更新命令**：Claude `claude plugin update <name>@<marketplace>`（日志 tag `[claude]`）；Codex `codex plugin add <name>@<marketplace>`（重新安装即更新，日志 tag `[codex]`）。

**表格差异**（插件分区）：

| 列 | 内容 |
|---|---|
| 名称 | 显示 `name`（不带 `@marketplace`）；detail = `Claude · claude-plugins-official` / `Codex · openai-plugins` / `Claude · claude.ai` |
| 已安装 / 最新 | Claude：`0.7.32` → `0.8.0`；Codex：`a1f3c9e` → `5b2d7f0`（`.monospaced`）；同步插件最新列 `—` |
| 状态 | `可更新` / `最新` / `已更新` / **只读**：symbol `icloud` `.secondary`，文字 `由 claude.ai 同步`，无 checkbox、无更新按钮，`info.circle` Popover："该插件由你的 claude.ai 账户同步管理，请在 claude.ai 中更新。" / `未知 · 无法读取 marketplace 清单` |

"由 claude.ai 同步"是一个独立的只读态（`canUpdate = false`，`isActionable = false`），不是 `.unknown`，因此不计入角标，也不在 §13 Sheet 中可勾选——但仍在列表中显示，让用户知道它存在且由谁管理。

**角标规则**：Skills 与插件 badge 同 §3——只统计 `isActionable`（可更新且 Xup 能更新）；同步插件、本地 skill 永远不计入。

**不可用**：PATH 中既无 `claude` 也无 `codex` → 6.3 文案"未检测到 Claude Code 或 Codex / 安装任一 CLI 后重新检测。"只装了其中一个时正常可用，Sheet 只列出存在的那家。

### 14.3 Symbol 补充

来源：`sparkles`（Skills）· `puzzlepiece.extension`（插件）；操作：`checklist`（选择软件…）· `eye.slash`（取消关注）· `safari`（在 GitHub 中打开）；状态：`icloud`（由 claude.ai 同步）。已并入 §9。

## 15. 验收批注二（主代理，2026-11-04，针对 §13/§14）
- 通过。与核心层对齐的调整（UI 以核心层为准）：
  1. 关注集合持久化在 UserDefaults（`AppSettings.tracked`），不是 watchlist.json；"首次启动"判定改为 `tracked` 全空且 `hasSeenWatchPicker == false`。
  2. 来自 claude.ai 同步的 Claude 插件 v1 不列出（核心层只读 installed_plugins.json）。
  3. "完成"后直接触发一次 `checkAll()`（只会检查关注项），不做"仅新增项"的增量检查。
  4. 取消关注的 ⌘Z 撤销 v1 不做。
  5. 状态栏"跟踪 N / M 个已安装"比例 v1 不做（需要额外 listInstalled 调用）。

---

## 16. 应用更新来源：自动识别与手动配置（2026-11-04 新增）

> 原型：`mockups/app-source.html`。背景：很多 App 自带更新器但 Xup 识别不了（截图中 Alma / Kaze / magpie / Nowledge Mem 均显示"未知 · 无法识别更新来源"）。用户拍板方案："**自动识别 + 手动配置来源**"。本节改动三件事：自动识别新增 electron-updater；每个应用可手动配置一个更新来源；识别不了且未配置的应用不再叫"未知"，改为"由应用自更新"并提供"启动应用"。

### 16.1 来源优先级与判定

每次检查时按下列顺序取**第一个命中**的来源，命中后不再往下试：

| 优先级 | 来源 | 判定依据 | 检查 / 更新方式 |
|---|---|---|---|
| 1 | **手动配置**（`ManagedApp.customSource`，§16.3） | 用户在 Sheet 中保存过配置 | 按配置类型拉取版本并下载替换；用户显式配置的来源永远优先于自动识别 |
| 2 | Homebrew cask | `brew list --cask` 中有安装到该路径的 cask（`brew info --cask --json=v2` 的 `installed` + `artifacts.app`） | `brew upgrade --cask <token>` |
| 3 | Sparkle | `Info.plist` 有 `SUFeedURL`，或 `Contents/Frameworks/Sparkle.framework` 存在且 defaults 中有 feed | 拉 appcast，Xup 下载替换（§4.1 步骤 4） |
| 4 | **electron-updater**（新增） | `Contents/Resources/app-update.yml` 存在 | 读 yml 的 `provider`：`generic` → `{url}/latest-mac.yml`；`github` → 该仓库最新 Release 中的 `latest-mac.yml`。再读 `version`、`files[]`（`url` / `sha512` / `size`），按本机架构选文件（名字含 `arm64` / `x64`，否则取第一个无架构后缀的 zip/dmg），下载 → sha512 校验 → 解压 → 替换 → 按需重启。`provider` 为 `s3` / `spaces` / `keygen` 等 v1 不支持，视为未识别 |
| 5 | App Store | `Contents/_MASReceipt/receipt` 存在 | 有 `mas` 时 `mas upgrade <id>`；无 `mas` 时 `未知 · 未安装 mas（brew install mas）· 可在 App Store 中更新`（沿用旧文案） |
| 6 | **自更新**（兜底） | 以上皆不命中 | Xup 不检查、不更新；状态 `由应用自更新`，操作列"启动应用"（§16.4） |

- 电子应用既有 `app-update.yml` 又装在 cask 里时按优先级走 cask（brew 能处理得更干净）。
- 一个应用被识别为 Sparkle / electron-updater 后，`detail` 中给出主机名，让用户知道 Xup 在跟谁要更新。
- 自动识别结果缓存在 `ManagedApp.detectedSource`，每次检查重新判定（用户可能后来 `brew install --cask` 了同一个 App）。

### 16.2 各来源的 detail / 状态文案

| 来源 | `detail`（名称下方 `.caption .secondary`） | 状态列（有更新 / 最新） | 不可用时 |
|---|---|---|---|
| 手动配置 · GitHub Releases | `自定义 · GitHub nowledge-co/mem` | `可更新` / `最新` | `失败 · GitHub 请求限流，稍后重试` / `失败 · 未找到匹配的资源文件` |
| 手动配置 · Tauri | `自定义 · Tauri releases.kaze.app` | 同上 | `失败 · 更新 JSON 中没有 darwin-aarch64 平台` |
| 手动配置 · electron-updater | `自定义 · electron-updater updates.kaze.app` | 同上 | `失败 · latest-mac.yml 解析失败` |
| 手动配置 · Sparkle | `自定义 · Sparkle example.com` | 同上 | `失败 · appcast 请求失败（404）` |
| Homebrew cask | `Homebrew cask google-chrome` | 同上 | `未知 · brew outdated 失败` |
| Sparkle（自动） | `Sparkle · iina.io` | 同上 | `未知 · appcast 请求失败` |
| electron-updater（自动） | `electron-updater · updates.alma.now`；GitHub provider 为 `electron-updater · GitHub owner/repo` | 同上 | `未知 · latest-mac.yml 请求失败` |
| App Store | `App Store` | 同上 | `未知 · 未安装 mas（brew install mas）· 可在 App Store 中更新` |
| 自更新 | 原路径 `/Applications/Kaze.app` | **`由应用自更新 · 在应用内检查更新，或右键配置更新来源`**（灰，`arrow.triangle.2.circlepath`） | — |

规则：`自定义 ·` 前缀只在手动配置时出现；主机名只取 host，不含路径；所有"失败/未知"的 msg 截断并 tooltip 完整（§3 既有规则）。手动配置来源的检查失败用 `.failed`（红）而不是 `.unknown`（灰）——用户亲手配的东西坏了应该醒目，提醒他回到 Sheet 用"测试"排查。

### 16.3 配置更新来源 Sheet（AppSourceSheet）

**入口**

1. 应用分区表格右键菜单 **配置更新来源…**（`slider.horizontal.3`），位于"启动应用"之后、"在 Finder 中显示"之前。
2. 设置 › 应用：**点击整行**（或行尾 `chevron.right`）。
3. 自更新行状态 hint 中的"右键配置更新来源"是文字提示，不是链接。

**规格**：`.sheet`，固定宽 **440**，高度随内容（GitHub 类型约 360，URL 类型约 300）。结构自上而下：

| 区域 | 内容 |
|---|---|
| 头部（`.bar` 底，下分隔线） | 应用图标 32pt · 标题 `.headline`"配置 Nowledge Mem 的更新来源" · 副标题 `.caption .secondary` 等宽：路径 ` · 已安装 1.3.0` · 右侧灰胶囊 **`自动识别：未识别`**（或 `自动识别：Sparkle` 等，告诉用户不配也行） |
| 来源类型 | `Picker("来源类型")` `.pickerStyle(.menu)`，四项：**GitHub Releases** / **Tauri 更新 JSON** / **electron-updater (latest-mac.yml)** / **Sparkle appcast**。下方一行 `.caption .secondary` 说明该类型如何取版本。切换类型时各类型已填内容分别保留到 Sheet 关闭 |
| 字段（按类型） | 见下表。所有 TextField `.textFieldStyle(.roundedBorder)` 等宽字体；标签右对齐宽 92（`LabeledContent` / `Form` 自动对齐） |
| 测试行 | `Button("测试")`（`.bordered`）+ 右侧 `.caption .secondary` 状态（"拉取一次，显示识别到的最新版本" / "正在获取…" / "刚刚 · 用时 0.8 秒"）。测试过后按钮文字变为"再次测试" |
| 测试结果区 | 一个 36pt 起高的圆角框，三态见 §16.3.1 |
| 底部 48–52pt | 左：`移除配置`（`.plain` 红字，**仅已有配置时可用**，点击后立刻清除配置并关闭 Sheet，该应用回到自动识别）· 右：`取消`（Esc）· `保存`（`.borderedProminent`，Return） |

**字段与本地校验**（不通过时 TextField 红边 + 红色 `.caption` 提示，`保存` 禁用）：

| 类型 | 字段 | 占位 / 校验 |
|---|---|---|
| GitHub Releases | `仓库` | 占位 `owner/repo`；正则 `^[\w.-]+/[\w.-]+$`；粘贴 `https://github.com/owner/repo(/releases…)` 自动裁成 `owner/repo` |
| | `资源文件匹配`（可选） | 占位 `*arm64*.dmg（可选）`；fnmatch 通配符，大小写不敏感；帮助文字"留空时自动选择与本机架构匹配的 `.dmg` / `.zip`" |
| | `包含预发布版本` checkbox | 默认关。关时用 `/releases/latest`；开时取 `/releases?per_page=10` 第一个非 draft |
| Tauri 更新 JSON | `URL` | 必须 `https://`；支持 `{{target}}` `{{arch}}` `{{current_version}}` 占位符（Xup 代入 `darwin` / `aarch64` 或 `x86_64` / 已安装版本）。读取 `version` + `platforms["darwin-aarch64"].url`（`.app.tar.gz`） |
| electron-updater | `URL` | 必须 `https://`；填目录 URL 时自动补 `latest-mac.yml`；帮助文字"读取 `latest-mac.yml` 的 `version` 与 `files`，按本机架构选择文件并校验 sha512" |
| Sparkle appcast | `URL` | 必须 `https://`（允许 `http://` 但显示黄色警告"未加密的 appcast"）；按 Xup 既有 Sparkle 流程处理 |

`保存`：字段通过本地校验即可用，**不强制测试成功**（离线也能配），但未测试时结果区保持 idle 态文案提醒。保存后：写入 `ManagedApp.customSource`，关闭 Sheet，立即对该应用执行一次 `check`，行进入 `.checking`。

#### 16.3.1 "测试"按钮三态

| 态 | 结果区 | 说明 |
|---|---|---|
| **未测试 / 测试中** | 虚线边框 `.tertiary`：`info.circle`"尚未测试。保存前建议测试一次，确认 Xup 能读到版本与资源文件。"；测试中换为 mini 菊花 + "正在获取 updates.kaze.app…" + 第二行等宽 `GET https://…`。测试中"测试""保存"禁用，"取消"可用（取消即中止请求） | 请求超时 15 秒 |
| **成功** | 绿 `checkmark.circle.fill`，边框淡绿：**`最新版本 1.4.2`**`（tag v1.4.2，2026-10-30）· 已安装 1.3.0 → 可更新`（橙字；相等时"已是最新"绿字；远端更低时"远端版本更低"灰字）。第二行 `.caption .secondary`：GitHub 为 `资源文件 Nowledge-Mem-1.4.2-arm64.dmg · 84.3 MB · 1 / 6 个匹配`；electron/Tauri/Sparkle 为将下载的文件名 + 大小 | 匹配到 >1 个资源文件时仍算成功，但第二行改为橙色 `匹配到 3 个资源文件，将使用第一个：… · 建议细化匹配规则` |
| **失败** | 红 `xmark.circle.fill`，边框淡红：粗体错误标题 + 括号内细节，第二行给可操作信息。同时把**责任字段**标红（如资源匹配无结果 → 标红"资源文件匹配"，仓库 404 → 标红"仓库"） | 错误文案清单：`仓库不存在或无权限（404）` · `GitHub 请求限流，稍后重试（剩余 0 / 60）` · `未找到匹配的资源文件（v1.4.2 共 6 个，0 个匹配 *x64*.pkg）`，第二行列出可用文件名 · `该 Release 没有 macOS 资源文件` · `无法解析版本号（tag "nightly-2026-11-01"）` · `latest-mac.yml 解析失败：缺少 version` · `更新 JSON 中没有 darwin-aarch64 平台` · `appcast 不是合法的 RSS` · `网络错误：…` · `请求超时` |

### 16.4 "由应用自更新"态与"启动应用"

- 新增只读态 `ItemStatus.selfUpdating`，与 §14.2"由 claude.ai 同步"同类：`canUpdate = false`、`isActionable = false`，**不计入角标 / 通知 / 全部更新**，不是 `.unknown`。"未知"从此只用于"识别到了来源但读取失败"的情形。
- 状态徽标：symbol `arrow.triangle.2.circlepath` `.secondary`，文字 `由应用自更新`，hint `· 在应用内检查更新，或右键配置更新来源`（`.tertiary`，截断 + tooltip）。版本列：已安装正常显示，最新为 `—`。
- 操作列：**`启动应用`** 按钮（`.bordered .small`，图标 `play.fill`），悬停或选中时显示（与"更新"按钮同规则）。行为：`NSWorkspace.shared.openApplication(at:)`；若已在运行则 `activate` 置前。tooltip："启动 Kaze，让它自己检查更新；若已在运行则置前"。日志写一行 `[app] 已启动 Kaze（由应用自更新）`。
- 自更新行**不显示**"更新后重启"开关（Xup 不替它更新，开关无意义）；设置 › 应用中该开关 `.disabled`。
- 右键菜单：`更新` 禁用 · **`启动应用`**（`play.circle`）· **`配置更新来源…`** · 分隔 · 在 Finder 中显示 · 复制名称 · 复制版本 · 分隔 · 移除。非自更新行也有"启动应用"（放在"更新"之后），但只有自更新行把它作为主操作放进操作列。
- 状态栏在应用分区追加计数：`共 7 项 · 2 个可更新 · 2 个由应用自更新`。
- 菜单栏面板不列自更新应用（它们永远没有"可更新"）。
- 自更新行在"更新方式"子菜单中全部禁用（Xup 不替它更新，策略无意义），配置 Sheet 中「更新方式」分组同样 `.disabled`。
- §6.5 空状态描述改为："添加 /Applications 中的应用，Xup 会自动识别它来自 Homebrew、Sparkle、electron-updater 还是 App Store；识别不了的可以手动配置来源。"

### 16.5 设置 › 应用 行的来源标签

每行结构：图标 20pt · 名称 + 路径 · **来源标签** · 更新后重启 · `chevron.right`（`.tertiary`）。整行可点击，悬停行背景微亮；点击打开 §16.3 Sheet。

| 来源 | 标签文字 | 样式 |
|---|---|---|
| Homebrew cask / Sparkle / electron-updater / App Store | `Homebrew cask` / `Sparkle` / `electron-updater` / `App Store` | 既有灰底胶囊 `.caption`，纯文字 |
| 手动配置 | `自定义 · GitHub` / `自定义 · Tauri` / `自定义 · electron-updater` / `自定义 · Sparkle` | 胶囊底色 `accentColor.opacity(0.10)`、文字 accent，前缀 `slider.horizontal.3`；tooltip 显示完整配置（`GitHub nowledge-co/mem · *arm64*.dmg`） |
| 自更新 | `自更新` | 透明底 + 虚线描边胶囊，前缀 `arrow.triangle.2.circlepath` `.secondary`；tooltip"无法识别且未配置：点击配置更新来源" |

脚注文案见 §7.3（已更新）。`+ / −` 按钮组不变。

### 16.6 持久化与模型

```swift
enum AppUpdateSource: Codable {
  case githubReleases(repo: String, assetPattern: String?, includePrerelease: Bool)
  case tauri(url: URL)
  case electronUpdater(url: URL)
  case sparkle(feed: URL)
}
struct ManagedApp { …; var customSource: AppUpdateSource?; var detectedSource: DetectedSource? }
```

- `customSource` 随 `ManagedApp` 一起存在 `AppSettings.apps`（UserDefaults，与 §15 对齐），移除应用时一并删除。
- 配置了来源但对应 App 已被删除：行沿用 §13.1"本机已卸载"文案，配置保留，直到用户移除该行。
- 下载替换流程复用 §4.1 步骤 4 的阶段文案（下载中 → 校验中 → 解压中 → 替换中 → 重启中）；GitHub / Tauri 来源的"校验中"只校验文件长度（无签名），electron-updater 校验 sha512，Sparkle 校验 EdDSA。签名缺失不算失败，但日志里记一行 `[app] 该来源不提供签名，仅校验长度`。

## 17. "更新后重启"改为"应用运行时的处理方式"（2026-11-04 文案与落点变更）

- 问题：应用分区每行的"更新后重启"Toggle 用户看不懂。它的真实语义是"应用正在运行时怎么办"：开 = 替换前自动退出、替换后自动重开；关 = 应用在运行就跳过本次更新，等用户关闭后再更新。
- 改法（仅 UI，`ManagedApp.restartAfterUpdate` 字段与 config 键不变）：两个选项固定为 **`自动退出并重新打开`**（true，默认）/ **`等我关闭后再更新`**（false），**只在每个应用自己的配置 Sheet 里修改**，不再散落在表格行 / 右键子菜单 / 设置列表。
  - **"应用设置"Sheet**（原 §16.3 "配置更新来源"升级，`AppSourceSheet`）：标题 `配置 <应用名>`；两个分组：「应用正在运行时」`Picker` `.radioGroup` 两选项 + 一句 `.caption .secondary` 说明；「更新来源」为原有的来源类型 / 字段 / 测试 / 移除配置。"保存"同时写 `setRestart` 与 `setSource`；来源字段没填过时只保存策略（不触发重新检查）。自更新行该 Picker `.disabled`。
  - 表格"应用"分区：操作列不再有 Toggle（宽度回到 84）；行副标题不显示策略；右键菜单 `配置更新来源…` 改名 **`配置应用…`**（`slider.horizontal.3`）。
  - 设置 › 应用：行尾 Toggle 换为只读简述 `运行中自动重开` / `运行中跳过`（`.caption .secondary`，自更新行不显示）；点击行或 `›` 打开同一个"应用设置"Sheet；列表下方追加一句脚注解释两种策略；§7.2"自动更新"脚注改为"应用分区仍遵循每个应用的'运行中处理方式'"。
  - 状态列：策略为"等我关闭后再更新"且应用正在运行且有新版本时，hint 显示 `应用运行中，按设置暂不更新；关闭后点"更新"，或在"配置应用…"里改为自动退出并重新打开`；AppsProvider 对应日志 / 抛错用其简短版。
  - schema `restartAfterUpdate.description`、SKILL.md、README、`xup apps add --restart/--no-restart` 帮助同步为上述两句含义。§4.2 / §7.3 / §16.4 / §16.5 中提到的"更新后重启"开关均以本节为准。

---

## 19. 更新方式（每条目策略，2026-11-04 新增）

> 原型：`mockups/policy.html`。背景：§7.1 原有的"发现更新时自动更新"是全局一刀切——开了会在用户正用着某个应用时把它退出，关了又得每次手点。用户拍板：**每个被关注的条目单独选更新方式**，全局只保留"新关注条目的默认值"。

### 19.1 策略定义与适用范围

| 策略 | `UpdatePolicy` | 适用 | 行为 |
|---|---|---|---|
| **手动更新**（默认） | `manual` | 所有条目 | 定时检查只把条目标为"可更新"并计入角标/通知，用户点"更新"才执行。即现状 |
| **空闲时自动更新** | `auto` | 所有条目 | 定时检查发现新版本后，等系统空闲（§19.2）再自动执行。应用条目在执行时遵循其 §17"应用正在运行时"策略：`自动退出并重新打开` → 空闲时直接退出替换重开；`等我关闭后再更新` → 应用若在运行则本轮跳过，下次复查再试 |
| **自动下载，手动重启** | `autoDownload` | **仅应用**，且来源为 Xup 自己下载替换的类型（Sparkle / electron-updater / 手动配置的四类） | 发现新版本后立即在后台下载 → 校验 → 解压到暂存目录，**不替换、不退出应用**。行状态变为 `已下载 1.5.0 · 待安装`（§19.4），用户点"安装并重启"（或 CLI）时才 退出 → 替换 → 重开 |
| └ 子开关 **空闲且应用未运行时自动安装** | `installWhenIdle: Bool`，默认 **关** | 仅在 `autoDownload` 下可用 | 开启后，暂存完成的包会在系统空闲（§19.2）且该应用**没有在运行**时自动完成安装；应用在运行就继续等用户点。相当于"只在不打扰我的情况下顺手装好" |

不适用的组合：

- Homebrew cask / App Store 应用：安装由 `brew` / `mas` 一步完成，无法预下载 → "自动下载，手动重启"选项 `.disabled`，下方说明 `该应用由 Homebrew / App Store 执行安装，不支持预下载`。
- 自更新应用（§16.4）、claude.ai 同步插件（§14.2）、pinned formula、无更新命令的 agent：三个选项全部禁用，子菜单项灰显，Sheet 分组灰显。它们本来就 `canUpdate = false`。
- 非应用条目的子菜单只有两项（不显示"自动下载"）。

**默认值与继承**：

- 新关注的条目（设置 › 软件 勾选、"添加应用…"、CLI `xup watch add`）取 `check.defaultPolicy`（§19.5），只有 `manual` / `auto` 两种可能；`autoDownload` 必须逐个应用手动选。
- 已关注条目**各自保留**自己的策略；改全局默认不回溯。
- 应用的策略可在 §17"应用设置"Sheet 的新分组「更新方式」里改（见 19.3）；非应用条目只能在表格右键 / 设置 › 软件 行里改。
- 迁移：旧 `check.autoUpdate == true` → `defaultPolicy = auto` 且所有已关注条目策略补为 `auto`；`false` → `manual`。迁移后删除 `autoUpdate` 键。

### 19.2 空闲判定与自动执行时机

**空闲**：`CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: kCGAnyInputEventType)` ≥ `check.idleMinutes × 60`（默认 5 分钟，设置里 1–60 可调）。锁屏 / 屏幕保护中直接视为空闲；系统睡眠时不执行（定时器本身不会跑）。**后续可选**（v1 不做，先在设置脚注预留文案位）：要求接通电源；"勿扰 / 专注模式"开启时不自动更新；低电量模式不自动更新。

**执行时机**（`AutoUpdateScheduler`）：

1. **只由定时检查触发**。一轮定时检查结束 → 收集 `policy == auto && isActionable` 的条目作为"待自动更新集合"；同时 `policy == autoDownload` 且 `outdated` 的应用**立即**开始后台下载（下载不需要空闲，它不打扰人）。
2. 立即判定空闲：空闲 → 马上按 §4.1 步骤 4 执行（同一来源串行、不同来源并行，与手动"全部更新"相同的通道）；不空闲 → 每 **5 分钟**复查一次。
3. 推迟上限 = **下一个检查周期开始**。新一轮定时检查会重新生成集合（版本可能又变了），旧集合作废，不累积。检查间隔 ≤ 15 分钟时复查间隔取 `min(5, interval/2)`。
4. **用户手动点"检查更新"（工具栏 / 面板 / ⌘R / CLI `xup check`）不触发自动更新**——用户在场，由他决定。手动检查会清掉当前待自动更新集合吗？不会：集合保持，继续等下一次空闲判定。
5. 自动更新执行中用户回来操作：不中断（v1 无取消通道，与 §12 一致）；菜单栏图标进入"工作中"，面板显示"正在自动更新 node (1/2)"（摘要前缀"自动"二字让用户知道不是自己点的）。
6. `installWhenIdle` 的自动安装走同一个调度器：集合中额外包含 `staged && installWhenIdle && !isRunning` 的应用；复查时若应用已启动则本轮跳过。
7. 自动执行期间若任一条目失败 → 行 `.failed`，**不重试**，等下次定时检查重新评估；连续 3 轮失败同一条目 → 通知里追加"已连续 3 次失败，建议手动检查日志"。
8. 日志每条自动操作前写 `[xup] 空闲 7 分钟，开始自动更新 2 项：node、typescript`，便于事后追溯"谁动了我的软件"。

**通知文案**（`UNNotification`，受 §7.1"发现更新时通知"开关控制；关闭时自动更新静默进行，仅写日志）：

| 时机 | 标题 | 正文 | 点击 |
|---|---|---|---|
| 自动更新完成（全部成功） | `已自动更新 2 项` | `node、typescript 已在你离开时更新到最新版本。` | 打开主窗口，选中"全部" |
| 自动更新完成（有失败） | `自动更新：1 成功，1 失败` | `IINA 更新失败：校验失败，签名不匹配。点击查看日志。` | 打开主窗口并展开日志、滚到错误行 |
| 自动更新失败（全部失败） | `自动更新失败：IINA` | `校验失败：签名不匹配。原版本未受影响。` | 同上 |
| 已下载待安装 | `IINA 1.5.0 已下载` | `新版本已准备好。点击"安装并重启"完成更新，只需几秒。` | 打开主窗口并选中该行 |
| `installWhenIdle` 自动安装完成 | `IINA 已更新到 1.5.0` | `已在应用未运行时自动完成安装。` | 打开主窗口并选中该行 |
| 暂存包失效 | `IINA 的更新包需要重新下载` | `已下载的 1.5.0 校验失败，Xup 会在下次检查时重新下载。` | 打开主窗口并选中该行 |

同一轮里多个"已下载待安装"合并为一条：`2 个应用已下载更新` / `IINA、Alma 已准备好，点击"安装并重启"完成更新。`

### 19.3 入口与控件

1. **表格右键菜单 → `更新方式` 子菜单**（`clock.arrow.circlepath`，位于"更新 / 启动应用"之后、"配置应用…"之前）。子菜单项带勾选态（`checkmark`）：`手动更新` · `空闲时自动更新` · （仅应用）`自动下载，手动重启`；应用再多一个分隔线后的 `Toggle` 项 `空闲且应用未运行时自动安装`（仅当前策略为 autoDownload 时可用）。
   - **多选批量设置**：右键选中的多行 → 子菜单作用于全部选中项；各行策略不一致时所有项无勾（SwiftUI 用 `Picker(selection: Binding<UpdatePolicy?>)`，nil 不勾）；包含非应用时"自动下载"项禁用并 tooltip `所选条目中含非应用`。改完后状态栏闪一行 `已将 3 项设为"空闲时自动更新"`（3 秒）。
   - 不可更新的条目（§19.1 不适用组合）：子菜单整体 `.disabled`。
2. **"应用设置"Sheet（§17 `AppSourceSheet`）新增分组「更新方式」**，放在「应用正在运行时」**上方**（先决定"要不要自动"，再决定"运行中怎么办"）。`Picker` `.pickerStyle(.radioGroup)` 三项，每项下一句 `.caption .secondary` 说明；第三项下方缩进 20pt 的 `Toggle("空闲且应用未运行时自动安装")`，仅第三项选中时可用。不支持预下载的来源第三项 `.disabled` + 说明。Sheet 高度相应增加约 110pt（GitHub 类型约 470）。"保存"一并写入 `setPolicy` / `setInstallWhenIdle`。
3. **设置 › 软件**（§13.7 `WatchListPane`）：每行已关注条目在版本列左侧显示**策略小标签**（19.6），点击弹出 `Menu`（同子菜单内容，两项或三项）；未关注行不显示。行右键同样弹出。
4. **设置 › 应用**：行尾只读简述追加策略，如 `空闲自动 · 运行中自动重开`（`.caption .secondary`）；点击行进 Sheet 改。
5. **设置 › 通用**：见 19.5。
6. **CLI**：`xup policy set <itemID> manual|auto|autoDownload [--install-when-idle]`、`xup policy get <itemID>`；`xup update <itemID>` 对 `staged` 条目等同"安装并重启"。
7. **菜单栏面板**：不提供改策略的入口（面板只看不配）。

### 19.4 新状态"已下载，待安装"

- `ItemStatus.staged(version: String)`，`canUpdate = true`，`isActionable = true`。只有 `policy == autoDownload` 的应用会进入此态。
- **状态徽标**：`arrow.down.circle.fill` + `Color.blue`（`systemBlue`，与 accent 默认同色但语义独立：用户改了 accent 色也保持蓝），文字 `已下载 1.5.0 · 待安装`。版本列 `latest` 加粗同"可更新"。后台下载进行中（尚未 staged）时仍是橙色"可更新"，hint `· 后台下载中 62%`（v1 无百分比时为 `· 后台下载中`），不计入"更新中"。
- **操作列**：按钮 **`安装并重启`**，`.buttonStyle(.borderedProminent)` `.controlSize(.small)`，**常显**（不像"更新"只在悬停时出现——这是用户该做的下一步）。若应用未运行，按钮文字为 `安装`（没有东西要重启）。点击 → 行进入 `.updating`，阶段文案直接从 `替换中` 开始（跳过下载/校验/解压）→ `重启中` → `.updated`。操作列宽度为此放宽到 **96**。
- **排序**：默认排序把"待安装"排在"可更新"之前（见 §2.4）：这是最便宜的一步操作，应该最先看到。
- **菜单栏面板**：待安装条目排在列表最前，行尾不显示版本箭头而显示小号 `安装并重启` 按钮（`.borderedProminent .mini`）；摘要行文案 `1 个待安装 · 4 个可更新`。面板"全部更新"同样会安装待安装项。
- **暂存与失效**：暂存目录 `~/Library/Application Support/Xup/Staged/<bundleID>/<version>/`，每个应用只保留一个版本；远端出现更高版本 → 丢弃旧暂存重新下载（行短暂回到"可更新 · 后台下载中"）。安装前重新校验长度/sha512/EdDSA；校验失败或文件被删 → 回到 `可更新 · 暂存包已失效，将重新下载`（橙），发 19.2 的失效通知，下次定时检查重下。暂存超过 **30 天**未安装也视为失效（避免装一个早就过时的版本）。移除应用 / 取消关注 / 改回其他策略 → 立即清理暂存。
- **磁盘提示**：设置 › 通用 底部 `LabeledContent("已下载待安装的更新", value: "2 项 · 186 MB")` + `Button("清除")`，v1 可选。
- 全部更新 / 更新选中 时待安装项与可更新项一起处理；确认 Alert 的计数把它们合并统计。

### 19.5 设置 › 通用 的两项

Section「检查」内，原"发现更新时自动更新"位置：

| 控件 | 文案 | 说明 |
|---|---|---|
| `Picker("新关注条目的默认更新方式")` `.pickerStyle(.menu)` | `手动更新` / `空闲时自动更新`，默认手动 | 脚注：`只影响之后新关注的条目；已有条目保留各自的更新方式，可在列表右键"更新方式"中逐条修改。` |
| `Stepper("空闲判定")` + `TextField` | `无操作 __ 分钟后视为空闲`，1–60，默认 5 | 脚注：`"空闲时自动更新"的条目会等到这么久没有键盘鼠标输入后才开始更新；锁屏与屏幕保护视为空闲。` 默认策略为手动且没有任何条目是自动时，该行 `.foregroundStyle(.secondary)`（仍可改） |

§11"定时检查默认只通知"结论不变：默认策略为"手动更新"，所以零配置下行为与之前完全一致。

### 19.6 策略小标签

灰底胶囊（与 §13.3 的 tag 同样式），`.font(.caption2)`，高 16，文字：

| 策略 | 标签 |
|---|---|
| `manual` | `手动` |
| `auto` | `空闲自动` |
| `autoDownload` | `自动下载`；`installWhenIdle` 开启时 tooltip 追加 `· 空闲且未运行时自动安装` |

- **主窗口表格**：标签放在名称列、名称文字右侧（与名称同一基线，间距 6），**只在策略 ≠ 手动时显示**——默认态什么都不加，保持 §0 "安静"；看见标签即表示"这个条目 Xup 会自己动"。
- **设置 › 软件**：所有已关注行都显示（含"手动"），因为这里就是配置的地方，需要一眼对比；可点击弹出菜单修改。
- **设置 › 应用**：不用胶囊，用只读文字简述（19.3 第 4 条）。
- 标签 tooltip 给出完整含义，如 `空闲时自动更新：无操作 5 分钟后自动执行`。

### 19.7 config.json 字段

```jsonc
{
  "check": {
    "intervalMinutes": 360,
    "notify": true,
    "defaultPolicy": "manual",      // "manual" | "auto"；替代旧 autoUpdate
    "idleMinutes": 5                // 1–60
  },
  "policies": {                     // 缺省条目 = 关注时写入的 defaultPolicy；读不到时按 manual
    "brew:node": "auto",
    "npm:typescript": "auto",
    "app:io.iina.IINA": "autoDownload"
  },
  "apps": [
    { "path": "/Applications/IINA.app", "restartAfterUpdate": true,
      "installWhenIdle": true,      // 仅 policy == autoDownload 时有意义，默认 false
      "customSource": null }
  ]
}
```

- `itemID` 形如 `<kind>:<identifier>`，与 §13.1 关注集合的 key 一致（brew formula/cask 名、npm 包名、uv tool 名、agent id、skill name、`name@marketplace`、应用 bundle id）。
- `policies` 中出现 `autoDownload` 但条目不是应用或来源不支持预下载 → 读取时降级为 `auto` 并写日志 `[xup] app:xxx 的来源不支持预下载，已按"空闲时自动更新"处理`。
- 取消关注 / 移除应用时删除对应 `policies` 键。
- schema 与 `SKILL.md`（`xup` 技能）同步补 `policy` 子命令。

### 19.8 对既有章节的影响

- §3：新增 `.staged` 行；`isActionable` 定义扩展。§2.4：默认排序与操作列宽。§4.1 步骤 1："除非设置中开启自动更新"改为"策略为 `auto` 的条目会在空闲时自动执行（§19.2）"。
- §5.2：面板行支持待安装样式与按钮；摘要行 `N 个待安装 · M 个可更新`。
- §7.1：两项新控件（19.5）。§7.3 / §17：Sheet 新分组、设置 › 应用 简述追加策略。§13.7：软件 Tab 行增加策略标签。
- §9：Symbol 清单已补。
- §11 第三条补充：默认策略手动，零配置行为不变。

## 20. 验收批注三（主代理，2026-11-04，针对 §19）
- 通过。v1 降级：① 表格里"后台下载中 62%"的百分比不做，状态文案为"后台下载中…"（增量下载进度只进日志）；② 设置 › 通用"已下载待安装 · 清除"行为可选项，若实现成本高可放到 v1.2。
- 实现顺序：待"更新历史"功能合入后再开工（共用 UpdateCenter / Scheduler / 表格 / CLI）。

---

## 18. 更新历史（2026-11-04 新增）

记录每一次更新（成功与失败都记），回答"昨天定时更新动了什么、哪个失败了、为什么"。数据层 `Core/UpdateHistory.swift`：`UpdateRecord { id, time, kind, itemID, name, detail?, fromVersion, toVersion?, duration, ok, error?, trigger }`，`Trigger = manual | cli | scheduled | auto`；文件 `~/Library/Application Support/Xup/history.jsonl`（每行一条 JSON，追加写，最多 2000 条，超出时重写只留最近 2000 条）。记录点是 `UpdateCenter.updateOne` 的结束（成功 `toVersion = latest`；失败 `error = localizedDescription`，`toVersion = nil`；`duration` 从开始到结束）。

### 18.1 信息架构位置

- 侧栏在"来源"分组下方新增分组 **"记录"**，唯一一项 **"更新历史"**（`clock.arrow.circlepath`），`⌘9`。
- 角标：最近 24 小时的失败次数，**红色**（`.badge(Text("2").foregroundStyle(.red))`）；为 0 不显示。与来源行的橙色"可更新数"角标语义区分：红 = 需要回头看的失败。
- 选中后内容区整体切换为 `HistoryView`（不再显示 §2.5 状态栏 / §2.6 日志面板，历史视图有自己的状态栏），副标题 `更新历史 · N 条`。
- 菜单栏面板 → 主窗口历史视图：见 18.5。

### 18.2 工具栏

| 控件 | 说明 |
|---|---|
| 筛选 `Picker`（`.menu`） | `全部`（`line.3.horizontal.decrease.circle`）/ `仅失败`（`exclamationmark.triangle`）；状态存 `UIState.historyFailedOnly` |
| 搜索 | 复用 `.searchable`，占位 `搜索名称或错误信息`；匹配 name / detail / error / itemID |
| 清空历史 `trash` | 二次确认 Alert：标题 `清空更新历史？`，正文 `将删除全部 N 条记录，此操作不可撤销。`，按钮 `清空`（destructive）/ `取消`；无记录时禁用 |

### 18.3 列表

`List(selection:)` + `.listStyle(.inset(alternatesRowBackgrounds: true))`，按自然日 `Section` 分组（新的在前），Section 标题 `今天` / `昨天` / `M月d日 EEE`（跨年 `yyyy年M月d日`），标题后缀 `N 条`（`.tertiary`）与 `· M 失败`（红，仅 M > 0）。列表上方一条 24pt 的列标题（`.caption .secondary`，`.bar` 背景），列宽与行共用常量（`HistoryRow`），920 宽窗口（侧栏 210）无横向滚动：

| 列 | 宽 | 内容 |
|---|---|---|
| 时间 | 40 | `HH:mm`，`.monospacedDigit` `.secondary`；tooltip 为完整相对日期时间 |
| 来源 | 16 | `kind.symbol`（`.secondary`），tooltip `kind.title` |
| 名称 | 弹性 | 上 `name`；下 `detail` `.caption .secondary`，中间截断 |
| 版本 | 200 | `from → to`；失败且无目标版本只显示 `from`，`.secondary` |
| 耗时 | 60，右对齐 | `0.8 秒` / `42 秒` / `2 分 05 秒`（`.caption .secondary`） |
| 结果 | 56 | 徽标，见 18.4 |
| 触发 | 40 | 小胶囊标签 `手动` / `CLI` / `定时` / `自动`（`.caption2`，`Capsule().fill(.quaternary)`） |

- 右键菜单：`复制错误信息`（无失败项时禁用；多选时每行 `名称：错误`）/ `在列表中定位`（`arrow.right.circle`，单选；切到该记录的来源分区并选中该条目，条目已不在当前列表时禁用，tooltip 说明）/ 分隔线 / `复制名称` / `复制版本`。双击 = 在列表中定位。
- 底部状态栏 28pt（`.bar`）：左 `共 N 条 · 显示 M 条（有筛选时）· 24 小时内 K 次失败`；右 `上次更新 今天 13:43`。

### 18.4 结果徽标

沿用 §3 的 `.updated` / `.failed` 约定：成功 = `checkmark.seal.fill` + `成功`，`Color.green`；失败 = `xmark.circle.fill` + `失败`，`Color.red`；`.font(.caption)` `.imageScale(.small)`。失败行徽标的 tooltip 为完整 `error`（列表里不再平铺错误文本，避免一行过长；复制走右键菜单）。

### 18.5 空状态与面板文案

- 没有任何记录：`ContentUnavailableView("还没有更新记录", systemImage: "clock.arrow.circlepath")`，描述 `每次更新成功或失败都会记录在这里。`
- 有记录但搜索无结果：`没有匹配“q”的记录`（`magnifyingglass`）+ `清除搜索`。
- 有记录但"仅失败"为空：`没有失败的更新`（`checkmark.seal.fill`）+ `最近的更新全部成功。` + `显示全部`。
- 菜单栏面板（§5.2）摘要区：在"上次检查 …"下方追加一行 `.caption .secondary`：**`上次更新 HH:mm · 成功 N / 失败 M`**（N/M 为当天统计；"失败 M"在 M > 0 时红色；最近一次更新不在今天时显示相对日期 `昨天 11:50`，且当天没有记录时不带成功/失败统计）。整行是 `.plain` 按钮，点击 `ui.sidebar = .history` 并打开主窗口。只在"有可更新"与"全部已是最新"两个状态显示；检查中 / 更新中 / 未选择软件不显示。

### 18.6 CLI / 控制通道

- 控制通道新增 `history`（`limit` 默认 50，`<= 0` 全部；`failedOnly`；`kind`）→ 记录数组（时间倒序，`duration` 保留一位小数）；`history-clear` → `{"cleared": N}`。`update` 命令写入的 `trigger` 为 `cli`。
- CLI：`xup history [--tail N] [--failed] [--kind k] [--json]`（表格列：时间、名称、版本、结果、触发；失败时结果列为 `失败：<error>`）；`xup history clear --yes`（缺 `--yes` 退出码 1）。

---

## 21. 主页面全量显示 + 工具栏"+"添加 Sheet + 设置精简（2026-11-04 IA 变更）

> 用户拍板：主页面要能看到**所有关注的软件及其当前版本**，而不只是可更新项；"软件"与"应用"的管理从设置窗口搬回主界面，且来源分区的交互与"应用"分区一致——工具栏"+"添加、右键"取消关注"/⌫ 移除，**不**做"已关注 | 已安装"分段。取代 §13.7，修订 §2.3 / §2.4 / §2.5 / §6 / §7 的相关条目。

### 21.1 主页面显示全部关注条目

- `ui.showUpToDate` **默认改为 `true`**（`ConfigStore` 默认值、内嵌 schema 与 `Support/config.schema.json`、CLI `defaultConfig()` 同步）。已有 config.json 里显式写的 `false` 不被覆盖（解码缺省才取 true）。
- 工具栏新增分段筛选 **`全部 | 仅可更新`**（`Picker` `.segmented`，直接绑定 `settings.showUpToDate`），位于 `primaryAction` 组末尾、紧挨搜索框左侧。设置 › 通用 的"显示已是最新的条目"开关保留，与该分段联动。
- 列表排序（`UpdateCenter.items(for:)`）：**待安装 → 可更新 → 其他状态（失败 / 未知 / 更新中 / 已更新）→ 最新**，同组按名称。表头手动排序规则不变（§2.4）。
- "最新"行的"最新"列显示当前版本（`latest ?? installed`，`.secondary`），与"已安装"列同值；各 Provider 对关注但未过期的条目返回 `.upToDate`（Homebrew 已如此）。
- 状态栏左侧文案固定顺序：**`共 N 项 · M 个可更新 · K 个待安装[ · F 个失败]`**，为 0 的段省略。

### 21.2 工具栏"+"与"添加要跟踪的 <来源>" Sheet（`AddWatchSheet`）

- 来源分区（Homebrew / npm 全局 / uv tool / Agents / Skills / 插件）与"全部"分区的工具栏有 **`+`**（`plus`，`⇧⌘N`，tooltip "添加 Homebrew…" / "添加软件…"）；"应用"分区的 `+` 仍是 NSOpenPanel（`⌘N`）。表格始终显示已关注条目，**没有**模式切换。
- 点击弹出 `.sheet(item: $ui.addWatch)`（`UIState.addWatch: AddWatchRequest?`，`AddWatchRequest { kind, showsPicker }`），固定 **560 × 480**，结构：
  - 头部（`.padding(.horizontal, 20)`）：标题 `.headline` **"添加要跟踪的 Homebrew"**（"全部"分区打开时为"添加要跟踪的软件"）；说明 `.caption .secondary`"从本机已安装的 {installedNoun} 中勾选，勾选即时生效；点'完成'后 Xup 会检查一次新关注的条目。"；**"全部"分区打开时多一行来源 Picker**（`.segmented` 六段纯文字，不可用来源 `.tertiary` + tooltip "未检测到 …"），搜索框（自带，`minWidth 160, maxWidth 240`）与 Picker 同行、放不下用 `ViewThatFits` 换行；来源分区打开时只有右对齐的搜索框。切换来源清空搜索。
  - 主体：`InstalledListView(kind:query:onDone:)`（原 §13.7 `WatchListPane` 的单来源形态，文件 `InstalledListView.swift`）：本机已安装清单（checkbox · 名称 · detail · 已关注行的策略小标签 §19.6 · 版本，行高 36，交替背景）；加载中 / 为空 / 读取失败 / 不可用 四态同 §13.4。
  - 底部 48pt：`全选` `清空`（只作用于当前过滤结果）· `已关注 N 项 · 共 M 项（显示 K 项）` · 右侧 **`完成`**（`.borderedProminent`，Return）。没有"取消"——勾选已即时生效。
- **勾选即时生效**：300ms 去抖写 `settings.setTracked`；有实际变化时把该来源记入 `ui.pendingRecheckKinds`。**"完成"或任何方式关闭 Sheet（`onDismiss`）** 时若集合非空 → 清空并调用一次 `ui.check(center:)`（沿用"检查中则不重复"的保护）。
- 已安装清单按来源缓存在 `ui.installedCache`，同一 Sheet 内切换来源 / 重新打开不反复执行 `brew list`；每次检查 / 更新结束、或点"重新读取"时清缓存。
- 入口统一改为弹出该 Sheet（`UIState.presentAddWatch(kind:)`，nil → Homebrew + 来源 Picker；`.app` 不走此 Sheet）：
  - §6.9 空状态按钮 **"添加 <来源>…"**（`plus`，`.borderedProminent`）。
  - §6.1 欢迎态：描述"点工具栏的'+'，从本机已安装的软件中勾选，勾选即时生效。"，主按钮 **"添加软件…"**（`plus`）→ 带来源 Picker 的 Sheet；次级链接"添加应用…"不变。
  - §6.6 搜索无结果的链接文案"在'添加…'中查找已安装但未跟踪的条目"。
  - 设置 › 通用："跟踪的软件 N 项 · `管理…`" → 打开主窗口（`openWindow(id:)` + `activate`，侧栏切到 Homebrew）并延迟 0.3s 弹出 Homebrew 的 Sheet。
- 调试：`XUP_DEBUG_SETTINGS=watch:<kind>` 打开主窗口到该来源并弹其 Sheet；`watch`（不带来源）打开"全部"分区并弹带 Picker 的 Sheet；`apps` 打开"应用"分区；`general` / `agents` 仍打开设置窗口。

### 21.3 移除与"应用"分区

- 移除统一走 **右键"取消关注"（`eye.slash`）/ 选中后 ⌫**（§13.1 已有）；工具栏**不加**"移除"按钮。"应用"分区同理：`添加应用…`（`plus`，`⌘N`）+ 右键"配置应用…"/"移除"+ ⌫，不加 `−`。
- 原 §7.3 设置 › 应用 列表（`AppsSettings`）删除；来源标签 §16.5 的样式继续用于"配置应用…"Sheet 头部。

### 21.4 设置窗口

- 只保留 **通用 / Agents**（`SettingsTab = general | agents`），尺寸仍 620×520。`UIState.pickerKind` / `selectWatchTab` 删除。
- 菜单栏面板与 CLI 不变。
