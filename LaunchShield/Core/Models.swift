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
    var category: String = ""
    /// 共享组（App Group）容器：bundleID 字段里放的是组标识。
    var isGroup: Bool = false

    var id: String { bundleID }
    /// 商店分类里带 game 的就是游戏；分类拿不到时按不是游戏算，不误伤。
    var isGame: Bool { category.lowercased().contains("game") }
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

/// 大文件榜 / 文件名搜索找到的一个文件。
struct FoundFile: Identifiable, Hashable {
    let path: String
    let containerPath: String
    let relativePath: String
    let size: UInt64
    let bundleID: String
    let appName: String

    var id: String { path }
    var sizeText: String { Format.bytes(size) }
    var fileName: String { (relativePath as NSString).lastPathComponent }
}

struct DiffCandidate: Identifiable, Hashable {
    let relativePath: String
    let size: UInt64
    let modified: Date
    let reason: String
    let isNew: Bool
    let delta: Int64
    var appName: String = ""
    var bundleID: String = ""
    var containerRoot: String = ""

    var id: String { bundleID.isEmpty ? relativePath : bundleID + "|" + relativePath }
    var kind: FileKind { FileKind.of(relativePath) }
    var sizeText: String { Format.bytes(size) }
    var modifiedText: String { Format.date(modified) }

    /// Rough call on whether this file is ad material: it sits in a known ad
    /// SDK's territory, or it is a brand-new image/video.
    var likelyAd: Bool {
        let path = relativePath.lowercased()
        if RulesStore.keywords.contains(where: { path.contains($0) }) { return true }
        return isNew && kind != .other
    }
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
    var bundleID: String = ""
    var appName: String = ""

    var id: String { path }
    var kind: FileKind { FileKind.of(path) }
    var sizeText: String { Format.bytes(size) }
}

/// 一次扫描里某个应用的识别结果：认出了哪几家广告商、各多少个文件，
/// 以及指纹库没登记过的目录名。上传后用来攒指纹库。
struct AppRecognition {
    let bundleID: String
    let name: String
    let groups: [String: Int]
    let unknownDirs: [String]
}

/// 收集数据 v2：一个文件的指纹（路径、大小、类型，图片带宽高、视频带时长秒数）。
struct CollectedFile {
    let path: String
    let size: UInt64
    var width: Int?
    var height: Int?
    var duration: Double?
}

/// 收集数据 v2：一个小配置文件的结构（只记键名，不记内容）。
struct CollectedConfig {
    let path: String
    let size: UInt64
    let keys: [String]
}

/// 收集数据 v2：某个应用的深度数据（上传时现采）。
struct DeepAppData {
    let bundleID: String
    let name: String
    let dirs: [String]
    let files: [CollectedFile]
    let configs: [CollectedConfig]
}

/// 用户手动标记的广告文件（用户自己认定的，权重最高，单独成一类上传）。
struct ManualMark: Codable, Identifiable {
    var bundleID: String
    var appName: String
    var relativePath: String
    var size: UInt64
    var markedAt: Date
    var id: String { bundleID + "|" + relativePath }
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
