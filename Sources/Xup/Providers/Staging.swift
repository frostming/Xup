import Foundation

/// §19.4 已下载、校验并解压好的新版本（尚未替换）。
/// 既用于 `AppInstaller.install` 的临时暂存，也用于"自动下载，手动重启"的持久暂存
/// （`~/Library/Caches/dev.fming.xup/staged/<bundleID>/<version>/<App>.app` + `staged.json`）。
struct StagedPackage: Codable, Equatable, Sendable {
    /// 暂存的 .app 路径。
    var appPath: String
    /// 将要替换的目标 .app 路径。
    var destination: String
    /// 新包 Info.plist 的 CFBundleShortVersionString（没有则 CFBundleVersion）。
    var version: String
    var build: String?
    var bundleID: String?
    /// 安装包下载地址。
    var sourceURL: String
    /// 安装包（zip/dmg/…）的 SHA-256（十六进制）。
    var sha256: String?
    /// 安装包大小（字节）。
    var archiveSize: Int64?
    var stagedAt: Date

    var appURL: URL { URL(fileURLWithPath: appPath) }
}

/// 持久暂存目录的读写与有效性校验。每个应用只保留一份。
enum StagingStore {
    /// 暂存根目录；测试可改。
    nonisolated(unsafe) static var rootURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("dev.fming.xup/staged", isDirectory: true)
    }()

    /// 暂存超过 30 天未安装视为失效。
    static let maxAge: TimeInterval = 30 * 24 * 3600
    static let metadataName = "staged.json"

    enum Invalid: LocalizedError, Equatable {
        case missing
        case versionMismatch(staged: String, latest: String)
        case expired(days: Int)
        case bundleMismatch(expected: String, actual: String)

        var errorDescription: String? {
            switch self {
            case .missing: return "暂存文件已不存在"
            case .versionMismatch(let s, let l): return "暂存版本 \(s) 与最新版本 \(l) 不一致"
            case .expired(let d): return "暂存已超过 \(d) 天"
            case .bundleMismatch(let e, let a): return "暂存包版本号 \(a) 与记录 \(e) 不一致"
            }
        }
    }

    nonisolated private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    nonisolated private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func sanitize(_ id: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let s = id.unicodeScalars.map { bad.contains($0) ? "_" : String($0) }.joined()
        return s.isEmpty ? "_" : s
    }

    /// `<root>/<bundleID>`。应用没有 bundle id 时用目标路径代替。
    static func directory(bundleID: String?, destination: String) -> URL {
        rootURL.appendingPathComponent(sanitize(bundleID ?? destination), isDirectory: true)
    }

    /// `<root>/<bundleID>/<version>`。
    static func directory(bundleID: String?, destination: String, version: String) -> URL {
        directory(bundleID: bundleID, destination: destination).appendingPathComponent(sanitize(version), isDirectory: true)
    }

    private static func metadataURL(in appDir: URL) -> URL { appDir.appendingPathComponent(metadataName) }

    /// 读取该应用的暂存记录（不校验有效性）。
    static func load(bundleID: String?, destination: String) -> StagedPackage? {
        let dir = directory(bundleID: bundleID, destination: destination)
        guard let subdirs = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        for sub in subdirs {
            if let data = try? Data(contentsOf: metadataURL(in: sub)), let pkg = try? decoder.decode(StagedPackage.self, from: data) {
                return pkg
            }
        }
        return nil
    }

    /// 写入记录（先清掉该应用其它版本的暂存，每应用只保留一份）。
    static func save(_ pkg: StagedPackage) throws {
        let appDir = pkg.appURL.deletingLastPathComponent()
        let parent = appDir.deletingLastPathComponent()
        if let others = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
            for o in others where o.standardizedFileURL.path != appDir.standardizedFileURL.path {
                try? FileManager.default.removeItem(at: o)
            }
        }
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        try encoder.encode(pkg).write(to: metadataURL(in: appDir), options: .atomic)
    }

    /// 删除该应用的全部暂存。
    // MARK: 安装中锁：正在被 apply 的暂存不得被清理/重新暂存（否则替换前文件消失，旧版会被删）。
    private static let inUseLock = NSLock()
    nonisolated(unsafe) private static var inUse: Set<String> = []

    static func beginInstall(destination: String) { inUseLock.withLock { _ = inUse.insert(destination) } }
    static func endInstall(destination: String) { inUseLock.withLock { _ = inUse.remove(destination) } }
    static func isInstalling(destination: String) -> Bool { inUseLock.withLock { inUse.contains(destination) } }

    static func clear(bundleID: String?, destination: String) {
        guard !isInstalling(destination: destination) else { return }
        try? FileManager.default.removeItem(at: directory(bundleID: bundleID, destination: destination))
    }

    /// 校验：文件存在、版本等于 `latest`、未超过 30 天、包内 Info.plist 版本与记录一致。失败返回原因。
    static func validate(_ pkg: StagedPackage, latest: String?, now: Date = Date()) -> Invalid? {
        guard FileManager.default.fileExists(atPath: pkg.appURL.appendingPathComponent("Contents/Info.plist").path) else { return .missing }
        if let latest, latest != pkg.version, VersionCompare.compare(latest, pkg.version) != .orderedSame {
            return .versionMismatch(staged: pkg.version, latest: latest)
        }
        let age = now.timeIntervalSince(pkg.stagedAt)
        if age > maxAge { return .expired(days: Int(age / 86400)) }
        if let actual = bundleVersion(at: pkg.appURL), actual != pkg.version, VersionCompare.compare(actual, pkg.version) != .orderedSame {
            return .bundleMismatch(expected: pkg.version, actual: actual)
        }
        return nil
    }

    /// 有效的暂存包；无效时顺手删除并返回 nil（通过 `onInvalid` 告知原因）。
    static func validPackage(bundleID: String?, destination: String, latest: String?, now: Date = Date(),
                             onInvalid: ((StagedPackage, Invalid) -> Void)? = nil) -> StagedPackage? {
        guard let pkg = load(bundleID: bundleID, destination: destination) else { return nil }
        if let why = validate(pkg, latest: latest, now: now) {
            onInvalid?(pkg, why)
            clear(bundleID: bundleID, destination: destination)
            return nil
        }
        return pkg
    }

    /// 不经 NSBundle 缓存读取 .app 的版本号。
    static func bundleVersion(at app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        return info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String
    }

    static func bundleIdentifier(at app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        return info["CFBundleIdentifier"] as? String
    }

    /// 全部暂存记录（设置 › 通用 "已下载待安装" 行用）。
    static func all() -> [StagedPackage] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var out: [StagedPackage] = []
        for d in dirs {
            guard let subs = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for sub in subs {
                if let data = try? Data(contentsOf: metadataURL(in: sub)), let pkg = try? decoder.decode(StagedPackage.self, from: data) {
                    out.append(pkg)
                }
            }
        }
        return out
    }

    /// 暂存目录占用的磁盘字节数。
    static func totalSize() -> Int64 {
        guard let e = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            if let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) {
                total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// 清空全部暂存。
    static func clearAll() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
