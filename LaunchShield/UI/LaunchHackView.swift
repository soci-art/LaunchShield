import SwiftUI
import ImageIO
import AVFoundation
import UIKit

// MARK: - LaunchHack data

private struct LaunchHackScanTarget: Hashable {
    let bundleID: String?
    let appName: String
    let rootPath: String
    let groupID: String?
}

private struct LaunchHackDomainFinding: Identifiable {
    let host: String
    var urls: [String]
    var configPaths: [String]
    var resourcePaths: Set<String>

    var id: String { host }
    var resourceCount: Int { resourcePaths.count }
}

private struct LaunchHackRuleDraft: Codable, Identifiable {
    let id: UUID
    let candidate: LaunchHackCandidate
    let createdAt: Date
    var status: String
}

private enum LaunchHackDraftStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("LaunchShield/LaunchHack", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("rule-drafts.json")
    }

    private static var loadFailure: String?

    static func load() -> [LaunchHackRuleDraft] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let drafts = try JSONDecoder().decode([LaunchHackRuleDraft].self, from: data)
            loadFailure = nil
            return drafts
        } catch {
            loadFailure = error.localizedDescription
            return []
        }
    }

    @discardableResult
    static func save(_ drafts: [LaunchHackRuleDraft]) -> Bool {
        guard loadFailure == nil, let data = try? JSONEncoder().encode(drafts) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

private struct LaunchHackContentEvidence {
    let sourcePath: String
    let urls: [String]
    let hasAdSignals: Bool
}

enum LaunchHackContentAnalyzer {
    private static let configExtensions: Set<String> = ["plist", "json", "xml"]

    static func isReadableConfig(_ path: String, size: UInt64) -> Bool {
        let lower = path.lowercased()
        let ext = (path as NSString).pathExtension.lowercased()
        let components = lower.split(separator: "/").map(String.init)
        let adSpecific = ["splash", "adcache", "ad_cache", "advert", "adsdk",
                          "launchad", "launch_ad", "bootimagebiz", "bootimagedoc"]
            .contains { marker in components.contains { $0.contains(marker) } }
        let preferences = lower.contains("/library/preferences/") || lower.hasPrefix("library/preferences/")
        let applicationSupport = lower.contains("/library/application support/")
            || lower.hasPrefix("library/application support/")
        return configExtensions.contains(ext) && size > 0 && size <= 512 * 1024
            && (preferences || applicationSupport || adSpecific)
    }

    static func analyze(path: String, relativePath: String, data: Data) -> LaunchHackContentEvidence? {
        let ext = (relativePath as NSString).pathExtension.lowercased()
        var structuredStrings: [String]?

        if (ext == "plist" || ext == "xml"),
           let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            structuredStrings = flattenStrings(object)
        } else if ext == "json",
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            structuredStrings = flattenStrings(object)
        }

        // Binary plist 不能直接按 UTF-8 扫描；优先使用结构化解析结果。
        // XML/JSON 文本解析失败时才回退到 UTF-8 原文。
        let rawText = String(data: data, encoding: .utf8)
        let searchableText = ((structuredStrings ?? []) + (rawText.map { [$0] } ?? []))
            .joined(separator: "\n")
        let urls = extractURLs(searchableText)
        let lower = searchableText.lowercased()
        let markers = [
            "splash", "cold_launch", "coldlaunch", "launch_ad", "startup_ad",
            "advertisement", "ad_cache", "advertising", "promotion", "campaign",
            "adsdk", "ad_material", "admob", "gdt", "pangolin", "beizi",
            "activity_message", "content_url_list", "appopen", "openad"
        ]
        let hasSignals = markers.contains { lower.contains($0) }
        guard !urls.isEmpty || hasSignals else { return nil }
        return LaunchHackContentEvidence(sourcePath: path, urls: urls, hasAdSignals: hasSignals)
    }

    static func resourceMatchReasons(_ relativePath: String, evidence: LaunchHackContentEvidence) -> [String] {
        let name = ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        guard !name.isEmpty else { return [] }

        var reasons: [String] = []
        for url in evidence.urls {
            if let component = URLComponents(string: url),
               let last = component.percentEncodedPath.split(separator: "/").last {
                let encodedName = (String(last) as NSString).deletingPathExtension.lowercased()
                let decodedName = encodedName.removingPercentEncoding?.lowercased() ?? encodedName
                if name == encodedName || name == decodedName {
                    reasons.append("本地文件名与配置 URL 路径文件名一致")
                }
            }
            if LocalADBlockRule.digests(for: url).contains(name) {
                reasons.append("本地文件名与配置 URL 的 MD5 对应")
            }
        }
        return Array(Set(reasons)).sorted()
    }

    static func displayURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value }
        components.query = nil
        components.fragment = nil
        return components.string ?? value
    }

    /// 对证据句子中的 URL 脱敏，避免 query/fragment 携带 token 或追踪参数。
    static func displayURLs(in text: String) -> String {
        let pattern = #"https?://[^\s"'<>]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let raw = String(result[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,);]"))
            result.replaceSubrange(range, with: displayURL(raw))
        }
        return result
    }

    private static func extractURLs(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s\\\"'<>]+") else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            let value = String(text[matchRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,);]"))
            guard seen.insert(value).inserted else { return nil }
            return value
        }
    }

    private static func flattenStrings(_ value: Any) -> [String] {
        if let text = value as? String { return [text] }
        if let dictionary = value as? [String: Any] {
            return dictionary.keys.sorted().flatMap { key in
                [key] + flattenStrings(dictionary[key] ?? NSNull())
            }
        }
        if let array = value as? [Any] {
            return array.flatMap { flattenStrings($0) }
        }
        return []
    }
}

private struct LaunchHackMediaAnalysis {
    let details: String
    let previewData: Data?
    let evidence: String
}

private enum LaunchHackMediaAnalyzer {
    // 临时副本只落在 LaunchShield 自己的 tmp 目录；目标容器始终只读。
    static func analyze(path: String, relativePath: String, channel: Channel) -> LaunchHackMediaAnalysis? {
        let kind = FileKind.of(relativePath)
        guard kind == .image || kind == .video else { return nil }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("LaunchHackMedia-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: directory) }

            let ext = (relativePath as NSString).pathExtension
            let localURL = directory.appendingPathComponent("candidate.\(ext.isEmpty ? "bin" : ext)")
            try channel.copyToLocal(path: path, destination: localURL.path)

            let attributes = try fileManager.attributesOfItem(atPath: localURL.path)
            let localSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            guard localSize > 0, localSize <= 32 * 1024 * 1024 else {
                return LaunchHackMediaAnalysis(details: "临时副本超出分析大小限制", previewData: nil,
                                               evidence: "[待验证] 媒体副本超出 32 MiB 分析上限")
            }

            let image: CGImage?
            var details: String
            var analysisEvidence = "[内容已分析] 已从临时副本提取媒体属性；未写入目标容器"
            switch kind {
            case .image:
                guard let source = CGImageSourceCreateWithURL(localURL as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                    return LaunchHackMediaAnalysis(details: "图片格式无法解析", previewData: nil,
                                                   evidence: "[无法分析] 图片副本无法解析")
                }
                image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 480,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ] as CFDictionary)
                details = "图片 · \(width) × \(height) · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: localSize), countStyle: .file))"
            case .video:
                let asset = AVURLAsset(url: localURL)
                let duration = asset.duration.seconds
                let safeDuration = duration.isFinite && duration > 0 ? duration : 0
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 480, height: 480)
                let frameTime = CMTime(seconds: min(0.5, safeDuration > 0 ? safeDuration / 2 : 0),
                                       preferredTimescale: 600)
                image = try? generator.copyCGImage(at: frameTime, actualTime: nil)
                guard safeDuration > 0 || image != nil else {
                    return LaunchHackMediaAnalysis(details: "视频容器无法解析或系统不支持该编码",
                                                   previewData: nil,
                                                   evidence: "[无法分析] AVFoundation 无法读取视频时长或关键帧")
                }
                if image == nil {
                    analysisEvidence = "[部分分析] 已读取视频时长，但未能提取关键帧"
                }
                let durationText = safeDuration > 0 ? String(format: "%.2f 秒", safeDuration) : "时长未知"
                let dimensions = image.map { "\($0.width) × \($0.height)" } ?? "关键帧不可用"
                details = "视频 · \(durationText) · \(dimensions) · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: localSize), countStyle: .file))"
            case .other:
                return nil
            }

            let preview = image.flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: 0.68) }
            let boundedPreview = (preview?.count ?? 0) <= 160 * 1024 ? preview : nil
            return LaunchHackMediaAnalysis(details: details, previewData: boundedPreview,
                                           evidence: analysisEvidence)
        } catch {
            return LaunchHackMediaAnalysis(details: "媒体分析失败：\(error.localizedDescription)",
                                           previewData: nil,
                                           evidence: "[无法分析] WQ 临时复制或媒体解析失败")
        }
    }
}

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

private enum LaunchHackTraceStage: String, Codable, CaseIterable, Identifiable {
    case baseline
    case afterFreeze
    case afterRestart
    case adReappeared

    var id: String { rawValue }
    var title: String {
        switch self {
        case .baseline: return "基线"
        case .afterFreeze: return "冻结后"
        case .afterRestart: return "重启后"
        case .adReappeared: return "复显后"
        }
    }
}

private struct LaunchHackTraceEntry: Codable {
    let size: UInt64
    let modifiedAt: Date
    let md5: String?
    let isImmutable: Bool
}

private struct LaunchHackTraceContainer: Codable, Identifiable {
    let bundleID: String?
    let groupID: String?
    let appName: String
    let rootPath: String
    let truncated: Bool
    let entries: [String: LaunchHackTraceEntry]

    var id: String {
        if let groupID { return "group:" + groupID }
        return "app:" + (bundleID ?? "unknown")
    }
}

private struct LaunchHackTraceCheckpoint: Codable, Identifiable {
    let stage: LaunchHackTraceStage
    let createdAt: Date
    let containers: [LaunchHackTraceContainer]
    let hashedFiles: Int
    let failedContainers: [String]

    var id: String { stage.rawValue }
}

private struct LaunchHackTraceChange: Identifiable {
    let containerName: String
    let relativePath: String
    let status: String
    let detail: String

    var id: String { containerName + "|" + relativePath + "|" + status }
}

private enum LaunchHackTraceStore {
    private static var loadFailure: String?
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("LaunchShield/LaunchHack", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("trace-checkpoints.json")
    }

    static func load() -> [LaunchHackTraceCheckpoint] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let records = try JSONDecoder().decode([LaunchHackTraceCheckpoint].self, from: data)
            loadFailure = nil
            return records
        } catch {
            loadFailure = error.localizedDescription
            return []
        }
    }

    static func save(_ records: [LaunchHackTraceCheckpoint]) -> Bool {
        guard loadFailure == nil, let data = try? JSONEncoder().encode(records) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

private enum LaunchHackTraceDiff {
    static func compare(baseline: LaunchHackTraceCheckpoint,
                        checkpoint: LaunchHackTraceCheckpoint) -> (changes: [LaunchHackTraceChange], incomplete: [String]) {
        let beforeByID = Dictionary(uniqueKeysWithValues: baseline.containers.map { ($0.id, $0) })
        let afterByID = Dictionary(uniqueKeysWithValues: checkpoint.containers.map { ($0.id, $0) })
        var changes: [LaunchHackTraceChange] = []
        var incomplete: [String] = []

        for after in checkpoint.containers {
            guard let before = beforeByID[after.id] else {
                incomplete.append(after.appName + "（缺少基线）")
                continue
            }
            guard before.rootPath == after.rootPath else {
                incomplete.append(after.appName + "（容器路径已变化，跳过对比）")
                continue
            }
            guard !before.truncated, !after.truncated else {
                incomplete.append(after.appName + "（扫描不完整，跳过对比）")
                continue
            }

            for path in Set(before.entries.keys).union(after.entries.keys).sorted() {
                let old = before.entries[path]
                let new = after.entries[path]
                guard let old else {
                    changes.append(LaunchHackTraceChange(containerName: after.appName,
                                                         relativePath: path,
                                                         status: "新增",
                                                         detail: "基线中不存在"))
                    continue
                }
                guard let new else {
                    changes.append(LaunchHackTraceChange(containerName: after.appName,
                                                         relativePath: path,
                                                         status: "删除",
                                                         detail: "当前检查点中不存在"))
                    continue
                }

                var details: [String] = []
                var statuses: [String] = []
                if let oldHash = old.md5, let newHash = new.md5, oldHash != newHash {
                    statuses.append("内容替换")
                    details.append("MD5 已变化")
                } else if old.size != new.size || old.modifiedAt != new.modifiedAt {
                    statuses.append("文件变化")
                    details.append(old.md5 == nil || new.md5 == nil
                                   ? "大小或修改时间变化；未完成哈希确认"
                                   : "大小或修改时间变化")
                }
                if old.isImmutable != new.isImmutable {
                    statuses.append("冻结状态变化")
                    details.append(new.isImmutable ? "当前已冻结" : "当前未冻结")
                }
                if !statuses.isEmpty {
                    changes.append(LaunchHackTraceChange(containerName: after.appName,
                                                         relativePath: path,
                                                         status: statuses.joined(separator: " · "),
                                                         detail: details.joined(separator: "；")))
                }
            }
        }

        let matchedIDs = Set(afterByID.keys)
        for before in baseline.containers where !matchedIDs.contains(before.id) {
            incomplete.append(before.appName + "（检查点缺失）")
        }

        changes.sort {
            if $0.status.contains("新增") != $1.status.contains("新增") {
                return $0.status.contains("新增")
            }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        return (Array(changes.prefix(500)), incomplete)
    }
}

@MainActor
private final class LaunchHackModel: ObservableObject {
    @Published var apps: [ContainerInfo] = []
    @Published var candidates: [LaunchHackCandidate] = []
    @Published var drafts: [LaunchHackRuleDraft] = LaunchHackDraftStore.load()
    @Published var isScanning = false
    @Published var isUploading = false
    @Published var uploadMessage = ""
    @Published var uploadResultUncertain = UserDefaults.standard.bool(forKey: "ls.launchHackUploadResultUncertain")
    @Published var scannedContainers = 0
    @Published var totalContainers = 0
    @Published var visitedFiles = 0
    @Published var scanMessage = "扫描只读取 WQ 当前可访问的容器，不会修改目标 App 文件。"
    @Published var traceCheckpoints: [LaunchHackTraceCheckpoint] = LaunchHackTraceStore.load()
    @Published var isTracking = false
    @Published var trackingMessage = "尚未建立追踪基线。"

    init() {
        if !traceCheckpoints.isEmpty {
            trackingMessage = "已载入本机追踪记录：\(traceCheckpoints.count) 个阶段。"
        }
    }

    func setApps(_ containers: [ContainerInfo]) {
        apps = containers
            .filter { !$0.isGroup && !AppState.isSystemApp($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func addDraft(_ candidate: LaunchHackCandidate) {
        guard !drafts.contains(where: { $0.candidate.id == candidate.id }) else { return }
        let previous = drafts
        let status = candidate.bundleID == nil ? "待关联宿主 App" : (candidate.groupID == nil ? "待验证" : "共享容器待验证")
        drafts.insert(LaunchHackRuleDraft(id: UUID(), candidate: candidate,
                                          createdAt: Date(), status: status), at: 0)
        if !LaunchHackDraftStore.save(drafts) {
            drafts = previous
        }
    }

    func removeDraft(_ draft: LaunchHackRuleDraft) {
        let previous = drafts
        drafts.removeAll { $0.id == draft.id }
        if !LaunchHackDraftStore.save(drafts) {
            drafts = previous
        }
    }

    func checkpoint(for stage: LaunchHackTraceStage) -> LaunchHackTraceCheckpoint? {
        traceCheckpoints.first { $0.stage == stage }
    }

    func traceChanges(for stage: LaunchHackTraceStage) -> (changes: [LaunchHackTraceChange], incomplete: [String])? {
        guard let baseline = checkpoint(for: .baseline),
              let checkpoint = checkpoint(for: stage), stage != .baseline else { return nil }
        return LaunchHackTraceDiff.compare(baseline: baseline, checkpoint: checkpoint)
    }

    func captureCheckpoint(stage: LaunchHackTraceStage,
                           targets: [LaunchHackScanTarget],
                           channel: Channel) {
        guard !isTracking else { return }
        guard channel.isAvailable else {
            trackingMessage = channel.unavailableReason
            return
        }
        guard !targets.isEmpty else {
            trackingMessage = "没有可记录的容器，请先选择至少一个 App。"
            return
        }
        if stage != .baseline && checkpoint(for: .baseline) == nil {
            trackingMessage = "请先建立基线，再记录后续阶段。"
            return
        }

        isTracking = true
        trackingMessage = "正在记录「\(stage.title)」检查点…"
        DispatchQueue.global(qos: .userInitiated).async {
            var containers: [LaunchHackTraceContainer] = []
            var failed: [String] = []
            var totalVisited = 0
            var hashedFiles = 0
            var hashedBytes: UInt64 = 0
            let totalFileBudget = 60000

            for target in targets {
                let remaining = totalFileBudget - totalVisited
                guard remaining > 0 else {
                    failed.append(target.appName + "（达到本次 60,000 文件上限）")
                    continue
                }
                let perContainerLimit = min(12000, remaining)
                do {
                    guard let rootItem = channel.item(at: target.rootPath),
                          rootItem.isDirectory, !rootItem.isSymlink else {
                        throw ChannelFailure("容器根目录不可访问或是符号链接")
                    }
                    let files = try channel.walkFiles(
                        at: target.rootPath,
                        limit: perContainerLimit,
                        skipDirNames: [".Trash", "Recently Deleted"],
                        skipDirSubstrings: [],
                        skipAccountDirs: false
                    )
                    totalVisited += files.count
                    var entries: [String: LaunchHackTraceEntry] = [:]
                    for file in files where !file.isDirectory && !file.isSymlink
                        && file.path.hasPrefix(target.rootPath + "/") {
                        let relative = String(file.path.dropFirst(target.rootPath.count + 1))
                        var digest: String?
                        let ext = (relative as NSString).pathExtension.lowercased()
                        let relevant = FileKind.of(relative) == .image
                            || FileKind.of(relative) == .video
                            || ["plist", "json", "xml"].contains(ext)
                            || ["splash", "ad", "advert", "campaign", "launch"].contains(where: { relative.lowercased().contains($0) })
                        if relevant, file.size > 0, file.size <= 16 * 1024 * 1024,
                           hashedFiles < 250, hashedBytes + file.size <= 128 * 1024 * 1024 {
                            digest = try? channel.md5(file.path)
                            if digest != nil {
                                hashedFiles += 1
                                hashedBytes += file.size
                            }
                        }
                        entries[relative] = LaunchHackTraceEntry(
                            size: file.size,
                            modifiedAt: file.modified,
                            md5: digest,
                            isImmutable: channel.isImmutable(file.path)
                        )
                    }
                    containers.append(LaunchHackTraceContainer(
                        bundleID: target.bundleID,
                        groupID: target.groupID,
                        appName: target.appName,
                        rootPath: target.rootPath,
                        truncated: files.count >= perContainerLimit,
                        entries: entries
                    ))
                } catch {
                    failed.append(target.appName + "（" + error.localizedDescription + "）")
                }
            }

            let checkpoint = LaunchHackTraceCheckpoint(
                stage: stage,
                createdAt: Date(),
                containers: containers,
                hashedFiles: hashedFiles,
                failedContainers: failed
            )
            DispatchQueue.main.async {
                self.isTracking = false
                guard !containers.isEmpty else {
                    self.trackingMessage = "没有容器成功完成本次记录，原有追踪数据保持不变。"
                    return
                }
                let hasIncompleteContainers = containers.contains(where: { $0.truncated })
                    || !failed.isEmpty
                    || containers.count != targets.count
                guard !hasIncompleteContainers else {
                    let truncatedCount = containers.filter { $0.truncated }.count
                    self.trackingMessage = "本次记录不完整：\(containers.count)/\(targets.count) 个容器成功读取，\(truncatedCount) 个达到扫描上限，\(failed.count) 个读取失败。为避免产生误导性差异，未覆盖原有检查点；请恢复容器访问后重新记录。"
                    return
                }
                let previous = self.traceCheckpoints
                if stage == .baseline {
                    self.traceCheckpoints = [checkpoint]
                } else {
                    self.traceCheckpoints.removeAll { $0.stage == stage }
                    self.traceCheckpoints.append(checkpoint)
                    self.traceCheckpoints.sort { $0.createdAt < $1.createdAt }
                }
                let saved = LaunchHackTraceStore.save(self.traceCheckpoints)
                if !saved {
                    self.traceCheckpoints = previous
                }
                let count = containers.reduce(0) { $0 + $1.entries.count }
                let incomplete = containers.filter { $0.truncated }.count
                self.trackingMessage = saved
                    ? "「\(stage.title)」已记录：\(containers.count) 个容器、\(count) 个文件、\(hashedFiles) 个 MD5；\(incomplete) 个容器达到扫描上限，\(failed.count) 个容器未能读取。已保存到本机。"
                    : "本机保存失败，已保留上一次追踪记录；请检查存储空间后重试。"
            }
        }
    }

    func clearTrace() {
        let previous = traceCheckpoints
        traceCheckpoints = []
        if LaunchHackTraceStore.save(traceCheckpoints) {
            trackingMessage = "本机追踪记录已清空。"
        } else {
            traceCheckpoints = previous
            trackingMessage = "无法更新本机追踪文件，已保留原有追踪记录。"
        }
    }

    func scan(targets: [LaunchHackScanTarget], channel: Channel) {
        guard !isScanning else { return }
        guard channel.isAvailable else {
            scanMessage = channel.unavailableReason
            return
        }
        guard !targets.isEmpty else {
            scanMessage = "没有可扫描的容器。请检查 WQ 通道和应用列表。"
            return
        }

        isScanning = true
        candidates = []
        scannedContainers = 0
        visitedFiles = 0
        totalContainers = targets.count
        scanMessage = "正在扫描 \(targets.count) 个容器…"

        DispatchQueue.global(qos: .userInitiated).async {
            var found: [LaunchHackCandidate] = []
            var visitedTotal = 0
            var completed = 0
            var failures: [String] = []
            var mediaAnalyzedCount = 0
            var mediaBytesCopied: UInt64 = 0

            for target in targets {
                do {
                    guard let rootItem = channel.item(at: target.rootPath),
                          rootItem.isDirectory, !rootItem.isSymlink else {
                        throw ChannelFailure("容器根目录不可访问或是符号链接")
                    }
                    let files = try channel.walkFiles(
                        at: target.rootPath,
                        limit: 12000,
                        skipDirNames: [".Trash", "Recently Deleted"],
                        skipDirSubstrings: [],
                        skipAccountDirs: false,
                        onVisit: { visited in
                            visitedTotal += 1
                            if visitedTotal % 250 == 0 {
                                let count = visitedTotal
                                DispatchQueue.main.async { self.visitedFiles = count }
                            }
                        }
                    )

                    if files.count >= 12000 {
                        failures.append("\(target.appName)：达到单容器 12,000 文件上限，结果可能不完整")
                    }

                    // 读取偏好设置、应用支持目录和广告特征配置，建立只读关联索引。
                    // 每容器最多读取 160 个配置、总计 24 MiB；单文件上限 512 KiB。
                    var configEvidence: [LaunchHackContentEvidence] = []
                    var configBytesRead: UInt64 = 0
                    for config in files where !config.isDirectory && !config.isSymlink
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

                    for file in files where !file.isDirectory && !file.isSymlink
                        && file.path.hasPrefix(target.rootPath + "/") {
                        let relative = String(file.path.dropFirst(target.rootPath.count + 1))
                        let assessment = LaunchHackAssessment.assess(relativePath: relative)
                        var score = assessment.score
                        var evidence = assessment.evidence

                        let isConfig = LaunchHackContentAnalyzer.isReadableConfig(relative, size: file.size)
                        if isConfig,
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

                        let digest: String?
                        if file.size <= 16 * 1024 * 1024, found.count < 250 {
                            digest = try? channel.md5(file.path)
                        } else {
                            digest = nil
                        }

                        var mediaDetails: String?
                        var previewData: Data?
                        if (FileKind.of(relative) == .image || FileKind.of(relative) == .video),
                           file.size <= 32 * 1024 * 1024,
                           mediaAnalyzedCount < 24,
                           mediaBytesCopied + file.size <= 128 * 1024 * 1024 {
                            mediaAnalyzedCount += 1
                            mediaBytesCopied += file.size
                            if let media = LaunchHackMediaAnalyzer.analyze(
                                path: file.path, relativePath: relative, channel: channel
                            ) {
                                mediaDetails = media.details
                                previewData = media.previewData
                                evidence.append(media.evidence)
                            }
                        }

                        found.append(LaunchHackCandidate(
                            bundleID: target.bundleID,
                            groupID: target.groupID,
                            appName: target.appName,
                            relativePath: relative,
                            size: file.size,
                            modifiedAt: file.modified,
                            md5: digest,
                            isFrozen: channel.isImmutable(file.path),
                            score: min(score, 98),
                            evidence: Array(Set(evidence)).sorted(),
                            mediaDetails: mediaDetails,
                            previewData: previewData
                        ))
                    }
                } catch {
                    failures.append("\(target.appName)：\(error.localizedDescription)")
                }

                completed += 1
                let done = completed
                let visited = visitedTotal
                DispatchQueue.main.async {
                    self.scannedContainers = done
                    self.visitedFiles = visited
                }
            }

            let sorted = found.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.modifiedAt > $1.modifiedAt
            }

            DispatchQueue.main.async {
                self.candidates = Array(sorted.prefix(500))
                self.isScanning = false
                let failureText = failures.isEmpty ? "" : "；\(failures.count) 个容器无法完整读取"
                self.scanMessage = "扫描完成：访问 \(visitedTotal) 个文件，发现 \(found.count) 个候选资源；媒体分析 \(mediaAnalyzedCount) 项\(failureText)。候选需要人工核验，不会自动冻结。"
            }
        }
    }


}

// MARK: - LaunchHack interface

struct LaunchHackView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = LaunchHackModel()

    private var selectedApps: [ContainerInfo] {
        guard state.targetChosen, !state.isWhitelisted(state.target.bundleID) else { return [] }
        return model.apps.filter { $0.bundleID == state.target.bundleID }
    }

    private var trackingTargets: [LaunchHackScanTarget] {
        var targets: [LaunchHackScanTarget] = []
        for app in selectedApps {
            targets.append(LaunchHackScanTarget(bundleID: app.bundleID,
                                                 appName: app.name,
                                                 rootPath: app.path,
                                                 groupID: nil))
            targets.append(contentsOf: state.associatedGroups(for: app.bundleID)
                .filter { !$0.path.isEmpty }
                .map {
                    LaunchHackScanTarget(bundleID: app.bundleID,
                                         appName: "共享容器 · \($0.bundleID)",
                                         rootPath: $0.path,
                                         groupID: $0.bundleID)
                })
        }
        var seen = Set<String>()
        return targets.filter { seen.insert($0.rootPath).inserted }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    heroHeader
                    targetApplicationCard
                    scanActionCard
                    resultOverviewCard
                    if !model.candidates.isEmpty {
                        Label("已同步到 LaunchShield 主界面。返回主页即可查看简要结果、展开证据并执行后续操作。",
                              systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.green)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .panel()
                    }
                }
                .padding(16)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("LaunchHack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .onAppear(perform: loadApps)
        .onChange(of: state.containers) { _, containers in
            model.setApps(containers)
        }
        .onChange(of: model.candidates) { _, candidates in
            state.syncLaunchHackFindings(candidates)
        }
    }

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.accentCyan)
                    .frame(width: 48, height: 48)
                    .background(Color.accentCyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text("LaunchHack")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(Color.primaryText)
                    Text("只读识别 · 结果同步")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.secondaryText)
                }
            }
            Text("这里只扫描并识别广告线索。不会清理、清零、冻结、导入规则或上传文件；识别结果自动交回 LaunchShield 主界面。")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }

    private var targetApplicationCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "app.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.accentCyan)
                .frame(width: 46, height: 46)
                .background(Color.accentCyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 4) {
                Text("当前检测应用")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondaryText)
                Text(selectedApps.first?.name ?? "尚未选择应用")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                    .lineLimit(1)
                Text(selectedApps.isEmpty
                     ? "请先返回 LaunchShield 主页选择一个可访问的应用"
                     : "仅检测当前应用及已确认关联的共享容器")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryText)
            }
            Spacer(minLength: 4)
            Image(systemName: selectedApps.isEmpty ? "exclamationmark.circle" : "checkmark.circle.fill")
                .foregroundStyle(selectedApps.isEmpty ? Color.orange : Color.green)
        }
        .padding(15)
        .panel()
    }

    private var scanActionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: beginScan) {
                HStack(spacing: 9) {
                    if model.isScanning {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                    Text(model.isScanning ? "正在检测…" : "开始广告检测")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.accentCyan, in: RoundedRectangle(cornerRadius: 15))
            }
            .buttonStyle(.plain)
            .disabled(model.isScanning || selectedApps.isEmpty || !state.channel.isAvailable || state.isBusy)

            if model.isScanning {
                ProgressView(value: Double(model.scannedContainers),
                             total: Double(max(model.totalContainers, 1)))
                Text("已检查 \(model.scannedContainers)/\(model.totalContainers) 个位置，访问 \(model.visitedFiles) 个文件")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryText)
            } else {
                Label("只读检测，不修改目标应用文件", systemImage: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryText)
            }
            if !model.scanMessage.isEmpty {
                Text(model.scanMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(15)
        .panel()
    }

    private var resultOverviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("识别摘要")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                Spacer()
                Text(model.isScanning ? "检测中" : (model.candidates.isEmpty ? "等待检测" : "已同步"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.isScanning ? Color.accentCyan : Color.secondaryText)
            }
            HStack(spacing: 8) {
                resultMetric("\(model.candidates.count)", "发现线索")
                resultMetric("\(model.candidates.filter { $0.score >= 80 }.count)", "优先核验")
                resultMetric("\(model.candidates.filter { $0.bundleID == nil }.count)", "待关联")
            }
            Text(model.candidates.isEmpty
                 ? "扫描完成后这里只显示数量摘要，完整识别结果会出现在 LaunchShield 主界面。"
                 : "识别结果已交回主界面。LaunchHack 不提供任何清理或冻结按钮。")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(15)
        .panel()
    }

    private func resultMetric(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .foregroundStyle(Color.primaryText)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.primaryText.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
    }

    private func loadApps() {
        if state.didLoadContainers {
            model.setApps(state.containers)
        } else {
            state.refreshContainers {
                model.setApps(state.containers)
            }
        }
    }

    private func beginScan() {
        guard !state.isBusy, !model.isScanning else {
            model.scanMessage = "LaunchShield 当前正在执行其他操作，请稍后再扫描。"
            return
        }
        let targets = trackingTargets
        guard !selectedApps.isEmpty, !targets.isEmpty else {
            model.scanMessage = "请先返回 LaunchShield 主页，选择一个可访问的用户 App。"
            return
        }
        model.scan(targets: targets, channel: state.channel)
    }
}
