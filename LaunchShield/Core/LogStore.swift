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
        DispatchQueue.main.async {
            self.lines.append(line)
            if self.lines.count > 600 {
                self.lines.removeFirst(self.lines.count - 600)
            }
        }
        persist(line)
    }

    func clear() {
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
            text += stored
        } else {
            text += lines.map { "[\(formatter.string(from: $0.date))] \($0.message)" }.joined(separator: "\n")
            text += "\n"
        }
        return text
    }

    // MARK: - Private

    private func persist(_ line: LogLine) {
        queue.async {
            let text = "[\(self.formatter.string(from: line.date))] [\(line.level.rawValue)] \(line.message)\n"
            guard let data = text.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: self.fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: self.fileURL)
            }
        }
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
