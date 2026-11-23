import AppKit
import SwiftUI

/// 入口：macOS 15+ 可用 `defaultLaunchBehavior` 精确控制主窗口是否随启动打开；
/// macOS 14 退回默认行为（首个 Window 场景随启动打开，非首次启动时由 MainWindow 立即关闭）。
@main
enum XupMain {
    static func main() {
        stayUnhidden()
        if #available(macOS 15, *) {
            NSLog("[Xup] entry: macOS 15+ App")
            XupApp15.main()
        } else {
            NSLog("[Xup] entry: macOS 14 App")
            XupApp.main()
        }
    }

    /// 菜单栏 App 没有 Dock 图标、不在 ⌘Tab 里，一旦被隐藏（`open -j` 启动、⌘H 等）用户就没法取消隐藏，
    /// 而隐藏状态下 MenuBarExtra 的面板点了也不显示。所以被隐藏后立即取消隐藏（不激活、不抢焦点）。
    /// `open -j` 是直接以隐藏状态启动，不发 didHide，所以启动完成时也要检查一次。
    private static func stayUnhidden() {
        for name in [NSApplication.didFinishLaunchingNotification, NSApplication.didHideNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    guard NSApp.isHidden else { return }
                    NSLog("[Xup] hidden (\(note.name.rawValue)), unhiding so the menu bar panel stays usable")
                    NSApp.unhideWithoutActivation()
                }
            }
        }
    }
}

/// 三个场景的公共构造，供两套 App 复用。
@MainActor
enum XupScenes {
    static func menuBar(_ model: AppModel, _ ui: UIState) -> some Scene {
        MenuBarExtra {
            MenuBarPanel().modifier(Inject(model: model, ui: ui))
        } label: {
            MenuBarLabel().modifier(Inject(model: model, ui: ui))
        }
        .menuBarExtraStyle(.window)
    }

    static func mainWindow(_ model: AppModel, _ ui: UIState) -> some Scene {
        Window("Xup", id: XupActions.mainWindowID) {
            MainWindow().modifier(Inject(model: model, ui: ui))
        }
        .defaultSize(width: 920, height: 640)
        .windowResizability(.contentMinSize)
    }

    static func settings(_ model: AppModel, _ ui: UIState) -> some Scene {
        Settings {
            SettingsView().modifier(Inject(model: model, ui: ui))
        }
    }

    struct Inject: ViewModifier {
        let model: AppModel
        let ui: UIState
        func body(content: Content) -> some View {
            content
                .environmentObject(model)
                .environmentObject(model.center)
                .environmentObject(model.history)
                .environmentObject(model.scheduler)
                .environmentObject(model.settings)
                .environmentObject(ui)
        }
    }
}

/// macOS 14：主窗口放在第一位以便首次启动自动打开。
struct XupApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var ui = UIState()

    var body: some Scene {
        XupScenes.mainWindow(model, ui)
        XupScenes.menuBar(model, ui)
        XupScenes.settings(model, ui)
    }
}

@available(macOS 15, *)
struct XupApp15: App {
    @StateObject private var model = AppModel()
    @StateObject private var ui = UIState()

    var body: some Scene {
        XupScenes.mainWindow(model, ui)
            .defaultLaunchBehavior(ui.openMainWindowOnLaunch ? .presented : .suppressed)
        XupScenes.menuBar(model, ui)
        XupScenes.settings(model, ui)
    }
}
