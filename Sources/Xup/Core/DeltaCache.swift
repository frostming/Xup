import Foundation

/// electron 应用增量下载的"基准包"缓存：
/// `~/Library/Caches/dev.fming.xup/electron/<bundleID>/<原文件名>.zip`（+ 同名 `.blockmap`，若已下载）。
/// 每个应用保留最近 `DeltaDownloadPolicy.keepVersionsPerApp` 个版本（按修改时间）。
enum DeltaCache {
    /// 缓存根目录；测试可改。
    nonisolated(unsafe) static var rootURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("dev.fming.xup/electron", isDirectory: true)
    }()

    struct Baseline: Sendable {
        var zip: URL
        var blockmap: URL?
    }

    static func directory(for bundleID: String) -> URL {
        rootURL.appendingPathComponent(sanitize(bundleID), isDirectory: true)
    }

    private static func sanitize(_ id: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let s = id.unicodeScalars.map { bad.contains($0) ? "_" : String($0) }.joined()
        return s.isEmpty ? "_" : s
    }

    private static func zips(in dir: URL) -> [(url: URL, mtime: Date)] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        return items.filter { $0.pathExtension.lowercased() == "zip" }.map { u in
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (u, d)
        }.sorted { $0.mtime > $1.mtime }
    }

    /// 最近一次缓存的 zip 及其 blockmap（文件名 `<zip>.blockmap`，不存在则为 nil）。
    static func baseline(for bundleID: String) -> Baseline? {
        guard let newest = zips(in: directory(for: bundleID)).first?.url else { return nil }
        let bm = URL(fileURLWithPath: newest.path + ".blockmap")
        return Baseline(zip: newest, blockmap: FileManager.default.fileExists(atPath: bm.path) ? bm : nil)
    }

    /// 把 zip（与可选 blockmap）移入缓存（同名覆盖），然后按 keepVersionsPerApp 清理旧版本。
    /// 移动失败（跨卷等）时退回复制。
    static func store(zip: URL, blockmap: URL?, bundleID: String) throws {
        let fm = FileManager.default
        let dir = directory(for: bundleID)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let destZip = dir.appendingPathComponent(zip.lastPathComponent)
        try moveOrCopy(zip, to: destZip)
        // 刷新修改时间，保证"最近存入"就是最新基准。
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: destZip.path)
        let destBM = URL(fileURLWithPath: destZip.path + ".blockmap")
        try? fm.removeItem(at: destBM)
        if let blockmap { try? moveOrCopy(blockmap, to: destBM) }
        prune(dir: dir, keep: max(1, DeltaDownloadPolicy.keepVersionsPerApp))
    }

    private static func moveOrCopy(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dst)
        do { try fm.moveItem(at: src, to: dst) }
        catch { try fm.copyItem(at: src, to: dst) }
    }

    private static func prune(dir: URL, keep: Int) {
        let fm = FileManager.default
        let all = zips(in: dir)
        let keepSet = Set(all.prefix(keep).map(\.url.path))
        for z in all.dropFirst(keep) {
            try? fm.removeItem(at: z.url)
            try? fm.removeItem(atPath: z.url.path + ".blockmap")
        }
        // 孤儿 blockmap（zip 已不在）
        if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for u in items where u.pathExtension == "blockmap" {
                let zipPath = String(u.path.dropLast(".blockmap".count))
                if !keepSet.contains(zipPath) { try? fm.removeItem(at: u) }
            }
        }
    }

    static func clear(bundleID: String) {
        try? FileManager.default.removeItem(at: directory(for: bundleID))
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    /// 缓存占用的总字节数。
    static func totalSize() -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            if let s = try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize { total += Int64(s) }
        }
        return total
    }

    // MARK: - 复用应用自身 electron-updater 的缓存（只读）

    /// `~/Library/Caches/<updaterCacheDirName>/pending/*.zip`：应用上次自更新留下的安装包，可直接作为基准。
    /// 多个时优先与新文件名架构标记一致的，再按修改时间最新；只读，不改不删。
    static func updaterBaseline(cacheDirName: String, newFileName: String? = nil) -> URL? {
        guard !cacheDirName.isEmpty, !cacheDirName.contains("/") else { return nil }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        let pending = caches.appendingPathComponent(cacheDirName, isDirectory: true).appendingPathComponent("pending", isDirectory: true)
        let candidates = zips(in: pending)
        guard !candidates.isEmpty else { return nil }
        let tags = ["arm64", "aarch64", "universal", "x64", "x86_64", "intel", "amd64"]
        let newTag = newFileName.flatMap { n in tags.first { n.lowercased().contains($0) } }
        if let newTag {
            if let same = candidates.first(where: { $0.url.lastPathComponent.lowercased().contains(newTag) }) { return same.url }
            // 新包有架构标记而候选没有同样标记：避免用错架构的包当基准
            if candidates.contains(where: { c in tags.contains { c.url.lastPathComponent.lowercased().contains($0) } }) { return nil }
        }
        return candidates.first?.url
    }
}
