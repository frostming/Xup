import Combine
import Foundation
import UserNotifications

/// 定时检查 + §19.2 自动更新调度（`AutoUpdateScheduler`）。
///
/// - 只有定时检查（`.scheduled`）与启动首检（`.auto`）结束后才评估自动更新；用户手动"检查更新"不触发。
/// - 策略为 `auto` 且可操作的条目进入"待空闲"集合：空闲立即执行，否则每 5 分钟复查，直到执行或下一轮定时检查重新生成集合（不累积）。
/// - 策略为 `autoDownload` 的应用立即后台预下载；`installWhenIdle` 打开且空闲且应用未运行时自动安装。
@MainActor
final class Scheduler: ObservableObject {
    private let settings: AppSettings
    private let center: UpdateCenter
    private let idle: IdleChecking
    private let now: () -> Date
    private var timer: Timer?
    private var recheckTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var lastNotifiedIDs: Set<String> = []
    private var started = false
    /// 同一条目连续自动更新失败次数（§19.2 第 7 条）。
    private var consecutiveFailures: [String: Int] = [:]

    // 可注入的依赖（测试用；默认走 UpdateCenter / NSWorkspace）。
    var itemsSource: () -> [UpdateItem]
    var runUpdate: (Set<String>, Trigger) async -> Void
    var runStage: (Set<String>) async -> Set<String>
    var isAppRunning: (String) -> Bool

    /// "待空闲"集合：策略为 auto、等系统空闲后自动更新的条目 id。
    @Published private(set) var pendingAutoIDs: Set<String> = []
    /// 集合生成时间（下一轮定时检查会重新生成）。
    private(set) var pendingSince: Date?
    /// 正在后台预下载 / 自动执行中（面板摘要"自动"前缀用）。
    @Published private(set) var isAutoUpdating = false

    init(settings: AppSettings, center: UpdateCenter, idle: IdleChecking = IdleMonitor(), now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.center = center
        self.idle = idle
        self.now = now
        itemsSource = { [unowned center] in center.items }
        runUpdate = { [unowned center] ids, trigger in await center.update(ids: ids, trigger: trigger) }
        runStage = { [unowned center] ids in await center.stage(ids: ids) }
        isAppRunning = { AppRunningPolicy.isRunning(appPath: $0) }
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
        Task { await runScheduledCheck(trigger: .auto) }
    }

    private func reschedule(minutes: Int) {
        timer?.invalidate()
        timer = nil
        guard minutes > 0 else { return }
        let interval = TimeInterval(minutes * 60)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.runScheduledCheck(trigger: .scheduled)
            }
        }
        t.tolerance = min(interval * 0.1, 300)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 执行一次检查，并根据设置发通知 / 评估自动更新。
    /// `trigger` 记入更新历史：计时器触发为 .scheduled，启动时的首次检查为 .auto。
    func runScheduledCheck(trigger: Trigger = .scheduled) async {
        await center.checkAll()
        notifyFoundUpdates()
        await evaluateAutomation(trigger: trigger)
    }

    /// §7.1 "发现更新时通知"（与自动更新无关）。
    private func notifyFoundUpdates() {
        let ids = Set(center.actionableItems.map(\.id))
        guard settings.notifyOnUpdates, center.outdatedCount > 0, ids != lastNotifiedIDs else { return }
        lastNotifiedIDs = ids
        let names = center.items(for: nil).filter { $0.status.isOutdated }.prefix(5).map(\.name)
        var body = names.joined(separator: "、")
        if center.outdatedCount > names.count { body += " 等" }
        Notifier.notify(title: "Xup：\(center.outdatedCount) 个可更新", body: body)
    }

    // MARK: - 自动更新评估

    /// 空闲阈值（秒）。
    var idleThreshold: TimeInterval { TimeInterval(settings.idleMinutes * 60) }

    /// 复查间隔：5 分钟；检查间隔 ≤ 15 分钟时取 min(5, interval/2)。
    var recheckInterval: TimeInterval {
        let m = settings.checkIntervalMinutes
        if m > 0, m <= 15 { return TimeInterval(min(5.0, Double(m) / 2) * 60) }
        return 5 * 60
    }

    /// 一轮定时检查结束后：重新生成"待空闲"集合（旧集合作废）、触发 autoDownload 的后台预下载、尝试立即执行。
    func evaluateAutomation(trigger: Trigger) async {
        let items = itemsSource()
        var autoIDs: Set<String> = []
        var downloadIDs: Set<String> = []
        for item in items where item.isActionable {
            switch settings.policy(for: item) {
            case .manual: continue
            case .auto: autoIDs.insert(item.id)
            case .autoDownload:
                if item.status.isOutdated { downloadIDs.insert(item.id) }
            }
        }
        pendingAutoIDs = autoIDs
        pendingSince = autoIDs.isEmpty ? nil : now()
        if !autoIDs.isEmpty {
            center.appendLog(source: "Xup", text: "\(autoIDs.count) 项将在空闲时自动更新：" + names(of: autoIDs, in: items))
        }
        if !downloadIDs.isEmpty {
            // 预下载不需要空闲，独立进行；完成后再评估 installWhenIdle 自动安装。
            Task { [weak self] in
                guard let self else { return }
                let staged = await self.runStage(downloadIDs)
                self.notifyStaged(staged)
                await self.tryInstallStaged(trigger: trigger)
                self.ensureRecheck()
            }
        }
        await tryRunPending(trigger: trigger)
    }

    /// 5 分钟复查：仍待空闲的集合 + installWhenIdle 的暂存应用。
    func recheckPending() async {
        await tryRunPending(trigger: .scheduled)
    }

    /// 空闲则执行待空闲集合与可自动安装的暂存应用；否则安排复查。
    private func tryRunPending(trigger: Trigger) async {
        if !pendingAutoIDs.isEmpty, idle.isIdle(threshold: idleThreshold) {
            let ids = pendingAutoIDs
            pendingAutoIDs = []
            pendingSince = nil
            let items = itemsSource()
            center.appendLog(source: "Xup", text: "\(IdleMonitor.describe(seconds: idle.secondsSinceLastInput()))，开始自动更新 \(ids.count) 项：" + names(of: ids, in: items))
            isAutoUpdating = true
            await runUpdate(ids, trigger)
            isAutoUpdating = false
            notifyAutoResult(ids)
        }
        await tryInstallStaged(trigger: trigger)
        ensureRecheck()
    }

    /// `installWhenIdle` 自动安装：staged && installWhenIdle && 空闲 && 应用未运行。应用在运行则本轮跳过。
    private func tryInstallStaged(trigger: Trigger) async {
        guard idle.isIdle(threshold: idleThreshold) else { return }
        let candidates = installWhenIdleCandidates(itemsSource())
        let ready = candidates.filter { item in
            guard let path = item.appPath else { return false }
            return !isAppRunning(path)
        }
        guard !ready.isEmpty else { return }
        let ids = Set(ready.map(\.id))
        center.appendLog(source: "Xup", text: "空闲且应用未运行，自动安装已下载的更新：" + ready.map(\.name).joined(separator: "、"))
        isAutoUpdating = true
        await runUpdate(ids, trigger)
        isAutoUpdating = false
        for item in itemsSource() where ids.contains(item.id) {
            if item.status == .updated {
                Notifier.notify(title: "\(item.name) 已更新到 \(item.latest ?? "")", body: "已在应用未运行时自动完成安装。")
            } else if case .failed(let msg) = item.status {
                Notifier.notify(title: "自动更新失败：\(item.name)", body: "\(msg)。原版本未受影响。")
            }
        }
    }

    /// 策略为 autoDownload、已暂存且 installWhenIdle 打开的应用。
    func installWhenIdleCandidates(_ items: [UpdateItem]) -> [UpdateItem] {
        items.filter { item in
            guard item.status.isStaged, let path = item.appPath else { return false }
            return settings.installWhenIdle(path: path) && settings.policy(for: item) == .autoDownload
        }
    }

    /// 还有事要等（待空闲集合非空，或有 installWhenIdle 的暂存应用）→ 安排复查定时器；否则取消。
    private func ensureRecheck() {
        let hasWork = !pendingAutoIDs.isEmpty || !installWhenIdleCandidates(itemsSource()).isEmpty
        recheckTimer?.invalidate()
        recheckTimer = nil
        guard hasWork else { return }
        let t = Timer(timeInterval: recheckInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.recheckPending() }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        recheckTimer = t
    }

    // MARK: - 通知文案（§19.2 表）

    private func names(of ids: Set<String>, in items: [UpdateItem]) -> String {
        items.filter { ids.contains($0.id) }.map(\.name).sorted().joined(separator: "、")
    }

    private func notifyAutoResult(_ ids: Set<String>) {
        let items = itemsSource().filter { ids.contains($0.id) }
        let updated = items.filter { $0.status == .updated }
        let failed = items.filter(\.isFailed)
        for item in items {
            if item.isFailed { consecutiveFailures[item.id, default: 0] += 1 } else { consecutiveFailures[item.id] = nil }
        }
        if failed.isEmpty { lastNotifiedIDs = [] }
        guard settings.notifyOnUpdates else { return }
        func failLine(_ item: UpdateItem) -> String {
            var s = "\(item.name) 更新失败：\(item.status.message ?? "")"
            if (consecutiveFailures[item.id] ?? 0) >= 3 { s += "（已连续 \(consecutiveFailures[item.id]!) 次失败，建议手动检查日志）" }
            return s
        }
        if failed.isEmpty {
            Notifier.notify(title: "已自动更新 \(updated.count) 项",
                            body: updated.map(\.name).joined(separator: "、") + " 已在你离开时更新到最新版本。")
        } else if updated.isEmpty {
            Notifier.notify(title: "自动更新失败：" + failed.map(\.name).joined(separator: "、"),
                            body: (failed.first.map { "\($0.status.message ?? "")。" } ?? "") + "原版本未受影响。"
                                + ((consecutiveFailures[failed.first!.id] ?? 0) >= 3 ? "已连续 3 次失败，建议手动检查日志。" : ""))
        } else {
            Notifier.notify(title: "自动更新：\(updated.count) 成功，\(failed.count) 失败",
                            body: failed.prefix(3).map(failLine).joined(separator: "；") + "。点击查看日志。")
        }
    }

    /// 已下载待安装：单个 `IINA 1.5.0 已下载`；多个合并为 `2 个应用已下载更新`。
    private func notifyStaged(_ ids: Set<String>) {
        guard settings.notifyOnUpdates, !ids.isEmpty else { return }
        let items = itemsSource().filter { ids.contains($0.id) && $0.status.isStaged }
        guard !items.isEmpty else { return }
        if items.count == 1, let it = items.first {
            Notifier.notify(title: "\(it.name) \(it.status.stagedVersion ?? "") 已下载",
                            body: "新版本已准备好。点击“安装并重启”完成更新，只需几秒。")
        } else {
            Notifier.notify(title: "\(items.count) 个应用已下载更新",
                            body: items.map(\.name).joined(separator: "、") + " 已准备好，点击“安装并重启”完成更新。")
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
