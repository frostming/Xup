import CoreGraphics
import Foundation

/// §19.2 空闲判定的可注入接口（Scheduler 与测试共用）。
protocol IdleChecking: Sendable {
    /// 无键盘鼠标输入的秒数。
    func secondsSinceLastInput() -> TimeInterval
    /// 锁屏 / 屏幕保护中。
    func isScreenLocked() -> Bool
}

extension IdleChecking {
    /// 无输入时间 ≥ 阈值，或已锁屏，即视为空闲。
    func isIdle(threshold: TimeInterval) -> Bool {
        isScreenLocked() || secondsSinceLastInput() >= threshold
    }
}

/// 真实系统：`CGEventSource.secondsSinceLastEventType(.combinedSessionState, kCGAnyInputEventType)` +
/// `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`。
struct IdleMonitor: IdleChecking {
    /// kCGAnyInputEventType = (CGEventType)(~0)，Swift 头文件未导出该常量。
    private static let anyInput: CGEventType = unsafeBitCast(UInt32.max, to: CGEventType.self)

    func secondsSinceLastInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInput)
    }

    func isScreenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = dict["CGSSessionScreenIsLocked"] as? Bool, locked { return true }
        if let n = dict["CGSSessionScreenIsLocked"] as? NSNumber, n.boolValue { return true }
        // 屏幕保护运行时 CGSSessionScreenIsLocked 通常也为真；兜底再看 loginwindow 的屏保标记。
        if let saver = dict["CGSSessionScreenSaverIsRunning"] as? NSNumber, saver.boolValue { return true }
        return false
    }

    /// 日志用：`空闲 7 分钟`。
    static func describe(seconds: TimeInterval) -> String {
        seconds >= 60 ? "空闲 \(Int(seconds / 60)) 分钟" : "空闲 \(Int(seconds)) 秒"
    }
}

/// 测试 / 调试用：固定返回值。
struct FixedIdle: IdleChecking {
    var seconds: TimeInterval
    var locked: Bool = false
    func secondsSinceLastInput() -> TimeInterval { seconds }
    func isScreenLocked() -> Bool { locked }
}
