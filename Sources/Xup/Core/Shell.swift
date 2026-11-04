import Foundation

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { status == 0 }
    var combined: String { stdout + (stderr.isEmpty ? "" : "\n" + stderr) }
}

enum ShellError: LocalizedError {
    case emptyCommand
    case notFound(String)
    case failed(String, Int32, String)

    var errorDescription: String? {
        switch self {
        case .emptyCommand: return "空命令"
        case .notFound(let n): return "找不到命令: \(n)"
        case .failed(let cmd, let code, let msg):
            let tail = msg.split(separator: "\n").suffix(3).joined(separator: " ")
            return "\(cmd) 退出码 \(code)\(tail.isEmpty ? "" : ": " + tail)"
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var outPartial = ""
    private var errPartial = ""
    private let onLine: (@Sendable (String, Bool) -> Void)?

    init(onLine: (@Sendable (String, Bool) -> Void)?) { self.onLine = onLine }

    func append(_ data: Data, isErr: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        if isErr { err.append(data) } else { out.append(data) }
        guard let onLine else { lock.unlock(); return }
        var partial = isErr ? errPartial : outPartial
        partial += String(decoding: data, as: UTF8.self)
        var lines = partial.components(separatedBy: "\n")
        partial = lines.removeLast()
        if isErr { errPartial = partial } else { outPartial = partial }
        lock.unlock()
        for l in lines {
            let cleaned = Shell.stripANSI(l).trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty { onLine(cleaned, isErr) }
        }
    }

    func flush() {
        lock.lock()
        let o = outPartial, e = errPartial
        outPartial = ""; errPartial = ""
        lock.unlock()
        for (l, isErr) in [(o, false), (e, true)] {
            let cleaned = Shell.stripANSI(l).trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty { onLine?(cleaned, isErr) }
        }
    }

    var stdout: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
    var stderr: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
}

enum Shell {
    static let home = NSHomeDirectory()

    /// Environment with the user's real shell PATH so brew/nvm/cargo/uv are all visible.
    /// 首次访问会同步执行一次登录 shell（最多 8 秒），请先在后台线程调用 `warmUp()`。
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        var parts: [String] = []
        func add(_ d: String) { if !d.isEmpty, !parts.contains(d) { parts.append(d) } }
        // Apple Silicon 优先 /opt/homebrew；用户自装工具目录其次；再是登录 shell 的 PATH；最后系统目录。
        for d in ["/opt/homebrew/bin", "/opt/homebrew/sbin", "\(home)/.local/bin", "\(home)/.cargo/bin"] where FileManager.default.fileExists(atPath: d) { add(d) }
        if let probed = loginShellPath() { probed.split(separator: ":").forEach { add(String($0)) } }
        (env["PATH"] ?? "").split(separator: ":").forEach { add(String($0)) }
        ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].forEach(add)
        env["PATH"] = parts.joined(separator: ":")
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        env["HOMEBREW_COLOR"] = "0"
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        env["CI"] = "1"
        env["npm_config_fund"] = "false"
        env["npm_config_progress"] = "false"
        env.removeValue(forKey: "CLICOLOR_FORCE")
        return env
    }()

    /// 在后台线程完成 `environment` 的首次初始化，避免阻塞主线程。
    static func warmUp() async {
        await Task.detached(priority: .userInitiated) { _ = environment }.value
    }

    /// 账户真正的登录 shell（取自用户数据库，而不是可能被宿主进程改写的 $SHELL）。
    static func userLoginShell() -> String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let path = String(cString: sh)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// 登录 shell + 对应 rc 文件（nvm/brew shellenv 常写在 .zshrc/.bashrc 里）得到的 PATH。
    private static func loginShellPath() -> String? {
        let shell = userLoginShell()
        let rc = shell.hasSuffix("zsh") ? "~/.zshrc" : (shell.hasSuffix("bash") ? "~/.bashrc" : "")
        let script = (rc.isEmpty ? "" : "[ -f \(rc) ] && . \(rc) >/dev/null 2>&1; ") + "printf '__XUP__%s' \"$PATH\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lc", script]
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return nil }
        let deadline = DispatchWorkItem { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        deadline.cancel()
        let text = String(decoding: data, as: UTF8.self)
        guard let r = text.range(of: "__XUP__") else { return nil }
        let path = text[r.upperBound...].split(separator: "\n").first.map(String.init) ?? ""
        return path.isEmpty ? nil : path
    }

    static func which(_ name: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// ESC [ … 终止符，以及孤立的 \r（进度条回车）。
    private static let ansiRegex = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\r")

    static func stripANSI(_ s: String) -> String {
        guard s.contains("\u{1B}") || s.contains("\r") else { return s }
        return ansiRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    @discardableResult
    static func run(_ command: [String], timeout: TimeInterval = 1800,
                    onOutput: (@Sendable (String, Bool) -> Void)? = nil) async throws -> CommandResult {
        guard let exe = command.first else { throw ShellError.emptyCommand }
        guard let path = which(exe) else { throw ShellError.notFound(exe) }
        let collector = OutputCollector(onLine: onOutput)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CommandResult, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = Array(command.dropFirst())
            p.environment = environment
            p.standardInput = FileHandle.nullDevice
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            out.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil } else { collector.append(d, isErr: false) }
            }
            err.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil } else { collector.append(d, isErr: true) }
            }
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                collector.append(out.fileHandleForReading.readDataToEndOfFile(), isErr: false)
                collector.append(err.fileHandleForReading.readDataToEndOfFile(), isErr: true)
                collector.flush()
                cont.resume(returning: CommandResult(status: proc.terminationStatus, stdout: collector.stdout, stderr: collector.stderr))
            }
            do {
                try p.run()
            } catch {
                cont.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard p.isRunning else { return }
                p.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                }
            }
        }
    }

    /// Runs and throws when the exit status is non-zero.
    @discardableResult
    static func runChecked(_ command: [String], timeout: TimeInterval = 1800,
                           onOutput: (@Sendable (String, Bool) -> Void)? = nil) async throws -> CommandResult {
        let r = try await run(command, timeout: timeout, onOutput: onOutput)
        guard r.ok else { throw ShellError.failed(command.joined(separator: " "), r.status, r.stderr.isEmpty ? r.stdout : r.stderr) }
        return r
    }

    /// Runs a shell snippet with administrator privileges via osascript.
    static func runPrivileged(_ script: String) async throws {
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let apple = "do shell script \"\(escaped)\" with administrator privileges"
        try await runChecked(["/usr/bin/osascript", "-e", apple], timeout: 300)
    }

    static func fetchJSON(_ url: URL, timeout: TimeInterval = 20, headers: [String: String] = [:]) async throws -> Any {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue("Xup/1.0 (macOS update helper)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw NSError(domain: "Xup", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) \(url.host ?? "")"])
        }
        return try JSONSerialization.jsonObject(with: data)
    }
}
