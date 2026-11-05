import SwiftUI

/// §19.3 "更新方式"菜单的目标：来自列表条目或"添加…"Sheet 的关注行。
struct PolicyTarget: Hashable {
    let id: String
    let isApp: Bool
    let supportsStaging: Bool
    let canUpdate: Bool
    let item: UpdateItem?

    init(item: UpdateItem) {
        id = item.id
        isApp = item.kind == .app
        supportsStaging = item.supportsStaging
        canUpdate = item.canUpdate
        self.item = item
    }

    /// "添加…"Sheet 的行：只知道来源与关注名（homebrew 可带 detail = formula/cask）。
    init(kind: ProviderKind, name: String, detail: String?) {
        if kind == .homebrew {
            let sub = (detail == "cask" || detail == "formula") ? detail! : "formula"
            id = "homebrew:\(sub)/\(name)"
        } else {
            id = "\(kind.rawValue):\(name)"
        }
        isApp = false
        supportsStaging = false
        canUpdate = true
        item = nil
    }

    var appPath: String? { isApp ? String(id.dropFirst("app:".count)) : nil }
}

/// 菜单项内容（放进 `Menu` / `contextMenu`）：手动更新 · 空闲时自动更新 · （仅应用）自动下载，手动重启 · 分隔 · Toggle 子开关。
/// 多选：各项策略不一致时都不勾；包含非应用时不显示"自动下载"。
struct PolicyMenuItems: View {
    let targets: [PolicyTarget]
    @EnvironmentObject private var center: UpdateCenter
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ui: UIState

    private var policies: Set<UpdatePolicy> {
        Set(targets.map { t in t.item.map { settings.policy(for: $0) } ?? settings.policy(for: t.id) })
    }
    private var current: UpdatePolicy? { policies.count == 1 ? policies.first : nil }
    private var allApps: Bool { !targets.isEmpty && targets.allSatisfy(\.isApp) }
    private var allStageable: Bool { !targets.isEmpty && targets.allSatisfy(\.supportsStaging) }
    private var anyAppRunningState: Bool? {
        let paths = targets.compactMap(\.appPath)
        guard !paths.isEmpty else { return nil }
        let states = Set(paths.map { settings.installWhenIdle(path: $0) })
        return states.count == 1 ? states.first : nil
    }
    /// 不可更新的条目（自更新 / pinned / 无更新命令）：整体禁用。
    private var allDisabled: Bool { !targets.isEmpty && targets.allSatisfy { !$0.canUpdate && $0.item != nil } }

    var body: some View {
        Group {
            option(.manual)
            option(.auto)
            if allApps {
                option(.autoDownload)
                    .disabled(!allStageable)
                    .help(allStageable ? UpdatePolicy.autoDownload.explanation : "该应用由 Homebrew / App Store 执行安装，不支持预下载")
                Divider()
                Toggle("空闲且应用未运行时自动安装", isOn: Binding(
                    get: { anyAppRunningState ?? false },
                    set: { on in
                        for p in targets.compactMap(\.appPath) { settings.setInstallWhenIdle(path: p, on) }
                    }
                ))
                .disabled(current != .autoDownload)
            }
        }
        .disabled(allDisabled)
    }

    private func option(_ p: UpdatePolicy) -> some View {
        Toggle(p.title, isOn: Binding(
            get: { current == p },
            set: { on in if on { apply(p) } }
        ))
    }

    private func apply(_ p: UpdatePolicy) {
        let ids = Set(targets.map(\.id))
        center.setPolicy(p, for: ids)
        ui.flash("已将 \(ids.count) 项设为“\(p.title)”")
    }
}

/// §19.6 策略小标签：灰底胶囊，`.caption2`，高 16。
struct PolicyTag: View {
    let policy: UpdatePolicy
    var installWhenIdle = false
    /// 显式传入而非 @EnvironmentObject：PolicyTag 会被渲染在 Table 行 / Menu label 等
    /// 由 AppKit 单独托管的视图里，macOS 27 上这些位置拿不到环境对象会直接崩溃。
    let idleMinutes: Int

    private var tooltip: String {
        switch policy {
        case .manual: return "手动更新：定时检查只通知，你点“更新”才执行"
        case .auto: return "空闲时自动更新：无操作 \(idleMinutes) 分钟后自动执行"
        case .autoDownload:
            return "自动下载，手动重启：发现新版本立即后台下载暂存，点“安装并重启”完成"
                + (installWhenIdle ? " · 空闲且未运行时自动安装" : "")
        }
    }

    var body: some View {
        Text(policy.shortTag)
            .font(.caption2)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
            .help(tooltip)
            .accessibilityLabel("更新方式：\(policy.title)")
    }
}
