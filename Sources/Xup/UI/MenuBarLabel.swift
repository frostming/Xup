import AppKit
import SwiftUI

/// §5.1 菜单栏图标。
/// MenuBarExtra 的 label 会被 SwiftUI 栅格化成 NSStatusBarButton 的 image；
/// Text 内嵌 Image、TimelineView、背景胶囊等都不可靠（图片丢失或无限刷新）。
/// 这里自己绘制一张模板 NSImage：左侧 SF Symbol，右侧可更新数量。
struct MenuBarLabel: View {
    @EnvironmentObject private var center: UpdateCenter

    private var working: Bool { center.isChecking || !center.updatingIDs.isEmpty }
    private var failed: Bool { center.items.contains(where: \.isFailed) || !center.providerErrors.isEmpty }
    private var count: Int { center.actionableItems.count }

    private var symbol: String {
        if working { return "arrow.triangle.2.circlepath" }
        if failed { return "exclamationmark.arrow.triangle.2.circlepath" }
        return count > 0 ? "arrow.up.circle.fill" : "arrow.up.circle"
    }

    var body: some View {
        Image(nsImage: StatusImage.make(symbol: symbol, count: working ? 0 : count))
    }
}

enum StatusImage {
    private static var cache: [String: NSImage] = [:]

    static func make(symbol: String, count: Int) -> NSImage {
        let key = "\(symbol)#\(count)"
        if let img = cache[key] { return img }

        let height: CGFloat = 18
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: "Xup")?
            .withSymbolConfiguration(config) ?? NSImage(size: NSSize(width: 16, height: 16))
        let iconSize = icon.size

        let text = count > 99 ? "99+" : (count > 0 ? "\(count)" : "")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]
        let textSize = text.isEmpty ? .zero : (text as NSString).size(withAttributes: attrs)
        let gap: CGFloat = text.isEmpty ? 0 : 3
        let width = ceil(iconSize.width + gap + textSize.width)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let iconRect = NSRect(x: 0, y: (height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height)
            icon.draw(in: iconRect)
            if !text.isEmpty {
                let textRect = NSRect(x: iconSize.width + gap, y: (height - textSize.height) / 2 - 0.5,
                                      width: textSize.width, height: textSize.height)
                (text as NSString).draw(in: textRect, withAttributes: attrs)
            }
            return true
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }
}
