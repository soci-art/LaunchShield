import SwiftUI
import ImageIO
import UIKit
import AVFoundation
import AVKit

private struct LaunchHackScanTarget: Hashable {
    let bundleID: String
    let appName: String
    let rootPath: String
    let groupID: String?
}

/// 素材墙里的一项：静态图、视频、动图，或成套出现的动画/网页
/// 包（第 69 条）。扫描时按路径证据排队、解码出预览，自带完整
/// 路径身份；用户点确认后按原路径生成候选、同步回主页处理
/// （Grace 2026-11-21 定：机器筛、人认图）。
/// 落盘时不存预览图（体积大），重开页面按路径重新解码补回。
private struct LaunchHackGalleryItem: Identifiable, Equatable {
    enum Kind: String {
        case image
        case video
        case animated
        case lottie
        case htmlBundle

        var badge: String {
            switch self {
            case .image: return ""
            case .video: return "视频"
            case .animated: return "动图"
            case .lottie: return "Lottie 动画"
            case .htmlBundle: return "网页包"
            }
        }
        var isBundle: Bool { self == .lottie || self == .htmlBundle }
    }

    let bundleID: String
    let groupID: String?
    let appName: String
    let rootPath: String
    let relativePath: String
    let size: UInt64
    let modifiedAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let pathScore: Int
    var previewData: Data?
    /// 第 69 条：素材种类，旧落盘没有这个字段、解码默认静态图。
    var kind: Kind = .image
    /// 视频时长（秒），只有视频有。
    var durationSeconds: Double? = nil
    /// 成套素材的文件数与内容摘要（名字＋大小），只有成套有。
    var bundleFileCount: Int = 0
    var bundleContents: [String] = []
    /// 动图的原始数据（不落盘，重开页面重新探补回），播放用。
    var animationData: Data? = nil
    /// 第 100 条：图片的差分哈希（dHash），探针解码时顺手算好，
    /// 用来把长得一样的图归组。跟落盘走，旧落盘没有就为空，
    /// 重开页面重新探测时自动补上。
    var imageHash: UInt64? = nil

    var id: String { (groupID ?? "app") + "|" + relativePath }

    /// 第 70 条排序键：像素面积（宽×高），成套素材没有尺寸记 0、排最后。
    var pixelArea: Int { pixelWidth * pixelHeight }

    static func sortedBySizeDescending(_ items: [LaunchHackGalleryItem]) -> [LaunchHackGalleryItem] {
        items.sorted {
            if $0.pixelArea != $1.pixelArea { return $0.pixelArea > $1.pixelArea }
            return $0.size > $1.size
        }
    }
    var folderPath: String { (relativePath as NSString).deletingLastPathComponent }
    var folderName: String {
        folderPath.isEmpty ? "（根目录）" : (folderPath as NSString).lastPathComponent
    }
    /// 格子下面的名字：成套素材显示文件夹自己的名字，其余显示
    /// 所在文件夹名。
    var tileCaption: String {
        kind.isBundle ? (relativePath as NSString).lastPathComponent : folderName
    }
    /// 标记按钮文案，按种类换词。
    var markButtonText: String {
        switch kind {
        case .image: return "就是这张，标记为广告图"
        case .video: return "就是这个，标记为广告视频"
        case .animated: return "就是这个，标记为广告动图"
        case .lottie, .htmlBundle: return "整个文件夹，标记为广告素材"
        }
    }
}

extension LaunchHackGalleryItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case bundleID, groupID, appName, rootPath, relativePath
        case size, modifiedAt, pixelWidth, pixelHeight, pathScore
        case kind, durationSeconds, bundleFileCount, bundleContents
        case imageHash
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try box.decode(String.self, forKey: .bundleID)
        groupID = try box.decodeIfPresent(String.self, forKey: .groupID)
        appName = try box.decode(String.self, forKey: .appName)
        rootPath = try box.decode(String.self, forKey: .rootPath)
        relativePath = try box.decode(String.self, forKey: .relativePath)
        size = try box.decode(UInt64.self, forKey: .size)
        modifiedAt = try box.decode(Date.self, forKey: .modifiedAt)
        pixelWidth = try box.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try box.decode(Int.self, forKey: .pixelHeight)
        pathScore = try box.decode(Int.self, forKey: .pathScore)
        // 第 69 条新增字段：旧落盘没有，一律给默认值（第 53 条
        // 教训：给持久化结构加字段必须走 decodeIfPresent）。
        kind = Kind(rawValue: try box.decodeIfPresent(String.self, forKey: .kind) ?? "") ?? .image
        durationSeconds = try box.decodeIfPresent(Double.self, forKey: .durationSeconds)
        bundleFileCount = try box.decodeIfPresent(Int.self, forKey: .bundleFileCount) ?? 0
        bundleContents = try box.decodeIfPresent([String].self, forKey: .bundleContents) ?? []
        // 第 100 条新增字段：旧落盘没有，给空（第 53 条规矩）。
        imageHash = try box.decodeIfPresent(UInt64.self, forKey: .imageHash)
        previewData = nil
        animationData = nil
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(bundleID, forKey: .bundleID)
        try box.encodeIfPresent(groupID, forKey: .groupID)
        try box.encode(appName, forKey: .appName)
        try box.encode(rootPath, forKey: .rootPath)
        try box.encode(relativePath, forKey: .relativePath)
        try box.encode(size, forKey: .size)
        try box.encode(modifiedAt, forKey: .modifiedAt)
        try box.encode(pixelWidth, forKey: .pixelWidth)
        try box.encode(pixelHeight, forKey: .pixelHeight)
        try box.encode(pathScore, forKey: .pathScore)
        try box.encode(kind.rawValue, forKey: .kind)
        try box.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try box.encode(bundleFileCount, forKey: .bundleFileCount)
        try box.encode(bundleContents, forKey: .bundleContents)
        try box.encodeIfPresent(imageHash, forKey: .imageHash)
    }
}

/// 图片墙与标记的落盘形状：关页面、重开还在（Grace 2026-11-21
/// 清单第 36 条）。只存当前目标应用这一轮的墙。
private struct LaunchHackGallerySession: Codable {
    let targetBundleID: String
    let items: [LaunchHackGalleryItem]
    let confirmedIDs: [String]
    let smallSkipped: Int
    let status: String
}

/// 第 100 条：差分哈希（dHash）——把图缩成 9×8 灰度，相邻像素
/// 逐个比大小，得 64 位「长相指纹」。同一张图改了尺寸、重新压过，
/// 指纹基本不变，用来把墙上重复出现的同图归成一组。不引第三方库。
/// 注意这跟已删除的截图比对不是一回事：这里只比墙上已有的图彼此
/// 像不像，不拿任何目标图去比对，也不产出任何识别结论。
private enum LaunchHackImageHash {
    static func dHash(of image: CGImage) -> UInt64? {
        let width = 9, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var hash: UInt64 = 0
        for row in 0..<height {
            for col in 0..<(width - 1) {
                let bit: UInt64 = pixels[row * width + col] > pixels[row * width + col + 1] ? 1 : 0
                hash = (hash << 1) | bit
            }
        }
        return hash
    }

    /// 两个指纹差了多少位（汉明距离）。
    static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    /// 近纯色图的指纹会退化（几乎全 0 或全 1），彼此距离假小；
    /// 这类图不参与归组，免得一堆纯色图被串成一组。
    static func isDegenerate(_ hash: UInt64) -> Bool {
        let ones = hash.nonzeroBitCount
        return ones <= 3 || ones >= 61
    }
}

/// 只把图片解码出来量尺寸、做预览：LaunchHack 不再做任何画面
/// 比对（截图识别已按 Grace 2026-11-21 定案整条删除），解码只
/// 服务图片墙的展示与人工认图。
private enum LaunchHackImageProbe {
    struct Result {
        let pixelWidth: Int
        let pixelHeight: Int
        let previewData: Data?
        let detail: String
        /// 第 69 条：帧数（动图 >1）与动图原始数据（播放用）。
        let frameCount: Int
        let animationData: Data?
        /// 第 100 条：长相指纹，在预览再压缩之前的那张图上算，
        /// 保证同一文件每次扫描算出来都一样。
        let imageHash: UInt64?
    }

    static func probe(path: String, relativePath: String, channel: Channel) -> Result? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchHackProbe-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            // 临时副本的后缀要用系统认得的：原文件靠内容认出来的
            // （如 .image），原后缀会让解码器认不出格式，按内容给。
            let originalExt = (relativePath as NSString).pathExtension.lowercased()
            let knownExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff"]
            let ext = knownExts.contains(originalExt) ? originalExt : "png"
            let localURL = folder.appendingPathComponent("asset.\(ext)")
            try channel.copyToLocal(path: path, destination: localURL.path)
            let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
            guard size > 0, size <= 40 * 1024 * 1024 else { return nil }
            guard let source = CGImageSourceCreateWithURL(localURL as CFURL, nil) else { return nil }
            let frameCount = CGImageSourceGetCount(source)
            // 动图把原始数据带回去放着播；太大的不带（只上墙第一帧）。
            let animationData = (frameCount > 1 && size <= 10 * 1024 * 1024)
                ? try? Data(contentsOf: localURL) : nil
            // 解码按方向标记摆正、限尺寸（手机照片常躺着存，靠标记
            // 摆正显示；墙上展示与量尺寸都要摆正后的）。
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 900
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                    ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            // 预览图：墙上当图、点开确认也用它。太大就缩一份小的。
            var preview = UIImage(cgImage: image).jpegData(compressionQuality: 0.65)
            if (preview?.count ?? 0) > 160 * 1024 {
                let scale = min(1, 480.0 / CGFloat(max(image.width, image.height)))
                let thumbSize = CGSize(width: CGFloat(image.width) * scale,
                                       height: CGFloat(image.height) * scale)
                let renderer = UIGraphicsImageRenderer(size: thumbSize)
                preview = renderer.jpegData(withCompressionQuality: 0.6) { _ in
                    UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: thumbSize))
                }
                if (preview?.count ?? 0) > 160 * 1024 { preview = nil }
            }
            return Result(pixelWidth: image.width, pixelHeight: image.height,
                          previewData: preview,
                          detail: "图片 · \(image.width) × \(image.height)",
                          frameCount: frameCount,
                          animationData: animationData,
                          imageHash: LaunchHackImageHash.dHash(of: image))
        } catch {
            return nil
        }
    }
}

/// 第 69 条：视频探测——拷到本地后读时长、画面尺寸，抽一帧当
/// 墙上的预览图。系统播放器认不出的格式（webm/mkv 等）探测会
/// 失败，那些视频只走机器数据线、不上墙。
private enum LaunchHackVideoProbe {
    struct Result {
        let pixelWidth: Int
        let pixelHeight: Int
        let durationSeconds: Double
        let previewData: Data?
        /// 第 100 条：抽出的那帧的长相指纹，与图片同款算法——
        /// 开屏视频的画面常与同活动的开屏图是同一张，能归一组。
        let imageHash: UInt64?
    }

    static func probe(path: String, relativePath: String, channel: Channel) -> Result? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchHackProbe-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let originalExt = (relativePath as NSString).pathExtension.lowercased()
            let knownExts: Set<String> = ["mp4", "mov", "m4v"]
            let ext = knownExts.contains(originalExt) ? originalExt : "mp4"
            let localURL = folder.appendingPathComponent("asset.\(ext)")
            try channel.copyToLocal(path: path, destination: localURL.path)
            let asset = AVURLAsset(url: localURL)
            let duration = CMTimeGetSeconds(asset.duration)
            guard duration.isFinite, duration > 0,
                  let track = asset.tracks(withMediaType: .video).first else { return nil }
            let natural = track.naturalSize.applying(track.preferredTransform)
            let width = Int(abs(natural.width))
            let height = Int(abs(natural.height))
            guard width > 0, height > 0 else { return nil }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 900, height: 900)
            let atSeconds = min(1.0, duration / 2)
            guard let cg = try? generator.copyCGImage(
                at: CMTime(seconds: atSeconds, preferredTimescale: 600), actualTime: nil) else { return nil }
            var preview = UIImage(cgImage: cg).jpegData(compressionQuality: 0.65)
            if (preview?.count ?? 0) > 160 * 1024 {
                let scale = min(1, 480.0 / CGFloat(max(cg.width, cg.height)))
                let thumbSize = CGSize(width: CGFloat(cg.width) * scale,
                                       height: CGFloat(cg.height) * scale)
                let renderer = UIGraphicsImageRenderer(size: thumbSize)
                preview = renderer.jpegData(withCompressionQuality: 0.6) { _ in
                    UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: thumbSize))
                }
                if (preview?.count ?? 0) > 160 * 1024 { preview = nil }
            }
            return Result(pixelWidth: width, pixelHeight: height,
                          durationSeconds: duration, previewData: preview,
                          imageHash: LaunchHackImageHash.dHash(of: cg))
        } catch {
            return nil
        }
    }
}

/// 第 69 条：动图播放——把 GIF/动图 WebP 的帧解出来拼成会动的
/// 图，交给 UIImageView 播。帧数和总时长都封顶，免得长动图吃内存。
private enum LaunchHackAnimated {
    static func animatedImage(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return UIImage(data: data) }
        var frames: [UIImage] = []
        var total: TimeInterval = 0
        for index in 0..<min(count, 90) {
            guard let cg = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let webp = props?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
                ?? (webp?[kCGImagePropertyWebPUnclampedDelayTime] as? Double)
                ?? (webp?[kCGImagePropertyWebPDelayTime] as? Double) ?? 0.1
            total += max(delay, 0.02)
            if total > 20 { break }
        }
        guard frames.count > 1 else { return UIImage(data: data) }
        return UIImage.animatedImage(with: frames, duration: max(total, 0.1))
    }
}

private struct AnimatedImageView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.image = LaunchHackAnimated.animatedImage(from: data)
        view.startAnimating()
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {}
}

/// 第 69 条：视频详情里的播放区——打开详情才把视频拷到本地播，
/// 关掉就删临时文件。拷不下来或格式不支持时给一句说明，标记
/// 照样能标。
private struct LaunchHackVideoPlayerView: View {
    let item: LaunchHackGalleryItem
    let channel: Channel
    @State private var player: AVPlayer?
    @State private var tempURL: URL?
    @State private var failed = false

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else if failed {
                Text("这个视频在本机播不了（格式不支持或文件读不到），可以照样标记它。")
                    .font(.system(size: 13)).foregroundStyle(Color.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            } else {
                ProgressView()
            }
        }
        .task {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("LaunchHackPlay-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let originalExt = (item.relativePath as NSString).pathExtension.lowercased()
                let knownExts: Set<String> = ["mp4", "mov", "m4v"]
                let ext = knownExts.contains(originalExt) ? originalExt : "mp4"
                let url = folder.appendingPathComponent("video.\(ext)")
                try channel.copyToLocal(path: item.rootPath + "/" + item.relativePath,
                                        destination: url.path)
                tempURL = url
                let p = AVPlayer(url: url)
                player = p
                p.play()
            } catch {
                failed = true
            }
        }
        .onDisappear {
            player?.pause()
            if let tempURL { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }
        }
    }
}

/// 按文件开头字节认图片/视频：SDWebImage 的 .image 缓存、无后缀的
/// 资源文件靠后缀认不出来，内容才是真的。只读前 16 个字节。
private enum LaunchHackMediaSniffer {
    static func sniff(path: String, channel: Channel) -> FileKind? {
        guard let data = try? channel.read(path, maxBytes: 16), data.count >= 4 else { return nil }
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .image }        // PNG
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return .image }              // JPEG
        if b.starts(with: [0x47, 0x49, 0x46, 0x38]) { return .image }        // GIF8
        if b.starts(with: [0x42, 0x4D]) { return .image }                    // BMP
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 {         // RIFF....WEBP
            return .image
        }
        if b.count >= 12, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {  // ....ftyp
            let brand = String(bytes: b[8..<12], encoding: .ascii) ?? ""
            if ["heic", "heix", "hevc", "mif1", "msf1", "avif", "avis"].contains(brand) { return .image }
            if ["isom", "iso2", "iso5", "mp41", "mp42", "avc1", "qt  ", "M4V ", "mmp4", "dash"].contains(brand) { return .video }
        }
        return nil
    }
}

/// 路径证据评分（旧版那套，按原样恢复）：规则目录、关键词、广告特征
/// 词逐项打分。两个用途：图片墙内部排序、机器那份数据出候选（只
/// 上传、不展示，Grace 2026-11-21 定）。
private enum LaunchHackAssessment {
    static func assess(relativePath: String) -> (score: Int, evidence: [String]) {
        let path = relativePath.lowercased()
        let components = path.split(separator: "/").map(String.init)
        let ext = (path as NSString).pathExtension
        let media = ["png", "jpg", "jpeg", "webp", "gif", "heic", "mp4", "mov", "m4v"].contains(ext)
        let config = ["plist", "json", "xml", "db", "sqlite", "sqlite3"].contains(ext)
        var score = 0
        var evidence: [String] = []

        for group in RulesStore.groups {
            for directory in group.directories {
                let marker = directory.lowercased()
                if path == marker || path.hasPrefix(marker + "/") {
                    score = max(score, 95)
                    evidence.append("[路径推测] 命中已知广告资源目录：\(group.group)")
                }
            }
        }

        if RulesStore.keywords.contains(where: { !$0.isEmpty && path.contains($0.lowercased()) }) {
            score = max(score, 75)
            evidence.append("[路径推测] 路径命中广告规则关键词")
        }

        let adTokens = [
            "splash", "cold_launch", "coldlaunch", "launch_ad", "startup_ad",
            "advertisement", "ad_cache", "advertising", "promotion", "campaign",
            "adsdk", "ad_material", "pangolin", "gdt", "beizi", "admob"
        ]
        if adTokens.contains(where: { token in components.contains(where: { $0.contains(token) }) }) {
            score = max(score, 65)
            evidence.append("[路径推测] 目录或文件名包含广告/启动资源特征")
        }

        if media && (path.contains("/caches/") || path.hasPrefix("caches/") || path.hasPrefix("tmp/")) {
            score = max(score, 42)
            evidence.append("[路径推测] 位于缓存目录的图片或视频，需人工认图")
        }

        if config && adTokens.contains(where: { path.contains($0) }) {
            score = max(score, 58)
            evidence.append("[路径推测] 疑似广告配置或索引文件")
        }

        if evidence.isEmpty {
            evidence.append("[待验证] 通用资源特征，尚无广告直接证据")
        }
        return (score, evidence)
    }
}

/// 扫描取消令牌（第 64 条）：界面在主线程置位，后台扫描在
/// 循环里读，NSLock 保证两边不打架。
private final class LaunchHackCancelToken {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

@MainActor
private final class LaunchHackModel: ObservableObject {
    /// 机器按证据查出的候选：只同步给主页作上传数据，不在本页展示。
    @Published var candidates: [LaunchHackCandidate] = []
    @Published var isRunning = false
    /// 真进度（已处理 ÷ 盘点总数）；盘点阶段为 nil，页面显示盘点中。
    @Published var scanProgress: Double? = nil
    @Published var visitedFiles = 0
    @Published var checkedMedia = 0
    @Published var totalContainers = 0
    @Published var gallery: [LaunchHackGalleryItem] = []
    @Published var confirmedGalleryIDs: Set<String> = []
    @Published var gallerySmallSkipped = 0
    @Published var status = "点「开始扫描」，把主页所选应用里的大图和动态素材列出来，认出哪个是广告就标记哪个。"
    /// 本轮扫描所属的目标应用；图片墙落盘与恢复按它对号。
    private var sessionTargetID = ""
    var onLog: ((String, LogLevel) -> Void)?
    /// 第 64 条：本轮扫描的取消令牌，点「取消扫描」置位。
    private var cancelToken: LaunchHackCancelToken?

    func cancelScan() {
        cancelToken?.cancel()
    }

    /// 目标应用变了（清单第 47 条）：扫描状态全部重置——状态
    /// 文案回初始、进度清掉、墙先清空，再按新目标恢复它自己
    /// 的图片墙（第 36 条落盘按应用对号）。
    func handleTargetChange(state: AppState) {
        let newID = state.targetChosen ? state.target.bundleID : ""
        // 目标没变、且图片墙落盘还在（没被「清除扫描」清掉）就不动；
        // 落盘被清了说明用户真清过，内存里的墙也要跟着重置。
        let sessionFileExists = FileManager.default.fileExists(atPath: gallerySessionURL.path)
        if newID == sessionTargetID && (gallery.isEmpty || sessionFileExists) { return }
        gallery = []
        confirmedGalleryIDs = []
        gallerySmallSkipped = 0
        scanProgress = nil
        visitedFiles = 0
        checkedMedia = 0
        totalContainers = 0
        isRunning = false
        status = "点「开始扫描」，把主页所选应用里的大图和动态素材列出来，认出哪个是广告就标记哪个。"
        sessionTargetID = ""
        restoreSessionIfNeeded(state: state)
    }

    func syncFromState(_ findings: [LaunchHackCandidate]) {
        if candidates != findings { candidates = findings }
    }

    // MARK: - 图片墙落盘（关页面重开还在）

    private var gallerySessionURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("LaunchShield", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("launchhack-gallery.json")
    }

    private func persistSession() {
        guard !sessionTargetID.isEmpty else { return }
        let session = LaunchHackGallerySession(targetBundleID: sessionTargetID,
                                               items: gallery,
                                               confirmedIDs: Array(confirmedGalleryIDs),
                                               smallSkipped: gallerySmallSkipped,
                                               status: status)
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? data.write(to: gallerySessionURL, options: [.atomic])
    }

    /// 进页面时把上次的墙恢复出来（目标应用对得上才恢复），预览图
    /// 落盘时没存，后台按路径逐张重新解码补回。
    func restoreSessionIfNeeded(state: AppState) {
        guard gallery.isEmpty, !isRunning else { return }
        guard state.targetChosen, !state.target.bundleID.isEmpty else { return }
        guard let data = try? Data(contentsOf: gallerySessionURL),
              let session = try? JSONDecoder().decode(LaunchHackGallerySession.self, from: data),
              session.targetBundleID.caseInsensitiveCompare(state.target.bundleID) == .orderedSame,
              !session.items.isEmpty else { return }
        sessionTargetID = session.targetBundleID
        gallery = LaunchHackGalleryItem.sortedBySizeDescending(session.items)
        confirmedGalleryIDs = Set(session.confirmedIDs)
        gallerySmallSkipped = session.smallSkipped
        status = session.status
        refillPreviews(channel: state.channel)
    }

    private func refillPreviews(channel: Channel) {
        // 成套素材没有预览图，天生就是空的，不用补；其余按种类
        // 各自重新探测（视频抽帧、动图连原始数据一起补回）。
        let missing = gallery.filter { !$0.kind.isBundle && $0.previewData == nil }
        guard !missing.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for item in missing {
                let full = item.rootPath + "/" + item.relativePath
                if item.kind == .video {
                    guard let probe = LaunchHackVideoProbe.probe(
                        path: full, relativePath: item.relativePath, channel: channel) else { continue }
                    let preview = probe.previewData
                    let hash = probe.imageHash
                    DispatchQueue.main.async {
                        if let index = self.gallery.firstIndex(where: { $0.id == item.id }) {
                            self.gallery[index].previewData = preview
                            // 第 100 条：旧落盘没存指纹的，补探针时顺手补上。
                            if self.gallery[index].imageHash == nil {
                                self.gallery[index].imageHash = hash
                            }
                        }
                    }
                } else {
                    guard let probe = LaunchHackImageProbe.probe(
                        path: full, relativePath: item.relativePath, channel: channel) else { continue }
                    let preview = probe.previewData
                    let animation = probe.animationData
                    let hash = probe.imageHash
                    DispatchQueue.main.async {
                        if let index = self.gallery.firstIndex(where: { $0.id == item.id }) {
                            self.gallery[index].previewData = preview
                            if self.gallery[index].kind == .animated {
                                self.gallery[index].animationData = animation
                            }
                            if self.gallery[index].imageHash == nil {
                                self.gallery[index].imageHash = hash
                            }
                        }
                    }
                }
            }
        }
    }

    func start(containers: [ContainerInfo], state: AppState) {
        guard !isRunning else { return }
        guard state.channel.isAvailable else {
            status = state.channel.unavailableReason
            onLog?(status, .warning)
            return
        }
        // 只扫主页选中的目标应用（Grace 2026-11-21 定）：它的数据容器
        // 加关联共享容器，不再全机扫。
        guard state.targetChosen, !state.target.bundleID.isEmpty else {
            status = "先在主页选择一个要检测的目标应用，再开始检测。"
            return
        }
        let targetID = state.target.bundleID
        guard !state.isWhitelisted(targetID) else {
            status = "当前目标应用已加入排除白名单，不会检测。"
            onLog?("LaunchHack 跳过：\(state.target.name) 在排除白名单中", .warning)
            return
        }
        var targets: [LaunchHackScanTarget] = []
        if let app = containers.first(where: { !$0.isGroup && $0.bundleID.caseInsensitiveCompare(targetID) == .orderedSame })
            ?? state.channel.container(for: targetID) {
            targets.append(LaunchHackScanTarget(bundleID: targetID, appName: state.target.name,
                                                rootPath: app.path, groupID: nil))
        }
        for group in state.associatedGroups(for: targetID) where !group.path.isEmpty {
            targets.append(LaunchHackScanTarget(bundleID: targetID,
                appName: state.target.name + "（共享容器）", rootPath: group.path, groupID: group.bundleID))
        }
        var seen = Set<String>()
        targets = targets.filter { seen.insert($0.rootPath).inserted }
        guard !targets.isEmpty else {
            status = "没有找到\(state.target.name)的容器。请确认它已安装并打开过一次。"
            onLog?("LaunchHack 无法检测：找不到 \(state.target.name) 的容器", .warning)
            return
        }

        isRunning = true
        scanProgress = nil
        candidates = []
        gallery = []
        confirmedGalleryIDs = []
        gallerySmallSkipped = 0
        visitedFiles = 0
        checkedMedia = 0
        totalContainers = targets.count
        sessionTargetID = targetID
        status = "正在扫描 \(state.target.name) 的 \(targets.count) 个容器…"
        onLog?("LaunchHack 开始扫描 \(state.target.name)：\(targets.count) 个容器（列图片墙＋机器数据只上传不展示）", .info)
        let channel = state.channel
        let token = LaunchHackCancelToken()
        cancelToken = token

        DispatchQueue.global(qos: .userInitiated).async {
            var matches: [LaunchHackCandidate] = []
            var visited = 0
            var lastPublishedVisited = 0
            var mediaCount = 0
            var dataCount = 0
            var sniffedMedia = 0
            var galleryPool: [LaunchHackGalleryItem] = []
            var dynamicPool: [LaunchHackGalleryItem] = []
            // 第 99 条：视频单独一摊，不再和动图/成套抢 dynamicPool
            // 的 30 个名额；视频自己也封顶 30 个（与原动态池同数，
            // 视频不再被挤掉，动图/成套的名额也不缩水）。
            var videoPool: [LaunchHackGalleryItem] = []
            var videoCount = 0
            var animatedCount = 0
            var bundleCount = 0
            var smallSkipped = 0
            var smallVideoSkipped = 0
            var failures: [String] = []
            var cancelled = false

            // 阶段一：盘点。先把每个容器的文件清单走完，真进度条的
            // 分母就有了；盘点期间 scanProgress 保持 nil（页面显示盘点中）。
            var plan: [(target: LaunchHackScanTarget, files: [FileItem], work: [FileItem])] = []
            for target in targets {
                if token.isCancelled { cancelled = true; break }
                do {
                    let files = try channel.walkFiles(at: target.rootPath, limit: 16000,
                        skipDirNames: [".Trash", "Recently Deleted"],
                        skipDirSubstrings: PersonalMedia.personalDirectorySubstrings,
                        skipAccountDirs: true,
                        onVisit: { count in
                            // 通道的 onVisit 给的是累计已走条数
                            // （文件＋目录），直接用它；每多走 100 条
                            // 刷新一次页面计数。第 54 条：旧写法自己
                            // +1、满 300 才刷新，通道回调稀疏时计数
                            // 一直是 0。
                            visited = count
                            if count - lastPublishedVisited >= 100 {
                                lastPublishedVisited = count
                                let snapshot = count
                                DispatchQueue.main.async { self.visitedFiles = snapshot }
                            }
                        })
                    if files.count >= 16000 {
                        failures.append("\(target.appName)：达到单容器 16,000 文件上限，结果可能不完整")
                    }
                    let work = files.filter { file in
                        !file.isDirectory && !file.isSymlink
                            && file.path.hasPrefix(target.rootPath + "/")
                            && !PersonalMedia.isPersonal(bundleID: target.bundleID,
                                relativePath: String(file.path.dropFirst(target.rootPath.count + 1)))
                    }
                    plan.append((target: target, files: files, work: work))
                } catch {
                    failures.append("\(target.appName)：\(error.localizedDescription)")
                }
            }
            let totalWork = plan.reduce(0) { $0 + $1.work.count }
            var processed = 0
            if !cancelled {
                DispatchQueue.main.async {
                    self.status = "盘点完成：共 \(totalWork) 个文件，正在逐个查看…"
                }
            }

            // 阶段二：逐个处理，进度 = 已处理 ÷ 总数（真进度）。
            for entry in plan {
                if token.isCancelled { cancelled = true; break }
                let target = entry.target
                let relativeOf: (FileItem) -> String = {
                    String($0.path.dropFirst(target.rootPath.count + 1))
                }

                // 配置文件先读一遍作内容证据（只读）：每容器最多
                // 160 个、总计 24 MB，单文件上限 512 KB（旧版口径）。
                // 这份证据只喂机器那份上传数据，不展示给用户。
                var configEvidence: [LaunchHackContentEvidence] = []
                var configBytesRead: UInt64 = 0
                for config in entry.files where !config.isDirectory && !config.isSymlink
                    && config.path.hasPrefix(target.rootPath + "/")
                    && LaunchHackContentAnalyzer.isReadableConfig(config.path, size: config.size) {
                    if configEvidence.count >= 160 { break }
                    if configBytesRead + config.size > 24 * 1024 * 1024 { continue }
                    let relative = String(config.path.dropFirst(target.rootPath.count + 1))
                    guard let data = try? channel.read(config.path, maxBytes: 512 * 1024) else { continue }
                    configBytesRead += UInt64(data.count)
                    guard let evidence = LaunchHackContentAnalyzer.analyze(
                        path: relative, relativePath: relative, data: data
                    ) else { continue }
                    configEvidence.append(evidence)
                }

                // 媒体判定：先看后缀，后缀认不出的再看文件内容
                // （SDWebImage 的 .image、无后缀缓存靠内容才认得出，
                // Grace 2026-11-21 定）。
                var kindOf: [String: FileKind] = [:]
                for file in entry.work {
                    let byExt = FileKind.of(relativeOf(file))
                    if byExt != .other {
                        kindOf[file.path] = byExt
                    } else if file.size > 0, file.size <= 40 * 1024 * 1024,
                              let byContent = LaunchHackMediaSniffer.sniff(path: file.path, channel: channel) {
                        kindOf[file.path] = byContent
                        sniffedMedia += 1
                    } else {
                        kindOf[file.path] = .other
                    }
                }

                // 图片排队：路径证据分高的、时间新的先解码，真广告
                // 先上墙（Grace 2026-11-21 定）；数据文件随后处理。
                let imageWork = entry.work
                    .filter { (kindOf[$0.path] ?? .other) == .image }
                    .map { (file: $0, score: LaunchHackAssessment.assess(relativePath: relativeOf($0)).score) }
                    .sorted { a, b in
                        if a.score != b.score { return a.score > b.score }
                        return a.file.modified > b.file.modified
                    }
                let dataWork = entry.work.filter {
                    let kind = kindOf[$0.path] ?? .other
                    return kind == .other || kind == .video
                }

                for imageEntry in imageWork {
                    if token.isCancelled { cancelled = true; break }
                    let file = imageEntry.file
                    processed += 1
                    if processed % 20 == 0 {
                        let snapshot = processed
                        DispatchQueue.main.async {
                            self.scanProgress = totalWork > 0 ? Double(snapshot) / Double(totalWork) : 1
                        }
                    }
                    let relative = relativeOf(file)
                    guard file.size > 0, file.size <= 40 * 1024 * 1024 else { continue }
                    mediaCount += 1
                    if mediaCount % 20 == 0 {
                        let snapshot = mediaCount
                        DispatchQueue.main.async { self.checkedMedia = snapshot }
                    }
                    guard let probe = LaunchHackImageProbe.probe(path: file.path,
                        relativePath: relative, channel: channel) else { continue }
                    // 图片墙：大图（短边 ≥300）按证据顺序收录，小图只
                    // 计数不上墙（Grace 2026-11-21 定：小图没必要显示）。
                    if min(probe.pixelWidth, probe.pixelHeight) >= 300 {
                        if probe.frameCount > 1 {
                            // 第 69 条：多帧的是动图，进动态素材那摊，
                            // 墙上点开能看它动。
                            if dynamicPool.count < 30, let preview = probe.previewData {
                                var item = LaunchHackGalleryItem(
                                    bundleID: target.bundleID, groupID: target.groupID,
                                    appName: target.appName, rootPath: target.rootPath,
                                    relativePath: relative, size: file.size,
                                    modifiedAt: file.modified,
                                    pixelWidth: probe.pixelWidth, pixelHeight: probe.pixelHeight,
                                    pathScore: imageEntry.score, previewData: preview)
                                item.kind = .animated
                                item.animationData = probe.animationData
                                item.imageHash = probe.imageHash
                                dynamicPool.append(item)
                                animatedCount += 1
                            }
                        } else if galleryPool.count < 60, let preview = probe.previewData {
                            var item = LaunchHackGalleryItem(
                                bundleID: target.bundleID, groupID: target.groupID,
                                appName: target.appName, rootPath: target.rootPath,
                                relativePath: relative, size: file.size,
                                modifiedAt: file.modified,
                                pixelWidth: probe.pixelWidth, pixelHeight: probe.pixelHeight,
                                pathScore: imageEntry.score, previewData: preview)
                            item.imageHash = probe.imageHash
                            galleryPool.append(item)
                        }
                    } else {
                        smallSkipped += 1
                    }
                }

                // 第 69 条：视频上墙——只收路径证据够的（缓存目录
                // 里的媒体起步 42 分），免得把应用自己的视频内容
                // 也堆上墙；顺序同样证据高的、时间新的在前。视频
                // 同时还留在下面的数据线里，机器数据口径不变。
                // 第 99 条补：视频进单独的 videoPool（自己 30 个
                // 名额），并照图片同口径加短边 ≥300 的门槛，小
                // 视频只计数不上墙。
                let videoWork = entry.work
                    .filter { (kindOf[$0.path] ?? .other) == .video }
                    .map { (file: $0, score: LaunchHackAssessment.assess(relativePath: relativeOf($0)).score) }
                    .filter { $0.score >= 42 }
                    .sorted { a, b in
                        if a.score != b.score { return a.score > b.score }
                        return a.file.modified > b.file.modified
                    }
                for videoEntry in videoWork {
                    if token.isCancelled { cancelled = true; break }
                    if videoPool.count >= 30 { break }
                    let file = videoEntry.file
                    // 进度计数不在这里加：视频文件在下面的数据线里
                    // 还会再处理一次，那边统一计数，免得进度超 100%。
                    let relative = relativeOf(file)
                    guard file.size > 0, file.size <= 256 * 1024 * 1024 else { continue }
                    mediaCount += 1
                    if mediaCount % 20 == 0 {
                        let snapshot = mediaCount
                        DispatchQueue.main.async { self.checkedMedia = snapshot }
                    }
                    guard let probe = LaunchHackVideoProbe.probe(path: file.path,
                        relativePath: relative, channel: channel) else { continue }
                    // 第 99 条：与图片同口径——探针回的天然尺寸短边
                    // 不到 300 的只计数不上墙（表情级小视频占名额
                    // 没用），略过数在收尾日志里报。
                    guard min(probe.pixelWidth, probe.pixelHeight) >= 300 else {
                        smallVideoSkipped += 1
                        continue
                    }
                    var item = LaunchHackGalleryItem(
                        bundleID: target.bundleID, groupID: target.groupID,
                        appName: target.appName, rootPath: target.rootPath,
                        relativePath: relative, size: file.size,
                        modifiedAt: file.modified,
                        pixelWidth: probe.pixelWidth, pixelHeight: probe.pixelHeight,
                        pathScore: videoEntry.score, previewData: probe.previewData)
                    item.kind = .video
                    item.durationSeconds = probe.durationSeconds
                    item.imageHash = probe.imageHash
                    videoPool.append(item)
                    videoCount += 1
                }

                for file in dataWork {
                    if token.isCancelled { cancelled = true; break }
                    processed += 1
                    if processed % 20 == 0 {
                        let snapshot = processed
                        DispatchQueue.main.async {
                            self.scanProgress = totalWork > 0 ? Double(snapshot) / Double(totalWork) : 1
                        }
                    }
                    let relative = relativeOf(file)
                    // 数据/配置文件走路径＋内容证据线，产出只进上传
                    // 数据，不展示给用户（Grace 2026-11-21 定）。
                    let assessment = LaunchHackAssessment.assess(relativePath: relative)
                    var score = assessment.score
                    var evidence = assessment.evidence
                    if LaunchHackContentAnalyzer.isReadableConfig(relative, size: file.size),
                       let parsed = configEvidence.first(where: { $0.sourcePath == relative }) {
                        if parsed.hasAdSignals {
                            score = max(score, 62)
                            evidence.append("[内容已读取] 配置内容包含广告/开屏字段或关键词")
                        }
                        if !parsed.urls.isEmpty {
                            score = max(score, 68)
                            evidence.append("[内容已读取] 配置中提取到 \(parsed.urls.count) 个 URL")
                            evidence.append(contentsOf: parsed.urls.prefix(3).map {
                                "[内容已读取] 配置 URL：\(LaunchHackContentAnalyzer.displayURL($0))"
                            })
                        }
                    }
                    let matchingConfigs = configEvidence.filter {
                        !LaunchHackContentAnalyzer.resourceMatchReasons(relative, evidence: $0).isEmpty
                    }
                    if !matchingConfigs.isEmpty {
                        score = max(score, 88)
                        evidence.append("[关联证据] 资源文件名与配置 URL 的文件名或 URL-MD5 精确对应")
                        for config in matchingConfigs.prefix(2) {
                            evidence.append("[关联配置] \(config.sourcePath)")
                            evidence.append(contentsOf: LaunchHackContentAnalyzer.resourceMatchReasons(relative, evidence: config)
                                .map { "[关联证据] \($0)" })
                            evidence.append(contentsOf: config.urls.prefix(2).map {
                                "[内容已读取] 关联 URL：\(LaunchHackContentAnalyzer.displayURL($0))"
                            })
                        }
                    }
                    guard score >= 40 else { continue }
                    let md5 = file.size <= 32 * 1024 * 1024 ? try? channel.md5(file.path) : nil
                    matches.append(LaunchHackCandidate(bundleID: target.bundleID,
                        groupID: target.groupID, appName: target.appName,
                        relativePath: relative, size: file.size, modifiedAt: file.modified,
                        md5: md5, isFrozen: channel.isImmutable(file.path),
                        score: min(score, 98), evidence: Array(Set(evidence)).sorted(),
                        mediaDetails: nil, previewData: nil))
                    dataCount += 1
                }

                // 第 69 条：成套素材上墙——Lottie 动画（json＋图片
                // 成套）和网页广告包（文件夹里有 html）按整个文件
                // 夹成组列出，用户认的是整套、标记也按整套走。
                if dynamicPool.count < 30 {
                    var byFolder: [String: [FileItem]] = [:]
                    for file in entry.work {
                        let relative = relativeOf(file)
                        let folder = (relative as NSString).deletingLastPathComponent
                        if !folder.isEmpty { byFolder[folder, default: []].append(file) }
                    }
                    var testedBundles = 0
                    for folder in byFolder.keys.sorted() {
                        if token.isCancelled { cancelled = true; break }
                        if dynamicPool.count >= 30 || testedBundles >= 24 { break }
                        guard let members = byFolder[folder] else { continue }
                        let folderLower = folder.lowercased()
                        let jsonFiles = members.filter {
                            (relativeOf($0) as NSString).pathExtension.lowercased() == "json"
                                && $0.size > 0 && $0.size <= 512 * 1024
                        }
                        let htmlFiles = members.filter {
                            ["html", "htm"].contains((relativeOf($0) as NSString).pathExtension.lowercased())
                        }
                        let hasImage = members.contains { (kindOf[$0.path] ?? .other) == .image }
                        var bundleKind: LaunchHackGalleryItem.Kind? = nil
                        if !jsonFiles.isEmpty && (folderLower.contains("lottie") || hasImage) {
                            testedBundles += 1
                            if folderLower.contains("lottie") {
                                bundleKind = .lottie
                            } else {
                                for json in jsonFiles.prefix(3) {
                                    guard let data = try? channel.read(json.path, maxBytes: 64 * 1024),
                                          let text = String(data: data, encoding: .utf8) else { continue }
                                    if text.contains("\"layers\"") && text.contains("\"assets\"")
                                        && text.contains("\"v\"") {
                                        bundleKind = .lottie
                                        break
                                    }
                                }
                            }
                        }
                        if bundleKind == nil && !htmlFiles.isEmpty {
                            let folderScore = LaunchHackAssessment.assess(relativePath: folder).score
                            let tokenHit = ["mraid", "omsdk", "splash", "advert", "ad_"]
                                .contains { folderLower.contains($0) }
                            if folderScore >= 42 || tokenHit { bundleKind = .htmlBundle }
                        }
                        guard let kind = bundleKind else { continue }
                        let totalSize = members.reduce(UInt64(0)) { $0 + $1.size }
                        let newest = members.map { $0.modified }.max() ?? Date()
                        let contents = members
                            .sorted { relativeOf($0) < relativeOf($1) }
                            .prefix(10)
                            .map { "\((relativeOf($0) as NSString).lastPathComponent)（\(ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .file))）" }
                        var item = LaunchHackGalleryItem(
                            bundleID: target.bundleID, groupID: target.groupID,
                            appName: target.appName, rootPath: target.rootPath,
                            relativePath: folder, size: totalSize,
                            modifiedAt: newest,
                            pixelWidth: 0, pixelHeight: 0,
                            pathScore: LaunchHackAssessment.assess(relativePath: folder).score,
                            previewData: nil)
                        item.kind = kind
                        item.bundleFileCount = members.count
                        item.bundleContents = Array(contents)
                        dynamicPool.append(item)
                        bundleCount += 1
                    }
                }
            }

            if cancelled {
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.scanProgress = nil
                    self.cancelToken = nil
                    self.status = "扫描已取消，需要时重新点「开始扫描」。"
                    self.onLog?("LaunchHack 扫描已取消", .notice)
                }
                return
            }

            let ordered = Array(matches.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.modifiedAt > $1.modifiedAt
            }.prefix(500))
            let dynamicTotal = dynamicPool.count + videoPool.count
            DispatchQueue.main.async {
                self.candidates = ordered
                self.gallery = LaunchHackGalleryItem.sortedBySizeDescending(galleryPool + dynamicPool + videoPool)
                self.gallerySmallSkipped = smallSkipped
                self.visitedFiles = visited
                self.checkedMedia = mediaCount
                self.isRunning = false
                self.cancelToken = nil
                self.scanProgress = 1
                var statusText: String
                if !failures.isEmpty {
                    statusText = "扫描完成但有 \(failures.count) 个容器未能完整读取；素材墙可能不完整。"
                } else if dynamicTotal > 0 {
                    statusText = "扫描完成：素材墙列出 \(galleryPool.count) 张大图、\(dynamicTotal) 项动态素材，点开认出广告就标记它。"
                } else {
                    statusText = "扫描完成：素材墙列出 \(galleryPool.count) 张大图，点开认出广告图就标记它。"
                }
                self.status = statusText
                self.persistSession()
                self.onLog?(statusText, failures.isEmpty ? .success : .warning)
                self.onLog?("LaunchHack 机器数据（只上传不展示）：按证据命中 \(dataCount) 项", .info)
                if !galleryPool.isEmpty || smallSkipped > 0 {
                    self.onLog?("LaunchHack 图片墙收录 \(galleryPool.count) 张大图（短边 ≥300），另略过 \(smallSkipped) 张小图", .info)
                }
                if dynamicTotal > 0 {
                    self.onLog?("LaunchHack 动态素材收录 \(dynamicTotal) 项（视频 \(videoCount)、动图 \(animatedCount)、成套 \(bundleCount)）", .info)
                }
                if videoCount > 0 || smallVideoSkipped > 0 {
                    self.onLog?("LaunchHack 视频墙收录 \(videoCount) 个视频（短边 ≥300），另略过 \(smallVideoSkipped) 个小视频", .info)
                }
                if sniffedMedia > 0 {
                    self.onLog?("LaunchHack 有 \(sniffedMedia) 个文件靠内容认出是图片/视频（后缀认不出）", .info)
                }
                for failure in failures.prefix(8) { self.onLog?("LaunchHack 容器异常：\(failure)", .warning) }
            }
        }
    }

    /// 第 100 条：把墙上长得一样的图归组——指纹距离 ≤5、宽高比
    /// 差 ≤5% 才算同图；逐项只跟每组的第一个成员（代表）比，防
    /// A 像 B、B 像 C、A 不像 C 也被链成一组。近纯色图的退化
    /// 指纹不参与。归组只影响显示和整组标记，绝不自动标记。
    var galleryClusters: [[LaunchHackGalleryItem]] {
        var groups: [[LaunchHackGalleryItem]] = []
        for item in gallery {
            guard let hash = item.imageHash, !LaunchHackImageHash.isDegenerate(hash),
                  item.pixelWidth > 0, item.pixelHeight > 0 else { continue }
            let ratio = Double(item.pixelWidth) / Double(item.pixelHeight)
            var placed = false
            for index in groups.indices {
                guard let rep = groups[index].first, let repHash = rep.imageHash,
                      rep.pixelWidth > 0, rep.pixelHeight > 0 else { continue }
                let repRatio = Double(rep.pixelWidth) / Double(rep.pixelHeight)
                guard abs(ratio - repRatio) / repRatio <= 0.05,
                      LaunchHackImageHash.distance(hash, repHash) <= 5 else { continue }
                groups[index].append(item)
                placed = true
                break
            }
            if !placed { groups.append([item]) }
        }
        return groups.filter { $0.count >= 2 }
    }

    /// 某一项所在同图组的总张数（含它自己）；不在组里回 0。
    func galleryClusterSize(of item: LaunchHackGalleryItem) -> Int {
        for group in galleryClusters where group.contains(where: { $0.id == item.id }) {
            return group.count
        }
        return 0
    }

    /// 格子角标文案：同图几张；不在组里就不显示。
    func galleryClusterBadge(of item: LaunchHackGalleryItem) -> String? {
        let size = galleryClusterSize(of: item)
        return size >= 2 ? "同图 \(size) 张" : nil
    }

    /// 某一项的同图组其他成员（不含它自己）；不在组里回空。
    func galleryClusterPeers(of item: LaunchHackGalleryItem) -> [LaunchHackGalleryItem] {
        for group in galleryClusters where group.contains(where: { $0.id == item.id }) {
            return group.filter { $0.id != item.id }
        }
        return []
    }

    /// 第 100 条：整组一起标记——必须是用户在详情页亲手点的动作，
    /// 对组内还没标记的逐个走现成的单项标记；已标记的自动跳过
    /// （单项标记自己有防重复）。取消仍逐项走单项取消。
    func confirmGalleryCluster(of item: LaunchHackGalleryItem, state: AppState) {
        confirmGalleryItem(item, state: state)
        for peer in galleryClusterPeers(of: item) {
            confirmGalleryItem(peer, state: state)
        }
    }

    /// 用户在素材墙里亲手认出一项广告素材：按它自带的完整路径
    /// 生成标记，存进主页的标记收集（跨应用保留、同步素材
    /// 清单），处理在素材清单那边统一做。成套素材的标记路径是
    /// 文件夹本身，同步时按整夹展开（第 69 条）。
    func confirmGalleryItem(_ item: LaunchHackGalleryItem, state: AppState) {
        guard !confirmedGalleryIDs.contains(item.id) else { return }
        confirmedGalleryIDs.insert(item.id)
        let confirmLine: String
        let detailLine: String
        let mediaDetails: String
        switch item.kind {
        case .image:
            confirmLine = "[用户确认] 在可疑图片墙中亲手认出这张是广告图"
            detailLine = "[只读分析] 图片 · \(item.pixelWidth) × \(item.pixelHeight)，原文件未被修改"
            mediaDetails = "图片 · \(item.pixelWidth) × \(item.pixelHeight)"
        case .video:
            confirmLine = "[用户确认] 在可疑素材墙中亲手认出这个视频是广告"
            let seconds = Int((item.durationSeconds ?? 0).rounded())
            detailLine = "[只读分析] 视频 · \(item.pixelWidth) × \(item.pixelHeight) · \(seconds) 秒，原文件未被修改"
            mediaDetails = "视频 · \(item.pixelWidth) × \(item.pixelHeight) · \(seconds) 秒"
        case .animated:
            confirmLine = "[用户确认] 在可疑素材墙中亲手认出这张动图是广告"
            detailLine = "[只读分析] 动图 · \(item.pixelWidth) × \(item.pixelHeight)，原文件未被修改"
            mediaDetails = "动图 · \(item.pixelWidth) × \(item.pixelHeight)"
        case .lottie, .htmlBundle:
            confirmLine = "[用户确认] 在可疑素材墙中亲手认出这一整套是广告素材（\(item.kind.badge)）"
            detailLine = "[只读分析] 整个文件夹共 \(item.bundleFileCount) 个文件，原文件未被修改"
            mediaDetails = "\(item.kind.badge) · 共 \(item.bundleFileCount) 个文件"
        }
        let locationLine = item.kind.isBundle
            ? "[位置] 文件夹：\(item.relativePath)"
            : "[位置] 所在文件夹：\(item.folderPath.isEmpty ? "（根目录）" : item.folderPath)"
        let candidate = LaunchHackCandidate(
            bundleID: item.bundleID, groupID: item.groupID, appName: item.appName,
            relativePath: item.relativePath, size: item.size, modifiedAt: item.modifiedAt,
            md5: nil,
            isFrozen: state.channel.isImmutable(item.rootPath + "/" + item.relativePath),
            score: 95,
            evidence: [confirmLine, locationLine, detailLine],
            mediaDetails: mediaDetails,
            previewData: item.previewData)
        state.addLaunchHackMark(candidate)
        persistSession()
        onLog?("LaunchHack 已标记：\(item.relativePath)", .success)
    }

    /// 第 82 条：取消标记。把确认状态撤掉、让 AppState 把
    /// 标记记录删掉（主页素材清单同步撤），详情页不关、
    /// 当场翻回未标记状态，还能重新标。
    func unconfirmGalleryItem(_ item: LaunchHackGalleryItem, state: AppState) {
        guard confirmedGalleryIDs.contains(item.id) else { return }
        confirmedGalleryIDs.remove(item.id)
        state.removeLaunchHackMark(bundleID: item.bundleID, groupID: item.groupID, relativePath: item.relativePath)
        persistSession()
        onLog?("LaunchHack 已取消标记：\(item.relativePath)", .info)
    }
}

struct LaunchHackView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = LaunchHackModel()
    @State private var selectedGalleryItem: LaunchHackGalleryItem?
    @State private var showUploadConfirm = false
    @State private var showSingleAppAlert = false

    /// 当前目标应用名下已标记的数量（顶部只显示这个数）。
    private var markedCount: Int {
        guard state.targetChosen else { return state.launchHackMarks.count }
        return state.launchHackMarks.filter {
            $0.bundleID?.caseInsensitiveCompare(state.target.bundleID) == .orderedSame
        }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    summaryPanel
                    scanPanel
                    gallerySection
                }
                .padding(16)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .onAppear {
            model.onLog = { message, level in state.log(message, level) }
            model.syncFromState(state.launchHackFindings)
            model.handleTargetChange(state: state)
        }
        .onChange(of: state.target.bundleID) { _, _ in
            model.handleTargetChange(state: state)
        }
        .alert("请选择单个应用", isPresented: $showSingleAppAlert) {
            Button("好", role: .cancel) { }
        } message: {
            Text("LaunchHack 只对单个应用检测。主页现在选了多个应用，先改成只选一个再来扫描。")
        }
        .onChange(of: model.candidates) { _, findings in
            state.syncLaunchHackFindings(findings)
        }
        .onChange(of: state.launchHackFindings) { _, findings in
            model.syncFromState(findings)
        }
        .sheet(item: $selectedGalleryItem) { item in
            galleryDetail(item)
        }
        .confirmationDialog("上传本次识别数据？", isPresented: $showUploadConfirm, titleVisibility: .visible) {
            Button("确认上传") {
                state.uploadAllRecognitionData()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text(state.launchHackUploadResultUncertain
                 ? "上次上传结果未确认，服务器可能已经收到数据。请先核对服务器记录，再决定是否重试。"
                 : "有哪份传哪份：你标记的、机器识别的和扫描识别数据都会传。仅上传文字信息（路径、文件指纹和脱敏证据），不上传图片、视频或其他原始文件。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.accentCyan)
                    .frame(width: 48, height: 48)
                    .background(Color.accentCyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text("LaunchHack").font(.system(size: 21, weight: .bold)).foregroundStyle(Color.primaryText)
                    Text("列图片和动态素材 · 手动标记").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryText)
                }
            }
            Text("扫描主页所选应用，把大图、视频、动图和成套的动画/网页包列出来，你认出哪个是广告就标记哪个。标记会同步到主页素材清单，在那里统一处理；机器按证据查到的数据不展示，上传时默认一并带上。")
                .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
        }
        .padding(.vertical, 3)
    }

    /// 顶部：已标记数量＋上传（Grace 2026-11-21 流程定稿）。
    private var summaryPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("已标记").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.primaryText)
                Spacer()
                Text("\(markedCount)").font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(Color.primaryText)
                Text("项").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryText)
            }
            Button {
                showUploadConfirm = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 16, weight: .semibold))
                    Text(state.isUploadingMergedRecognition ? "正在上传…" : "上传识别数据")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(Color.accentCyan)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color.accentCyan.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(state.isUploadingMergedRecognition || state.isUploadingLaunchHackFindings || state.isBusy)
            if !state.mergedUploadMessage.isEmpty {
                Text(state.mergedUploadMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(state.mergedUploadMessage.hasPrefix("已上传") ? Color.green : Color.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(15).panel()
    }

    private var scanPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if state.checkedIDs.count >= 2 {
                    showSingleAppAlert = true
                } else {
                    runScan()
                }
            } label: {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text(model.isRunning ? "正在扫描…" : "开始扫描")
                }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(Color.accentCyan, in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(model.isRunning)
            if state.checkedIDs.count >= 2 {
                Text("主页现在选了多个应用，LaunchHack 只检测单个应用，请先改成只选一个。")
                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            }
            if model.isRunning {
                if let progress = model.scanProgress {
                    ProgressView(value: progress)
                    Text("已访问 \(model.visitedFiles) 个文件，已查看 \(model.checkedMedia) 个素材 · \(Int(progress * 100))%")
                        .font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                } else {
                    ProgressView()
                    Text("正在盘点文件…已访问 \(model.visitedFiles) 个文件")
                        .font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                }
                Button {
                    model.cancelScan()
                } label: {
                    Text("取消扫描")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(Color.accentCyan, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            Text(model.status).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
        }
        .padding(15).panel()
    }

    private var gallerySection: some View {
        Group {
            if !model.gallery.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("可疑素材").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.primaryText)
                        Spacer()
                        Text("\(model.gallery.count) 项")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.secondaryText)
                    }
                    Text("按证据排出的大图和动态素材，小图已略过。点开看：视频能播、动图会动，成套的看整个文件夹。认出是广告就标记它，再回主页素材清单里处理。")
                        .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    // 第 62 条：固定三列、每格等大正方形；图片用
                    // overlay 塞进格子并裁切，绝不溢出压到邻格；
                    // 已标记的勾在格子内最上层，不会被图盖住。
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                        ForEach(model.gallery) { item in
                            Button { selectedGalleryItem = item } label: {
                                VStack(spacing: 4) {
                                    Color.clear
                                        .aspectRatio(1, contentMode: .fit)
                                        .overlay {
                                            if let data = item.previewData, let ui = UIImage(data: data) {
                                                Image(uiImage: ui).resizable().scaledToFill()
                                            } else if item.kind.isBundle {
                                                // 成套素材没有单张预览图：
                                                // 图标＋种类＋文件数。
                                                ZStack {
                                                    Rectangle().fill(Color.accentCyan.opacity(0.10))
                                                    VStack(spacing: 5) {
                                                        Image(systemName: item.kind == .lottie ? "play.square.stack" : "globe")
                                                            .font(.system(size: 22))
                                                            .foregroundStyle(Color.accentCyan)
                                                        Text(item.kind.badge)
                                                            .font(.system(size: 10, weight: .semibold))
                                                            .foregroundStyle(Color.primaryText)
                                                        Text("共 \(item.bundleFileCount) 个文件")
                                                            .font(.system(size: 9))
                                                            .foregroundStyle(Color.secondaryText)
                                                    }
                                                }
                                            } else {
                                                Rectangle().fill(Color.secondaryText.opacity(0.15))
                                            }
                                        }
                                        .overlay(alignment: .bottomLeading) {
                                            // 第 69 条：视频/动图在格子左下
                                            // 角标明种类，视频带时长。
                                            if item.kind == .video || item.kind == .animated {
                                                Text(kindBadgeText(item))
                                                    .font(.system(size: 9, weight: .semibold))
                                                    .foregroundStyle(.white)
                                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                                    .background(Color.black.opacity(0.55),
                                                                in: RoundedRectangle(cornerRadius: 5))
                                                    .padding(4)
                                            }
                                        }
                                        .overlay(alignment: .topTrailing) {
                                            if model.confirmedGalleryIDs.contains(item.id) {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.system(size: 17))
                                                    .foregroundStyle(.green)
                                                    .background(Circle().fill(.white).padding(2.5))
                                                    .padding(4)
                                            }
                                        }
                                        .overlay(alignment: .bottomTrailing) {
                                            // 第 100 条：同图归组角标（右下，
                                            // 与左下种类角标、右上已标记勾错开）。
                                            if let badge = model.galleryClusterBadge(of: item) {
                                                Text(badge)
                                                    .font(.system(size: 9, weight: .semibold))
                                                    .foregroundStyle(.white)
                                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                                    .background(Color.black.opacity(0.55),
                                                                in: RoundedRectangle(cornerRadius: 5))
                                                    .padding(4)
                                            }
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        // 第 74 条：太宽的图画面虽被裁住，
                                        // 点击区域却会溢出到左右邻格（从
                                        // 旁边格子能点到这张宽图）。把命
                                        // 中区域也锁死在这块圆角正方形里。
                                        .contentShape(RoundedRectangle(cornerRadius: 10))
                                    Text(item.tileCaption).font(.system(size: 10)).foregroundStyle(Color.secondaryText)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if model.gallerySmallSkipped > 0 {
                        Text("另有 \(model.gallerySmallSkipped) 张小图（短边不到 300）已略过。")
                            .font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                    }
                }
                .padding(15).panel()
            }
        }
    }

    /// 格子左下角的种类角标：视频带时长，动图就写「动图」。
    private func kindBadgeText(_ item: LaunchHackGalleryItem) -> String {
        switch item.kind {
        case .video:
            let total = Int((item.durationSeconds ?? 0).rounded())
            return "视频 \(total / 60):\(String(format: "%02d", total % 60))"
        case .animated:
            return "动图"
        default:
            return item.kind.badge
        }
    }

    private func galleryDetail(_ item: LaunchHackGalleryItem) -> some View {
        NavigationStack {
            // 第 63 条：整页不滚动——图片区占满剩余高度、图缩进
            // 框内，下面的路径信息和标记按钮一屏内直接可见。
            VStack(alignment: .leading, spacing: 12) {
                    ZStack {
                        switch item.kind {
                        case .video:
                            LaunchHackVideoPlayerView(item: item, channel: state.channel)
                        case .animated:
                            if let data = item.animationData {
                                AnimatedImageView(data: data)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else if let data = item.previewData, let ui = UIImage(data: data) {
                                Image(uiImage: ui).resizable().scaledToFit()
                            }
                        case .lottie, .htmlBundle:
                            // 成套素材没有单张图可看：列夹里都有
                            // 什么，用户对着名单认整套。
                            VStack(alignment: .leading, spacing: 6) {
                                Label(item.kind.badge, systemImage: item.kind == .lottie ? "play.square.stack" : "globe")
                                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.primaryText)
                                Text("整个文件夹共 \(item.bundleFileCount) 个文件：")
                                    .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                                ForEach(Array(item.bundleContents.prefix(8).enumerated()), id: \.offset) { _, line in
                                    Text(line).font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                                        .lineLimit(1)
                                }
                                if item.bundleFileCount > 8 {
                                    Text("还有 \(item.bundleFileCount - 8) 个文件没列出来。")
                                        .font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        case .image:
                            if let data = item.previewData, let ui = UIImage(data: data) {
                                Image(uiImage: ui).resizable().scaledToFit()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text(item.relativePath)
                        .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    if item.kind.isBundle {
                        Text("这是一个文件夹，标记后夹里的文件会一起进素材清单。")
                            .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                        Text("共 \(item.bundleFileCount) 个文件 · 总大小 \(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))")
                            .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    } else {
                        Text("所在文件夹：\(item.folderPath.isEmpty ? "（根目录）" : item.folderPath)")
                            .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                        if item.kind == .video {
                            let total = Int((item.durationSeconds ?? 0).rounded())
                            Text("尺寸 \(item.pixelWidth) × \(item.pixelHeight) · 时长 \(total / 60):\(String(format: "%02d", total % 60)) · 大小 \(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))")
                                .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                        } else {
                            Text("尺寸 \(item.pixelWidth) × \(item.pixelHeight) · 大小 \(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))")
                                .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                        }
                    }
                    // 第 100 条：同图组——还有几张长得一样的，列个
                    // 缩略条，点任意一张跳过去看它自己那页；「这一组
                    // 一起标记」是用户亲手点的动作，逐项走单项标记。
                    let clusterPeers = model.galleryClusterPeers(of: item)
                    if !clusterPeers.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("还有 \(clusterPeers.count) 张长得一样的，应该是同一张图在不同地方存了多份：")
                                .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(clusterPeers) { peer in
                                        Button { selectedGalleryItem = peer } label: {
                                            ZStack {
                                                if let data = peer.previewData, let ui = UIImage(data: data) {
                                                    Image(uiImage: ui).resizable().scaledToFill()
                                                } else {
                                                    Rectangle().fill(Color.secondaryText.opacity(0.15))
                                                }
                                            }
                                            .frame(width: 54, height: 54)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay(alignment: .topTrailing) {
                                                if model.confirmedGalleryIDs.contains(peer.id) {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .font(.system(size: 13))
                                                        .foregroundStyle(.green)
                                                        .background(Circle().fill(.white).padding(2))
                                                        .padding(2)
                                                }
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            if !model.confirmedGalleryIDs.contains(item.id)
                                || clusterPeers.contains(where: { !model.confirmedGalleryIDs.contains($0.id) }) {
                                Button {
                                    model.confirmGalleryCluster(of: item, state: state)
                                } label: {
                                    HStack {
                                        Image(systemName: "checkmark.circle")
                                        Text("这一组一起标记")
                                    }
                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentCyan)
                                    .frame(maxWidth: .infinity).frame(height: 42)
                                    .background(Color.panel, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentCyan.opacity(0.5), lineWidth: 1))
                                }
                            }
                        }
                    }
                    if model.confirmedGalleryIDs.contains(item.id) {
                        Label("已标记，会同步到主页素材清单，在那里处理它。", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(.green)
                        Button {
                            model.unconfirmGalleryItem(item, state: state)
                        } label: {
                            HStack {
                                Image(systemName: "xmark.circle")
                                Text("取消标记")
                            }
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.red)
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .background(Color.panel, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.red, lineWidth: 1.5))
                        }
                    } else {
                        Button {
                            model.confirmGalleryItem(item, state: state)
                            selectedGalleryItem = nil
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.circle")
                                Text(item.markButtonText)
                            }
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .background(Color.accentCyan, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
            }
            .padding(16)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.appBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { selectedGalleryItem = nil }
                }
            }
        }
    }

    private func runScan() {
        guard !model.isRunning else { return }
        if state.didLoadContainers {
            model.start(containers: state.containers, state: state)
        } else {
            state.refreshContainers {
                self.model.start(containers: self.state.containers, state: self.state)
            }
        }
    }
}
