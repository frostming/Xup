import AppKit
import SwiftUI

/// 开发自检：设置环境变量 `XUP_SNAPSHOT_DIR` 后，窗口出现约 2.5 秒把自身渲染为 PNG 写入该目录。
/// 优先用 CGWindowListCreateImage 截本进程窗口（含侧栏毛玻璃与标题栏；自家窗口不需要屏幕录制权限），
/// 失败时退回 `cacheDisplay`。生产环境下无环境变量即不做任何事。
struct WindowSnapshotHook: NSViewRepresentable {
    let name: String
    let delay: TimeInterval

    init(_ name: String, delay: TimeInterval = 2.5) {
        self.name = name
        self.delay = delay
    }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["XUP_SNAPSHOT_DIR"] else { return v }
        // `XUP_SNAPSHOT_DELAY`（秒）可统一覆盖延迟，便于等首次检查结束后再截。
        let delay = env["XUP_SNAPSHOT_DELAY"].flatMap(Double.init) ?? self.delay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak v] in
            guard let window = v?.window else { return }
            Self.snapshot(window, to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// 渲染本进程窗口，不依赖屏幕录制权限：优先把 Core Animation 图层树画出来（侧栏等层托管内容
    /// 用 `cacheDisplay` 会是空白），没有图层时退回 `cacheDisplay`。
    static func snapshot(_ window: NSWindow, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let frameView = window.contentView?.superview ?? window.contentView else { return }
        let bounds = frameView.bounds
        let scale = window.backingScaleFactor
        let rep: NSBitmapImageRep
        if let layer = frameView.layer,
           let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
           let ctx = NSGraphicsContext(bitmapImageRep: bitmap) {
            bitmap.size = bounds.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            ctx.cgContext.scaleBy(x: scale, y: scale)
            layer.render(in: ctx.cgContext)
            NSGraphicsContext.restoreGraphicsState()
            rep = bitmap
        } else {
            guard let cached = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            frameView.cacheDisplay(in: bounds, to: cached)
            rep = cached
        }
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}

/// 调试钩子：`XUP_DEBUG_PANEL_PREVIEW=1` 时在主窗口出现后把 MenuBarPanel 放进一个普通 320pt 窗口显示
/// （SwiftUI 没有公开 API 可编程打开 MenuBarExtra 面板），配合 `XUP_SNAPSHOT_DIR` 截取面板内容。
@MainActor
enum DebugHooks {
    private static var previewWindow: NSWindow?

    static func presentPanelPreviewIfRequested(model: AppModel, ui: UIState) {
        guard ProcessInfo.processInfo.environment["XUP_DEBUG_PANEL_PREVIEW"] == "1", previewWindow == nil else { return }
        // 等首次检查结束再显示，面板才会处于"有更新 / 全部最新"态（含"上次更新"行）；最多等 120 秒。
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(120)
            while (model.center.isChecking || model.center.lastChecked == nil) && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(300))
            }
            let host = NSHostingView(rootView: MenuBarPanel().modifier(XupScenes.Inject(model: model, ui: ui)))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 10), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "MenuBarPanel 预览"
            w.contentView = host
            w.setContentSize(host.fittingSize)
            w.center()
            w.orderFront(nil)
            previewWindow = w
            NSLog("[Xup] XUP_DEBUG_PANEL_PREVIEW → 面板预览窗口 \(host.fittingSize)")
        }
    }
}
