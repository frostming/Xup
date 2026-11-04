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

    static func openSettings() {
        activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
