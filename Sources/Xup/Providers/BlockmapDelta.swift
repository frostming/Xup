import Compression
import CryptoKit
import Foundation

/// electron 应用 zip 增量下载的开关（由设置接入）。
enum DeltaDownloadPolicy {
    /// 关闭后 electron zip 走普通整包下载，也不再写基准包缓存。
    nonisolated(unsafe) static var isEnabled = true
    /// 每个应用在 DeltaCache 里保留的基准包个数。
    nonisolated(unsafe) static var keepVersionsPerApp = 1
}

enum DeltaError: LocalizedError, Equatable {
    case badGzip(String)
    case badBlockmap(String)
    case noBaseline
    case noOldBlockmap(String)
    case noChecksum
    case rangesUnsupported
    case sizeMismatch(expected: Int64, got: Int64)
    case http(Int, String)
    case segmentSize(expected: Int64, got: Int64)
    case checksumMismatch
    case littleGain(reuse: Int64, total: Int64)

    var errorDescription: String? {
        switch self {
        case .badGzip(let w): return "gzip 解压失败：\(w)"
        case .badBlockmap(let w): return "blockmap 无法解析：\(w)"
        case .noBaseline: return "没有可用的基准包（首次更新）"
        case .noOldBlockmap(let w): return "拿不到旧版本的 blockmap：\(w)"
        case .noChecksum: return "latest-mac.yml 缺少 sha512，无法校验增量结果"
        case .rangesUnsupported: return "服务器不支持 Range 请求"
        case .sizeMismatch(let e, let g): return "文件大小不一致（期望 \(e)，实际 \(g)）"
        case .http(let code, let what): return "HTTP \(code) \(what)"
        case .segmentSize(let e, let g): return "分段长度不符（期望 \(e)，实际 \(g)）"
        case .checksumMismatch: return "拼接结果 sha512 校验失败"
        case .littleGain(let r, let t): return "可复用部分太少（\(r)/\(t) 字节）"
        }
    }
}

// MARK: - gzip

enum Gzip {
    static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    /// 解 gzip（RFC 1952）：自行跳过头/尾，用 Compression 的 raw DEFLATE 解码；失败时退回 `/usr/bin/gunzip`。
    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b else { throw DeltaError.badGzip("不是 gzip 数据") }
        guard bytes[2] == 8 else { throw DeltaError.badGzip("未知压缩方法 \(bytes[2])") }
        let flags = bytes[3]
        var pos = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard pos + 2 <= bytes.count else { throw DeltaError.badGzip("头部截断") }
            pos += 2 + (Int(bytes[pos]) | Int(bytes[pos + 1]) << 8)
        }
        for bit: UInt8 in [0x08, 0x10] where flags & bit != 0 {  // FNAME / FCOMMENT（NUL 结尾）
            while pos < bytes.count, bytes[pos] != 0 { pos += 1 }
            pos += 1
        }
        if flags & 0x02 != 0 { pos += 2 }  // FHCRC
        guard pos <= bytes.count - 8 else { throw DeltaError.badGzip("头部截断") }
        let tail = bytes.suffix(4)
        let isize = tail.enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        let deflated = Data(bytes[pos..<(bytes.count - 8)])
        do {
            let out = try inflateRaw(deflated, sizeHint: isize)
            // ISIZE 是原始长度 mod 2^32；blockmap 远小于 4 GB，直接比对。
            if out.count != isize { throw DeltaError.badGzip("解压长度 \(out.count) ≠ ISIZE \(isize)") }
            return out
        } catch {
            if let out = gunzipFallback(data) { return out }
            throw error
        }
    }

    private static func inflateRaw(_ input: Data, sizeHint: Int) throws -> Data {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
            throw DeltaError.badGzip("compression_stream_init 失败")
        }
        defer { compression_stream_destroy(stream) }
        let bufSize = 1 << 16
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { dst.deallocate() }
        var out = Data()
        out.reserveCapacity(max(sizeHint, 0))
        try input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let base = src.baseAddress else { throw DeltaError.badGzip("空输入") }
            stream.pointee.src_ptr = base.assumingMemoryBound(to: UInt8.self)
            stream.pointee.src_size = src.count
            var status: compression_status
            repeat {
                stream.pointee.dst_ptr = dst
                stream.pointee.dst_size = bufSize
                status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status != COMPRESSION_STATUS_ERROR else { throw DeltaError.badGzip("DEFLATE 数据损坏") }
                out.append(dst, count: bufSize - stream.pointee.dst_size)
            } while status == COMPRESSION_STATUS_OK
        }
        return out
    }

    private static func gunzipFallback(_ data: Data) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        p.arguments = ["-c"]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        inPipe.fileHandleForWriting.write(data)
        try? inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 && !out.isEmpty ? out : nil
    }
}

// MARK: - blockmap

/// electron-builder 的 `<file>.blockmap`（gzip JSON）：
/// `{"version":"2","files":[{"name":"file","offset":0,"checksums":[...],"sizes":[...]}]}`。
struct Blockmap: Equatable, Sendable {
    struct File: Equatable, Sendable {
        var name: String
        var offset: Int64
        var checksums: [String]
        var sizes: [Int64]
    }

    var version: String
    var files: [File]

    var totalSize: Int64 { files.reduce(0) { $0 + $1.sizes.reduce(0, +) } }

    /// 原始下载内容：gzip 则先解压；也接受未压缩的 JSON。
    static func parse(_ raw: Data) throws -> Blockmap {
        try parse(json: Gzip.isGzip(raw) ? Gzip.decompress(raw) : raw)
    }

    static func parse(json: Data) throws -> Blockmap {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { throw DeltaError.badBlockmap("不是 JSON 对象") }
        let version: String
        if let v = root["version"] as? String { version = v } else if let v = root["version"] as? NSNumber { version = v.stringValue } else { version = "" }
        guard let rawFiles = root["files"] as? [[String: Any]], !rawFiles.isEmpty else { throw DeltaError.badBlockmap("files 为空") }
        var files: [File] = []
        for f in rawFiles {
            guard let checksums = f["checksums"] as? [String], let sizesAny = f["sizes"] as? [NSNumber] else { throw DeltaError.badBlockmap("缺少 checksums/sizes") }
            let sizes = sizesAny.map { $0.int64Value }
            guard checksums.count == sizes.count else { throw DeltaError.badBlockmap("checksums 与 sizes 数量不一致") }
            guard sizes.allSatisfy({ $0 > 0 }) else { throw DeltaError.badBlockmap("块大小必须为正") }
            files.append(File(name: f["name"] as? String ?? "file", offset: (f["offset"] as? NSNumber)?.int64Value ?? 0, checksums: checksums, sizes: sizes))
        }
        return Blockmap(version: version, files: files)
    }
}

// MARK: - 差分计划

enum DeltaOp: Equatable, Sendable {
    /// 从旧包 oldOffset 起复制 length 字节。
    case copy(oldOffset: Int64, length: Int64)
    /// 从服务器下载新包 [newOffset, newOffset+length) 区间。
    case download(newOffset: Int64, length: Int64)

    var length: Int64 {
        switch self {
        case .copy(_, let l), .download(_, let l): return l
        }
    }
}

/// 按 electron-updater `computeOperations` 语义生成的操作序列（按新文件顺序，依次写入即得到新文件）。
struct DeltaPlan: Equatable, Sendable {
    var ops: [DeltaOp]
    var newSize: Int64
    var copyBytes: Int64
    var downloadBytes: Int64
    var changedBlocks: Int

    var downloadRanges: [ClosedRange<Int64>] {
        ops.compactMap { if case .download(let o, let l) = $0 { return o...(o + l - 1) } else { return nil } }
    }

    /// 旧 blockmap 按 checksum 建索引；新 blockmap 的每块：checksum 命中且大小一致 → copy，否则 download；相邻可合并的操作合并。
    static func make(old: Blockmap, new: Blockmap) throws -> DeltaPlan {
        guard let newFile = new.files.first else { throw DeltaError.badBlockmap("新 blockmap 无文件") }
        guard let oldFile = old.files.first(where: { $0.name == newFile.name }) ?? old.files.first else { throw DeltaError.badBlockmap("旧 blockmap 无文件") }

        var oldOffsetByChecksum: [String: Int64] = [:]
        var oldSizeByChecksum: [String: Int64] = [:]
        var off = oldFile.offset
        for (c, s) in zip(oldFile.checksums, oldFile.sizes) {
            if oldOffsetByChecksum[c] == nil { oldOffsetByChecksum[c] = off; oldSizeByChecksum[c] = s }
            off += s
        }

        var ops: [DeltaOp] = []
        var copyBytes: Int64 = 0, downloadBytes: Int64 = 0, changed = 0
        var newOffset = newFile.offset
        for (c, size) in zip(newFile.checksums, newFile.sizes) {
            defer { newOffset += size }
            if let oldOff = oldOffsetByChecksum[c], oldSizeByChecksum[c] == size {
                copyBytes += size
                if case .copy(let o, let l)? = ops.last, o + l == oldOff {
                    ops[ops.count - 1] = .copy(oldOffset: o, length: l + size)
                } else {
                    ops.append(.copy(oldOffset: oldOff, length: size))
                }
            } else {
                changed += 1
                downloadBytes += size
                if case .download(let o, let l)? = ops.last, o + l == newOffset {
                    ops[ops.count - 1] = .download(newOffset: o, length: l + size)
                } else {
                    ops.append(.download(newOffset: newOffset, length: size))
                }
            }
        }
        return DeltaPlan(ops: ops, newSize: newOffset - newFile.offset, copyBytes: copyBytes, downloadBytes: downloadBytes, changedBlocks: changed)
    }
}

// MARK: - 传输层（可注入，测试用本地文件实现）

struct DeltaHead: Sendable {
    var acceptsRanges: Bool
    var contentLength: Int64?
}

protocol DeltaTransport: Sendable {
    func head(_ url: URL) async throws -> DeltaHead
    /// 小文件（blockmap）。
    func fetch(_ url: URL) async throws -> Data
    /// 下载整个文件（range 为 nil）或 `Range: bytes=a-b`（闭区间）到临时文件；调用方负责删除。
    func download(_ url: URL, range: ClosedRange<Int64>?) async throws -> URL
}

struct URLSessionTransport: DeltaTransport {
    var session: URLSession = .shared

    private func request(_ url: URL, method: String = "GET", timeout: TimeInterval = 60) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Xup/1.1 (electron-updater compatible)", forHTTPHeaderField: "User-Agent")
        return req
    }

    func head(_ url: URL) async throws -> DeltaHead {
        let (_, resp) = try await session.data(for: request(url, method: "HEAD", timeout: 30))
        guard let http = resp as? HTTPURLResponse else { return DeltaHead(acceptsRanges: false, contentLength: nil) }
        if http.statusCode >= 400 { throw DeltaError.http(http.statusCode, "HEAD \(url.lastPathComponent)") }
        let ar = http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased()
        let len = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
        return DeltaHead(acceptsRanges: ar == "bytes", contentLength: len)
    }

    func fetch(_ url: URL) async throws -> Data {
        let (data, resp) = try await session.data(for: request(url, timeout: 30))
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 { throw DeltaError.http(http.statusCode, url.lastPathComponent) }
        return data
    }

    func download(_ url: URL, range: ClosedRange<Int64>?) async throws -> URL {
        var req = request(url, timeout: 600)
        if let range { req.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
        let (tmp, resp) = try await session.download(for: req)
        // URLSession 的临时文件只保证在返回前有效，立刻挪到自己的位置。
        let mine = FileManager.default.temporaryDirectory.appendingPathComponent("xup-seg-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: tmp, to: mine)
        if let http = resp as? HTTPURLResponse {
            if http.statusCode >= 400 { try? FileManager.default.removeItem(at: mine); throw DeltaError.http(http.statusCode, url.lastPathComponent) }
            if range != nil, http.statusCode != 206 { try? FileManager.default.removeItem(at: mine); throw DeltaError.rangesUnsupported }
        }
        return mine
    }
}

// MARK: - 执行

enum BlockmapDownloader {
    struct Stats: Sendable {
        var copyBytes: Int64
        var downloadBytes: Int64
        var requests: Int
        var duration: TimeInterval
    }

    static let chunk = 8 << 20

    /// 进度：每完成 10% 打一行。
    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var done: Int64 = 0
        private var lastDecile = 0
        let total: Int64
        let log: Logger
        init(total: Int64, log: @escaping Logger) { self.total = max(total, 1); self.log = log }
        func add(_ n: Int64) {
            lock.lock()
            done += n
            let decile = Int(done * 10 / total)
            let emit = decile > lastDecile
            if emit { lastDecile = decile }
            lock.unlock()
            if emit { log("增量下载进度 \(decile * 10)%", false) }
        }
    }

    /// 按计划把旧包与分段下载拼成 `output`（预先 truncate 到 newSize，各段按偏移写入；下载段最多 `concurrency` 个并发）。
    /// 不做 sha512 校验，由调用方负责。
    static func assemble(plan: DeltaPlan, newURL: URL, oldZip: URL, output: URL, transport: DeltaTransport,
                         concurrency: Int = 4, log: @escaping Logger) async throws -> Stats {
        let fm = FileManager.default
        let start = Date()
        try? fm.removeItem(at: output)
        guard fm.createFile(atPath: output.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let h = try FileHandle(forWritingTo: output)
            try h.truncate(atOffset: UInt64(plan.newSize))
            try h.close()
        }

        // 每个操作在新文件里的写入位置
        var placed: [(op: DeltaOp, newOffset: Int64)] = []
        var cursor: Int64 = 0
        for op in plan.ops { placed.append((op, cursor)); cursor += op.length }

        let progress = Progress(total: plan.newSize, log: log)
        let downloads = placed.filter { if case .download = $0.op { return true } else { return false } }
        let copies = placed.filter { if case .copy = $0.op { return true } else { return false } }

        try await withThrowingTaskGroup(of: Void.self) { group in
            // 复制：单任务顺序读旧包
            group.addTask {
                guard !copies.isEmpty else { return }
                let src = try FileHandle(forReadingFrom: oldZip)
                defer { try? src.close() }
                let dst = try FileHandle(forWritingTo: output)
                defer { try? dst.close() }
                for (op, newOffset) in copies {
                    guard case .copy(let oldOffset, let length) = op else { continue }
                    try Task.checkCancellation()
                    try src.seek(toOffset: UInt64(oldOffset))
                    try dst.seek(toOffset: UInt64(newOffset))
                    var remaining = length
                    while remaining > 0 {
                        let n = Int(min(Int64(chunk), remaining))
                        guard let data = try src.read(upToCount: n), !data.isEmpty else {
                            throw DeltaError.sizeMismatch(expected: oldOffset + length, got: oldOffset + length - remaining)
                        }
                        try dst.write(contentsOf: data)
                        remaining -= Int64(data.count)
                        progress.add(Int64(data.count))
                    }
                }
            }
            // 下载：有限并发
            var next = 0
            var running = 0
            func launch() {
                let (op, newOffset) = downloads[next]
                next += 1
                running += 1
                group.addTask {
                    guard case .download(let from, let length) = op else { return }
                    let seg = try await transport.download(newURL, range: from...(from + length - 1))
                    defer { try? fm.removeItem(at: seg) }
                    let got = (try? fm.attributesOfItem(atPath: seg.path)[.size] as? Int64) ?? -1
                    guard got == length else { throw DeltaError.segmentSize(expected: length, got: got) }
                    let src = try FileHandle(forReadingFrom: seg)
                    defer { try? src.close() }
                    let dst = try FileHandle(forWritingTo: output)
                    defer { try? dst.close() }
                    try dst.seek(toOffset: UInt64(newOffset))
                    while let data = try src.read(upToCount: chunk), !data.isEmpty {
                        try Task.checkCancellation()
                        try dst.write(contentsOf: data)
                        progress.add(Int64(data.count))
                    }
                }
            }
            while next < downloads.count, running < max(1, concurrency) { launch() }
            while running > 0 {
                try await group.next()
                running -= 1
                if next < downloads.count { launch() }
            }
            try await group.waitForAll()
        }

        return Stats(copyBytes: plan.copyBytes, downloadBytes: plan.downloadBytes, requests: downloads.count, duration: Date().timeIntervalSince(start))
    }

    /// 文件的 sha512，base64（与 latest-mac.yml 的 `sha512` 同格式）。
    static func sha512Base64(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA512()
        while let data = try h.read(upToCount: chunk), !data.isEmpty { hasher.update(data: data) }
        return Data(hasher.finalize()).base64EncodedString()
    }

    static func mb(_ n: Int64) -> String { String(format: "%.1f MB", Double(n) / 1_048_576) }
}

// MARK: - 一次 electron 更新的下载会话

/// 供 `AppInstaller.install(download:)` 使用：优先 blockmap 增量，失败回退整包；两种方式都校验 sha512，
/// 成功后 `commit` 把新 zip + blockmap 存入 DeltaCache 作为下次基准。
final class ElectronDeltaSession: @unchecked Sendable {
    let bundleID: String?
    let expectedSHA512: String?
    let expectedSize: Int64?
    let updaterCacheDirName: String?
    let transport: DeltaTransport
    let work: URL

    private let lock = NSLock()
    private var newZip: URL?
    private var newBlockmap: URL?
    /// 同步设置结果（NSLock 不能在 async 上下文直接 lock/unlock）。
    private func recordResult(zip: URL, blockmap: URL?) {
        lock.withLock {
            newZip = zip
            newBlockmap = blockmap
        }
    }

    init(bundleID: String?, expectedSHA512: String?, expectedSize: Int?, updaterCacheDirName: String?,
         transport: DeltaTransport = URLSessionTransport()) {
        self.bundleID = bundleID
        self.expectedSHA512 = expectedSHA512
        self.expectedSize = expectedSize.map(Int64.init)
        self.updaterCacheDirName = updaterCacheDirName
        self.transport = transport
        self.work = FileManager.default.temporaryDirectory.appendingPathComponent("xup-delta-\(UUID().uuidString)", isDirectory: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: work) }

    /// 返回交给 AppInstaller 的本地文件（它会被移走/删除；这里保留一份 APFS 克隆用于 commit）。
    func download(_ url: URL, log: @escaping Logger) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let name = url.lastPathComponent.isEmpty ? "payload.zip" : url.lastPathComponent
        let dest = work.appendingPathComponent(name)
        let bmDest = URL(fileURLWithPath: dest.path + ".blockmap")

        var delivered = false
        if DeltaDownloadPolicy.isEnabled, name.lowercased().hasSuffix(".zip") {
            do {
                try await downloadDelta(url, to: dest, blockmapTo: bmDest, log: log)
                delivered = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log("增量下载不可用，改为整包下载：\(error.localizedDescription)", false)
                try? fm.removeItem(at: dest)
            }
        }
        if !delivered {
            try await downloadFull(url, to: dest, blockmapTo: bmDest, log: log)
        }
        recordResult(zip: dest, blockmap: fm.fileExists(atPath: bmDest.path) ? bmDest : nil)

        let handoff = work.appendingPathComponent("handoff-\(name)")
        try? fm.removeItem(at: handoff)
        try fm.copyItem(at: dest, to: handoff)  // APFS 上是 clone，不占额外空间
        return handoff
    }

    /// 安装成功后调用：把新 zip 与 blockmap 存为基准。
    func commit(log: @escaping Logger) {
        lock.lock()
        let zip = newZip, bm = newBlockmap
        newZip = nil; newBlockmap = nil
        lock.unlock()
        guard let zip, let bundleID, DeltaDownloadPolicy.isEnabled else { return }
        do {
            try DeltaCache.store(zip: zip, blockmap: bm, bundleID: bundleID)
            log("已缓存安装包作为下次增量基准：\(zip.lastPathComponent)", false)
        } catch {
            log("缓存基准包失败：\(error.localizedDescription)", false)
        }
    }

    // MARK: 整包

    private func downloadFull(_ url: URL, to dest: URL, blockmapTo bmDest: URL, log: @escaping Logger) async throws {
        let fm = FileManager.default
        log("下载 \(url.absoluteString)", false)
        let start = Date()
        let tmp = try await transport.download(url, range: nil)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: tmp, to: dest)
        let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
        log("下载完成：\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))，用时 \(Self.fmt(Date().timeIntervalSince(start)))", false)
        if let expectedSize, size != expectedSize { throw DeltaError.sizeMismatch(expected: expectedSize, got: size) }
        if let expectedSHA512 {
            let got = try BlockmapDownloader.sha512Base64(of: dest)
            guard got == expectedSHA512 else {
                try? fm.removeItem(at: dest)
                throw ShellError.failed(dest.lastPathComponent, 1, "sha512 校验失败，已删除下载文件")
            }
        }
        // 顺手把新包的 blockmap 存下来，下次增量就不用再下旧 blockmap。
        if DeltaDownloadPolicy.isEnabled, dest.pathExtension.lowercased() == "zip", let bmURL = Self.blockmapURL(for: url),
           let data = try? await transport.fetch(bmURL), (try? Blockmap.parse(data)) != nil {
            try? data.write(to: bmDest)
        }
    }

    // MARK: 增量

    private func downloadDelta(_ url: URL, to dest: URL, blockmapTo bmDest: URL, log: @escaping Logger) async throws {
        let fm = FileManager.default
        guard let expectedSHA512 else { throw DeltaError.noChecksum }
        let newName = url.lastPathComponent

        // 1. 基准包
        var baseline: DeltaCache.Baseline?
        if let bundleID { baseline = DeltaCache.baseline(for: bundleID) }
        if baseline == nil, let dirName = updaterCacheDirName, let z = DeltaCache.updaterBaseline(cacheDirName: dirName, newFileName: newName) {
            baseline = DeltaCache.Baseline(zip: z, blockmap: nil)
        }
        guard let baseline else { throw DeltaError.noBaseline }
        log("增量下载：基准包 \(baseline.zip.lastPathComponent)", false)

        // 2. 新旧 blockmap
        guard let newBMURL = Self.blockmapURL(for: url) else { throw DeltaError.badBlockmap("无法构造 blockmap URL") }
        let newBMData = try await transport.fetch(newBMURL)
        let newBM = try Blockmap.parse(newBMData)
        let oldBM: Blockmap
        if let cached = baseline.blockmap, let data = try? Data(contentsOf: cached), let bm = try? Blockmap.parse(data) {
            oldBM = bm
        } else {
            guard let oldURL = AppSources.fileURL(baseline.zip.lastPathComponent + ".blockmap", relativeTo: url) else {
                throw DeltaError.noOldBlockmap("无法构造 URL")
            }
            do {
                oldBM = try Blockmap.parse(try await transport.fetch(oldURL))
            } catch {
                throw DeltaError.noOldBlockmap(error.localizedDescription)
            }
        }
        let oldSize = (try? fm.attributesOfItem(atPath: baseline.zip.path)[.size] as? Int64) ?? -1
        guard oldSize == oldBM.totalSize else { throw DeltaError.sizeMismatch(expected: oldBM.totalSize, got: oldSize) }

        // 3. 计划
        let plan = try DeltaPlan.make(old: oldBM, new: newBM)
        if let expectedSize, plan.newSize != expectedSize { throw DeltaError.sizeMismatch(expected: expectedSize, got: plan.newSize) }
        guard plan.copyBytes * 20 >= plan.newSize else { throw DeltaError.littleGain(reuse: plan.copyBytes, total: plan.newSize) }

        // 4. 服务器能力
        let head = try await transport.head(url)
        guard head.acceptsRanges else { throw DeltaError.rangesUnsupported }
        if let len = head.contentLength, len != plan.newSize { throw DeltaError.sizeMismatch(expected: plan.newSize, got: len) }

        let pct = Int((Double(plan.downloadBytes) / Double(max(plan.newSize, 1)) * 100).rounded())
        log("增量下载：复用 \(BlockmapDownloader.mb(plan.copyBytes))，需下载 \(BlockmapDownloader.mb(plan.downloadBytes))（\(pct)%，\(plan.downloadRanges.count) 段，\(plan.changedBlocks) 个变化块）", false)

        // 5. 拼装 + 校验
        let stats = try await BlockmapDownloader.assemble(plan: plan, newURL: url, oldZip: baseline.zip, output: dest, transport: transport, log: log)
        let got = try BlockmapDownloader.sha512Base64(of: dest)
        guard got == expectedSHA512 else {
            try? fm.removeItem(at: dest)
            throw DeltaError.checksumMismatch
        }
        try? newBMData.write(to: bmDest)
        log("增量下载完成：下载 \(BlockmapDownloader.mb(stats.downloadBytes))（\(stats.requests) 个请求），复用 \(BlockmapDownloader.mb(stats.copyBytes))，用时 \(Self.fmt(stats.duration))，sha512 校验通过", false)
    }

    static func blockmapURL(for zip: URL) -> URL? {
        URL(string: zip.absoluteString + ".blockmap")
    }

    private static func fmt(_ t: TimeInterval) -> String {
        t >= 60 ? String(format: "%d 分 %.0f 秒", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) : String(format: "%.1f 秒", t)
    }
}
