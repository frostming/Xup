import AppKit
import SwiftUI

/// §5.2 菜单栏面板，宽 320，四态：有更新 / 全部最新 / 检查中 / 更新中。
struct MenuBarPanel: View {
    @EnvironmentObject private var center: UpdateCenter
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ui: UIState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var actionable: [UpdateItem] { center.items(for: nil).filter(\.isActionable) }
    private var outdated: [UpdateItem] { center.items(for: nil).filter { $0.status.isOutdated } }
    private var isUpdating: Bool { !center.updatingIDs.isEmpty }
    private var failedCount: Int { center.items.filter(\.isFailed).count }
    /// §13.5 (4)：没有选择任何要跟踪的软件。
    private var nothingTracked: Bool {
        settings.tracked.values.allSatisfy(\.isEmpty) && settings.managedApps.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(12)
            if !outdated.isEmpty {
                Divider()
                itemList.padding(.vertical, 4)
            }
            Divider()
            actionButtons.padding(12)
            Divider()
            menuItems.padding(.vertical, 4)
        }
        .frame(width: 320)
        .ignoresSafeArea()
    }

    // MARK: 摘要

    @ViewBuilder private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            if isUpdating, let p = ui.progress(center: center) {
                ProgressView().controlSize(.small).tint(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("正在更新 \(p.current ?? "…") (\(min(p.done + 1, p.total))/\(p.total))").font(.headline)
                    HStack(spacing: 0) {
                        Text("\(p.done) 已完成").foregroundStyle(.secondary)
                        if failedCount > 0 { Text(" · \(failedCount) 个失败").foregroundStyle(.red) }
                    }.font(.caption)
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).padding(.top, 4)
                }
            } else if isUpdating {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("正在自动更新…").font(.headline)
                    Text(XupFormat.lastChecked(center.lastChecked)).font(.caption).foregroundStyle(.secondary)
                }
            } else if center.isChecking {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("正在检查更新…").font(.headline)
                    Text(checkingSources).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                refreshButton.disabled(true)
            } else if nothingTracked {
                Image(systemName: "checklist").foregroundStyle(.secondary).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("还没有选择要跟踪的软件").font(.headline).foregroundStyle(.secondary)
                    Text("打开 Xup 选择要检查更新的软件").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            } else if !outdated.isEmpty {
                Image(systemName: "arrow.up.circle.fill").foregroundStyle(.orange).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 0) {
                        Text("\(outdated.count) 个可更新").font(.headline)
                        if failedCount > 0 { Text(" · \(failedCount) 个失败").font(.caption).foregroundStyle(.red) }
                    }
                    Text(XupFormat.lastChecked(center.lastChecked)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                refreshButton
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 0) {
                        Text(center.lastChecked == nil ? "尚未检查" : "全部已是最新").font(.headline)
                        if failedCount > 0 { Text(" · \(failedCount) 个失败").font(.caption).foregroundStyle(.red) }
                    }
                    Text("\(center.items.count) 个条目 · \(XupFormat.lastChecked(center.lastChecked))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                refreshButton
            }
        }
    }

    private var checkingSources: String {
        ProviderKind.sidebarOrder.filter { !center.unavailable.contains($0) && !center.untrackedKinds.contains($0) }.map(\.title).joined(separator: "、")
    }

    private var refreshButton: some View {
        Button { ui.check(center: center) } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("检查更新")
    }

    // MARK: 条目

    private var itemList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(outdated.prefix(5)) { item in
                Button {
                    ui.reveal(item)
                    openMain()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.kind.symbol).foregroundStyle(.secondary).frame(width: 16)
                        Text(item.name).lineLimit(1)
                        Spacer()
                        HStack(spacing: 3) {
                            Text(item.installed)
                            Text("→")
                            Text(item.latestText).fontWeight(.medium)
                        }
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PanelRowStyle())
                .foregroundStyle(center.isChecking ? .secondary : .primary)
            }
            if outdated.count > 5 {
                Button {
                    ui.sidebar = .all
                    openMain()
                } label: {
                    Text("还有 \(outdated.count - 5) 项…")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 36).frame(height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PanelRowStyle())
            }
        }
    }

    // MARK: 按钮

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                openMain()
            } label: {
                Label("打开 Xup", systemImage: "macwindow").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            if (!actionable.isEmpty || isUpdating) && !nothingTracked {
                Button {
                    ui.updateAll(center: center, kind: nil)
                } label: {
                    Label("全部更新", systemImage: "arrow.down.to.line").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isUpdating || center.isChecking)
            }
        }
        .controlSize(.large)
    }

    // MARK: 菜单项

    private var menuItems: some View {
        VStack(spacing: 0) {
            PanelMenuItem(title: "检查更新", shortcut: "⌘R") { ui.check(center: center) }
                .disabled(center.isChecking || isUpdating || nothingTracked)
                .keyboardShortcut("r", modifiers: .command)
            PanelMenuItem(title: "设置…", shortcut: "⌘,") {
                // MenuBarExtra 面板是独立窗口，sendAction(showSettingsWindow:) 在这里没有响应链目标；
                // 用 SwiftUI 的 openSettings 环境动作，并先激活应用让设置窗口到前台。
                XupActions.activate()
                openSettings()
            }
                .keyboardShortcut(",", modifiers: .command)
            PanelMenuItem(title: "退出 Xup", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
    }

    private func openMain() {
        ui.mainWindowRequested = true
        openWindow(id: XupActions.mainWindowID)
        XupActions.activate()
    }
}

/// 面板里的菜单式行：悬停高亮 accent。
private struct PanelMenuItem: View {
    let title: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(shortcut).foregroundStyle(.secondary).font(.caption)
            }
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelRowStyle())
    }
}

/// 悬停高亮的行按钮样式。
struct PanelRowStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovering && isEnabled ? Color.accentColor : .clear)
                    .padding(.horizontal, 6)
            )
            .foregroundStyle(hovering && isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.5)
            .onHover { hovering = $0 }
    }
}
