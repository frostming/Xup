import XCTest
@testable import Xup

/// §18 更新历史：jsonl 往返、2000 条截断、按天分组与筛选辅助函数。
@MainActor
final class HistoryTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xup-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private var fileURL: URL { tmp.appendingPathComponent("history.jsonl") }

    private func record(_ name: String, time: Date = Date(), kind: ProviderKind = .homebrew, ok: Bool = true,
                        trigger: Trigger = .manual, error: String? = nil, detail: String? = nil) -> UpdateRecord {
        UpdateRecord(time: time, kind: kind, itemID: "\(kind.rawValue):\(name)", name: name, detail: detail,
                     fromVersion: "1.0", toVersion: ok ? "1.1" : nil, duration: 2.5, ok: ok,
                     error: ok ? nil : (error ?? "boom"), trigger: trigger)
    }

    // MARK: 读写往返

    func testAppendThenReloadRoundTrip() throws {
        let h = UpdateHistory(url: fileURL)
        XCTAssertTrue(h.records.isEmpty)
        let a = record("node", kind: .homebrew, trigger: .cli, detail: "formula")
        let b = record("iina", kind: .app, ok: false, trigger: .scheduled, error: "签名不匹配")
        h.append(a)
        h.append(b)
        XCTAssertEqual(h.records, [a, b])

        // 文件：两行 JSON
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"itemID\":\"homebrew:node\""))
        XCTAssertTrue(lines[1].contains("\"trigger\":\"scheduled\""))

        // 重新加载：内容一致（时间按 ISO8601 秒级往返）
        let reloaded = UpdateHistory(url: fileURL)
        XCTAssertEqual(reloaded.records.count, 2)
        XCTAssertEqual(reloaded.records[0].id, a.id)
        XCTAssertEqual(reloaded.records[1].error, "签名不匹配")
        XCTAssertEqual(reloaded.records[1].toVersion, nil)
        XCTAssertEqual(reloaded.records[1].trigger, .scheduled)
        XCTAssertEqual(reloaded.records[0].time.timeIntervalSince1970, a.time.timeIntervalSince1970, accuracy: 1)
    }

    func testCorruptLinesAreSkipped() throws {
        let h = UpdateHistory(url: fileURL)
        h.append(record("a"))
        var data = try Data(contentsOf: fileURL)
        data.append(Data("not json\n{\"half\":true}\n".utf8))
        try data.write(to: fileURL)
        h.append(record("b"))
        let reloaded = UpdateHistory(url: fileURL)
        XCTAssertEqual(reloaded.records.map(\.name), ["a", "b"])
    }

    func testClearEmptiesFile() throws {
        let h = UpdateHistory(url: fileURL)
        h.append(record("a"))
        h.clear()
        XCTAssertTrue(h.records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fileURL).count, 0)
        XCTAssertTrue(UpdateHistory(url: fileURL).records.isEmpty)
    }

    // MARK: 2000 条截断

    func testTruncatesToMaxRecords() throws {
        let h = UpdateHistory(url: fileURL)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<(UpdateHistory.maxRecords + 5) {
            h.append(record("pkg\(i)", time: base.addingTimeInterval(TimeInterval(i))))
        }
        XCTAssertEqual(h.records.count, UpdateHistory.maxRecords)
        XCTAssertEqual(h.records.first?.name, "pkg5", "最早的 5 条被淘汰")
        XCTAssertEqual(h.records.last?.name, "pkg\(UpdateHistory.maxRecords + 4)")

        // 文件也只剩 2000 行
        let lines = try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, UpdateHistory.maxRecords)
        let reloaded = UpdateHistory(url: fileURL)
        XCTAssertEqual(reloaded.records.count, UpdateHistory.maxRecords)
        XCTAssertEqual(reloaded.records.first?.name, "pkg5")
    }

    func testLoadTruncatesOversizedFile() throws {
        // 文件被外部写到超过上限：加载时只保留最近的。
        var data = Data()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        for i in 0..<(UpdateHistory.maxRecords + 10) {
            data.append(try enc.encode(record("x\(i)", time: Date(timeIntervalSince1970: TimeInterval(i)))))
            data.append(UInt8(ascii: "\n"))
        }
        try data.write(to: fileURL)
        let h = UpdateHistory(url: fileURL)
        XCTAssertEqual(h.records.count, UpdateHistory.maxRecords)
        XCTAssertEqual(h.records.first?.name, "x10")
    }

    // MARK: 分组与筛选

    func testGroupByDayTitlesAndOrder() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        // 2026-11-04 10:30 本地
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 10, minute: 30))!
        let today1 = now.addingTimeInterval(-3600)
        let today2 = now.addingTimeInterval(-60)
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        let older = cal.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 9))!
        let lastYear = cal.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 9))!
        let records = [
            record("a", time: older), record("b", time: today1), record("c", time: yesterday),
            record("d", time: today2), record("e", time: lastYear),
        ]
        let groups = UpdateHistory.groupByDay(records, now: now, calendar: cal)
        XCTAssertEqual(groups.map(\.title), ["今天", "昨天", "10月28日 周三", "2025年12月31日"])
        XCTAssertEqual(groups[0].records.map(\.name), ["d", "b"], "组内按时间倒序")
        XCTAssertEqual(groups[1].records.map(\.name), ["c"])
    }

    func testFilterByKindFailedQueryAndLimit() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            record("node", time: base, kind: .homebrew),
            record("typescript", time: base.addingTimeInterval(10), kind: .npm, ok: false, error: "EACCES"),
            record("iina", time: base.addingTimeInterval(20), kind: .app, ok: false, error: "签名不匹配"),
            record("nox", time: base.addingTimeInterval(30), kind: .uv),
        ]
        XCTAssertEqual(UpdateHistory.filter(records).map(\.name), ["nox", "iina", "typescript", "node"], "默认按时间倒序")
        XCTAssertEqual(UpdateHistory.filter(records, kind: .npm).map(\.name), ["typescript"])
        XCTAssertEqual(UpdateHistory.filter(records, failedOnly: true).map(\.name), ["iina", "typescript"])
        XCTAssertEqual(UpdateHistory.filter(records, query: "签名").map(\.name), ["iina"], "搜索命中错误信息")
        XCTAssertEqual(UpdateHistory.filter(records, query: "NODE").map(\.name), ["node"], "大小写不敏感")
        XCTAssertEqual(UpdateHistory.filter(records, limit: 2).map(\.name), ["nox", "iina"])
        XCTAssertEqual(UpdateHistory.filter(records, failedOnly: true, limit: 1).map(\.name), ["iina"])

        let h = UpdateHistory(url: fileURL)
        records.forEach(h.append)
        XCTAssertEqual(h.records(kind: .app, failedOnly: true, limit: 10).map(\.name), ["iina"])
    }

    func testFailedCountAndDayStats() {
        let now = Date()
        let records = [
            record("a", time: now.addingTimeInterval(-3600), ok: false),
            record("b", time: now.addingTimeInterval(-30 * 3600), ok: false),
            record("c", time: now.addingTimeInterval(-600)),
        ]
        XCTAssertEqual(UpdateHistory.failedCount(records, since: now.addingTimeInterval(-24 * 3600)), 1)
        let stats = UpdateHistory.dayStats(records, on: now)
        // a、c 可能跨越午夜；只断言不变量
        XCTAssertEqual(stats.ok + stats.failed, records.filter { Calendar.current.isDate($0.time, inSameDayAs: now) }.count)
        XCTAssertEqual(stats.last, records.filter { Calendar.current.isDate($0.time, inSameDayAs: now) }.map(\.time).max())
    }

    func testVersionAndDurationText() {
        var r = record("a")
        XCTAssertEqual(r.versionText, "1.0 → 1.1")
        r.toVersion = nil
        XCTAssertEqual(r.versionText, "1.0")
        XCTAssertEqual(UpdateHistory.formatDuration(0.83), "0.8 秒")
        XCTAssertEqual(UpdateHistory.formatDuration(42.4), "42 秒")
        XCTAssertEqual(UpdateHistory.formatDuration(125), "2 分 05 秒")
    }
}
