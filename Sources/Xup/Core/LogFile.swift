import Foundation

/// 把界面日志同步追加到 ~/Library/Logs/Xup/xup.log，便于事后排查（超过 5 MB 时轮转为 xup.log.1）。
final class LogFile: @unchecked Sendable {
    static let shared = LogFile()
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Xup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("xup.log")
    }()

    private let queue = DispatchQueue(label: "dev.fming.xup.logfile")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    func write(_ line: LogLine) {
        let text = "\(formatter.string(from: line.time)) [\(line.source)]\(line.isError ? " ERROR" : "") \(line.text)\n"
        queue.async {
            let url = Self.url
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 5_000_000 {
                let rotated = url.deletingPathExtension().appendingPathExtension("log.1")
                try? FileManager.default.removeItem(at: rotated)
                try? FileManager.default.moveItem(at: url, to: rotated)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(text.utf8))
                try? h.close()
            } else {
                try? Data(text.utf8).write(to: url)
            }
        }
    }
}
