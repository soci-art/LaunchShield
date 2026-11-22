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

/// LaunchHack 的只读识别结果。这里只承载证据，不包含任何治理动作。
struct LaunchHackCandidate: Codable, Identifiable, Hashable {
    let bundleID: String?
    let groupID: String?
    let appName: String
    let relativePath: String
    let size: UInt64
    let modifiedAt: Date
    let md5: String?
    let isFrozen: Bool
    let score: Int
    let evidence: [String]
    var mediaDetails: String? = nil
    var previewData: Data? = nil

    var id: String {
        let owner = bundleID ?? "unowned"
        let container = groupID.map { "group:" + $0 } ?? "app"
        return owner + "|" + container + "|" + relativePath
    }

    var priorityText: String {
        score >= 80 ? "优先核验" : (score >= 60 ? "建议核验" : "低优先级")
    }

    var kindText: String {
        switch FileKind.of(relativePath) {
        case .image: return "图片"
        case .video: return "视频"
        case .other: return "配置或其他文件"
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

    /// 给普通用户看的人话判断：这文件像不像广告。
    /// 顺序：先认广告（规则目录/关键词/开屏命名），再认图片视频，
    /// 再认应用自己的东西（模型、日志、数据库、系统缓存），剩下算未知。
    var verdict: FileVerdict {
        let lower = relativePath.lowercased()
        for group in RulesStore.groups {
            for directory in group.directories {
                let dir = directory.lowercased()
                if lower == dir || lower.hasPrefix(dir + "/") { return .ad }
            }
        }
        if RulesStore.keywords.contains(where: { lower.contains($0) }) { return .ad }
        if lower.contains("cold_launch") || lower.contains("splash") { return .ad }
        if PersonalMedia.isPersonal(bundleID: bundleID, relativePath: relativePath) { return .personal }
        let kind = FileKind.of(relativePath)
        // 应用自家的启动图/引导图（路径带 boot/launch/guide）：也是要处理
        // 的对象，标成疑似广告让用户能勾选替换。个人内容已在上面先排除。
        if (kind == .image || kind == .video), LaunchImageHint.matches(lower) { return .ad }
        if kind == .image || kind == .video { return .media }
        let ext = (relativePath as NSString).pathExtension.lowercased()
        if ["blm", "mnn", "dyld4", "dyld", "blog", "log", "db", "sqlite", "sqlite3",
            "plist", "bin", "dat", "tflite", "onnx", "model"].contains(ext) { return .appInternal }
        if lower.contains("modmgr") || lower.contains("com.apple.dyld")
            || lower.contains("splashboard") || lower.contains("/logs") { return .appInternal }
        return .unknown
    }
}

enum FileVerdict {
    case ad
    case media
    case personal
    case appInternal
    case unknown

    var label: String {
        switch self {
        case .ad: return "疑似广告"
        case .media: return "图片/视频"
        case .personal: return "个人内容"
        case .appInternal: return "应用文件"
        case .unknown: return "未知"
        }
    }
}

/// 数据库文件（广告 SDK 的统计库、缓存索引库这类）：会被应用常驻打开读写，
/// 清零多半撞「暂时不可用」，本身也不是广告素材。守护补扫跳过它们，
/// 免得每轮重试、刷一屏失败警告。
enum DatabaseFile {
    static func matches(relativePath: String) -> Bool {
        let name = (relativePath as NSString).lastPathComponent.lowercased()
        if name.hasSuffix(".db") || name.hasSuffix(".sqlite") || name.hasSuffix(".sqlite3") { return true }
        if name.hasSuffix("-shm") || name.hasSuffix("-wal") { return true }
        if name.hasSuffix(".db-journal") || name.hasSuffix(".sqlite-journal") { return true }
        return false
    }
}

/// 个人内容守卫：聊天类应用账号目录里的媒体是用户自己的聊天图、短视频、
/// 表情包，不是广告素材。命中就一律绕开——不标疑似、不自动判定、
/// 不进文件工具的默认列表。宁可漏抓广告，也不能误伤用户自己的东西。
enum PersonalMedia {
    /// 聊天媒体的典型目录名：短视频、自定义表情、表情包、聊天图、接收的文件等。
    /// 走访时按这份名单整棵剪枝——目录里的每个文件都会命中同名
    /// 路径段，剪枝只影响速度，不改变判定结果。
    static let personalDirectoryNames: Set<String> = ["shortvideo", "customface", "emoji", "emojis",
                                                      "sticker", "stickers", "messageimg",
                                                      "messageimgdecode", "filerecv", "ptt"]
    /// 路径里带这个子串的目录同理整棵剪枝。
    static let personalDirectorySubstrings = ["wechatprivate"]

    static func isPersonal(bundleID: String, relativePath: String) -> Bool {
        let lower = relativePath.lowercased()
        let segments = lower.split(separator: "/").map(String.init)
        // 账号目录：Documents/<纯数字账号> 或 Documents/<长哈希>，
        // QQ、微信的用户数据都放在这种目录里。
        if segments.count >= 2, segments[0] == "documents" {
            let account = segments[1]
            if account.count >= 5, account.allSatisfy({ $0.isNumber }) { return true }
            if account.count >= 24, account.allSatisfy({ $0.isHexDigit }) { return true }
        }
        if segments.contains(where: { personalDirectoryNames.contains($0) }) { return true }
        if lower.contains("wechatprivate") { return true }
        return false
    }
}

/// 广告候选的证据评分。评分用于排序和提示，不单独授权删除。
/// Level 区分明确排除项与不同置信度；实际处理仍由调用方和用户确认控制。
struct AdAssessment: Hashable {
    enum Level: Hashable {
        case excluded
        case high
        case medium
        case low

        var label: String {
            switch self {
            case .excluded: return "已排除"
            case .high: return "高置信度"
            case .medium: return "中置信度"
            case .low: return "低置信度"
            }
        }
    }

    let score: Int
    let reasons: [String]
    let level: Level
    let isAutoEligible: Bool
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

    /// 多维广告证据评分。评分只用于排序和提示，不直接授权删除。
    /// 个人内容、数据库、应用内部文件和系统资源始终先行排除。
    var adAssessment: AdAssessment {
        let lower = relativePath.lowercased()
        let components = lower.split(separator: "/").map(String.init)
        let ext = (relativePath as NSString).pathExtension.lowercased()
        let internalExtensions: Set<String> = [
            "db", "sqlite", "sqlite3", "plist", "json", "log", "mnn",
            "blm", "dyld", "dyld4", "tflite", "onnx", "model", "bin", "dat"
        ]
        let excludedPathMarkers = ["extracted_dirs", "monet_res", "splashboard"]
        let isExcluded = PersonalMedia.isPersonal(bundleID: bundleID, relativePath: relativePath)
            || DatabaseFile.matches(relativePath: relativePath)
            || internalExtensions.contains(ext)
            || components.contains(where: { excludedPathMarkers.contains($0) })
            || components.contains("logs")
        if isExcluded {
            return AdAssessment(score: 0, reasons: ["个人数据、数据库或应用内部资源，已排除"],
                                level: .excluded, isAutoEligible: false)
        }

        var score = 0
        var reasons: [String] = []
        var matchedKnownDirectory = false
        for group in RulesStore.groups {
            for directory in group.directories {
                let dir = directory.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if lower == dir || lower.hasPrefix(dir + "/") {
                    score += 70
                    reasons.append("命中广告 SDK 目录：\(group.group)")
                    matchedKnownDirectory = true
                    break
                }
            }
            if matchedKnownDirectory { break }
        }

        let strongMarkers = ["appopen", "openad", "splashad", "ad_splash",
                             "admaterial", "ad_material", "ad_cache", "interstitialad",
                             "rewardvideo", "nativead"]
        let matchedStrongMarker = components.contains { component in
            strongMarkers.contains { component.contains($0) }
        }
        if matchedStrongMarker {
            score += 55
            reasons.append("文件路径包含明确广告素材标记")
        }

        let keywords = RulesStore.keywords.map { $0.lowercased() }
        let matchedKeyword = components.contains { component in
            keywords.contains { keyword in !keyword.isEmpty && component.contains(keyword) }
        }
        if matchedKeyword {
            score += 25
            reasons.append("命中广告 SDK 关键词")
        }

        if kind != .other {
            score += 8
            reasons.append("文件类型为图片或视频")
        }
        if isNew {
            score += 12
            reasons.append("广告播放期间新生成")
        } else if delta > 0 {
            score += 6
            reasons.append("广告播放期间文件体积增加")
        }

        // boot/launch/guide/splash 等通用名称不足以证明是广告。
        let level: AdAssessment.Level
        if score >= 80 {
            level = .high
        } else if score >= 40 {
            level = .medium
        } else {
            level = .low
        }
        let autoEligible = kind != .other && (
            matchedKnownDirectory && score >= 80
                || matchedStrongMarker && matchedKeyword && score >= 80
        )
        return AdAssessment(score: min(score, 100), reasons: reasons,
                            level: level, isAutoEligible: autoEligible)
    }

    var likelyAd: Bool {
        adAssessment.level == .high || adAssessment.level == .medium
    }

    /// 仅高置信度且有明确广告目录证据的候选可进入批量清理组。
    /// UI 仍会要求用户二次确认，实际清理前还会执行备份。
    var autoVerdict: Bool {
        adAssessment.isAutoEligible
    }
}

/// 启动图/引导图路径特征：应用自己存在容器里的启动页、引导页，
/// 路径常带 boot / launch / guide 字样（如 bootLoginGuideCacheFolder）。
/// 系统的 Library/SplashBoard 是系统快照，不在此列（各处判定都先排除它）。
enum LaunchImageHint {
    static let words = ["boot", "launch", "guide"]
    static func matches(_ lowerPath: String) -> Bool {
        words.contains { lowerPath.contains($0) }
    }
}

struct BackupRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let bundleID: String
    /// 文件在共享组容器里时这里是组标识；应用自己容器里是 nil。
    let groupID: String?
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
    /// 文件在共享组容器里时这里是组标识；应用自己容器里是 nil。
    var groupID: String? = nil
}

/// 文件夹守护（清单第 52 条，2026-11-21 Grace 定）：处理任何条目
/// 都优先按文件夹冻结——清零一个文件时，把它所在的文件夹登记
/// 在这里，启动巡查会把这个文件夹里新冒出来的文件一并清掉，
/// 治「文件级清零后冷启动第三次必有新广告」。
struct DirectoryGuard: Codable, Identifiable, Hashable {
    let id: UUID
    var bundleID: String
    var appName: String
    /// 文件夹所在的容器：应用自己容器为 nil，共享组容器为组标识。
    var groupID: String? = nil
    /// 文件夹在容器内的相对路径。
    var relativePath: String
    var createdAt: Date
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
