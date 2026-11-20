import Foundation

enum LogLevel: String, Codable {
    case info
    case notice
    case success
    case warning

    var label: String {
        switch self {
        case .info: return "信息"
        case .notice: return "提示"
        case .success: return "成功"
        case .warning: return "异常"
        }
    }
}

struct LogLine: Identifiable, Codable {
    let id: UUID
    let date: Date
    let message: String
    let level: LogLevel
}

/// The run log: newest 600 lines in memory, everything on disk, so an export
/// still includes what happened before the app was last closed.
final class LogStore: ObservableObject {
    @Published private(set) var lines: [LogLine] = []

    /// 待发布的日志行（只在 queue 上碰）：批量干活时日志逐行狂刷，
    /// 逐行发布会让界面几秒内被迫重画几百上千次——iOS 27.2 beta 2 上
    /// 这会把界面合成弄出重影（真机对照实验：清零必犯、扫描日志少就不犯）。
    /// 改成先攒着、每 0.3 秒合并发布一次；存盘仍逐行立刻写，记录不丢。
    private var pendingLines: [LogLine] = []
    private var flushScheduled = false

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.sociart.launchshield.log")
    private let formatter: DateFormatter

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = support.appendingPathComponent("LaunchShield", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("log.txt")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        self.formatter = formatter

        loadTail()
    }

    func add(_ message: String, level: LogLevel = .info) {
        let line = LogLine(id: UUID(), date: Date(), message: message, level: level)
        persist(line)
        queue.async {
            self.pendingLines.append(line)
            guard !self.flushScheduled else { return }
            self.flushScheduled = true
            self.queue.asyncAfter(deadline: .now() + 0.3) {
                let batch = self.pendingLines
                self.pendingLines.removeAll()
                self.flushScheduled = false
                guard !batch.isEmpty else { return }
                DispatchQueue.main.async {
                    self.lines.append(contentsOf: batch)
                    if self.lines.count > 600 {
                        self.lines.removeFirst(self.lines.count - 600)
                    }
                }
            }
        }
    }

    func clear() {
        queue.async {
            self.pendingLines.removeAll()
            self.lastPersistKey = nil
            self.pendingRepeats = 0
        }
        DispatchQueue.main.async { self.lines.removeAll() }
        queue.async {
            try? FileManager.default.removeItem(at: self.fileURL)
        }
    }

    /// Text for the share sheet: a header with the system and app versions,
    /// then every line on disk.
    func exportText(header: [String]) -> String {
        var text = header.joined(separator: "\n")
        text += "\n\n———— 运行日志 ————\n"
        if let stored = try? String(contentsOf: fileURL, encoding: .utf8), !stored.isEmpty {
            text += Self.collapseRepeats(stored)
        } else {
            text += lines.map { "[\(formatter.string(from: $0.date))] \($0.message)" }.joined(separator: "\n")
            text += "\n"
        }
        return text
    }

    // MARK: - Private

    /// 防重复刷屏（清单第 10 条，只在 queue 上碰）：同一条日志连着
    /// 重复出现时只落盘第一条，后面的攒成计数，等不同的日志来了
    /// 再补一行「重复了 N 次」。出过一台设备同一条权限错误刷了
    /// 上千行、把日志撑到 305 KB 的事，不能再让它发生。
    private var lastPersistKey: String?
    private var pendingRepeats = 0

    private func persist(_ line: LogLine) {
        queue.async {
            let key = "\(line.level.rawValue)|\(line.message)"
            if key == self.lastPersistKey {
                self.pendingRepeats += 1
                return
            }
            self.flushRepeatsLocked()
            self.lastPersistKey = key
            self.writeLineLocked(line)
        }
    }

    private func flushRepeatsLocked() {
        guard pendingRepeats > 0 else { return }
        let count = pendingRepeats
        pendingRepeats = 0
        writeLineLocked(LogLine(id: UUID(), date: Date(),
                                message: "（上一条日志重复了 \(count) 次，已合并）", level: .info))
    }

    private func writeLineLocked(_ line: LogLine) {
        let text = "[\(self.formatter.string(from: line.date))] [\(line.level.rawValue)] \(line.message)\n"
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: self.fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: self.fileURL)
        }
        self.trimIfNeeded()
    }

    /// 导出时再兜一层：老日志文件里已经刷屏的重复行也合并掉，
    /// 比对时去掉开头的 [时间] [级别]，只看正文。
    private static func collapseRepeats(_ stored: String) -> String {
        var out: [String] = []
        var lastKey: String?
        var run = 0
        func flush() {
            if run > 1 { out.append("（上一条日志重复了 \(run - 1) 次，已合并）") }
            run = 0
        }
        for raw in stored.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let parts = line.components(separatedBy: "] ")
            let key = parts.count >= 3 ? parts.dropFirst(2).joined(separator: "] ") : line
            if key == lastKey {
                run += 1
                continue
            }
            flush()
            out.append(line)
            lastKey = key
            run = 1
        }
        flush()
        return out.joined(separator: "\n") + "\n"
    }

    /// 存盘日志封顶：文件涨过 3 MB 就只留最后约 2 MB（从整行处切），
    /// 老的自动丢掉，免得涨过收集箱单份 5 MB 的上传上限。
    private func trimIfNeeded() {
        let maxBytes = 3_000_000
        let keepBytes = 2_000_000
        guard let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int,
              size > maxBytes,
              let data = try? Data(contentsOf: fileURL), data.count > keepBytes else { return }
        var tail = data.suffix(keepBytes)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")), newline + 1 < tail.count {
            tail = tail.suffix(from: newline + 1)
        }
        try? Data(tail).write(to: fileURL, options: .atomic)
    }

    private func loadTail() {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return }
        let recent = text.split(separator: "\n").suffix(300)
        var loaded: [LogLine] = []
        for raw in recent {
            let line = String(raw)
            guard line.hasPrefix("[") else { continue }
            let parts = line.components(separatedBy: "] ")
            guard parts.count >= 2 else { continue }
            let head = parts[0]
            let message = parts.dropFirst().joined(separator: "] ")
            let fields = head.replacingOccurrences(of: "[", with: "").components(separatedBy: " [")
            let dateText = fields.first ?? ""
            let levelText = fields.count > 1 ? fields[1] : "info"
            loaded.append(LogLine(id: UUID(),
                                  date: formatter.date(from: dateText) ?? Date(),
                                  message: message,
                                  level: LogLevel(rawValue: levelText) ?? .info))
        }
        lines = Array(loaded.suffix(600))
    }
}
