import Foundation

struct HomebrewProvider: UpdateProvider {
    let kind: ProviderKind = .homebrew
    let greedy: Bool
    let brewState: BrewState

    func isAvailable() -> Bool { Shell.which("brew") != nil }

    // MARK: - 已安装列表

    /// `brew list --formula --versions` / `brew list --cask --versions`，每行 "token v1 [v2…]"。
    func listInstalled(log: @escaping Logger) async throws -> [InstalledEntry] {
        async let f = Shell.runChecked(["brew", "list", "--formula", "--versions"], timeout: 120)
        async let c = Shell.runChecked(["brew", "list", "--cask", "--versions"], timeout: 120)
        let (formulae, casks) = try await (f, c)
        var out: [InstalledEntry] = []
        out += Self.parseListVersions(formulae.stdout).map { InstalledEntry(name: $0.0, detail: "formula", version: $0.1) }
        out += Self.parseListVersions(casks.stdout).map { InstalledEntry(name: $0.0, detail: "cask", version: $0.1) }
        // 同名 formula 与 cask 极少见；以 token 去重，formula 在前。
        var seen: Set<String> = []
        return out.filter { seen.insert($0.name).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func parseListVersions(_ text: String) -> [(String, String)] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let token = parts.first, !token.isEmpty else { return nil }
            let versions = parts.dropFirst().joined(separator: ", ")
            return (String(token), versions.isEmpty ? "?" : versions)
        }
    }

    // MARK: - 检查

    func check(tracked: Set<String>, log: @escaping Logger) async throws -> [UpdateItem] {
        await brewState.begin()
        var finished = false
        defer { if !finished { Task { await brewState.finish() } } }

        guard !tracked.isEmpty else {
            log("Homebrew: 未选择任何软件，跳过", false)
            await brewState.finish()
            finished = true
            return []
        }

        log("brew update", false)
        let upd = try await Shell.run(["brew", "update"], timeout: 600, onOutput: log)
        if !upd.ok { log("brew update 失败（继续使用本地索引）", true) }

        var args = ["brew", "outdated", "--json=v2"]
        if greedy { args.append("--greedy") }
        let r = try await Shell.runChecked(args, timeout: 600)
        let json = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8))
        var items: [UpdateItem] = []
        var outdatedTokens: Set<String> = []
        var outdatedCasks: [String: (installed: String, current: String)] = [:]
        if let root = json as? [String: Any] {
            for f in root["formulae"] as? [[String: Any]] ?? [] {
                guard let name = f["name"] as? String else { continue }
                let installed = (f["installed_versions"] as? [String])?.joined(separator: ", ") ?? "?"
                let current = f["current_version"] as? String ?? "?"
                let pinned = f["pinned"] as? Bool ?? false
                guard tracked.contains(name) else { continue }
                outdatedTokens.insert(name)
                items.append(UpdateItem(kind: .homebrew, name: name, detail: "formula", installed: installed, latest: current,
                                        status: .outdated, canUpdate: !pinned, hint: pinned ? "已 pin，跳过" : nil, idSuffix: "formula/\(name)"))
            }
            for c in root["casks"] as? [[String: Any]] ?? [] {
                guard let name = c["name"] as? String else { continue }
                let installed = (c["installed_versions"] as? [String])?.joined(separator: ", ") ?? "?"
                let current = c["current_version"] as? String ?? "?"
                if installed == current { continue } // greedy "latest" casks
                outdatedCasks[name] = (installed, current)   // Apps 分区需要完整的 cask 过期表，不按 tracked 过滤
                guard tracked.contains(name) else { continue }
                outdatedTokens.insert(name)
                items.append(UpdateItem(kind: .homebrew, name: name, detail: "cask", installed: installed, latest: current,
                                        status: .outdated, idSuffix: "cask/\(name)"))
            }
        }

        // 关注但未过期的条目标记为最新，让用户看到已被关注。
        let installedAll = (try? await listInstalled(log: log)) ?? []
        for e in installedAll where tracked.contains(e.name) && !outdatedTokens.contains(e.name) {
            items.append(UpdateItem(kind: .homebrew, name: e.name, detail: e.detail, installed: e.version, latest: e.version,
                                    status: .upToDate, idSuffix: "\(e.detail ?? "formula")/\(e.name)"))
        }

        var installed: [CaskInfo] = []
        if let info = try? await Shell.runChecked(["brew", "info", "--cask", "--json=v2", "--installed"], timeout: 300),
           let j = try? JSONSerialization.jsonObject(with: Data(info.stdout.utf8)) {
            installed = BrewJSON.parseInstalledCasks(j)
        }
        await brewState.publish(installed: installed, outdated: outdatedCasks)
        finished = true
        log("Homebrew: \(outdatedTokens.count)/\(tracked.count) 个可更新", false)
        return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func update(_ item: UpdateItem, log: @escaping Logger) async throws {
        var cmd = ["brew", "upgrade"]
        if item.detail == "cask" {
            cmd.append("--cask")
            if greedy { cmd.append("--greedy") }
        } else {
            cmd.append("--formula")
        }
        cmd.append(item.name)
        log("$ " + cmd.joined(separator: " "), false)
        try await Shell.runChecked(cmd, timeout: 1800, onOutput: log)
    }
}
