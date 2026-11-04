import AppKit
import SwiftUI

/// 开发自检：设置环境变量 `XUP_SNAPSHOT_DIR` 后，窗口出现约 2.5 秒把自身渲染为 PNG 写入该目录。
/// 使用 `cacheDisplay` 渲染本进程窗口，不依赖屏幕录制权限。生产环境下无环境变量即不做任何事。
struct WindowSnapshotHook: NSViewRepresentable {
    let name: String
    let delay: TimeInterval

    init(_ name: String, delay: TimeInterval = 2.5) {
        self.name = name
        self.delay = delay
    }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        guard let dir = ProcessInfo.processInfo.environment["XUP_SNAPSHOT_DIR"] else { return v }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak v] in
            guard let window = v?.window else { return }
            Self.snapshot(window, to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func snapshot(_ window: NSWindow, to url: URL) {
        guard let frameView = window.contentView?.superview ?? window.contentView else { return }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }
}
