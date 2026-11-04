import Foundation

// MARK: - 错误与退出码

/// 退出码：0 成功 / 1 失败 / 2 参数错误。
enum ExitCode: Int32 {
    case ok = 0, failure = 1, usage = 2
}

struct CLIError: Error, CustomStringConvertible {
    let message: String
    let code: ExitCode
    init(_ message: String, code: ExitCode = .failure) {
        self.message = message
        self.code = code
    }
    var description: String { message }
}

func usageError(_ msg: String) -> CLIError { CLIError(msg, code: .usage) }

// MARK: - JSON 工具

enum JSON {
    static func parse(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func parse(_ text: String) throws -> Any {
        try parse(Data(text.utf8))
    }

    /// 把命令行上的值解析为 JSON；不是合法 JSON 时按字符串处理（方便 `config set tracked.uv.0 nox`）。
    static func parseLoose(_ text: String) -> Any {
        if let v = try? parse(text) { return v }
        return text
    }

    static func pretty(_ obj: Any) -> String {
        var opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        if obj is NSNull { return "null" }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: opts), let s = String(data: data, encoding: .utf8) {
            return s
        }
        opts.remove(.prettyPrinted)
        return "\(obj)"
    }

    static func compact(_ obj: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "\(obj)"
    }

    /// 标量的人类可读形式（字符串不带引号）。
    static func scalar(_ v: Any) -> String {
        if let s = v as? String { return s }
        if v is NSNull { return "null" }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        return compact(v)
    }

    static func isBool(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    // MARK: 路径读写（a.b.c，数组用下标 apps.0.path）

    static func splitPath(_ path: String) -> [String] {
        path.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
    }

    static func get(_ obj: Any, path: String) -> Any? {
        var cur: Any = obj
        for comp in splitPath(path) {
            if let d = cur as? [String: Any] {
                guard let next = d[comp] else { return nil }
                cur = next
            } else if let a = cur as? [Any], let i = Int(comp), i >= 0, i < a.count {
                cur = a[i]
            } else {
                return nil
            }
        }
        return cur
    }

    /// 返回写入后的新对象；中间缺失的对象会被创建；数组下标等于 count 时追加。
    static func set(_ obj: Any, path: String, value: Any) throws -> Any {
        try setComponents(obj, ArraySlice(splitPath(path)), value: value, trail: "")
    }

    private static func setComponents(_ obj: Any, _ comps: ArraySlice<String>, value: Any, trail: String) throws -> Any {
        guard let key = comps.first else { return value }
        let rest = comps.dropFirst()
        let here = trail.isEmpty ? key : "\(trail).\(key)"
        if var a = obj as? [Any] {
            guard let i = Int(key) else { throw CLIError("\(trail) 是数组，下标必须是数字：\(key)", code: .usage) }
            if i >= 0 && i < a.count {
                a[i] = try setComponents(a[i], rest, value: value, trail: here)
            } else if i == a.count {
                a.append(try setComponents([String: Any](), rest, value: value, trail: here))
            } else {
                throw CLIError("下标越界：\(here)（长度 \(a.count)）", code: .usage)
            }
            return a
        }
        var d = (obj as? [String: Any]) ?? [:]
        if !(obj is [String: Any]) && !(obj is NSNull) && comps.count >= 1 && !(trail.isEmpty) {
            // 把标量替换成对象
            d = [:]
        }
        d[key] = try setComponents(d[key] ?? NSNull(), rest, value: value, trail: here)
        return d
    }

    static func delete(_ obj: Any, path: String) -> Any {
        var comps = splitPath(path)
        guard let last = comps.popLast() else { return obj }
        func rec(_ o: Any, _ cs: ArraySlice<String>) -> Any {
            guard let k = cs.first else {
                if var d = o as? [String: Any] { d[last] = nil; return d }
                if var a = o as? [Any], let i = Int(last), i >= 0, i < a.count { a.remove(at: i); return a }
                return o
            }
            if var d = o as? [String: Any], let child = d[k] { d[k] = rec(child, cs.dropFirst()); return d }
            if var a = o as? [Any], let i = Int(k), i >= 0, i < a.count { a[i] = rec(a[i], cs.dropFirst()); return a }
            return o
        }
        return rec(obj, ArraySlice(comps))
    }
}

// MARK: - 迷你 JSON Schema 校验（与 App 内 ConfigSchemaValidator 同一子集）

struct SchemaValidator {
    let schema: [String: Any]

    init?(data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        schema = obj
    }

    struct Report {
        var errors: [String] = []
        var warnings: [String] = []
    }

    /// `strictUnknown` 为 true 时未知字段算错误（CLI 写入前用），否则算警告。
    func validate(_ value: Any, strictUnknown: Bool = true) -> Report {
        var r = Report()
        walk(value, schema, path: "", strict: strictUnknown, report: &r)
        return r
    }

    private func resolve(_ s: [String: Any]) -> [String: Any] {
        guard let ref = s["$ref"] as? String, ref.hasPrefix("#/") else { return s }
        var cur: Any = schema
        for comp in ref.dropFirst(2).split(separator: "/") {
            guard let d = cur as? [String: Any], let next = d[String(comp)] else { return s }
            cur = next
        }
        return cur as? [String: Any] ?? s
    }

    static func typeName(_ v: Any) -> String {
        if v is NSNull { return "null" }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return "boolean" }
            return n.doubleValue == n.doubleValue.rounded() && !n.stringValue.contains(".") ? "integer" : "number"
        }
        if v is String { return "string" }
        if v is [Any] { return "array" }
        if v is [String: Any] { return "object" }
        return "unknown"
    }

    private func walk(_ value: Any, _ raw: [String: Any], path: String, strict: Bool, report: inout Report) {
        let s = resolve(raw)
        let here = path.isEmpty ? "(root)" : path
        let actual = Self.typeName(value)
        if let t = s["type"] {
            let wants = (t as? [String]) ?? [(t as? String) ?? ""]
            if !wants.contains(where: { $0 == actual || ($0 == "number" && actual == "integer") }) {
                report.errors.append("\(here) 应为 \(wants.joined(separator: "|"))，实际为 \(actual)")
                return
            }
        }
        if let c = s["const"], !Self.equal(value, c) {
            report.errors.append("\(here) 必须等于 \(JSON.compact(c))")
        }
        if let e = s["enum"] as? [Any], !e.contains(where: { Self.equal(value, $0) }) {
            report.errors.append("\(here) 必须是 \(e.map(JSON.compact).joined(separator: " / ")) 之一")
        }
        if let options = s["oneOf"] as? [[String: Any]] {
            var best: Report?
            var matched = false
            for opt in options {
                var sub = Report()
                walk(value, opt, path: path, strict: strict, report: &sub)
                if sub.errors.isEmpty {
                    report.warnings.append(contentsOf: sub.warnings)
                    matched = true
                    break
                }
                if best == nil || sub.errors.count < best!.errors.count { best = sub }
            }
            if !matched, let best { report.errors.append(contentsOf: best.errors) }
        }
        if let n = value as? NSNumber, !JSON.isBool(n), let min = (s["minimum"] as? NSNumber)?.doubleValue, n.doubleValue < min {
            report.errors.append("\(here) 不能小于 \(Int(min))")
        }
        if let n = value as? NSNumber, !JSON.isBool(n), let max = (s["maximum"] as? NSNumber)?.doubleValue, n.doubleValue > max {
            report.errors.append("\(here) 不能大于 \(Int(max))")
        }
        if let str = value as? String, let pattern = s["pattern"] as? String,
           let re = try? NSRegularExpression(pattern: pattern),
           re.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)) == nil {
            report.errors.append("\(here) 不符合格式 \(pattern)")
        }
        if let dict = value as? [String: Any] {
            let props = s["properties"] as? [String: Any] ?? [:]
            for req in s["required"] as? [String] ?? [] where dict[req] == nil {
                report.errors.append("\(here) 缺少必填字段 \(req)")
            }
            for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
                let child = path.isEmpty ? k : "\(path).\(k)"
                if let ps = props[k] as? [String: Any] {
                    walk(v, ps, path: child, strict: strict, report: &report)
                } else if let ap = s["additionalProperties"] as? [String: Any] {
                    walk(v, ap, path: child, strict: strict, report: &report)
                } else if let ap = s["additionalProperties"] as? Bool, ap == false {
                    let known = props.keys.sorted().joined(separator: ", ")
                    let msg = "未知字段 \(child)" + (known.isEmpty ? "" : "（可用：\(known)）")
                    if strict { report.errors.append(msg) } else { report.warnings.append(msg) }
                }
            }
        }
        if let arr = value as? [Any], let items = s["items"] as? [String: Any] {
            for (i, v) in arr.enumerated() { walk(v, items, path: "\(path)[\(i)]", strict: strict, report: &report) }
        }
    }

    private static func equal(_ a: Any, _ b: Any) -> Bool {
        if let x = a as? NSNumber, let y = b as? NSNumber { return x == y }
        if let x = a as? String, let y = b as? String { return x == y }
        if a is NSNull, b is NSNull { return true }
        return false
    }
}
