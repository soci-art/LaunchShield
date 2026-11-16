import Foundation

struct AppTarget: Identifiable, Hashable {
    let bundleID: String
    let name: String
    var id: String { bundleID }

    static let baidu = AppTarget(bundleID: "com.baidu.netdisk", name: "百度网盘")
}

struct ContainerInfo: Identifiable, Hashable {
    let bundleID: String
    let path: String
    let name: String
    let isSystem: Bool
    var id: String { bundleID }
}

enum FileKind {
    case image
    case video
    case other

    static func of(_ path: String) -> FileKind {
        let ext = (path as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff"].contains(ext) {
            return .image
        }
        if ["mp4", "mov", "m4v", "avi", "webm", "mkv"].contains(ext) {
            return .video
        }
        return .other
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "video"
        case .other: return "doc"
        }
    }

    var label: String {
        switch self {
        case .image: return "图片"
        case .video: return "视频"
        case .other: return "文件"
        }
    }
}

struct FileItem: Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: UInt64
    let modified: Date
    let isImmutable: Bool

    var id: String { path }
    var kind: FileKind { FileKind.of(path) }
    var sizeText: String { Format.bytes(size) }
    var modifiedText: String { Format.date(modified) }
}

struct ContainerSnapshot: Codable {
    struct Entry: Codable {
        let size: UInt64
        let modified: Double
    }

    let bundleID: String
    let root: String
    let createdAt: Date
    let truncated: Bool
    let entries: [String: Entry]

    var fileCount: Int { entries.count }
    var totalBytes: UInt64 { entries.values.reduce(UInt64(0)) { $0 + $1.size } }
}

struct DiffCandidate: Identifiable, Hashable {
    let relativePath: String
    let size: UInt64
    let modified: Date
    let reason: String
    let isNew: Bool
    let delta: Int64

    var id: String { relativePath }
    var kind: FileKind { FileKind.of(relativePath) }
    var sizeText: String { Format.bytes(size) }
    var modifiedText: String { Format.date(modified) }
}

struct BackupRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let bundleID: String
    let appName: String
    let relativePath: String
    let localFileName: String
    let originalSize: UInt64
    let md5: String
    let createdAt: Date
    let source: String

    var sizeText: String { Format.bytes(originalSize) }
    var shortMD5: String { String(md5.prefix(8)) }
}

struct Recipe: Codable, Identifiable, Hashable {
    let id: UUID
    var bundleID: String
    var appName: String
    var relativePath: String
    var createdAt: Date
    var frozen: Bool
    var placeholder: Bool
    var lastCheckedAt: Date?
    var lastState: String
}

enum RecipeState: String {
    case normal
    case recurred
    case frozen
    case placeholder
    case missing
    case unknown

    var label: String {
        switch self {
        case .normal: return "正常（0 字节）"
        case .recurred: return "已复发"
        case .frozen: return "已冻结"
        case .placeholder: return "文件夹占位中"
        case .missing: return "文件不见了"
        case .unknown: return "还没检查"
        }
    }

    var isHealthy: Bool { self == .normal || self == .frozen || self == .placeholder }
}

struct RecipeStatus {
    let state: RecipeState
    let size: UInt64
    let detail: String
}

struct TargetFile: Identifiable, Hashable {
    let path: String
    let relativePath: String
    let group: String
    let note: String
    let size: UInt64
    let isSmallConfig: Bool

    var id: String { path }
    var kind: FileKind { FileKind.of(path) }
    var sizeText: String { Format.bytes(size) }
}

struct SplashResolution {
    let key: String
    let url: String
    let md5: String
    let path: String
    let exists: Bool
    let inferred: Bool
    let cachedFileCount: Int
}

enum Format {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
