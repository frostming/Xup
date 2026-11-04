import Foundation

struct AppcastItem {
    var title: String = ""
    var shortVersion: String?
    var build: String?
    var channel: String?
    var minimumSystemVersion: String?
    var enclosureURL: URL?
    var enclosureType: String?

    var displayVersion: String { shortVersion ?? build ?? "?" }
}

/// Minimal Sparkle appcast (RSS) parser.
final class AppcastParser: NSObject, XMLParserDelegate {
    private var items: [AppcastItem] = []
    private var current: AppcastItem?
    private var text = ""
    private var inItem = false

    static func fetch(_ url: URL) async throws -> [AppcastItem] {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Xup/1.0 Sparkle-compatible", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw NSError(domain: "Xup", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "appcast HTTP \(http.statusCode)"])
        }
        let p = AppcastParser()
        let xml = XMLParser(data: data)
        xml.delegate = p
        xml.shouldProcessNamespaces = false
        guard xml.parse() else { throw xml.parserError ?? NSError(domain: "Xup", code: 1, userInfo: [NSLocalizedDescriptionKey: "appcast 解析失败"]) }
        return p.items
    }

    /// Picks the newest item on the default channel that this macOS can run.
    static func newest(in items: [AppcastItem]) -> AppcastItem? {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let eligible = items.filter { item in
            if let ch = item.channel, !ch.isEmpty { return false }
            if let min = item.minimumSystemVersion, !min.isEmpty, VersionCompare.isNewer(min, than: osString) { return false }
            return item.shortVersion != nil || item.build != nil
        }
        return eligible.max { a, b in
            let c = VersionCompare.compare(a.shortVersion ?? a.build ?? "0", b.shortVersion ?? b.build ?? "0")
            if c != .orderedSame { return c == .orderedAscending }
            return VersionCompare.compare(a.build ?? "0", b.build ?? "0") == .orderedAscending
        }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        text = ""
        if name == "item" { inItem = true; current = AppcastItem(); return }
        guard inItem, var cur = current else { return }
        if name == "enclosure" {
            // 同一 item 可能有多个 enclosure（完整包 + 若干 delta 包）；只取完整包。
            if attributes["sparkle:deltaFrom"] != nil { return }
            if let u = attributes["url"] { cur.enclosureURL = URL(string: u) }
            cur.enclosureType = attributes["type"]
            if cur.shortVersion == nil { cur.shortVersion = attributes["sparkle:shortVersionString"] }
            if cur.build == nil { cur.build = attributes["sparkle:version"] }
            current = cur
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard inItem, var cur = current else { return }
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "item":
            items.append(cur); current = nil; inItem = false
        case "title": if cur.title.isEmpty { cur.title = v }
        case "sparkle:shortVersionString": cur.shortVersion = v
        case "sparkle:version": cur.build = v
        case "sparkle:channel": cur.channel = v
        case "sparkle:minimumSystemVersion": cur.minimumSystemVersion = v
        default: break
        }
        current = cur
    }
}

/// Downloads an update archive and swaps the app bundle in place.
enum AppInstaller {
    /// 下载 → 解压/挂载 → 找 .app → 校验签名 → 暂存到临时目录 → `beforeReplace` → 替换。
    /// `beforeReplace` 在真正替换 bundle 之前被调用（下载/解压/校验/暂存都已完成），
    /// 调用方用它来退出应用或在应用仍在运行时中止；抛错即取消替换。
    /// `download` 可自定义获取安装包的方式（如 blockmap 增量下载），返回本地文件 URL；该文件归 AppInstaller 所有（会被移走/删除）。
    /// 为 nil 时用 URLSession 整包下载。
    static func install(from url: URL, into destination: String, expectedBundleID: String?, log: @escaping Logger,
                        beforeReplace: (@Sendable () async throws -> Void)? = nil,
                        download: ((URL, @escaping Logger) async throws -> URL)? = nil) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("xup-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let tmp: URL
        var mime: String?
        if let download {
            tmp = try await download(url, log)
        } else {
            log("下载 \(url.absoluteString)", false)
            let dlStart = Date()
            let (t, resp) = try await URLSession.shared.download(from: url)
            if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                throw NSError(domain: "Xup", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "下载失败 HTTP \(http.statusCode)"])
            }
            let size = (try? fm.attributesOfItem(atPath: t.path)[.size] as? Int64) ?? 0
            log("下载完成：\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))，用时 \(fmt(Date().timeIntervalSince(dlStart)))", false)
            tmp = t
            mime = resp.mimeType
        }
        var ext = url.pathExtension.lowercased()
        if ext.isEmpty { ext = tmp.pathExtension.lowercased() }
        if ext.isEmpty, let mime {
            if mime.contains("zip") { ext = "zip" } else if mime.contains("diskimage") { ext = "dmg" }
        }
        let archive = work.appendingPathComponent("payload.\(ext.isEmpty ? "bin" : ext)")
        try fm.moveItem(at: tmp, to: archive)

        let extracted = work.appendingPathComponent("extracted")
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        var mountPoint: URL?
        defer { if let m = mountPoint { Task { try? await Shell.run(["/usr/bin/hdiutil", "detach", m.path, "-quiet", "-force"], timeout: 60) } } }

        var searchRoot = extracted
        let exStart = Date()
        switch ext {
        case "zip":
            log("解压 zip", false)
            try await Shell.runChecked(["/usr/bin/ditto", "-x", "-k", archive.path, extracted.path], timeout: 300)
        case "dmg", "bin":
            log("挂载 dmg", false)
            let mp = work.appendingPathComponent("mnt")
            try await Shell.runChecked(["/usr/bin/hdiutil", "attach", archive.path, "-nobrowse", "-readonly", "-noverify", "-noautoopen", "-mountpoint", mp.path], timeout: 300)
            mountPoint = mp
            searchRoot = mp
        case "tar", "gz", "tgz", "bz2", "xz", "tbz":
            log("解压 tar", false)
            try await Shell.runChecked(["/usr/bin/tar", "-xf", archive.path, "-C", extracted.path], timeout: 300)
        default:
            throw NSError(domain: "Xup", code: 2, userInfo: [NSLocalizedDescriptionKey: "不支持的安装包类型 .\(ext)"])
        }
        log("解压/挂载完成，用时 \(fmt(Date().timeIntervalSince(exStart)))", false)

        guard let newApp = findApp(in: searchRoot, bundleID: expectedBundleID) else {
            throw NSError(domain: "Xup", code: 3, userInfo: [NSLocalizedDescriptionKey: "安装包里没找到 .app"])
        }
        if let expected = expectedBundleID, let got = Bundle(url: newApp)?.bundleIdentifier, got != expected {
            throw NSError(domain: "Xup", code: 4, userInfo: [NSLocalizedDescriptionKey: "bundle id 不匹配: \(got) ≠ \(expected)"])
        }

        log("校验签名", false)
        let sig = try await Shell.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", newApp.path], timeout: 300)
        if !sig.ok { throw NSError(domain: "Xup", code: 5, userInfo: [NSLocalizedDescriptionKey: "签名校验失败，已中止: \(sig.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"]) }
        let gate = try await Shell.run(["/usr/sbin/spctl", "--assess", "--type", "execute", newApp.path], timeout: 120)

        log("暂存新版本", false)
        let dest = URL(fileURLWithPath: destination)
        let staged = work.appendingPathComponent(dest.lastPathComponent)
        try await Shell.runChecked(["/usr/bin/ditto", newApp.path, staged.path], timeout: 300)
        if gate.ok { _ = try? await Shell.run(["/usr/bin/xattr", "-dr", "com.apple.quarantine", staged.path], timeout: 60) }
        else { log("Gatekeeper 评估未通过，保留 quarantine 属性（首次打开会提示）", true) }

        // 一切就绪，替换前最后一步：交给调用方确认 / 退出应用。抛错则不替换。
        if let beforeReplace { try await beforeReplace() }

        log("替换 \(destination)", false)
        let rpStart = Date()
        do {
            try replace(dest: dest, with: staged)
        } catch {
            log("直接替换失败（\(error.localizedDescription)），请求管理员权限", true)
            let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            try await Shell.runPrivileged("rm -rf \(q(dest.path)) && /usr/bin/ditto \(q(staged.path)) \(q(dest.path))")
        }
        log("替换完成，用时 \(fmt(Date().timeIntervalSince(rpStart)))", false)
    }

    private static func fmt(_ t: TimeInterval) -> String {
        t >= 60 ? String(format: "%d 分 %.0f 秒", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) : String(format: "%.1f 秒", t)
    }

    private static func replace(dest: URL, with staged: URL) throws {
        let fm = FileManager.default
        let backup = dest.deletingLastPathComponent().appendingPathComponent(".\(dest.lastPathComponent).xup-old")
        try? fm.removeItem(at: backup)
        if fm.fileExists(atPath: dest.path) { try fm.moveItem(at: dest, to: backup) }
        do {
            try fm.copyItem(at: staged, to: dest)
        } catch {
            try? fm.moveItem(at: backup, to: dest)
            throw error
        }
        try? fm.removeItem(at: backup)
    }

    private static func findApp(in root: URL, bundleID: String?) -> URL? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var candidates: [URL] = []
        for case let u as URL in e where u.pathExtension == "app" {
            candidates.append(u)
            e.skipDescendants()
        }
        if let id = bundleID, let match = candidates.first(where: { Bundle(url: $0)?.bundleIdentifier == id }) { return match }
        return candidates.first
    }
}
