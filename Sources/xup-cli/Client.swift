import Foundation

/// 与运行中的 Xup 通过 Unix socket 交换一行 JSON。
enum Client {
    private static var nextID = 1

    /// 连接 socket；失败返回 nil。
    private static func connectOnce() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = Paths.socketPath.withCString { cstr -> Bool in
            guard strlen(cstr) < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(strlen(cstr)) + 1) { _ = strcpy($0, cstr) }
            }
            return true
        }
        guard ok else { close(fd); return nil }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if r != 0 { close(fd); return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// 连接；App 未运行时用 `open -gj` 拉起并等待 socket（最多 10 秒）。
    static func connect(autoLaunch: Bool = true) throws -> Int32 {
        if let fd = connectOnce() { return fd }
        guard autoLaunch else { throw CLIError("Xup 未运行（\(Paths.display(Paths.socketPath)) 不可用）") }
        guard let app = Paths.appPath else {
            throw CLIError("Xup 未运行，且找不到 Xup.app（可设置 XUP_APP_PATH，候选：\(Paths.appCandidates.joined(separator: ", "))）")
        }
        warn("Xup 未运行，正在启动 \(app)…")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-gj", app]
        do { try p.run() } catch { throw CLIError("启动 Xup 失败：\(error.localizedDescription)") }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CLIError("open \(app) 退出码 \(p.terminationStatus)") }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            usleep(200_000)
            if let fd = connectOnce() { return fd }
        }
        throw CLIError("等待 Xup 控制通道超时（10 秒）：\(Paths.display(Paths.socketPath))")
    }

    /// 发送一条命令并返回 result；`ok:false` 时抛出 error 文本。
    static func call(_ cmd: String, _ params: [String: Any] = [:], autoLaunch: Bool = true) throws -> Any {
        let fd = try connect(autoLaunch: autoLaunch)
        defer { close(fd) }
        let id = nextID
        nextID += 1
        var req: [String: Any] = ["id": id, "cmd": cmd]
        if !params.isEmpty { req["params"] = params }
        var data = try JSONSerialization.data(withJSONObject: req, options: [.sortedKeys])
        data.append(UInt8(ascii: "\n"))
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = send(fd, buf.baseAddress! + off, buf.count - off, 0)
                if n <= 0 { throw CLIError("发送请求失败：\(String(cString: strerror(errno)))") }
                off += n
            }
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n < 0 {
                if errno == EINTR { continue }
                throw CLIError("读取响应失败：\(String(cString: strerror(errno)))")
            }
            if n == 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.last == UInt8(ascii: "\n") { break }
        }
        guard !buffer.isEmpty else { throw CLIError("Xup 关闭了连接，没有返回响应") }
        guard let resp = try? JSON.parse(buffer) as? [String: Any] else {
            throw CLIError("响应不是 JSON：\(String(data: buffer, encoding: .utf8) ?? "")")
        }
        if (resp["ok"] as? Bool) == true {
            return resp["result"] ?? NSNull()
        }
        throw CLIError(resp["error"] as? String ?? "未知错误")
    }

    static var isRunning: Bool {
        if let fd = connectOnce() { close(fd); return true }
        return false
    }
}
