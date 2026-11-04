import AppKit
import SwiftUI

/// §16.3 / §17 "应用设置" Sheet（宽 440）：「应用正在运行时」策略 + 「更新来源」配置。
struct AppSourceSheet: View {
    let app: ManagedApp

    @EnvironmentObject private var center: UpdateCenter
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    enum SourceType: String, CaseIterable, Identifiable {
        case github, tauri, electron, appcast
        var id: String { rawValue }

        var title: String {
            switch self {
            case .github: return "GitHub Releases"
            case .tauri: return "Tauri 更新 JSON"
            case .electron: return "electron-updater (latest-mac.yml)"
            case .appcast: return "Sparkle appcast"
            }
        }

        var explanation: String {
            switch self {
            case .github: return "读取最新 Release 的 tag 与资源文件"
            case .tauri: return "Tauri 更新 JSON"
            case .electron: return "electron-updater 的 latest-mac.yml"
            case .appcast: return "Sparkle appcast"
            }
        }

        var urlPlaceholder: String {
            switch self {
            case .tauri: return "https://releases.example.com/latest.json"
            case .electron: return "https://updates.example.com/latest-mac.yml"
            case .appcast: return "https://example.com/appcast.xml"
            case .github: return ""
            }
        }
    }

    enum TestState: Equatable {
        case idle
        case running
        case success(latest: String, file: String?, elapsed: TimeInterval)
        case failure(String, elapsed: TimeInterval)
    }

    @State private var type: SourceType = .github
    @State private var repo = ""
    @State private var assetPattern = ""
    /// 各 URL 类型分别保留输入（§16.3：切换类型时已填内容保留）。
    @State private var urls: [SourceType: String] = [:]
    @State private var test: TestState = .idle
    @State private var testTask: Task<Void, Never>?
    /// §17 应用正在运行时的处理方式（映射 `restartAfterUpdate`）。
    @State private var policy: AppRunningPolicy = .relaunch
    /// §19.3 更新方式 + 子开关。
    @State private var updatePolicy: UpdatePolicy = .manual
    @State private var installWhenIdle = false

    private var item: UpdateItem? { center.items.first { $0.id == "app:\(app.path)" } }
    private var installed: String { item?.installed ?? "?" }
    private var hasExisting: Bool { app.source != nil }
    private var selfUpdating: Bool { item?.isSelfUpdating ?? false }
    /// 来源是否支持预下载（自动识别结果或已配置来源）。
    private var supportsStaging: Bool {
        if hasExisting { return true }  // 四类手动来源都由 Xup 下载替换
        return item?.supportsStaging ?? false
    }
    private var storedUpdatePolicy: UpdatePolicy { item.map { settings.policy(for: $0) } ?? settings.policy(for: app.itemID) }
    private var policyChanged: Bool {
        policy.restartAfterUpdate != app.restartAfterUpdate
            || updatePolicy != storedUpdatePolicy
            || installWhenIdle != app.installWhenIdle
    }
    /// 用户是否填写过来源字段（或本来就有配置）；没有的话"保存"只写策略。
    private var sourceTouched: Bool {
        hasExisting || !repo.trimmingCharacters(in: .whitespaces).isEmpty
            || !assetPattern.trimmingCharacters(in: .whitespaces).isEmpty
            || urls.values.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    private var canSave: Bool {
        guard test != .running else { return false }
        if sourceTouched { return fieldsValid }
        return policyChanged
    }

    private var urlText: Binding<String> {
        Binding(get: { urls[type] ?? "" }, set: { urls[type] = $0 })
    }

    // MARK: 校验

    private static let repoRegex = try! NSRegularExpression(pattern: "^[\\w.-]+/[\\w.-]+$")

    /// 把 https://github.com/owner/repo(/releases…) 裁成 owner/repo。
    private static func normalizeRepo(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: "github.com/") {
            t = String(t[r.upperBound...])
            let parts = t.split(separator: "/", omittingEmptySubsequences: true)
            if parts.count >= 2 { t = "\(parts[0])/\(parts[1])" }
            if t.hasSuffix(".git") { t = String(t.dropLast(4)) }
        }
        return t
    }

    private var repoValid: Bool {
        let t = repo.trimmingCharacters(in: .whitespaces)
        return Self.repoRegex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    private var currentURL: URL? {
        var t = (urls[type] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = URL(string: t)?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        if type == .electron, !t.lowercased().hasSuffix(".yml"), !t.lowercased().hasSuffix(".yaml") {
            if !t.hasSuffix("/") { t += "/" }
            t += "latest-mac.yml"
        }
        guard let u = URL(string: t), u.host != nil else { return nil }
        return u
    }

    private var urlValid: Bool { currentURL != nil }
    private var urlInsecure: Bool { currentURL?.scheme?.lowercased() == "http" }

    private var fieldsValid: Bool { type == .github ? repoValid : urlValid }

    /// 由当前输入构造来源；校验不通过返回 nil。
    private var builtSource: AppUpdateSource? {
        switch type {
        case .github:
            guard repoValid else { return nil }
            let p = assetPattern.trimmingCharacters(in: .whitespaces)
            return .githubReleases(repo: repo.trimmingCharacters(in: .whitespaces), assetPattern: p.isEmpty ? nil : p)
        case .tauri:
            guard let u = currentURL else { return nil }
            return .tauri(url: u)
        case .electron:
            guard let u = currentURL else { return nil }
            return .electronYML(url: u)
        case .appcast:
            guard let u = currentURL else { return nil }
            return .appcast(url: u)
        }
    }

    // MARK: 视图

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                // §19.3 更新方式（先决定"要不要自动"，再决定"运行中怎么办"）
                LabeledContent("更新方式") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $updatePolicy) {
                            ForEach(UpdatePolicy.allCases) { p in
                                Text(p.title).tag(p)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        .disabled(selfUpdating)
                        .onChange(of: updatePolicy) { _, p in
                            if p == .autoDownload, !supportsStaging { updatePolicy = storedUpdatePolicy == .autoDownload ? .auto : storedUpdatePolicy }
                        }
                        Text(selfUpdating ? "该应用自行更新，此项无效。" : updatePolicy.explanation)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !supportsStaging, !selfUpdating {
                            Text("由 \(stagingBlockedBy) 安装，无法预下载")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Toggle("空闲且应用未运行时自动安装", isOn: $installWhenIdle)
                            .disabled(updatePolicy != .autoDownload || selfUpdating)
                            .padding(.leading, 20)
                            .help("暂存完成的包会在系统空闲且该应用没有在运行时自动完成安装；应用在运行就继续等你点“安装并重启”。")
                    }
                }

                Divider().padding(.vertical, 4)

                // §17 应用正在运行时
                LabeledContent("应用正在运行时") {
                    Picker("", selection: $policy) {
                        ForEach(AppRunningPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .disabled(selfUpdating)
                }
                Text(selfUpdating ? "该应用自行更新，此项无效。" : policy.tooltip)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().padding(.vertical, 4)

                // §16.3 更新来源
                Picker("更新来源", selection: $type) {
                    ForEach(SourceType.allCases) { t in Text(t.title).tag(t) }
                }
                .pickerStyle(.menu)
                .onChange(of: type) { _, _ in test = .idle }
                Text(type.explanation).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                fields

                LabeledContent {
                    HStack(spacing: 8) {
                        Button(test == .idle ? "测试" : "再次测试") { runTest() }
                            .buttonStyle(.bordered)
                            .disabled(!fieldsValid || test == .running)
                        Text(testStatusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } label: { Text("") }
                resultBox
            }
            .formStyle(.columns)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            footer
        }
        .frame(width: 440)
        .background(WindowSnapshotHook("sheet", delay: 3))
        .onAppear(perform: load)
        .onDisappear { testTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("配置 \(app.name)").font(.headline)
                Text("\(app.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) · 已安装 \(installed)")
                    .font(.caption).monospaced().foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(detectedLabel)
                .font(.caption)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: Capsule())
                .help("不配置时 Xup 按自动识别结果检查更新")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    /// "自动下载"不可用时的原因。
    private var stagingBlockedBy: String {
        let tag = appSourceTag(detail: item?.detail)
        switch tag {
        case "Homebrew cask": return "Homebrew"
        case "App Store": return "App Store"
        default: return "应用自身"
        }
    }

    /// 自动识别结果：当前无手动配置时直接来自列表 detail；已有配置时核心层不再暴露识别结果。
    private var detectedLabel: String {
        if hasExisting { return "已手动配置" }
        let tag = appSourceTag(detail: item?.detail)
        return "自动识别：" + (tag == "自更新" || tag == "未知" ? "未识别" : tag)
    }

    @ViewBuilder private var fields: some View {
        switch type {
        case .github:
            LabeledContent("仓库") {
                VStack(alignment: .leading, spacing: 3) {
                    TextField("", text: $repo, prompt: Text("owner/repo"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder).monospaced()
                        .overlay(invalidBorder(!repo.isEmpty && !repoValid))
                        .onChange(of: repo) { _, v in
                            let n = Self.normalizeRepo(v)
                            if n != v { repo = n }
                            test = .idle
                        }
                    Text(!repo.isEmpty && !repoValid ? "格式应为 owner/repo" : "可直接粘贴仓库 URL")
                        .font(.caption).foregroundStyle(!repo.isEmpty && !repoValid ? .red : .secondary)
                }
            }
            LabeledContent("资源文件匹配") {
                VStack(alignment: .leading, spacing: 3) {
                    TextField("", text: $assetPattern, prompt: Text(verbatim: "*arm64*.dmg（可选）"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder).monospaced()
                        .onChange(of: assetPattern) { _, _ in test = .idle }
                    Text("留空则自动选择本机架构的 .dmg / .zip")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .tauri, .electron, .appcast:
            LabeledContent("URL") {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: "link").foregroundStyle(.secondary).imageScale(.small)
                        TextField("", text: urlText, prompt: Text(type.urlPlaceholder))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder).monospaced()
                            .overlay(invalidBorder(!(urls[type] ?? "").isEmpty && !urlValid))
                            .onChange(of: urls[type]) { _, _ in test = .idle }
                    }
                    if !(urls[type] ?? "").isEmpty, !urlValid {
                        Text("必须是 http(s):// 开头的完整 URL").font(.caption).foregroundStyle(.red)
                    } else if urlInsecure {
                        Label("未加密的 \(type == .appcast ? "appcast" : "URL")", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.yellow)
                    } else if type == .electron {
                        Text("目录 URL 会自动补 latest-mac.yml").font(.caption).foregroundStyle(.secondary)
                    } else if type == .tauri {
                        Text("更新 JSON 的完整地址").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("建议使用 https").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func invalidBorder(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5).stroke(Color.red, lineWidth: on ? 1 : 0)
    }

    private var testStatusText: String {
        switch test {
        case .idle: return "拉取一次，显示识别到的最新版本"
        case .running: return "正在获取…"
        case .success(_, _, let e), .failure(_, let e): return String(format: "刚刚 · 用时 %.1f 秒", e)
        }
    }

    // MARK: 结果区（§16.3.1 三态）

    @ViewBuilder private var resultBox: some View {
        Group {
            switch test {
            case .idle:
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                    Text("尚未测试")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.tertiary))
            case .running:
                HStack(alignment: .top, spacing: 8) {
                    ProgressView().controlSize(.mini)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("正在获取 \(targetHost)…")
                        if let s = targetDescription {
                            Text(s).font(.caption).monospaced().foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.tertiary))
            case .success(let latest, let file, _):
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("最新版本 \(latest)").fontWeight(.semibold)
                            Text("· 已安装 \(installed) →").foregroundStyle(.secondary)
                            Text(comparison(latest).0).foregroundStyle(comparison(latest).1)
                        }
                        Text(file.map { "下载 \($0)" } ?? "未找到可下载的 macOS 安装包（保存后只能显示版本）")
                            .font(.caption).foregroundStyle(file == nil ? .orange : .secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.green.opacity(0.35)))
            case .failure(let msg, _):
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(msg).fontWeight(.semibold).foregroundStyle(.red).lineLimit(3)
                        Text("仍可保存，但可能读不到版本")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.red.opacity(0.35)))
            }
        }
        .font(.callout)
        .frame(minHeight: 36)
        .textSelection(.enabled)
    }

    private var targetHost: String {
        switch type {
        case .github: return "api.github.com"
        default: return currentURL?.host ?? ""
        }
    }

    private var targetDescription: String? {
        switch type {
        case .github: return "GET https://api.github.com/repos/\(repo.trimmingCharacters(in: .whitespaces))/releases/latest"
        default: return currentURL.map { "GET \($0.absoluteString)" }
        }
    }

    private func comparison(_ latest: String) -> (String, Color) {
        guard installed != "?" else { return ("无法比较", .secondary) }
        switch VersionCompare.compare(latest, installed) {
        case .orderedDescending: return ("可更新", .orange)
        case .orderedSame: return ("已是最新", .green)
        case .orderedAscending: return ("远端版本更低", .secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button("移除配置", role: .destructive) {
                settings.setSource(path: app.path, nil)
                dismiss()
                Task { await center.checkAll() }
            }
            .buttonStyle(.plain)
            .foregroundStyle(hasExisting ? .red : .secondary)
            .disabled(!hasExisting)
            .help("清除手动配置，恢复自动识别")
            Spacer()
            Button("取消") {
                testTask?.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("保存") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
    }

    // MARK: 动作

    private func load() {
        policy = AppRunningPolicy(restartAfterUpdate: app.restartAfterUpdate)
        updatePolicy = storedUpdatePolicy
        installWhenIdle = app.installWhenIdle
        switch app.source {
        case .githubReleases(let r, let p):
            type = .github; repo = r; assetPattern = p ?? ""
        case .tauri(let u):
            type = .tauri; urls[.tauri] = u.absoluteString
        case .electronYML(let u):
            type = .electron; urls[.electron] = u.absoluteString
        case .appcast(let u):
            type = .appcast; urls[.appcast] = u.absoluteString
        case nil:
            break
        }
    }

    private func runTest() {
        guard let source = builtSource else { return }
        testTask?.cancel()
        test = .running
        let started = Date()
        testTask = Task {
            do {
                let r = try await withTimeout(seconds: 15) { try await center.probeSource(for: app, source: source) }
                guard !Task.isCancelled else { return }
                test = .success(latest: r.latest, file: r.downloadURL?.lastPathComponent, elapsed: Date().timeIntervalSince(started))
            } catch {
                guard !Task.isCancelled else { return }
                let msg = error is TimeoutError ? "请求超时" : error.localizedDescription
                test = .failure(msg, elapsed: Date().timeIntervalSince(started))
            }
        }
    }

    /// 同时写入更新方式、运行时策略与来源；来源字段没动过时只保存策略（不触发重新检查）。
    private func save() {
        testTask?.cancel()
        if policy.restartAfterUpdate != app.restartAfterUpdate { settings.setRestart(path: app.path, policy.restartAfterUpdate) }
        if installWhenIdle != app.installWhenIdle { settings.setInstallWhenIdle(path: app.path, installWhenIdle) }
        if updatePolicy != storedUpdatePolicy { center.setPolicy(updatePolicy, for: [app.itemID]) }
        if sourceTouched {
            guard let source = builtSource else { return }
            let changed = source != app.source
            settings.setSource(path: app.path, source)
            dismiss()
            if changed { Task { await center.checkAll() } }
        } else {
            dismiss()
        }
    }
}

// MARK: - 超时

private struct TimeoutError: Error {}

private func withTimeout<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }
        let r = try await group.next()!
        group.cancelAll()
        return r
    }
}
