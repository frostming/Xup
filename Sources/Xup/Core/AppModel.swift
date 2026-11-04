import Foundation

@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let center: UpdateCenter
    let scheduler: Scheduler
    let control: ControlServer

    init() {
        let settings = AppSettings()
        let center = UpdateCenter(settings: settings)
        self.settings = settings
        self.center = center
        self.scheduler = Scheduler(settings: settings, center: center)
        self.control = ControlServer(handler: ControlCommands.makeHandler(center: center, settings: settings))

        // config.json 的日志（含启动期缓存的迁移/加载消息）进入界面日志与 xup.log。
        settings.store.log = { [weak center] text, isError in
            center?.appendLog(source: "配置", text: text, isError: isError)
        }
        // electron.deltaDownload / keepVersionsPerApp → Providers/BlockmapDelta.swift 的 DeltaDownloadPolicy。
        settings.store.onElectronSettings = { enabled, keep in
            DeltaDownloadPolicy.isEnabled = enabled
            DeltaDownloadPolicy.keepVersionsPerApp = keep
        }
        // 配置被外部修改（CLI / 编辑器）后，关注列表 / 应用列表 / Homebrew 选项变化时重新检查一次；
        // 只改间隔、通知等开关不触发检查。
        settings.onExternalChange = { [weak center] old, new, source in
            guard let center, source == .external else { return }
            guard old.tracked != new.tracked || old.apps != new.apps || old.homebrew != new.homebrew else { return }
            Task { @MainActor in
                await center.waitUntilIdle()
                await center.checkAll()
            }
        }

        if let err = control.start() {
            center.appendLog(source: "控制", text: err, isError: true)
        } else {
            center.appendLog(source: "控制", text: "控制通道就绪：\(control.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
        }

        scheduler.start()
        installDebugHooks()
    }

    /// 验收用调试钩子：`XUP_DEBUG_UPDATE=id1,id2` → 首次检查完成后自动更新这些条目。
    private func installDebugHooks() {
        guard let raw = ProcessInfo.processInfo.environment["XUP_DEBUG_UPDATE"], !raw.isEmpty else { return }
        let ids = Set(raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        Task { [center] in
            while center.lastChecked == nil || center.isChecking {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            center.appendLog(source: "Debug", text: "XUP_DEBUG_UPDATE → 更新 \(ids.sorted().joined(separator: ", "))")
            await center.update(ids: ids)
        }
    }
}
