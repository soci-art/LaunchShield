import SwiftUI
import PhotosUI
import Vision
import AVFoundation
import ImageIO
import UIKit

private struct LaunchHackScanTarget: Hashable {
    let bundleID: String
    let appName: String
    let rootPath: String
    let groupID: String?
}

private struct LaunchHackVisualMatch {
    let distance: Float
    let textOverlap: Int
    let previewData: Data?
    let mediaDetails: String
    let evidence: [String]

    var score: Int {
        let visual = max(0, min(100, Int((1.0 - Double(distance) / 0.30) * 100)))
        let textBonus = min(12, textOverlap * 4)
        return min(99, visual + textBonus)
    }

    var isStrong: Bool {
        distance <= 0.10 || (distance <= 0.17 && textOverlap >= 2)
    }
}

/// Screenshot-led matching. A file is never promoted by its name or folder alone:
/// its decoded pixels must be compared with the user-provided ad screenshot.
private enum LaunchHackVisualMatcher {
    static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 900,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary)
    }

    static func featurePrint(_ image: CGImage) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFit
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let result = request.results?.first as? VNFeaturePrintObservation else {
            throw ChannelFailure("无法提取截图视觉特征")
        }
        return result
    }

    static func recognizedText(_ image: CGImage) -> Set<String> {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let raw = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let tokens = raw.joined(separator: " ").lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "一-龥")).inverted)
        return Set(tokens.filter { $0.count >= 2 })
    }

    static func compare(reference: VNFeaturePrintObservation,
                        referenceText: Set<String>,
                        candidate: CGImage) -> (Float, Int)? {
        guard let candidateFeature = try? featurePrint(candidate) else { return nil }
        var distance: Float = 1
        guard (try? reference.computeDistance(&distance, to: candidateFeature)) != nil else { return nil }
        let candidateText = recognizedText(candidate)
        let overlap = referenceText.intersection(candidateText).count
        return (distance, overlap)
    }

    static func inspect(path: String, relativePath: String, channel: Channel,
                        reference: VNFeaturePrintObservation,
                        referenceText: Set<String>,
                        kind: FileKind) -> LaunchHackVisualMatch? {
        guard kind == .image || kind == .video else { return nil }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchHackVisual-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            // 临时副本的后缀要用系统认得的：原文件靠内容认出来的
            // （如 .image），原后缀会让解码器认不出格式，按内容给。
            let originalExt = (relativePath as NSString).pathExtension.lowercased()
            let knownExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif",
                                          "bmp", "tiff", "mp4", "mov", "m4v", "avi", "webm", "mkv"]
            let ext = knownExts.contains(originalExt) ? originalExt : (kind == .image ? "png" : "mp4")
            let localURL = folder.appendingPathComponent("asset.\(ext)")
            try channel.copyToLocal(path: path, destination: localURL.path)
            let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
            guard size > 0, size <= 40 * 1024 * 1024 else { return nil }

            var frames: [CGImage] = []
            var detail = ""
            if kind == .image {
                guard let source = CGImageSourceCreateWithURL(localURL as CFURL, nil) else { return nil }
                // 解码必须和截图那头一致：按方向标记摆正、限尺寸。
                // 手机拍的照片像素常是躺着存的、靠方向标记摆正显示；
                // 之前直接拿原始像素比对，等于躺着的图和站着的图比，
                // 距离必然爆掉（阳性对照实验 2026-11-21 坐实）。
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 900
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                        ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
                frames = [image]
                detail = "图片 · \(image.width) × \(image.height)"
            } else {
                let asset = AVURLAsset(url: localURL)
                let duration = asset.duration.seconds
                guard duration.isFinite, duration > 0 else { return nil }
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 900, height: 900)
                let fractions: [Double] = [0.08, 0.30, 0.55, 0.80, 0.95]
                for fraction in fractions {
                    let time = CMTime(seconds: max(0, min(duration, duration * fraction)), preferredTimescale: 600)
                    if let frame = try? generator.copyCGImage(at: time, actualTime: nil) { frames.append(frame) }
                }
                guard !frames.isEmpty else { return nil }
                detail = "视频 · \(String(format: "%.1f", duration)) 秒 · 比较 \(frames.count) 个关键帧"
            }

            let comparisons = frames.compactMap { compare(reference: reference, referenceText: referenceText, candidate: $0) }
            guard let best = comparisons.min(by: { $0.0 < $1.0 }) else { return nil }
            let preview = UIImage(cgImage: frames[0]).jpegData(compressionQuality: 0.65)
            let boundedPreview = (preview?.count ?? 0) <= 160 * 1024 ? preview : nil
            var evidence = [
                "[截图视觉匹配] 最佳视觉距离：\(String(format: "%.4f", best.0))",
                "[截图视觉匹配] OCR 文本交集：\(best.1) 个词",
                "[只读分析] \(detail)，原文件未被修改"
            ]
            if best.0 <= 0.10 { evidence.append("[高置信度] 视觉特征高度接近用户提供的广告截图") }
            if best.1 >= 2 { evidence.append("[辅助证据] 截图与素材包含相同文字") }
            return LaunchHackVisualMatch(distance: best.0, textOverlap: best.1,
                                          previewData: boundedPreview, mediaDetails: detail,
                                          evidence: evidence)
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
/// 词逐项打分，供数据/配置文件这条线出候选。
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
            evidence.append("[路径推测] 位于缓存目录的图片或视频，需与广告画面比对")
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
    @Published var candidates: [LaunchHackCandidate] = []
    @Published var isRunning = false
    /// 真进度（已处理 ÷ 盘点总数）；盘点阶段为 nil，页面显示盘点中。
    @Published var scanProgress: Double? = nil
    @Published var visitedFiles = 0
    @Published var checkedMedia = 0
    @Published var totalContainers = 0
    @Published var status = "导入广告截图后，LaunchHack 会检索主页所选应用的容器：图片、视频按截图比对，数据文件按路径与内容证据识别。"
    var onLog: ((String, LogLevel) -> Void)?

    func syncFromState(_ findings: [LaunchHackCandidate]) {
        if candidates != findings { candidates = findings }
    }

    func start(screenshot: Data, containers: [ContainerInfo], state: AppState) {
        guard !isRunning else { return }
        guard state.channel.isAvailable else {
            status = state.channel.unavailableReason
            onLog?(status, .warning)
            return
        }
        guard let referenceImage = LaunchHackVisualMatcher.cgImage(from: screenshot),
              let referenceFeature = try? LaunchHackVisualMatcher.featurePrint(referenceImage) else {
            status = "截图无法解析，请重新选择清晰的广告截图。"
            return
        }

        let referenceText = LaunchHackVisualMatcher.recognizedText(referenceImage)
        // 只扫主页选中的目标应用（Grace 2026-11-21 定）：它的数据容器
        // 加关联共享容器，不再全机扫。
        guard state.targetChosen, !state.target.bundleID.isEmpty else {
            status = "先在主页选择一个要检测的目标应用，再导入截图。"
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
        visitedFiles = 0
        checkedMedia = 0
        totalContainers = targets.count
        status = "正在分析截图并检索 \(state.target.name) 的 \(targets.count) 个容器…"
        onLog?("LaunchHack 开始检测 \(state.target.name)：\(targets.count) 个容器，OCR 提取 \(referenceText.count) 个文本词项", .info)
        let channel = state.channel

        DispatchQueue.global(qos: .userInitiated).async {
            var matches: [LaunchHackCandidate] = []
            var visited = 0
            var mediaCount = 0
            var visualCount = 0
            var dataCount = 0
            var sniffedMedia = 0
            var closest: [(path: String, distance: Float)] = []
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
                self.status = "盘点完成：共 \(totalWork) 个文件，正在逐个比对…"
            }

            // 阶段二：逐个处理，进度 = 已处理 ÷ 总数（真进度）。
            for entry in plan {
                let target = entry.target
                let relativeOf: (FileItem) -> String = {
                    String($0.path.dropFirst(target.rootPath.count + 1))
                }

                // 配置文件先读一遍作内容证据（只读）：每容器最多
                // 160 个、总计 24 MB，单文件上限 512 KB（旧版口径）。
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

                // 媒体排队：路径证据分高的、时间新的先比对，真广告
                // 先冒出来（Grace 2026-11-21 定）；数据文件随后处理。
                let mediaWork = entry.work
                    .filter { let kind = kindOf[$0.path] ?? .other; return kind == .image || kind == .video }
                    .map { (file: $0, score: LaunchHackAssessment.assess(relativePath: relativeOf($0)).score) }
                    .sorted { a, b in
                        if a.score != b.score { return a.score > b.score }
                        return a.file.modified > b.file.modified
                    }
                    .map { $0.file }
                let dataWork = entry.work.filter { (kindOf[$0.path] ?? .other) == .other }

                for file in mediaWork {
                    processed += 1
                    if processed % 20 == 0 {
                        let snapshot = processed
                        DispatchQueue.main.async {
                            self.scanProgress = totalWork > 0 ? Double(snapshot) / Double(totalWork) : 1
                        }
                    }
                    let relative = relativeOf(file)
                    // 媒体文件走截图视觉比对线。已取消分析上限：
                    // 选中应用的文件全部比对完（Grace 2026-11-21 定）。
                    guard file.size > 0, file.size <= 40 * 1024 * 1024 else { continue }
                    mediaCount += 1
                    if mediaCount % 20 == 0 {
                        let snapshot = mediaCount
                        DispatchQueue.main.async { self.checkedMedia = snapshot }
                    }
                    guard let match = LaunchHackVisualMatcher.inspect(path: file.path,
                        relativePath: relative, channel: channel,
                        reference: referenceFeature, referenceText: referenceText,
                        kind: kindOf[file.path] ?? .other) else { continue }
                    // 没过线也把距离留下来：整轮未命中时，日志报最接近
                    // 的几个，一眼分清图不在还是差一点（Grace 定）。
                    closest.append((path: relative, distance: match.distance))
                    guard match.isStrong else { continue }
                    let md5 = file.size <= 32 * 1024 * 1024 ? try? channel.md5(file.path) : nil
                    matches.append(LaunchHackCandidate(bundleID: target.bundleID,
                        groupID: target.groupID, appName: target.appName,
                        relativePath: relative, size: file.size, modifiedAt: file.modified,
                        md5: md5, isFrozen: channel.isImmutable(file.path),
                        score: match.score, evidence: match.evidence,
                        mediaDetails: match.mediaDetails, previewData: match.previewData))
                    visualCount += 1
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
                    // 数据/配置文件走路径＋内容证据线（旧版那套，
                    // Grace 2026-11-21 定：数据文件一并扫）。
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
                self.visitedFiles = visited
                self.checkedMedia = mediaCount
                self.isRunning = false
                self.scanProgress = 1
                let statusText = failures.isEmpty
                    ? "检索完成：视觉分析 \(mediaCount) 个媒体文件、命中 \(visualCount) 个；数据文件按证据命中 \(dataCount) 个。"
                    : "检索完成但有 \(failures.count) 个容器未能完整读取；结果可能不完整。"
                self.status = statusText
                self.onLog?(statusText, failures.isEmpty ? .success : .warning)
                if sniffedMedia > 0 {
                    self.onLog?("LaunchHack 有 \(sniffedMedia) 个文件靠内容认出是图片/视频（后缀认不出）", .info)
                }
                if visualCount == 0, !closest.isEmpty {
                    let top = closest.sorted { $0.distance < $1.distance }.prefix(3)
                        .map { "\($0.path)（距离 \(String(format: "%.4f", $0.distance))）" }
                        .joined(separator: "；")
                    self.onLog?("LaunchHack 视觉线未命中，最接近的 \(min(3, closest.count)) 个：\(top)。强匹配线为距离 ≤0.10", .warning)
                }
                for failure in failures.prefix(8) { self.onLog?("LaunchHack 容器异常：\(failure)", .warning) }
            }
        }
    }
}

struct LaunchHackView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = LaunchHackModel()
    @State private var photoItem: PhotosPickerItem?
    @State private var screenshotData: Data?
    @State private var screenshotImage: UIImage?
    @State private var isLoadingScreenshot = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    screenshotPicker
                    pipelineStatus
                    resultSummary
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
            loadContainersAndRunIfReady()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                isLoadingScreenshot = true
                defer { isLoadingScreenshot = false }
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    model.status = "无法读取这张截图，请重新选择。"
                    return
                }
                screenshotData = data
                screenshotImage = image
                loadContainersAndRunIfReady()
            }
        }
        .onChange(of: state.containers) { _, _ in loadContainersAndRunIfReady() }
        .onChange(of: model.candidates) { _, findings in
            state.syncLaunchHackFindings(findings)
        }
        .onChange(of: state.launchHackFindings) { _, findings in
            model.syncFromState(findings)
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
                    Text("截图驱动 · 自动定位 · 自动同步").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryText)
                }
            }
            Text("只需导入真实广告界面截图。LaunchHack 自动提取视觉与文字特征，检索所选应用的资源：媒体按画面比对，数据文件按证据识别，结果同步到 LaunchShield。")
                .font(.system(size: 12)).foregroundStyle(Color.secondaryText)
        }
        .padding(.vertical, 3)
    }

    private var screenshotPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("广告界面截图").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.primaryText)
            if let image = screenshotImage {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxHeight: 300).clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                ContentUnavailableView("尚未导入截图", systemImage: "photo.badge.plus",
                    description: Text("选择一张包含完整广告画面的截图，作为资源匹配基准。"))
                    .frame(maxWidth: .infinity).frame(height: 170)
            }
            PhotosPicker(selection: $photoItem, matching: .images) {
                HStack {
                    if isLoadingScreenshot { ProgressView().tint(.white) }
                    Image(systemName: "photo.on.rectangle.angled")
                    Text(isLoadingScreenshot ? "正在读取截图…" : "导入广告截图并自动开始")
                }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(Color.accentCyan, in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(model.isRunning || isLoadingScreenshot)
            Label("截图只在本机用于视觉分析，不会上传到服务器。", systemImage: "lock.shield")
                .font(.system(size: 11)).foregroundStyle(Color.secondaryText)
        }
        .padding(15).panel()
    }

    private var pipelineStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("自动化流水线").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.primaryText)
                Spacer()
                Text(model.isRunning ? "运行中" : (model.candidates.isEmpty ? "待命" : "已完成"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.isRunning ? Color.accentCyan : Color.secondaryText)
            }
            if model.isRunning {
                if let progress = model.scanProgress {
                    ProgressView(value: progress)
                    Text("已访问 \(model.visitedFiles) 个文件，已分析 \(model.checkedMedia) 个媒体资源 · \(Int(progress * 100))%")
                        .font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                } else {
                    ProgressView()
                    Text("正在盘点文件…")
                        .font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                }
            }
            Text(model.status).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            if !model.candidates.isEmpty {
                Label("识别结果已自动同步到 LaunchShield 主界面。", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.green)
            }
        }
        .padding(15).panel()
    }

    private var resultSummary: some View {
        HStack(spacing: 8) {
            metric("\(model.candidates.count)", "匹配资源")
            metric("\(model.candidates.filter { $0.score >= 90 }.count)", "极高匹配")
            metric("\(model.candidates.filter { $0.isFrozen }.count)", "已冻结")
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 21, weight: .bold, design: .rounded)).foregroundStyle(Color.primaryText)
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12).panel()
    }

    private func loadContainersAndRunIfReady() {
        guard let screenshotData, !model.isRunning else { return }
        if state.didLoadContainers {
            model.start(screenshot: screenshotData, containers: state.containers, state: state)
        } else {
            state.refreshContainers {
                guard let data = self.screenshotData else { return }
                self.model.start(screenshot: data, containers: self.state.containers, state: self.state)
            }
        }
    }
}
