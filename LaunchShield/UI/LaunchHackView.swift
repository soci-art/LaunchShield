import SwiftUI
import ImageIO
import UIKit

private struct LaunchHackScanTarget: Hashable {
    let bundleID: String
    let appName: String
    let rootPath: String
    let groupID: String?
}

/// 图片墙的一张图：扫描时按路径证据排队、解码出来的大图，自带
/// 完整路径身份；用户点确认后按原路径生成候选、同步回主页处理
/// （Grace 2026-11-21 定：机器筛、人认图）。
/// 落盘时不存预览图（体积大），重开页面按路径重新解码补回。
private struct LaunchHackGalleryItem: Identifiable, Equatable {
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

    var id: String { (groupID ?? "app") + "|" + relativePath }
    var folderPath: String { (relativePath as NSString).deletingLastPathComponent }
    var folderName: String {
        folderPath.isEmpty ? "（根目录）" : (folderPath as NSString).lastPathComponent
    }
}

extension LaunchHackGalleryItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case bundleID, groupID, appName, rootPath, relativePath
        case size, modifiedAt, pixelWidth, pixelHeight, pathScore
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
        previewData = nil
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

/// 只把图片解码出来量尺寸、做预览：LaunchHack 不再做任何画面
/// 比对（截图识别已按 Grace 2026-11-21 定案整条删除），解码只
/// 服务图片墙的展示与人工认图。
private enum LaunchHackImageProbe {
    struct Result {
        let pixelWidth: Int
        let pixelHeight: Int
        let previewData: Data?
        let detail: String
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
                          detail: "图片 · \(image.width) × \(image.height)")
        } catch {
            return nil
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
    @Published var status = "点「开始扫描」，把主页所选应用里的大图列出来，认出哪张是广告就标记哪张。"
    /// 本轮扫描所属的目标应用；图片墙落盘与恢复按它对号。
    private var sessionTargetID = ""
    var onLog: ((String, LogLevel) -> Void)?

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
        gallery = session.items
        confirmedGalleryIDs = Set(session.confirmedIDs)
        gallerySmallSkipped = session.smallSkipped
        status = session.status
        refillPreviews(channel: state.channel)
    }

    private func refillPreviews(channel: Channel) {
        let missing = gallery.filter { $0.previewData == nil }
        guard !missing.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for item in missing {
                guard let probe = LaunchHackImageProbe.probe(
                    path: item.rootPath + "/" + item.relativePath,
                    relativePath: item.relativePath, channel: channel) else { continue }
                let preview = probe.previewData
                DispatchQueue.main.async {
                    if let index = self.gallery.firstIndex(where: { $0.id == item.id }) {
                        self.gallery[index].previewData = preview
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

        DispatchQueue.global(qos: .userInitiated).async {
            var matches: [LaunchHackCandidate] = []
            var visited = 0
            var mediaCount = 0
            var dataCount = 0
            var sniffedMedia = 0
            var galleryPool: [LaunchHackGalleryItem] = []
            var smallSkipped = 0
            var failures: [String] = []

            // 阶段一：盘点。先把每个容器的文件清单走完，真进度条的
            // 分母就有了；盘点期间 scanProgress 保持 nil（页面显示盘点中）。
            var plan: [(target: LaunchHackScanTarget, files: [FileItem], work: [FileItem])] = []
            for target in targets {
                do {
                    let files = try channel.walkFiles(at: target.rootPath, limit: 16000,
                        skipDirNames: [".Trash", "Recently Deleted"],
                        skipDirSubstrings: PersonalMedia.personalDirectorySubstrings,
                        skipAccountDirs: true,
                        onVisit: { count in
                            visited += 1
                            if visited % 300 == 0 {
                                let snapshot = visited
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
            DispatchQueue.main.async {
                self.status = "盘点完成：共 \(totalWork) 个文件，正在逐个查看…"
            }

            // 阶段二：逐个处理，进度 = 已处理 ÷ 总数（真进度）。
            for entry in plan {
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
                        if galleryPool.count < 60, let preview = probe.previewData {
                            galleryPool.append(LaunchHackGalleryItem(
                                bundleID: target.bundleID, groupID: target.groupID,
                                appName: target.appName, rootPath: target.rootPath,
                                relativePath: relative, size: file.size,
                                modifiedAt: file.modified,
                                pixelWidth: probe.pixelWidth, pixelHeight: probe.pixelHeight,
                                pathScore: imageEntry.score, previewData: preview))
                        }
                    } else {
                        smallSkipped += 1
                    }
                }

                for file in dataWork {
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
            }

            let ordered = Array(matches.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.modifiedAt > $1.modifiedAt
            }.prefix(500))
            DispatchQueue.main.async {
                self.candidates = ordered
                self.gallery = galleryPool
                self.gallerySmallSkipped = smallSkipped
                self.visitedFiles = visited
                self.checkedMedia = mediaCount
                self.isRunning = false
                self.scanProgress = 1
                var statusText: String
                if !failures.isEmpty {
                    statusText = "扫描完成但有 \(failures.count) 个容器未能完整读取；图片墙可能不完整。"
                } else {
                    statusText = "扫描完成：图片墙列出 \(galleryPool.count) 张大图，点开认出广告图就标记它。"
                }
                self.status = statusText
                self.persistSession()
                self.onLog?(statusText, failures.isEmpty ? .success : .warning)
                self.onLog?("LaunchHack 机器数据（只上传不展示）：按证据命中 \(dataCount) 项", .info)
                if !galleryPool.isEmpty || smallSkipped > 0 {
                    self.onLog?("LaunchHack 图片墙收录 \(galleryPool.count) 张大图（短边 ≥300），另略过 \(smallSkipped) 张小图", .info)
                }
                if sniffedMedia > 0 {
                    self.onLog?("LaunchHack 有 \(sniffedMedia) 个文件靠内容认出是图片/视频（后缀认不出）", .info)
                }
                for failure in failures.prefix(8) { self.onLog?("LaunchHack 容器异常：\(failure)", .warning) }
            }
        }
    }

    /// 用户在图片墙里亲手认出一张广告图：按它自带的完整路径生成
    /// 标记，存进主页的标记收集（跨应用保留、同步素材清单），
    /// 处理在素材清单那边统一做。
    func confirmGalleryItem(_ item: LaunchHackGalleryItem, state: AppState) {
        guard !confirmedGalleryIDs.contains(item.id) else { return }
        confirmedGalleryIDs.insert(item.id)
        let candidate = LaunchHackCandidate(
            bundleID: item.bundleID, groupID: item.groupID, appName: item.appName,
            relativePath: item.relativePath, size: item.size, modifiedAt: item.modifiedAt,
            md5: nil,
            isFrozen: state.channel.isImmutable(item.rootPath + "/" + item.relativePath),
            score: 95,
            evidence: [
                "[用户确认] 在可疑图片墙中亲手认出这张是广告图",
                "[位置] 所在文件夹：\(item.folderPath.isEmpty ? "（根目录）" : item.folderPath)",
                "[只读分析] 图片 · \(item.pixelWidth) × \(item.pixelHeight)，原文件未被修改"
            ],
            mediaDetails: "图片 · \(item.pixelWidth) × \(item.pixelHeight)",
            previewData: item.previewData)
        state.addLaunchHackMark(candidate)
        persistSession()
        onLog?("LaunchHack 已标记：\(item.relativePath)", .success)
    }
}

struct LaunchHackView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = LaunchHackModel()
    @State private var selectedGalleryItem: LaunchHackGalleryItem?
    @State private var showUploadConfirm = false

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
            model.restoreSessionIfNeeded(state: state)
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
                    Text("只列图片 · 手动标记").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryText)
                }
            }
            Text("扫描主页所选应用，把大图列出来，你认出哪张是广告就标记哪张。标记会同步到主页素材清单，在那里统一处理；机器按证据查到的数据不展示，上传时默认一并带上。")
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
                Text("张").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryText)
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
                runScan()
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
            if model.isRunning {
                if let progress = model.scanProgress {
                    ProgressView(value: progress)
                    Text("已访问 \(model.visitedFiles) 个文件，已查看 \(model.checkedMedia) 张图片 · \(Int(progress * 100))%")
                        .font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                } else {
                    ProgressView()
                    Text("正在盘点文件…")
                        .font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                }
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
                        Text("可疑图片").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.primaryText)
                        Spacer()
                        Text("\(model.gallery.count) 张大图")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.secondaryText)
                    }
                    Text("按证据排出的大图，小图已略过。点开看大图，认出是广告就标记它，再回主页素材清单里处理。")
                        .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                        ForEach(model.gallery) { item in
                            Button { selectedGalleryItem = item } label: {
                                VStack(spacing: 4) {
                                    ZStack(alignment: .topTrailing) {
                                        if let data = item.previewData, let ui = UIImage(data: data) {
                                            Image(uiImage: ui).resizable().scaledToFill()
                                                .frame(maxWidth: .infinity).frame(height: 110).clipped()
                                        } else {
                                            Rectangle().fill(Color.secondaryText.opacity(0.15)).frame(height: 110)
                                        }
                                        if model.confirmedGalleryIDs.contains(item.id) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.green).padding(4)
                                        }
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    Text(item.folderName).font(.system(size: 10)).foregroundStyle(Color.secondaryText)
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

    private func galleryDetail(_ item: LaunchHackGalleryItem) -> some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if let data = item.previewData, let ui = UIImage(data: data) {
                        Image(uiImage: ui).resizable().scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    Text(item.relativePath)
                        .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    Text("所在文件夹：\(item.folderPath.isEmpty ? "（根目录）" : item.folderPath)")
                        .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    Text("尺寸 \(item.pixelWidth) × \(item.pixelHeight) · 大小 \(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))")
                        .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    if model.confirmedGalleryIDs.contains(item.id) {
                        Label("已标记，会同步到主页素材清单，在那里处理它。", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(.green)
                    } else {
                        Button {
                            model.confirmGalleryItem(item, state: state)
                            selectedGalleryItem = nil
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.circle")
                                Text("就是这张，标记为广告图")
                            }
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .background(Color.accentCyan, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
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
