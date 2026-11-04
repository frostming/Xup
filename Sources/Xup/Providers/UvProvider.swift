import Foundation

struct UvProvider: UpdateProvider {
    let kind: ProviderKind = .uv

    func isAvailable() -> Bool { Shell.which("uv") != nil }

    /// `uv tool list` 输出 "name v1.2.3" 行，后跟 "- entrypoint" 行。
    private func installedTools() async throws -> [(String, String)] {
        let r = try await Shell.runChecked(["uv", "tool", "list"], timeout: 120)
        var tools: [(String, String)] = []
        for line in r.stdout.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("-") else { continue }
            let parts = s.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            var v = String(parts[1])
            if v.hasPrefix("v") { v.removeFirst() }
            // "name v1.2.3 (from …)" → drop extras
            v = String(v.split(separator: " ").first ?? Substring(v))
            tools.append((String(parts[0]), v))
        }
        return tools
    }

    func listInstalled(log: @escaping Logger) async throws -> [InstalledEntry] {
        try await installedTools()
            .map { InstalledEntry(name: $0.0, detail: "uv tool", version: $0.1) }
            .sorted { $0.name < $1.name }
    }

    func check(tracked: Set<String>, log: @escaping Logger) async throws -> [UpdateItem] {
        guard !tracked.isEmpty else {
            log("uv: 未选择任何软件，跳过", false)
            return []
        }
        let tools = try await installedTools().filter { tracked.contains($0.0) }
        log("uv: 查询 PyPI 最新版本（\(tools.count) 个）", false)
        let items: [UpdateItem] = await withTaskGroup(of: UpdateItem.self) { group in
            for (name, installed) in tools {
                group.addTask {
                    do {
                        let json = try await Shell.fetchJSON(URL(string: "https://pypi.org/pypi/\(name)/json")!)
                        let latest = ((json as? [String: Any])?["info"] as? [String: Any])?["version"] as? String ?? "?"
                        let status: ItemStatus = VersionCompare.isNewer(latest, than: installed) ? .outdated : .upToDate
                        return UpdateItem(kind: .uv, name: name, detail: "uv tool", installed: installed, latest: latest, status: status)
                    } catch {
                        return UpdateItem(kind: .uv, name: name, detail: "uv tool", installed: installed, latest: nil,
                                          status: .unknown("PyPI 查询失败: \(error.localizedDescription)"))
                    }
                }
            }
            var out: [UpdateItem] = []
            for await i in group { out.append(i) }
            return out.sorted { $0.name < $1.name }
        }
        log("uv: \(items.filter(\.status.isOutdated).count)/\(items.count) 个可更新", false)
        return items
    }

    func update(_ item: UpdateItem, log: @escaping Logger) async throws {
        let cmd = ["uv", "tool", "upgrade", item.name]
        log("$ " + cmd.joined(separator: " "), false)
        try await Shell.runChecked(cmd, timeout: 900, onOutput: log)
    }
}
