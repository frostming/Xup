import Foundation

/// Loose version comparison that copes with semver, Homebrew "1.2.3,4567" style,
/// pre-release suffixes and leading "v".
enum VersionCompare {
    private enum Token: Equatable {
        case num(Int)
        case str(String)
    }

    private static func tokenize(_ s: String) -> [Token] {
        var v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        var tokens: [Token] = []
        var current = ""
        var currentIsNum: Bool? = nil
        func flush() {
            guard !current.isEmpty else { return }
            if currentIsNum == true, let n = Int(current) { tokens.append(.num(n)) } else { tokens.append(.str(current.lowercased())) }
            current = ""
            currentIsNum = nil
        }
        for ch in v {
            if ".,-_+: ".contains(ch) { flush(); continue }
            let isNum = ch.isNumber
            if let cur = currentIsNum, cur != isNum { flush() }
            currentIsNum = isNum
            current.append(ch)
        }
        flush()
        return tokens
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let ta = tokenize(a), tb = tokenize(b)
        let n = max(ta.count, tb.count)
        for i in 0..<n {
            let x = i < ta.count ? ta[i] : nil
            let y = i < tb.count ? tb[i] : nil
            switch (x, y) {
            case (nil, nil): return .orderedSame
            case (nil, .some(let t)):
                // "1.0" vs "1.0.1" -> less; "1.0" vs "1.0-beta" -> greater
                if case .num(let k) = t { return k == 0 ? .orderedSame : .orderedAscending }
                return .orderedDescending
            case (.some(let t), nil):
                if case .num(let k) = t { return k == 0 ? .orderedSame : .orderedDescending }
                return .orderedAscending
            case (.some(let p), .some(let q)):
                switch (p, q) {
                case (.num(let i), .num(let j)):
                    if i != j { return i < j ? .orderedAscending : .orderedDescending }
                case (.str(let s), .str(let t)):
                    if s != t { return s < t ? .orderedAscending : .orderedDescending }
                case (.num, .str): return .orderedDescending
                case (.str, .num): return .orderedAscending
                }
            }
        }
        return .orderedSame
    }

    static func isNewer(_ latest: String, than installed: String) -> Bool {
        compare(latest, installed) == .orderedDescending
    }

    /// Extracts the first thing that looks like a version from arbitrary text.
    static func extract(from text: String) -> String? {
        let pattern = #"\d+\.\d+(?:\.\d+)*(?:[-+][0-9A-Za-z.]+)?"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }
}
