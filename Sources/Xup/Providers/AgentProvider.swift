import Foundation

struct AgentProvider: UpdateProvider {
    let kind: ProviderKind = .agent
    let specs: [AgentSpec]

    func isAvailable() -> Bool { true }

    enum ManagedBy { case brew, npm, uv, native }

    static func managedBy(path: String) -> ManagedBy {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        // brew formula 可能把 npm 包装在 Cellar/.../node_modules 下，所以 Cellar/Caskroom 先判；
        // 但 Homebrew 的 node 装的全局包在 /opt/homebrew/lib/node_modules，归 npm，所以 npm 要在泛匹配 /homebrew/ 之前。
        if resolved.contains("/Cellar/") || resolved.contains("/Caskroom/") { return .brew }
        if resolved.contains("/node_modules/") || resolved.contains("/.nvm/") || resolved.contains("/.volta/") || resolved.contains("/.fnm/") { return .npm }
        if resolved.contains("/uv/tools/") { return .uv }
        if resolved.contains("/homebrew/") { return .brew }
        return .native
    }

    /// 本机存在且不由 brew/npm/uv 管理的 agent（其他的在对应分区更新）。
    private func nativeSpecs() -> [(AgentSpec, String)] {
        specs.compactMap { spec in
            guard let path = Shell.which(spec.binary), Self.managedBy(path: path) == .native else { return nil }
            return (spec, path)
        }
    }

    private func installedVersion(_ spec: AgentSpec) async -> String {
        let args = [spec.binary] + (spec.versionArgs ?? ["--version"])
        if let r = try? await Shell.run(args, timeout: 30), let v = VersionCompare.extract(from: r.stdout + " " + r.stderr) {
            return v
        }
        return "?"
    }

    /// 最新版本来源：npm 包优先，其次 GitHub release；都没有返回 nil。
    private func latestSourceName(_ spec: AgentSpec) -> String? {
        if spec.npmPackage != nil { return "registry" }
        if spec.githubRepo != nil { return "GitHub release" }
        return nil
    }

    private func latestVersion(_ spec: AgentSpec) async throws -> String? {
        if let pkg = spec.npmPackage {
            let json = try await Shell.fetchJSON(URL(string: "https://registry.npmjs.org/\(pkg)/latest")!)
            return (json as? [String: Any])?["version"] as? String
        }
        if let repo = spec.githubRepo {
            return try await AppSources.latestGitHubRelease(repo: repo).version
        }
        return nil
    }

    func listInstalled(log: @escaping Logger) async throws -> [InstalledEntry] {
        let native = nativeSpecs()
        return await withTaskGroup(of: InstalledEntry.self) { group in
            for (spec, path) in native {
                group.addTask {
                    InstalledEntry(name: spec.binary,
                                   detail: "\(spec.name) · \(path.replacingOccurrences(of: Shell.home, with: "~"))",
                                   version: await installedVersion(spec))
                }
            }
            var out: [InstalledEntry] = []
            for await e in group { out.append(e) }
            return out.sorted { $0.name < $1.name }
        }
    }

    func check(tracked: Set<String>, log: @escaping Logger) async throws -> [UpdateItem] {
        guard !tracked.isEmpty else {
            log("Agents: 未选择任何软件，跳过", false)
            return []
        }
        let targets = specs.filter { tracked.contains($0.binary) }
        let items: [UpdateItem] = await withTaskGroup(of: UpdateItem?.self) { group in
            for spec in targets {
                group.addTask { await checkOne(spec, log: log) }
            }
            var out: [UpdateItem] = []
            for await i in group { if let i { out.append(i) } }
            return out.sorted { $0.name < $1.name }
        }
        log("Agents: \(items.filter(\.status.isOutdated).count)/\(items.count) 个可更新", false)
        return items
    }

    private func checkOne(_ spec: AgentSpec, log: @escaping Logger) async -> UpdateItem? {
        guard let path = Shell.which(spec.binary) else {
            log("\(spec.name) 已不在 PATH 中，跳过", true)
            return nil
        }
        let managed = Self.managedBy(path: path)
        switch managed {
        case .brew: log("\(spec.name) 由 Homebrew 管理，在 Homebrew 分区更新", false); return nil
        case .npm: log("\(spec.name) 由 npm 管理，在 npm 分区更新", false); return nil
        case .uv: log("\(spec.name) 由 uv 管理，在 uv 分区更新", false); return nil
        case .native: break
        }
        let installed = await installedVersion(spec)
        var latest: String? = nil
        var status: ItemStatus = .unknown("无最新版本来源")
        if let source = latestSourceName(spec) {
            do {
                latest = try await latestVersion(spec)
                if let latest, installed != "?" {
                    status = VersionCompare.isNewer(latest, than: installed) ? .outdated : .upToDate
                } else {
                    status = .unknown("无法读取本地版本")
                }
            } catch {
                status = .unknown("\(source) 查询失败: \(error.localizedDescription)")
            }
        }
        let canUpdate = spec.hasUpdateCommand
        return UpdateItem(kind: .agent, name: spec.name, detail: path.replacingOccurrences(of: Shell.home, with: "~"),
                          installed: installed, latest: latest, status: status, canUpdate: canUpdate,
                          hint: canUpdate ? nil : "未配置更新命令，可在 agents.json 中添加 updateCommand", idSuffix: spec.binary)
    }

    func update(_ item: UpdateItem, log: @escaping Logger) async throws {
        let binary = item.id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
        guard let spec = specs.first(where: { $0.binary == binary }), spec.hasUpdateCommand, let cmd = spec.updateCommand else {
            throw ShellError.failed(item.name, 1, "没有配置更新命令")
        }
        log("$ " + cmd.joined(separator: " "), false)
        try await Shell.runChecked(cmd, timeout: 600, onOutput: log)
    }
}
