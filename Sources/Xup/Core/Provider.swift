import Foundation

typealias Logger = @Sendable (_ text: String, _ isError: Bool) -> Void

/// 本机已安装、可供用户加入关注列表的条目（"选择软件" Sheet 使用）。
/// `name` 即关注集合中保存的键（brew 为 token、npm/uv 为包名、agent 为 binary、
/// skill 为 skill 名、plugin 为 "claude/<name@mkt>" 或 "codex/<name@mkt>"）。
struct InstalledEntry: Identifiable, Hashable, Sendable {
    let name: String
    let detail: String?
    let version: String

    var id: String { name }

    init(name: String, detail: String? = nil, version: String) {
        self.name = name
        self.detail = detail
        self.version = version
    }
}

protocol UpdateProvider: Sendable {
    var kind: ProviderKind { get }
    /// Whether the underlying tool exists on this machine.
    func isAvailable() -> Bool
    /// 列出本机已安装、可被关注的条目；供"选择软件" Sheet 使用。
    func listInstalled(log: @escaping Logger) async throws -> [InstalledEntry]
    /// 只检查 `tracked` 中的条目；`tracked` 为空时直接返回 []（不做 brew update 等重活）。
    /// `.app` 的 AppsProvider 忽略该参数（managedApps 即选择）。
    func check(tracked: Set<String>, log: @escaping Logger) async throws -> [UpdateItem]
    /// Updates a single item. Throws on failure.
    func update(_ item: UpdateItem, log: @escaping Logger) async throws
}

struct CaskInfo: Sendable {
    let token: String
    let installedVersion: String?
    let currentVersion: String
    let autoUpdates: Bool
    let appNames: [String]
}

/// Shared Homebrew knowledge so the Apps provider can reuse what the Homebrew provider already fetched.
actor BrewState {
    private(set) var installedCasks: [CaskInfo] = []
    private(set) var outdatedCasks: [String: (installed: String, current: String)] = [:]
    private var ready = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func begin() { ready = false }

    func publish(installed: [CaskInfo], outdated: [String: (installed: String, current: String)]) {
        installedCasks = installed
        outdatedCasks = outdated
        finish()
    }

    func finish() {
        ready = true
        let w = waiters
        waiters = []
        w.forEach { $0.resume() }
    }

    func waitUntilReady() async {
        if ready { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func cask(forApp appName: String) -> CaskInfo? {
        installedCasks.first { $0.appNames.contains(appName) }
    }
}

enum BrewJSON {
    static func parseInstalledCasks(_ json: Any) -> [CaskInfo] {
        guard let root = json as? [String: Any], let casks = root["casks"] as? [[String: Any]] else { return [] }
        return casks.compactMap { c in
            guard let token = c["token"] as? String else { return nil }
            var apps: [String] = []
            for art in c["artifacts"] as? [[String: Any]] ?? [] {
                if let a = art["app"] as? [Any] {
                    for e in a {
                        if let s = e as? String { apps.append((s as NSString).lastPathComponent) }
                        else if let d = e as? [String: Any], let t = d["target"] as? String { apps.append((t as NSString).lastPathComponent) }
                    }
                }
            }
            return CaskInfo(token: token,
                            installedVersion: c["installed"] as? String,
                            currentVersion: c["version"] as? String ?? "",
                            autoUpdates: c["auto_updates"] as? Bool ?? false,
                            appNames: apps)
        }
    }
}
