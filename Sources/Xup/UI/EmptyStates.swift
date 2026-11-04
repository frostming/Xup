import SwiftUI

/// §6 空状态与特殊状态。
enum EmptyStates {
    /// 6.1 首次启动（从未选择任何软件）
    struct Welcome: View {
        let pick: () -> Void
        let addApps: () -> Void
        var body: some View {
            ContentUnavailableView {
                Label("先选择要跟踪的软件", systemImage: "arrow.up.circle")
            } description: {
                Text("Xup 只会检查和更新你勾选的条目。点工具栏的“+”，从本机已安装的软件中勾选，勾选即时生效。")
            } actions: {
                Button(action: pick) { Label("添加软件…", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                Button("添加应用…", action: addApps).buttonStyle(.link)
            }
        }
    }

    /// 6.1b 已选择但从未检查
    struct Ready: View {
        let count: Int
        let check: () -> Void
        var body: some View {
            ContentUnavailableView {
                Label("准备就绪", systemImage: "arrow.up.circle")
            } description: {
                Text("已跟踪 \(count) 个条目。点击“检查更新”开始。")
            } actions: {
                Button("检查更新", action: check).buttonStyle(.borderedProminent)
            }
        }
    }

    /// 6.9 关注集合为空（某来源）
    struct Untracked: View {
        let kind: ProviderKind
        let pick: () -> Void
        var body: some View {
            ContentUnavailableView {
                Label("还没有选择要跟踪的软件", systemImage: kind.symbol)
            } description: {
                Text("从本机已安装的 \(kind.installedNoun) 中勾选要让 Xup 检查更新的条目。")
            } actions: {
                Button(action: pick) { Label("添加 \(kind.title)…", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// 6.2 检查中（无结果缓存）
    struct Checking: View {
        let sources: [String]
        var body: some View {
            ContentUnavailableView {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("正在检查更新…").font(.title3)
                }
            } description: {
                Text("正在查询 " + sources.joined(separator: "、") + "…")
            }
        }
    }

    /// 6.3 来源不可用
    struct Unavailable: View {
        let kind: ProviderKind
        let recheck: () -> Void
        private var tool: String {
            switch kind {
            case .homebrew: return "brew"
            case .npm: return "npm"
            case .uv: return "uv"
            case .agent: return "已知的 CLI agent"
            case .app: return "应用"
            case .skill: return "npx 与 ~/.agents/.skill-lock.json"
            case .plugin: return "claude 或 codex"
            }
        }
        private var docs: URL? {
            switch kind {
            case .homebrew: return URL(string: "https://brew.sh/zh-cn/")
            case .npm: return URL(string: "https://nodejs.org/zh-cn/download")
            case .uv: return URL(string: "https://docs.astral.sh/uv/getting-started/installation/")
            default: return nil
            }
        }
        var body: some View {
            ContentUnavailableView {
                Label("未检测到 \(kind.title)", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Xup 在 PATH 中找不到 `\(tool)`。安装后重新检查即可。")
            } actions: {
                HStack {
                    if let docs { Link("安装说明", destination: docs).buttonStyle(.bordered) }
                    Button("重新检测", action: recheck).buttonStyle(.bordered)
                }
            }
        }
    }

    /// 检查失败（provider 级错误）
    struct ProviderFailed: View {
        let kind: ProviderKind
        let message: String
        let retry: () -> Void
        var body: some View {
            ContentUnavailableView {
                Label("\(kind.title) 检查失败", systemImage: "xmark.circle")
            } description: {
                Text(message)
            } actions: {
                Button("重试", action: retry).buttonStyle(.bordered)
            }
        }
    }

    /// 6.4 全部最新
    struct AllUpToDate: View {
        let total: Int
        let lastChecked: Date?
        let recheck: () -> Void
        var body: some View {
            ContentUnavailableView {
                Label {
                    Text("全部已是最新")
                } icon: {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                }
            } description: {
                Text("\(total) 个条目均为最新版本。\(XupFormat.lastChecked(lastChecked))")
            } actions: {
                Button("再次检查", action: recheck).buttonStyle(.bordered)
            }
        }
    }

    /// 6.5 应用分区为空
    struct NoApps: View {
        let addApps: () -> Void
        var body: some View {
            ContentUnavailableView {
                Label("还没有跟踪的应用", systemImage: "macwindow.badge.plus")
            } description: {
                Text("添加 /Applications 中的应用，Xup 会自动识别它来自 Homebrew、Sparkle、electron-updater 还是 App Store；识别不了的可以手动配置来源。")
            } actions: {
                Button("添加应用…", action: addApps).buttonStyle(.borderedProminent)
            }
        }
    }

    /// 6.6 搜索无结果
    struct NoResults: View {
        let query: String
        let clear: () -> Void
        var pick: (() -> Void)? = nil
        var body: some View {
            ContentUnavailableView {
                Label("没有匹配“\(query)”的条目", systemImage: "magnifyingglass")
            } description: {
                if pick != nil { Text("主窗口只显示已跟踪的条目。") }
            } actions: {
                Button("清除搜索", action: clear).buttonStyle(.bordered)
                if let pick {
                    Button("在“添加…”中查找已安装但未跟踪的条目", action: pick).buttonStyle(.link)
                }
            }
        }
    }

    /// 6.7 无任何可用来源
    struct NoSources: View {
        let addApps: () -> Void
        var body: some View {
            ContentUnavailableView {
                Label("没有可用的更新来源", systemImage: "questionmark.folder")
            } description: {
                Text("未检测到 Homebrew、npm、uv、skills CLI、Claude Code / Codex 或已知的 CLI agent。你仍可以在“应用”中添加 App。")
            } actions: {
                Button("添加应用…", action: addApps).buttonStyle(.bordered)
            }
        }
    }
}
