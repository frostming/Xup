import Foundation

/// 一次更新的触发方式。
enum Trigger: String, Codable, CaseIterable {
    /// 主窗口 / 菜单栏面板的按钮。
    case manual
    /// `xup update`（控制通道）。
    case cli
    /// 定时检查后的自动更新（设置里开启"自动更新"，由计时器触发）。
    case scheduled
    /// 启动时检查后的自动更新，或 `XUP_DEBUG_UPDATE` 调试钩子。
    case auto

    /// 界面小标签。
    var label: String {
        switch self {
        case .manual: return "手动"
        case .cli: return "CLI"
        case .scheduled: return "定时"
        case .auto: return "自动"
        }
    }
}

/// 一条更新记录（§18）。成功与失败都记录。
struct UpdateRecord: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var time: Date
    var kind: ProviderKind
    var itemID: String
    var name: String
    var detail: String?
    var fromVersion: String
    var toVersion: String?
    var duration: TimeInterval
    var ok: Bool
    var error: String?
    var trigger: Trigger

    /// 列表"版本"列：`from → to`；失败且不知道目标版本时只显示 from。
    var versionText: String {
        guard let to = toVersion, !to.isEmpty else { return fromVersion }
        return "\(fromVersion) → \(to)"
    }

    /// 耗时文案：`0.8 秒` / `12 秒` / `2 分 05 秒`。
    var durationText: String { UpdateHistory.formatDuration(duration) }
}

/// 更新历史：`~/Library/Application Support/Xup/history.jsonl`，每行一条 JSON，追加写；最多保留 `maxRecords` 条。
@MainActor
final class UpdateHistory: ObservableObject {
    nonisolated static let maxRecords = 2000
    nonisolated static var defaultURL: URL { AppSettings.supportDirectory.appendingPathComponent("history.jsonl") }

    @Published private(set) var records: [UpdateRecord] = []
    let url: URL
    /// 写文件失败时的最后一条错误（界面日志用）。
    private(set) var lastError: String?

    /// JSONEncoder/Decoder 不是 Sendable，按需构造（开销可忽略）。
    nonisolated private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    nonisolated private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    init(url: URL = UpdateHistory.defaultURL) {
        self.url = url
        records = Self.load(from: url)
    }

    // MARK: - 读写

    /// 读取文件：坏行跳过；超过上限只保留最近的。
    nonisolated static func load(from url: URL) -> [UpdateRecord] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        var out: [UpdateRecord] = []
        let decoder = decoder
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            if let r = try? decoder.decode(UpdateRecord.self, from: line) { out.append(r) }
        }
        if out.count > maxRecords { out.removeFirst(out.count - maxRecords) }
        return out
    }

    /// 追加一条：内存 + 文件末尾追加一行；超出上限时整体重写为最近 `maxRecords` 条。
    func append(_ record: UpdateRecord) {
        records.append(record)
        if records.count > Self.maxRecords {
            records.removeFirst(records.count - Self.maxRecords)
            rewrite()
            return
        }
        guard let line = Self.encodeLine(record) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
            }
            lastError = nil
        } catch {
            lastError = "写入 history.jsonl 失败：\(error.localizedDescription)"
        }
    }

    /// 清空全部记录（内存与文件）。
    func clear() {
        records.removeAll()
        rewrite()
    }

    /// 按来源 / 仅失败 过滤，按时间倒序，最多 `limit` 条（`limit <= 0` 为不限）。
    func records(kind: ProviderKind? = nil, failedOnly: Bool = false, limit: Int = 0) -> [UpdateRecord] {
        Self.filter(records, kind: kind, failedOnly: failedOnly, limit: limit)
    }

    private func rewrite() {
        var data = Data()
        let encoder = Self.encoder
        for r in records { if let l = Self.encodeLine(r, encoder: encoder) { data.append(l) } }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            lastError = nil
        } catch {
            lastError = "重写 history.jsonl 失败：\(error.localizedDescription)"
        }
    }

    nonisolated private static func encodeLine(_ r: UpdateRecord, encoder: JSONEncoder = UpdateHistory.encoder) -> Data? {
        guard var d = try? encoder.encode(r) else { return nil }
        d.append(UInt8(ascii: "\n"))
        return d
    }

    // MARK: - 纯函数辅助（界面 / CLI / 测试共用）

    /// 过滤 + 倒序 + 截断。
    nonisolated static func filter(_ records: [UpdateRecord], kind: ProviderKind? = nil, failedOnly: Bool = false,
                                   query: String = "", limit: Int = 0) -> [UpdateRecord] {
        var list = records
        if let kind { list = list.filter { $0.kind == kind } }
        if failedOnly { list = list.filter { !$0.ok } }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(q)
                    || ($0.detail?.localizedCaseInsensitiveContains(q) ?? false)
                    || ($0.error?.localizedCaseInsensitiveContains(q) ?? false)
                    || $0.itemID.localizedCaseInsensitiveContains(q)
            }
        }
        list.sort { $0.time > $1.time }
        if limit > 0, list.count > limit { list = Array(list.prefix(limit)) }
        return list
    }

    struct DayGroup: Identifiable, Hashable {
        let day: Date
        let title: String
        let records: [UpdateRecord]
        var id: Date { day }
    }

    /// 按自然日分组（新的在前），标题：今天 / 昨天 / `M月d日`（跨年带年份）。组内按时间倒序。
    nonisolated static func groupByDay(_ records: [UpdateRecord], now: Date = Date(), calendar: Calendar = .current) -> [DayGroup] {
        let buckets = Dictionary(grouping: records) { calendar.startOfDay(for: $0.time) }
        return buckets.keys.sorted(by: >).map { day in
            DayGroup(day: day, title: dayTitle(day, now: now, calendar: calendar),
                     records: buckets[day]!.sorted { $0.time > $1.time })
        }
    }

    nonisolated static func dayTitle(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "今天" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) { return "昨天" }
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = calendar.isDate(day, equalTo: now, toGranularity: .year) ? "M月d日 EEE" : "yyyy年M月d日"
        return f.string(from: day)
    }

    /// 某个时间窗口内的失败数（侧栏角标用 24 小时）。
    nonisolated static func failedCount(_ records: [UpdateRecord], since: Date) -> Int {
        records.filter { !$0.ok && $0.time >= since }.count
    }

    /// 某天的统计（菜单栏面板"上次更新 HH:mm · 成功 N / 失败 M"）。
    nonisolated static func dayStats(_ records: [UpdateRecord], on date: Date = Date(), calendar: Calendar = .current) -> (ok: Int, failed: Int, last: Date?) {
        let todays = records.filter { calendar.isDate($0.time, inSameDayAs: date) }
        return (todays.filter(\.ok).count, todays.filter { !$0.ok }.count, todays.map(\.time).max())
    }

    nonisolated static func formatDuration(_ s: TimeInterval) -> String {
        if s < 10 { return String(format: "%.1f 秒", max(s, 0)) }
        if s < 60 { return "\(Int(s.rounded())) 秒" }
        let m = Int(s) / 60, sec = Int(s) % 60
        return String(format: "%d 分 %02d 秒", m, sec)
    }
}
