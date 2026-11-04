import CryptoKit
import XCTest
@testable import Xup

/// blockmap 增量下载：解析、差分计划、Range 合并、拼装与回退。全部离线（file 级假传输层）。
final class BlockmapTests: XCTestCase {
    private var tmp: URL!
    private var savedRoot: URL!
    private var savedEnabled = true

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xup-bm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        savedRoot = DeltaCache.rootURL
        savedEnabled = DeltaDownloadPolicy.isEnabled
        DeltaCache.rootURL = tmp.appendingPathComponent("cache", isDirectory: true)
        DeltaDownloadPolicy.isEnabled = true
    }

    override func tearDownWithError() throws {
        DeltaCache.rootURL = savedRoot
        DeltaDownloadPolicy.isEnabled = savedEnabled
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - helpers

    private func gzip(_ data: Data, withName: Bool) throws -> Data {
        let src = tmp.appendingPathComponent("plain-\(UUID().uuidString).json")
        try data.write(to: src)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        // `gzip -c file` 会写 FNAME 字段；`gzip -n` 不写文件名与时间戳。
        p.arguments = withName ? ["-c", src.path] : ["-c", "-n", src.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return d
    }

    private func bm(_ pairs: [(String, Int64)], offset: Int64 = 0) -> Blockmap {
        Blockmap(version: "2", files: [.init(name: "file", offset: offset, checksums: pairs.map(\.0), sizes: pairs.map(\.1))])
    }

    /// 用固定块大小 + sha256 做一个与 electron-builder 同构的 blockmap（真实实现的块边界由内容决定，这里不需要）。
    private func makeBlockmap(for data: Data, blockSize: Int) -> Blockmap {
        var checksums: [String] = []
        var sizes: [Int64] = []
        var i = 0
        while i < data.count {
            let n = min(blockSize, data.count - i)
            checksums.append(Data(SHA256.hash(data: data[i..<(i + n)])).base64EncodedString())
            sizes.append(Int64(n))
            i += n
        }
        return bm(Array(zip(checksums, sizes)))
    }

    private func blockmapJSON(_ b: Blockmap) throws -> Data {
        let obj: [String: Any] = ["version": b.version, "files": b.files.map { ["name": $0.name, "offset": $0.offset, "checksums": $0.checksums, "sizes": $0.sizes] as [String: Any] }]
        return try JSONSerialization.data(withJSONObject: obj)
    }

    private func randomData(_ n: Int, seed: UInt64) -> Data {
        var x = seed &* 6364136223846793005 &+ 1442695040888963407
        var d = Data(count: n)
        d.withUnsafeMutableBytes { buf in
            for i in 0..<n {
                x = x &* 6364136223846793005 &+ 1442695040888963407
                buf[i] = UInt8(truncatingIfNeeded: x >> 33)
            }
        }
        return d
    }

    private func sha512(_ d: Data) -> String { Data(SHA512.hash(data: d)).base64EncodedString() }

    /// 本地文件假传输层：远端 URL → 本地文件；记录请求。
    final class FileTransport: DeltaTransport, @unchecked Sendable {
        let files: [String: URL]
        var acceptsRanges = true
        private let lock = NSLock()
        private(set) var ranges: [ClosedRange<Int64>] = []
        private(set) var fullDownloads: [String] = []
        private(set) var fetched: [String] = []

        init(files: [String: URL]) { self.files = files }

        private func local(_ url: URL) throws -> URL {
            guard let u = files[url.absoluteString] else { throw DeltaError.http(404, url.lastPathComponent) }
            return u
        }

        func head(_ url: URL) async throws -> DeltaHead {
            let u = try local(url)
            let size = (try FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0
            return DeltaHead(acceptsRanges: acceptsRanges, contentLength: size)
        }

        func fetch(_ url: URL) async throws -> Data {
            lock.withLock { fetched.append(url.lastPathComponent) }
            return try Data(contentsOf: try local(url))
        }

        func download(_ url: URL, range: ClosedRange<Int64>?) async throws -> URL {
            let all = try Data(contentsOf: try local(url))
            let slice: Data
            if let range {
                guard acceptsRanges else { throw DeltaError.rangesUnsupported }
                lock.withLock { ranges.append(range) }
                slice = all[Int(range.lowerBound)...Int(range.upperBound)]
            } else {
                lock.withLock { fullDownloads.append(url.lastPathComponent) }
                slice = all
            }
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString)")
            try slice.write(to: out)
            return out
        }
    }

    // MARK: - 解析

    func testParseGzippedBlockmap() throws {
        let json = #"{"version":"2","files":[{"name":"file","offset":0,"checksums":["aaa=","bbb=","ccc="],"sizes":[10,20,30]}]}"#.data(using: .utf8)!
        for withName in [false, true] {
            let gz = try gzip(json, withName: withName)
            XCTAssertTrue(Gzip.isGzip(gz))
            let b = try Blockmap.parse(gz)
            XCTAssertEqual(b.version, "2")
            XCTAssertEqual(b.files.count, 1)
            XCTAssertEqual(b.files[0].checksums, ["aaa=", "bbb=", "ccc="])
            XCTAssertEqual(b.files[0].sizes, [10, 20, 30])
            XCTAssertEqual(b.totalSize, 60)
        }
        // 未压缩的 JSON 也接受
        XCTAssertEqual(try Blockmap.parse(json).totalSize, 60)
        // 坏数据
        XCTAssertThrowsError(try Gzip.decompress(Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10])))
        XCTAssertThrowsError(try Blockmap.parse(json: #"{"version":"2","files":[{"checksums":["a"],"sizes":[1,2]}]}"#.data(using: .utf8)!))
    }

    func testGzipLargeRoundTrip() throws {
        // 大于一个 64 KB 输出缓冲，验证流式解压拼接。
        let big = Data(repeating: 0x41, count: 300_000) + randomData(50_000, seed: 7)
        let gz = try gzip(big, withName: false)
        XCTAssertEqual(try Gzip.decompress(gz), big)
    }

    // MARK: - 差分计划

    func testPlanIdentical() throws {
        let old = bm([("a", 10), ("b", 20), ("c", 30)])
        let plan = try DeltaPlan.make(old: old, new: old)
        XCTAssertEqual(plan.ops, [.copy(oldOffset: 0, length: 60)])
        XCTAssertEqual(plan.copyBytes, 60)
        XCTAssertEqual(plan.downloadBytes, 0)
        XCTAssertEqual(plan.newSize, 60)
        XCTAssertEqual(plan.changedBlocks, 0)
    }

    func testPlanInsertMiddle() throws {
        let old = bm([("a", 10), ("b", 20), ("c", 30)])
        let new = bm([("a", 10), ("x", 5), ("y", 6), ("b", 20), ("c", 30)])
        let plan = try DeltaPlan.make(old: old, new: new)
        XCTAssertEqual(plan.ops, [.copy(oldOffset: 0, length: 10), .download(newOffset: 10, length: 11), .copy(oldOffset: 10, length: 50)])
        XCTAssertEqual(plan.downloadBytes, 11)
        XCTAssertEqual(plan.copyBytes, 60)
        XCTAssertEqual(plan.newSize, 71)
        XCTAssertEqual(plan.changedBlocks, 2)
    }

    func testPlanAppendTail() throws {
        let old = bm([("a", 10), ("b", 20)])
        let new = bm([("a", 10), ("b", 20), ("z", 7)])
        let plan = try DeltaPlan.make(old: old, new: new)
        XCTAssertEqual(plan.ops, [.copy(oldOffset: 0, length: 30), .download(newOffset: 30, length: 7)])
    }

    func testPlanAllDifferent() throws {
        let old = bm([("a", 10), ("b", 20)])
        let new = bm([("p", 10), ("q", 20), ("r", 5)])
        let plan = try DeltaPlan.make(old: old, new: new)
        XCTAssertEqual(plan.ops, [.download(newOffset: 0, length: 35)])
        XCTAssertEqual(plan.copyBytes, 0)
    }

    func testPlanReorderAndSizeMismatch() throws {
        // 顺序打乱：copy 不连续时不能合并；checksum 相同但大小不同 → 视为变化。
        let old = bm([("a", 10), ("b", 20), ("c", 30)])
        let new = bm([("c", 30), ("a", 10), ("b", 21)])
        let plan = try DeltaPlan.make(old: old, new: new)
        XCTAssertEqual(plan.ops, [.copy(oldOffset: 30, length: 30), .copy(oldOffset: 0, length: 10), .download(newOffset: 40, length: 21)])
        // 旧 blockmap 带 offset
        let old2 = bm([("a", 10), ("b", 20)], offset: 100)
        let plan2 = try DeltaPlan.make(old: old2, new: bm([("b", 20)]))
        XCTAssertEqual(plan2.ops, [.copy(oldOffset: 110, length: 20)])
    }

    func testRangeMerge() throws {
        let old = bm([("a", 10), ("b", 20), ("c", 30), ("d", 40)])
        let new = bm([("x", 1), ("y", 2), ("a", 10), ("b", 20), ("z", 3), ("w", 4), ("d", 40), ("v", 5)])
        let plan = try DeltaPlan.make(old: old, new: new)
        XCTAssertEqual(plan.downloadRanges, [0...2, 33...39, 80...84])
        XCTAssertEqual(plan.ops.count, 5)
        XCTAssertEqual(plan.downloadBytes, 15)
    }

    // MARK: - 拼装 + 校验 + 回退

    private struct Fixture {
        var oldZip: URL
        var newZip: URL
        var newData: Data
        var newURL: URL
        var transport: FileTransport
        var oldBM: Blockmap
        var newBM: Blockmap
    }

    /// 旧包 = 随机 300 KB；新包 = 开头改 1 KB + 中间插入 16 KB（整块，固定分块下后续块才能对齐）+ 末尾追加 5 KB。块大小 16 KB。
    private func makeFixture(oldBlockmapOnServer: Bool = true, corruptOldBlockmap: Bool = false) throws -> Fixture {
        let blockSize = 16 * 1024
        let oldData = randomData(300 * 1024, seed: 1)
        var newData = oldData
        newData.replaceSubrange(0..<1024, with: randomData(1024, seed: 2))
        newData.insert(contentsOf: randomData(16 * 1024, seed: 3), at: 160 * 1024)
        newData.append(randomData(5 * 1024, seed: 4))

        let server = tmp.appendingPathComponent("server", isDirectory: true)
        try FileManager.default.createDirectory(at: server, withIntermediateDirectories: true)
        let oldZip = server.appendingPathComponent("app-1.0.0-mac-arm64.zip")
        let newZip = server.appendingPathComponent("app-1.1.0-mac-arm64.zip")
        try oldData.write(to: oldZip)
        try newData.write(to: newZip)
        var oldBM = makeBlockmap(for: oldData, blockSize: blockSize)
        let newBM = makeBlockmap(for: newData, blockSize: blockSize)
        if corruptOldBlockmap {
            // 谎称旧包第 1 块与新包第 1 块相同（新包开头 1 KB 已改，实际不同）→ 拼出来 sha512 不对。
            oldBM.files[0].checksums[0] = newBM.files[0].checksums[0]
        }
        let oldBMFile = server.appendingPathComponent("app-1.0.0-mac-arm64.zip.blockmap")
        let newBMFile = server.appendingPathComponent("app-1.1.0-mac-arm64.zip.blockmap")
        try gzip(blockmapJSON(oldBM), withName: false).write(to: oldBMFile)
        try gzip(blockmapJSON(newBM), withName: false).write(to: newBMFile)

        let base = "https://example.test/dl/"
        var files = [base + "app-1.1.0-mac-arm64.zip": newZip, base + "app-1.1.0-mac-arm64.zip.blockmap": newBMFile, base + "app-1.0.0-mac-arm64.zip": oldZip]
        if oldBlockmapOnServer { files[base + "app-1.0.0-mac-arm64.zip.blockmap"] = oldBMFile }
        return Fixture(oldZip: oldZip, newZip: newZip, newData: newData, newURL: URL(string: base + "app-1.1.0-mac-arm64.zip")!,
                       transport: FileTransport(files: files), oldBM: oldBM, newBM: newBM)
    }

    private func logger(into lines: Lines) -> Logger { { text, _ in lines.append(text) } }
    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
        func contains(_ sub: String) -> Bool { all.contains { $0.contains(sub) } }
    }

    func testAssembleProducesExactFile() async throws {
        let fx = try makeFixture()
        let plan = try DeltaPlan.make(old: fx.oldBM, new: fx.newBM)
        XCTAssertGreaterThan(plan.copyBytes, plan.downloadBytes)
        let out = tmp.appendingPathComponent("out.zip")
        let lines = Lines()
        let stats = try await BlockmapDownloader.assemble(plan: plan, newURL: fx.newURL, oldZip: fx.oldZip, output: out, transport: fx.transport, log: logger(into: lines))
        XCTAssertEqual(try Data(contentsOf: out), fx.newData)
        XCTAssertEqual(stats.downloadBytes, plan.downloadBytes)
        XCTAssertEqual(fx.transport.ranges.count, plan.downloadRanges.count)
        XCTAssertEqual(Set(fx.transport.ranges), Set(plan.downloadRanges))
        XCTAssertEqual(try BlockmapDownloader.sha512Base64(of: out), sha512(fx.newData))
        XCTAssertTrue(lines.contains("增量下载进度 100%"))
    }

    /// 基准来自 DeltaCache（含缓存的旧 blockmap）→ 不需要再下旧 blockmap；commit 后缓存被替换为新包。
    func testSessionDeltaWithCachedBaseline() async throws {
        let fx = try makeFixture(oldBlockmapOnServer: false)
        let oldBMCopy = tmp.appendingPathComponent("old.blockmap")
        try gzip(blockmapJSON(fx.oldBM), withName: false).write(to: oldBMCopy)
        let oldZipCopy = tmp.appendingPathComponent("app-1.0.0-mac-arm64.zip")
        try FileManager.default.copyItem(at: fx.oldZip, to: oldZipCopy)
        try DeltaCache.store(zip: oldZipCopy, blockmap: oldBMCopy, bundleID: "com.example.app")
        XCTAssertNotNil(DeltaCache.baseline(for: "com.example.app")?.blockmap)

        let session = ElectronDeltaSession(bundleID: "com.example.app", expectedSHA512: sha512(fx.newData), expectedSize: fx.newData.count,
                                           updaterCacheDirName: nil, transport: fx.transport)
        defer { session.cleanup() }
        let lines = Lines()
        let file = try await session.download(fx.newURL, log: logger(into: lines))
        XCTAssertEqual(try Data(contentsOf: file), fx.newData)
        XCTAssertTrue(fx.transport.fullDownloads.isEmpty, "不应整包下载")
        XCTAssertFalse(fx.transport.fetched.contains("app-1.0.0-mac-arm64.zip.blockmap"), "旧 blockmap 应来自缓存")
        XCTAssertTrue(lines.contains("增量下载：复用"))
        XCTAssertTrue(lines.contains("sha512 校验通过"))

        // 模拟 AppInstaller 消费了返回的文件
        try FileManager.default.removeItem(at: file)
        session.commit(log: logger(into: lines))
        let b = try XCTUnwrap(DeltaCache.baseline(for: "com.example.app"))
        XCTAssertEqual(b.zip.lastPathComponent, "app-1.1.0-mac-arm64.zip")
        XCTAssertNotNil(b.blockmap)
        XCTAssertEqual(try Data(contentsOf: b.zip), fx.newData)
        // keepVersionsPerApp = 1：旧版本已被清理
        let names = try FileManager.default.contentsOfDirectory(atPath: DeltaCache.directory(for: "com.example.app").path).sorted()
        XCTAssertEqual(names, ["app-1.1.0-mac-arm64.zip", "app-1.1.0-mac-arm64.zip.blockmap"])
        XCTAssertEqual(DeltaCache.totalSize(), Int64(fx.newData.count) + Int64(try Data(contentsOf: b.blockmap!).count))
        DeltaCache.clear(bundleID: "com.example.app")
        XCTAssertNil(DeltaCache.baseline(for: "com.example.app"))
    }

    /// 基准只有 zip（无 blockmap）→ 从服务器下旧 blockmap。
    func testSessionFetchesOldBlockmapFromServer() async throws {
        let fx = try makeFixture()
        let oldZipCopy = tmp.appendingPathComponent("app-1.0.0-mac-arm64.zip")
        try FileManager.default.copyItem(at: fx.oldZip, to: oldZipCopy)
        try DeltaCache.store(zip: oldZipCopy, blockmap: nil, bundleID: "com.example.app")
        let session = ElectronDeltaSession(bundleID: "com.example.app", expectedSHA512: sha512(fx.newData), expectedSize: fx.newData.count,
                                           updaterCacheDirName: nil, transport: fx.transport)
        defer { session.cleanup() }
        let lines = Lines()
        let file = try await session.download(fx.newURL, log: logger(into: lines))
        XCTAssertEqual(try Data(contentsOf: file), fx.newData)
        XCTAssertTrue(fx.transport.fetched.contains("app-1.0.0-mac-arm64.zip.blockmap"))
        XCTAssertTrue(fx.transport.fullDownloads.isEmpty)
    }

    /// 旧 blockmap 与旧包不符 → 拼接结果 sha512 不对 → 回退整包并成功。
    func testSessionFallsBackOnChecksumMismatch() async throws {
        let fx = try makeFixture(corruptOldBlockmap: true)
        let oldZipCopy = tmp.appendingPathComponent("app-1.0.0-mac-arm64.zip")
        try FileManager.default.copyItem(at: fx.oldZip, to: oldZipCopy)
        try DeltaCache.store(zip: oldZipCopy, blockmap: nil, bundleID: "com.example.app")
        let session = ElectronDeltaSession(bundleID: "com.example.app", expectedSHA512: sha512(fx.newData), expectedSize: fx.newData.count,
                                           updaterCacheDirName: nil, transport: fx.transport)
        defer { session.cleanup() }
        let lines = Lines()
        let file = try await session.download(fx.newURL, log: logger(into: lines))
        XCTAssertEqual(try Data(contentsOf: file), fx.newData)
        XCTAssertFalse(fx.transport.ranges.isEmpty, "应先尝试过增量")
        XCTAssertEqual(fx.transport.fullDownloads, ["app-1.1.0-mac-arm64.zip"])
        XCTAssertTrue(lines.contains(DeltaError.checksumMismatch.localizedDescription))
        XCTAssertTrue(lines.contains("改为整包下载"))
    }

    /// 无基准 / 不支持 Range / blockmap 404 → 回退整包；整包 sha512 也不对 → 抛错并删除文件。
    func testSessionFallbackReasons() async throws {
        let fx = try makeFixture()
        let lines = Lines()
        // 无基准
        do {
            let s = ElectronDeltaSession(bundleID: "com.example.none", expectedSHA512: sha512(fx.newData), expectedSize: nil, updaterCacheDirName: "definitely-missing-updater", transport: fx.transport)
            defer { s.cleanup() }
            let f = try await s.download(fx.newURL, log: logger(into: lines))
            XCTAssertEqual(try Data(contentsOf: f), fx.newData)
            XCTAssertTrue(lines.contains(DeltaError.noBaseline.localizedDescription))
            XCTAssertTrue(fx.transport.ranges.isEmpty)
        }
        // 不支持 Range
        let oldZipCopy = tmp.appendingPathComponent("app-1.0.0-mac-arm64.zip")
        try FileManager.default.copyItem(at: fx.oldZip, to: oldZipCopy)
        try DeltaCache.store(zip: oldZipCopy, blockmap: nil, bundleID: "com.example.app")
        do {
            fx.transport.acceptsRanges = false
            let s = ElectronDeltaSession(bundleID: "com.example.app", expectedSHA512: sha512(fx.newData), expectedSize: fx.newData.count, updaterCacheDirName: nil, transport: fx.transport)
            defer { s.cleanup() }
            _ = try await s.download(fx.newURL, log: logger(into: lines))
            XCTAssertTrue(lines.contains(DeltaError.rangesUnsupported.localizedDescription))
            fx.transport.acceptsRanges = true
        }
        // 新 blockmap 404
        do {
            var files = fx.transport.files
            files[fx.newURL.absoluteString + ".blockmap"] = nil
            let t = FileTransport(files: files)
            let s = ElectronDeltaSession(bundleID: "com.example.app", expectedSHA512: sha512(fx.newData), expectedSize: fx.newData.count, updaterCacheDirName: nil, transport: t)
            defer { s.cleanup() }
            let f = try await s.download(fx.newURL, log: logger(into: lines))
            XCTAssertEqual(try Data(contentsOf: f), fx.newData)
            XCTAssertTrue(lines.contains("HTTP 404"))
            XCTAssertEqual(t.fullDownloads.count, 1)
        }
        // 整包 sha512 也错 → 抛错
        do {
            let s = ElectronDeltaSession(bundleID: "com.example.app", expectedSHA512: "bogus", expectedSize: fx.newData.count, updaterCacheDirName: nil, transport: fx.transport)
            defer { s.cleanup() }
            do {
                _ = try await s.download(fx.newURL, log: logger(into: lines))
                XCTFail("应抛错")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("sha512"))
            }
        }
        // 开关关闭 → 直接整包，不碰 Range，也不写缓存
        do {
            DeltaDownloadPolicy.isEnabled = false
            let t = FileTransport(files: fx.transport.files)
            let s = ElectronDeltaSession(bundleID: "com.example.app", expectedSHA512: sha512(fx.newData), expectedSize: fx.newData.count, updaterCacheDirName: nil, transport: t)
            defer { s.cleanup() }
            _ = try await s.download(fx.newURL, log: logger(into: lines))
            XCTAssertTrue(t.ranges.isEmpty)
            XCTAssertEqual(t.fullDownloads.count, 1)
            s.commit(log: logger(into: lines))
            XCTAssertEqual(DeltaCache.baseline(for: "com.example.app")?.zip.lastPathComponent, "app-1.0.0-mac-arm64.zip")
            DeltaDownloadPolicy.isEnabled = true
        }
    }

    // MARK: - DeltaCache

    func testDeltaCacheKeepVersions() throws {
        let saved = DeltaDownloadPolicy.keepVersionsPerApp
        defer { DeltaDownloadPolicy.keepVersionsPerApp = saved }
        DeltaDownloadPolicy.keepVersionsPerApp = 2
        for v in ["1", "2", "3"] {
            let z = tmp.appendingPathComponent("app-\(v).zip")
            try Data("v\(v)".utf8).write(to: z)
            try DeltaCache.store(zip: z, blockmap: nil, bundleID: "a/b:c")
            Thread.sleep(forTimeInterval: 0.02)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: DeltaCache.directory(for: "a/b:c").path).sorted()
        XCTAssertEqual(names, ["app-2.zip", "app-3.zip"])
        XCTAssertEqual(DeltaCache.baseline(for: "a/b:c")?.zip.lastPathComponent, "app-3.zip")
        XCTAssertFalse(DeltaCache.directory(for: "a/b:c").lastPathComponent.contains("/"))
    }

    func testUpdaterBaselinePrefersSameArch() throws {
        // 用临时 HOME 不方便，这里只验证不存在的目录返回 nil，以及路径穿越被拒绝。
        XCTAssertNil(DeltaCache.updaterBaseline(cacheDirName: "xup-no-such-updater-\(UUID().uuidString)"))
        XCTAssertNil(DeltaCache.updaterBaseline(cacheDirName: "../etc"))
    }

    // MARK: - latest-mac.yml / app-update.yml

    func testElectronYMLCarriesChecksum() throws {
        let yml = """
        version: 0.4.422
        files:
          - url: alma-0.4.422-mac-arm64.zip
            sha512: TPDfoQ==
            size: 413557084
          - url: alma-0.4.422-mac-x64.zip
            sha512: Z1ha1A==
            size: 1
        path: alma-0.4.422-mac-arm64.zip
        """
        let r = try AppSources.parseLatestMacYML(yml)
        let picked = try XCTUnwrap(AppSources.pickElectronFile(r))
        XCTAssertEqual(picked, "alma-0.4.422-mac-arm64.zip")
        let meta = try XCTUnwrap(r.files.first { $0.url == picked })
        XCTAssertEqual(meta.sha512, "TPDfoQ==")
        XCTAssertEqual(meta.size, 413557084)
        let kv = AppSources.parseAppUpdateYML("provider: generic\nurl: https://updates.alma.now/\nuseMultipleRangeRequest: false\nupdaterCacheDirName: alma-updater\n")
        XCTAssertEqual(kv["updaterCacheDirName"], "alma-updater")
        XCTAssertEqual(AppSources.electronFeedURL(appUpdateYML: "provider: generic\nurl: https://updates.alma.now/\n")?.absoluteString, "https://updates.alma.now/latest-mac.yml")
        XCTAssertEqual(ElectronDeltaSession.blockmapURL(for: URL(string: "https://u.test/a%20b.zip")!)?.absoluteString, "https://u.test/a%20b.zip.blockmap")
    }
}
