import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 与 AppKit 打交道的小动作。
@MainActor
enum XupActions {
    static let mainWindowID = "main"

    static func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 仅作兜底；视图内请优先用 `@Environment(\.openSettings)`（macOS 14+），响应链方式在菜单栏面板里不可靠。
    static func openSettings() {
        activate()
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    /// 打开 NSOpenPanel 选择 .app，多选。
    static func chooseApps(completion: @escaping ([String]) -> Void) {
        activate()
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "选择要让 Xup 跟踪更新的应用"
        panel.prompt = "添加"
        panel.begin { response in
            guard response == .OK else { return }
            completion(panel.urls.map(\.path))
        }
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func copy(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    /// 正在运行的受管应用名（用于更新前确认）。
    static func runningApps(among items: [UpdateItem]) -> [String] {
        let paths = Set(items.compactMap(\.appPath))
        guard !paths.isEmpty else { return [] }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
        return items.filter { item in
            guard let p = item.appPath else { return false }
            return running.contains(URL(fileURLWithPath: p).standardizedFileURL.path)
        }.map(\.name)
    }
}

/// 来源 tag（设置 › 应用 使用）。
func appSourceTag(detail: String?) -> String {
    guard let d = detail else { return "未知" }
    if d.hasPrefix("Homebrew cask") { return "Homebrew cask" }
    if d.hasPrefix("Sparkle") { return "Sparkle" }
    if d.hasPrefix("electron-updater") { return "electron-updater" }
    if d.hasPrefix("App Store") { return "App Store" }
    if d == AppsProvider.selfUpdateDetail { return "自更新" }
    if d.hasPrefix("自定义 · ") { return "自定义" }
    return "未知"
}

/// §16.5 手动配置来源的标签文字与 tooltip。
extension AppUpdateSource {
    var tagText: String {
        switch self {
        case .githubReleases: return "自定义 · GitHub"
        case .tauri: return "自定义 · Tauri"
        case .electronYML: return "自定义 · electron-updater"
        case .appcast: return "自定义 · Sparkle"
        }
    }

    var tooltip: String {
        switch self {
        case .githubReleases(let repo, let pattern): return "GitHub \(repo)" + (pattern.map { " · \($0)" } ?? "")
        case .tauri(let url): return "Tauri \(url.absoluteString)"
        case .electronYML(let url): return "electron-updater \(url.absoluteString)"
        case .appcast(let url): return "Sparkle \(url.absoluteString)"
        }
    }
}

/// §17 `ManagedApp.restartAfterUpdate` 的界面语义："应用正在运行时怎么办"。
/// 只是文案层的映射，配置键与字段名不变。
enum AppRunningPolicy: Hashable, CaseIterable {
    /// restartAfterUpdate = true：替换前自动退出，替换后自动重新打开。
    case relaunch
    /// restartAfterUpdate = false：应用在运行就跳过本次更新，等用户关闭后再更新。
    case waitForQuit

    init(restartAfterUpdate: Bool) { self = restartAfterUpdate ? .relaunch : .waitForQuit }
    var restartAfterUpdate: Bool { self == .relaunch }

    /// Picker / 右键菜单选项文字。
    var title: String {
        switch self {
        case .relaunch: return "自动退出并重新打开"
        case .waitForQuit: return "等我关闭后再更新"
        }
    }

    /// 表格 detail 行末尾的小标签。
    var shortTag: String {
        switch self {
        case .relaunch: return "运行中自动重开"
        case .waitForQuit: return "运行中跳过"
        }
    }

    var tooltip: String {
        switch self {
        case .relaunch: return "更新时若应用正在运行，Xup 会先下载校验，替换前自动退出它，替换后自动重新打开。"
        case .waitForQuit: return "更新时若应用正在运行，这次更新会跳过；等你关闭应用后再更新。应用未运行时照常更新。"
        }
    }

    /// 设置 › 应用 列表下方的说明。
    static let explanation = "每个应用可在“配置应用…”里选择正在运行时的处理：“自动退出并重新打开”（运行中自动重开）会在替换前退出、替换后重开；“等我关闭后再更新”（运行中跳过）则在应用运行时跳过本次更新，等你关闭后再更新。"

    /// 策略为"等我关闭后再更新"且应用正在运行、又有新版本时，状态列的提示。
    static let skippedWhileRunningHint = "应用运行中，按设置暂不更新；关闭后点“更新”，或在“配置应用…”里改为自动退出并重新打开"

    /// 轻量判断：该 .app 是否有正在运行的进程（按 bundleURL 路径比对）。
    static func isRunning(appPath: String) -> Bool {
        let target = URL(fileURLWithPath: appPath).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL.path == target }
    }
}
