import Combine
import Foundation
import UserNotifications

@MainActor
final class Scheduler {
    private let settings: AppSettings
    private let center: UpdateCenter
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var lastNotifiedIDs: Set<String> = []
    private var started = false

    init(settings: AppSettings, center: UpdateCenter) {
        self.settings = settings
        self.center = center
    }

    /// 应用启动时调用：立即检查一次并开始计时。
    func start() {
        guard !started else { return }
        started = true
        Notifier.requestAuthorization()
        settings.$config
            .map(\.check.intervalMinutes)
            .removeDuplicates()
            .sink { [weak self] minutes in
                self?.reschedule(minutes: minutes)
            }
            .store(in: &cancellables)
        Task { await runScheduledCheck() }
    }

    private func reschedule(minutes: Int) {
        timer?.invalidate()
        timer = nil
        guard minutes > 0 else { return }
        let interval = TimeInterval(minutes * 60)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.runScheduledCheck()
            }
        }
        t.tolerance = min(interval * 0.1, 300)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 执行一次检查，并根据设置发通知 / 自动更新。
    func runScheduledCheck() async {
        await center.checkAll()
        let actionable = center.actionableItems
        let ids = Set(actionable.map(\.id))

        if settings.notifyOnUpdates, center.outdatedCount > 0, ids != lastNotifiedIDs {
            lastNotifiedIDs = ids
            let names = center.items(for: nil).filter { $0.status.isOutdated }.prefix(5).map(\.name)
            var body = names.joined(separator: "、")
            if center.outdatedCount > names.count { body += " 等" }
            Notifier.notify(title: "Xup：\(center.outdatedCount) 个可更新", body: body)
        }

        if settings.autoUpdate, !actionable.isEmpty {
            await center.updateAll()
            let updated = center.items.filter { ids.contains($0.id) && $0.status == .updated }
            let failed = center.items.filter { ids.contains($0.id) && { if case .failed = $0.status { return true }; return false }($0) }
            var body = "成功 \(updated.count) 个"
            if !failed.isEmpty {
                body += "，失败 \(failed.count) 个：" + failed.prefix(5).map(\.name).joined(separator: "、")
            }
            Notifier.notify(title: "Xup：自动更新完成", body: body)
            if failed.isEmpty { lastNotifiedIDs = [] }
        }
    }
}

enum Notifier {
    /// 只有在 .app bundle 内运行时 UNUserNotificationCenter 才可用，否则会崩溃。
    private static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error { print("[Xup] 通知授权失败：\(error.localizedDescription)") }
            else if !granted { print("[Xup] 用户未允许通知") }
        }
    }

    static func notify(title: String, body: String) {
        guard isAvailable else {
            print("[Xup 通知] \(title) — \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("[Xup] 发送通知失败：\(error.localizedDescription)") }
        }
    }
}
