import Foundation

struct NpmProvider: UpdateProvider {
    let kind: ProviderKind = .npm

    func isAvailable() -> Bool { Shell.which("npm") != nil }

    /// `npm ls -g --depth=0 --json` → { dependencies: { name: { version } } }
    private func installedPackages() async throws -> [String: String] {
        let ls = try await Shell.run(["npm", "ls", "-g", "--depth=0", "--json"], timeout: 120)
        var installed: [String: String] = [:]
        if let j = try? JSONSerialization.jsonObject(with: Data(ls.stdout.utf8)) as? [String: Any],
           let deps = j["dependencies"] as? [String: Any] {
            for (k, v) in deps { installed[k] = (v as? [String: Any])?["version"] as? String ?? "?" }
        }
        return installed
    }

    func listInstalled(log: @escaping Logger) async throws -> [InstalledEntry] {
        try await installedPackages()
            .map { InstalledEntry(name: $0.key, detail: "npm -g", version: $0.value) }
            .sorted { $0.name < $1.name }
    }

    func check(tracked: Set<String>, log: @escaping Logger) async throws -> [UpdateItem] {
        guard !tracked.isEmpty else {
            log("npm: 未选择任何软件，跳过", false)
            return []
        }
        let installed = try await installedPackages().filter { tracked.contains($0.key) }
        // npm outdated exits 1 when something is outdated; that is not an error.
        log("npm outdated -g", false)
        let out = try await Shell.run(["npm", "outdated", "-g", "--json"], timeout: 300)
        var outdated: [String: (current: String, latest: String)] = [:]
        if !out.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let j = try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any] {
            for (k, v) in j where tracked.contains(k) {
                guard let d = v as? [String: Any] else { continue }
                outdated[k] = (d["current"] as? String ?? installed[k] ?? "?", d["latest"] as? String ?? d["wanted"] as? String ?? "?")
            }
        } else if out.status > 1 {
            throw ShellError.failed("npm outdated -g", out.status, out.stderr)
        }
        var items: [UpdateItem] = []
        for (name, ver) in installed.sorted(by: { $0.key < $1.key }) {
            if let o = outdated[name] {
                items.append(UpdateItem(kind: .npm, name: name, detail: "npm -g", installed: o.current, latest: o.latest, status: .outdated))
            } else {
                items.append(UpdateItem(kind: .npm, name: name, detail: "npm -g", installed: ver, latest: ver, status: .upToDate))
            }
        }
        let missing = tracked.subtracting(installed.keys)
        if !missing.isEmpty { log("npm: 关注的 \(missing.sorted().joined(separator: "、")) 已不在全局安装列表中", true) }
        log("npm: \(outdated.count)/\(installed.count) 个可更新", false)
        return items
    }

    func update(_ item: UpdateItem, log: @escaping Logger) async throws {
        let cmd = ["npm", "install", "-g", "\(item.name)@latest"]
        log("$ " + cmd.joined(separator: " "), false)
        try await Shell.runChecked(cmd, timeout: 900, onOutput: log)
    }
}
