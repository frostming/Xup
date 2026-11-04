import Foundation

/// 本机控制通道：Unix domain socket（0600），每行一个 JSON 请求 → 一行 JSON 响应。
///
/// 请求：`{"id":1,"cmd":"status","params":{...}}`（`params` 可省略，也可把参数直接放在顶层）
/// 响应：`{"id":1,"ok":true,"result":{...}}` 或 `{"id":1,"ok":false,"error":"…"}`
///
/// 网络 I/O 在私有队列上用 POSIX socket + DispatchSource 完成；命令处理切到 MainActor 调用 UpdateCenter。
final class ControlServer: @unchecked Sendable {
    struct Request {
        let id: Any?
        let cmd: String
        let params: [String: Any]

        func string(_ key: String) -> String? { params[key] as? String }
        func bool(_ key: String) -> Bool { (params[key] as? Bool) ?? false }
        func int(_ key: String) -> Int? { (params[key] as? NSNumber)?.intValue }
        func strings(_ key: String) -> [String]? {
            if let a = params[key] as? [String] { return a }
            if let s = params[key] as? String { return [s] }
            return nil
        }
    }

    struct CommandError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    typealias Handler = @MainActor (Request) async throws -> Any

    nonisolated static var defaultPath: String {
        AppSettings.supportDirectory.appendingPathComponent("control.sock").path
    }

    let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "dev.fming.xup.control")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]
    var log: (@Sendable (String, Bool) -> Void)?

    private final class Client {
        let fd: Int32
        var buffer = Data()
        var source: DispatchSourceRead?
        init(fd: Int32) { self.fd = fd }
    }

    init(path: String = ControlServer.defaultPath, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    deinit { stop() }

    // MARK: 生命周期

    /// 启动监听；返回错误描述（成功为 nil）。若另一实例仍在服务则不抢占。
    @discardableResult
    func start() -> String? {
        if Self.isAlive(path) {
            return "control.sock 已被另一个 Xup 实例占用，控制通道未启动"
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return "socket() 失败：\(String(cString: strerror(errno)))" }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = path.withCString { cstr -> Bool in
            let len = strlen(cstr)
            guard len < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(len) + 1) { dst in
                    _ = strcpy(dst, cstr)
                }
            }
            return true
        }
        guard ok else { close(fd); return "socket 路径过长：\(path)" }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            let e = String(cString: strerror(errno)); close(fd)
            return "bind(\(path)) 失败：\(e)"
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let e = String(cString: strerror(errno)); close(fd); unlink(path)
            return "listen 失败：\(e)"
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptClients() }
        src.resume()
        acceptSource = src
        return nil
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1; unlink(path) }
        queue.async { [self] in
            for c in clients.values { c.source?.cancel(); close(c.fd) }
            clients.removeAll()
        }
    }

    /// 尝试连接：有人在监听则为 true。
    nonisolated static func isAlive(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = path.withCString { cstr -> Bool in
            guard strlen(cstr) < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(strlen(cstr)) + 1) { _ = strcpy($0, cstr) }
            }
            return true
        }
        guard ok else { return false }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return r == 0
    }

    // MARK: 连接处理

    private func acceptClients() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let client = Client(fd: fd)
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self, weak client] in
                guard let self, let client else { return }
                self.read(client)
            }
            src.setCancelHandler { close(fd) }
            client.source = src
            clients[fd] = client
            src.resume()
        }
    }

    private func read(_ client: Client) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = recv(client.fd, &chunk, chunk.count, 0)
        if n <= 0 {
            drop(client)
            return
        }
        client.buffer.append(contentsOf: chunk[0..<n])
        while let nl = client.buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = client.buffer.subdata(in: client.buffer.startIndex..<nl)
            client.buffer.removeSubrange(client.buffer.startIndex...nl)
            if line.isEmpty { continue }
            handle(line, from: client)
        }
        if client.buffer.count > 4 * 1024 * 1024 { drop(client) }
    }

    private func drop(_ client: Client) {
        client.source?.cancel()
        clients[client.fd] = nil
    }

    private func handle(_ line: Data, from client: Client) {
        var id: Any?
        var request: Request?
        do {
            guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw CommandError("请求必须是 JSON 对象")
            }
            id = obj["id"]
            guard let cmd = obj["cmd"] as? String else { throw CommandError("缺少 cmd") }
            var params = obj["params"] as? [String: Any] ?? [:]
            for (k, v) in obj where k != "id" && k != "cmd" && k != "params" && params[k] == nil { params[k] = v }
            request = Request(id: id, cmd: cmd, params: params)
        } catch {
            send(["id": id ?? NSNull(), "ok": false, "error": error.localizedDescription], to: client)
            return
        }
        guard let req = request else { return }
        let fd = client.fd
        let handler = self.handler
        Task { @MainActor [weak self] in
            var payload: [String: Any] = ["id": req.id ?? NSNull()]
            do {
                payload["ok"] = true
                payload["result"] = try await handler(req)
            } catch {
                payload["ok"] = false
                payload["error"] = error.localizedDescription
            }
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, let c = self.clients[fd] else { return }
                self.send(payload, to: c)
            }
        }
    }

    private func send(_ payload: [String: Any], to client: Client) {
        var data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            data = Data(#"{"ok":false,"error":"响应无法序列化为 JSON"}"#.utf8)
        }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buf.count {
                let n = Darwin.send(client.fd, buf.baseAddress! + offset, buf.count - offset, 0)
                if n <= 0 {
                    if errno == EAGAIN { usleep(2000); continue }
                    return
                }
                offset += n
            }
        }
    }
}

// MARK: - 命令实现（MainActor，调用 UpdateCenter / AppSettings）

@MainActor
enum ControlCommands {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func makeHandler(center: UpdateCenter, settings: AppSettings, scheduler: Scheduler? = nil) -> ControlServer.Handler {
        return { req in try await dispatch(req, center: center, settings: settings, scheduler: scheduler) }
    }

    private static func kind(_ raw: String) throws -> ProviderKind {
        let normalized = raw == "brew" ? "homebrew" : raw
        guard let k = ProviderKind(rawValue: normalized) else {
            throw ControlServer.CommandError("未知来源 \(raw)；可选：\(ProviderKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return k
    }

    static func dispatch(_ req: ControlServer.Request, center: UpdateCenter, settings: AppSettings, scheduler: Scheduler? = nil) async throws -> Any {
        switch req.cmd {
        case "ping":
            return ["pid": ProcessInfo.processInfo.processIdentifier, "version": appVersion]

        case "status":
            return status(center: center, settings: settings, scheduler: scheduler)

        case "items":
            var list = center.items
            if let k = req.string("kind") { let kk = try kind(k); list = list.filter { $0.kind == kk } }
            return list.sorted { $0.id < $1.id }.map { encode($0, settings: settings) }

        case "stage":
            // §19.4 预下载：只下载暂存，不替换、不退出应用。
            guard let list = req.strings("ids"), !list.isEmpty else { throw ControlServer.CommandError("缺少 ids") }
            let ids = Set(list)
            let known = Set(center.items.map(\.id))
            let unknown = ids.subtracting(known).sorted()
            if !unknown.isEmpty { throw ControlServer.CommandError("未知 id：\(unknown.joined(separator: ", "))（先执行 check）") }
            let targets = center.items.filter { ids.contains($0.id) }
            let unsupported = targets.filter { !$0.supportsStaging }.map(\.id).sorted()
            let stageable = Set(targets.filter { $0.supportsStaging && $0.status.isOutdated }.map(\.id))
            let alreadyStaged = targets.filter { $0.status.isStaged }.map(\.id).sorted()
            if stageable.isEmpty {
                return ["staged": alreadyStaged, "skipped": unsupported, "note": unsupported.isEmpty ? "没有需要预下载的条目" : "所选条目的来源不支持预下载（仅 Sparkle / electron-updater / 手动配置来源的应用）"]
            }
            let mark = center.log.last?.id
            if req.bool("wait") {
                let done = await center.stage(ids: stageable)
                return [
                    "staged": done.union(alreadyStaged).sorted(),
                    "failed": stageable.subtracting(done).sorted(),
                    "skipped": unsupported,
                    "items": center.items.filter { ids.contains($0.id) }.sorted { $0.id < $1.id }.map { encode($0, settings: settings) },
                    "log": center.logLines(after: mark).map(encode),
                ]
            }
            Task { await center.stage(ids: stageable) }
            return ["started": stageable.sorted(), "skipped": unsupported]

        case "policy-get":
            guard let id = req.string("id") else { throw ControlServer.CommandError("缺少 id") }
            return policyEntry(id, center: center, settings: settings)

        case "policy-list":
            var ids = Set(settings.config.policies.keys)
            ids.formUnion(center.items.map(\.id))
            for (k, names) in settings.tracked { for n in names { ids.insert("\(k.rawValue):\(n)") } }
            for app in settings.managedApps { ids.insert(app.itemID) }
            // 同一 homebrew 条目：列表里有 formula/cask 形式时省略 token 形式。
            let full = Set(ids.filter { $0.hasPrefix("homebrew:") && $0.contains("/") }.map { AppSettings.aliasKeys(for: $0)[0] })
            let list = ids.filter { !($0.hasPrefix("homebrew:") && !$0.contains("/") && full.contains($0)) }
            return ["defaultPolicy": settings.defaultPolicy.rawValue, "idleMinutes": settings.idleMinutes,
                    "items": list.sorted().map { policyEntry($0, center: center, settings: settings) }]

        case "policy-set":
            guard let list = req.strings("ids"), !list.isEmpty else { throw ControlServer.CommandError("缺少 ids") }
            guard let raw = req.string("policy"), let policy = UpdatePolicy(cli: raw) else {
                throw ControlServer.CommandError("policy 必须是 manual / auto / autoDownload")
            }
            center.setPolicy(policy, for: Set(list))
            if let on = req.params["installWhenIdle"] as? Bool {
                for id in list where id.hasPrefix("app:") { settings.setInstallWhenIdle(path: String(id.dropFirst(4)), on) }
            }
            return list.sorted().map { policyEntry($0, center: center, settings: settings) }

        case "installed":
            guard let k = req.string("kind") else { throw ControlServer.CommandError("缺少 kind") }
            let kk = try kind(k)
            guard kk != .app else { throw ControlServer.CommandError("app 没有已安装清单；请用 config 的 apps 字段") }
            let entries = try await center.listInstalled(for: kk)
            return entries.map { e -> [String: Any] in
                var d: [String: Any] = ["name": e.name, "version": e.version, "tracked": settings.isTracked(kk, e.name)]
                if let det = e.detail { d["detail"] = det }
                return d
            }

        case "check":
            var kinds: Set<ProviderKind>?
            if let ks = req.strings("kinds") ?? req.strings("kind"), !ks.isEmpty {
                kinds = Set(try ks.map(kind))
            }
            if req.bool("wait") {
                await center.waitUntilIdle()
                await center.check(kinds: kinds)
                return status(center: center, settings: settings)
            }
            let started = !center.isChecking
            Task { await center.check(kinds: kinds) }
            return ["started": started, "alreadyChecking": !started]

        case "update":
            var ids: Set<String>
            if req.bool("all") {
                ids = Set(center.actionableItems.map(\.id))
            } else if let list = req.strings("ids"), !list.isEmpty {
                ids = Set(list)
            } else {
                throw ControlServer.CommandError("缺少 ids 或 all:true")
            }
            let known = Set(center.items.map(\.id))
            let unknown = ids.subtracting(known).sorted()
            if !unknown.isEmpty {
                throw ControlServer.CommandError("未知 id：\(unknown.joined(separator: ", "))（先执行 check）")
            }
            let targets = center.items.filter { ids.contains($0.id) && $0.canUpdate }
            let skipped = ids.subtracting(targets.map(\.id)).sorted()
            if targets.isEmpty {
                return ["updated": [], "skipped": skipped, "note": "没有可更新的条目"]
            }
            let mark = center.log.last?.id
            if req.bool("wait") {
                await center.update(ids: Set(targets.map(\.id)), trigger: .cli)
                let done = center.items.filter { ids.contains($0.id) }
                return [
                    "items": done.sorted { $0.id < $1.id }.map { encode($0, settings: settings) },
                    "skipped": skipped,
                    "succeeded": done.filter { $0.status == .updated }.map(\.id).sorted(),
                    "failed": done.filter { if case .failed = $0.status { return true }; return false }.map(\.id).sorted(),
                    "log": center.logLines(after: mark).map(encode),
                ]
            }
            Task { await center.update(ids: Set(targets.map(\.id)), trigger: .cli) }
            return ["started": targets.map(\.id).sorted(), "skipped": skipped]

        case "probe-source":
            guard let path = req.string("path") else { throw ControlServer.CommandError("缺少 path") }
            guard let src = req.params["source"] else { throw ControlServer.CommandError("缺少 source") }
            let data = try JSONSerialization.data(withJSONObject: src)
            let source: AppUpdateSource
            do {
                source = try JSONDecoder().decode(AppUpdateSource.self, from: data)
            } catch {
                throw ControlServer.CommandError("source 无法解析：\(error.localizedDescription)")
            }
            let app = settings.managedApps.first { $0.path == path } ?? ManagedApp(path: path)
            let r = try await center.probeSource(for: app, source: source)
            var out: [String: Any] = ["latest": r.latest]
            if let u = r.downloadURL { out["downloadURL"] = u.absoluteString }
            if let item = center.items.first(where: { $0.id == "app:\(path)" }) {
                out["installed"] = item.installed
                out["isNewer"] = VersionCompare.isNewer(r.latest, than: item.installed)
            } else if let v = Bundle(path: path)?.infoDictionary?["CFBundleShortVersionString"] as? String {
                out["installed"] = v
                out["isNewer"] = VersionCompare.isNewer(r.latest, than: v)
            }
            return out

        case "reload-config":
            if let err = settings.reloadConfig() { throw ControlServer.CommandError(err) }
            return ["reloaded": true, "path": settings.configURL.path, "warnings": settings.store.lastWarnings]

        case "log":
            let n = req.int("tail") ?? 50
            var lines = center.log
            if req.bool("errorsOnly") { lines = lines.filter(\.isError) }
            if n > 0, lines.count > n { lines = Array(lines.suffix(n)) }
            return lines.map(encode)

        case "history":
            // 参数：limit（默认 50，<=0 为全部）、failedOnly、kind；按时间倒序。
            var k: ProviderKind?
            if let raw = req.string("kind"), !raw.isEmpty { k = try kind(raw) }
            let limit = req.int("limit") ?? 50
            return center.history.records(kind: k, failedOnly: req.bool("failedOnly"), limit: limit).map(encode)

        case "history-clear":
            let n = center.history.records.count
            center.history.clear()
            center.appendLog(source: "控制", text: "已清空更新历史（\(n) 条）")
            return ["cleared": n]

        case "launch":
            guard let path = req.string("path") else { throw ControlServer.CommandError("缺少 path") }
            guard FileManager.default.fileExists(atPath: path) else { throw ControlServer.CommandError("应用不存在：\(path)") }
            let app = settings.managedApps.first { $0.path == path } ?? ManagedApp(path: path)
            await center.launch(app)
            return ["launched": path]

        default:
            throw ControlServer.CommandError("未知命令 \(req.cmd)")
        }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["CFBundleShortVersionString"] as? String ?? "dev") + " (" + (info["CFBundleVersion"] as? String ?? "0") + ")"
    }

    /// 一条策略记录：生效策略、配置里的原始值（无则 null）、是否降级、installWhenIdle。
    static func policyEntry(_ id: String, center: UpdateCenter, settings: AppSettings) -> [String: Any] {
        let item = center.items.first { $0.id == id }
        let stored = settings.storedPolicy(for: id)
        let effective = item.map { settings.policy(for: $0) } ?? settings.policy(for: id)
        var d: [String: Any] = [
            "id": id, "policy": effective.rawValue,
            "stored": stored?.rawValue ?? NSNull(),
            "inherited": stored == nil,
            "downgraded": stored == .autoDownload && effective != .autoDownload,
        ]
        if let item { d["name"] = item.name; d["status"] = statusKey(item.status); d["supportsStaging"] = item.supportsStaging }
        if id.hasPrefix("app:") { d["installWhenIdle"] = settings.installWhenIdle(path: String(id.dropFirst(4))) }
        return d
    }

    static func status(center: UpdateCenter, settings: AppSettings, scheduler: Scheduler? = nil) -> [String: Any] {
        var byKind: [String: Int] = [:]
        for k in ProviderKind.allCases { byKind[k.rawValue] = center.count(for: k) }
        return [
            "version": appVersion,
            "lastChecked": center.lastChecked.map { iso.string(from: $0) } ?? NSNull(),
            "isChecking": center.isChecking,
            "updating": center.updatingIDs.sorted(),
            "staging": center.stagingIDs.sorted(),
            "pendingAuto": scheduler?.pendingAutoIDs.sorted() ?? [],
            "defaultPolicy": settings.defaultPolicy.rawValue,
            "idleMinutes": settings.idleMinutes,
            "counts": [
                "items": center.items.count,
                "outdated": center.outdatedCount,
                "staged": center.stagedCount,
                "actionable": center.actionableItems.count,
                "byKind": byKind,
            ],
            "unavailable": center.unavailable.map(\.rawValue).sorted(),
            "providerErrors": Dictionary(uniqueKeysWithValues: center.providerErrors.map { ($0.key.rawValue, $0.value) }),
            "tracked": Dictionary(uniqueKeysWithValues: settings.tracked.map { ($0.key.rawValue, $0.value.sorted()) }),
            "apps": settings.managedApps.map(\.path),
            "items": center.items.sorted { $0.id < $1.id }.map { item -> [String: Any] in
                var d: [String: Any] = ["id": item.id, "name": item.name, "kind": item.kind.rawValue,
                                        "installed": item.installed, "status": statusKey(item.status), "actionable": item.isActionable,
                                        "policy": settings.policy(for: item).rawValue]
                if let l = item.latest { d["latest"] = l }
                return d
            },
            "configPath": settings.configURL.path,
        ]
    }

    static func statusKey(_ s: ItemStatus) -> String {
        switch s {
        case .checking: return "checking"
        case .outdated: return "outdated"
        case .upToDate: return "upToDate"
        case .unknown: return "unknown"
        case .updating: return "updating"
        case .updated: return "updated"
        case .failed: return "failed"
        case .staged: return "staged"
        }
    }

    static func encode(_ item: UpdateItem, settings: AppSettings? = nil) -> [String: Any] {
        var d: [String: Any] = [
            "id": item.id, "kind": item.kind.rawValue, "name": item.name, "installed": item.installed,
            "status": statusKey(item.status), "canUpdate": item.canUpdate, "actionable": item.isActionable,
        ]
        if let settings { d["policy"] = settings.policy(for: item).rawValue }
        if let v = item.status.stagedVersion { d["stagedVersion"] = v }
        if let v = item.latest { d["latest"] = v }
        if let v = item.detail { d["detail"] = v }
        if let v = item.hint { d["hint"] = v }
        if let v = item.status.message { d["message"] = v }
        return d
    }

    static func encode(_ line: LogLine) -> [String: Any] {
        ["time": iso.string(from: line.time), "source": line.source, "text": line.text, "isError": line.isError]
    }

    static func encode(_ r: UpdateRecord) -> [String: Any] {
        var d: [String: Any] = [
            "id": r.id.uuidString, "time": iso.string(from: r.time), "kind": r.kind.rawValue, "itemID": r.itemID,
            "name": r.name, "fromVersion": r.fromVersion, "ok": r.ok, "trigger": r.trigger.rawValue,
            // 保留一位小数输出（JSONSerialization 对 Double 会打出 48.299999999999997）。
            "duration": NSDecimalNumber(string: String(format: "%.1f", r.duration)),
        ]
        if let v = r.detail { d["detail"] = v }
        if let v = r.toVersion { d["toVersion"] = v }
        if let v = r.error { d["error"] = v }
        return d
    }
}
