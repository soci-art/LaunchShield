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

private struct LaunchHackCandidate: Codable, Identifiable, Hashable {
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
        (bundleID ?? "group:\(groupID ?? "unknown")") + "|" + relativePath
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

    static func load() -> [LaunchHackRuleDraft] {
        guard let data = try? Data(contentsOf: fileURL),
              let drafts = try? JSONDecoder().decode([LaunchHackRuleDraft].self, from: data) else {
            return []
        }
        return drafts
    }

    static func save(_ drafts: [LaunchHackRuleDraft]) {
        guard let data = try? JSONEncoder().encode(drafts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private struct LaunchHackContentEvidence {
    let sourcePath: String
    let urls: [String]
    let hasAdSignals: Bool
}

private enum LaunchHackContentAnalyzer {
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

    var id: String { (bundleID ?? groupID ?? "unknown") + (bundleID == nil ? ":group" : ":app") }
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
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("LaunchShield/LaunchHack", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("trace-checkpoints.json")
    }

    static func load() -> [LaunchHackTraceCheckpoint] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([LaunchHackTraceCheckpoint].self, from: data) else {
            return []
        }
        return records
    }

    static func save(_ records: [LaunchHackTraceCheckpoint]) -> Bool {
        guard let data = try? JSONEncoder().encode(records) else { return false }
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
        let status = candidate.groupID == nil ? "待验证" : "待关联宿主 App"
        drafts.insert(LaunchHackRuleDraft(id: UUID(), candidate: candidate,
                                          createdAt: Date(), status: status), at: 0)
        LaunchHackDraftStore.save(drafts)
    }

    /// 用户主动上传识别结果；仅提交可审计元数据，不上传原始媒体或文件内容。
    func uploadRecognitionData() {
        guard !isUploading else { return }
        guard !candidates.isEmpty else {
            uploadMessage = "没有可上传的识别数据。"
            return
        }
        let records: [[String: Any]] = candidates.map { candidate in
            [
                "bundleID": candidate.bundleID as Any? ?? NSNull(),
                "groupID": candidate.groupID as Any? ?? NSNull(),
                "appName": candidate.appName,
                "relativePath": candidate.relativePath,
                "size": candidate.size,
                "modifiedAt": ISO8601DateFormatter().string(from: candidate.modifiedAt),
                "md5": candidate.md5 as Any? ?? NSNull(),
                "isFrozen": candidate.isFrozen,
                "priorityScore": candidate.score,
                "evidence": candidate.evidence,
                "mediaDetails": candidate.mediaDetails as Any? ?? NSNull()
            ]
        }
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "uploadedAt": ISO8601DateFormatter().string(from: Date()),
            "source": "LaunchHack",
            "records": records
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            uploadMessage = "识别数据序列化失败，未上传。"
            return
        }
        isUploading = true
        uploadMessage = "正在上传识别元数据…"
        CollectUploader.upload(kind: "launchhack-recognition",
                               contentType: "application/json",
                               body: data) { success, message in
            self.isUploading = false
            self.uploadMessage = success
                ? "识别数据上传成功（\(self.candidates.count) 项）。"
                : "识别数据上传失败：\(message)"
        }
    }

    func removeDraft(_ draft: LaunchHackRuleDraft) {
        drafts.removeAll { $0.id == draft.id }
        LaunchHackDraftStore.save(drafts)
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
                    let files = try channel.walkFiles(
                        at: target.rootPath,
                        limit: perContainerLimit,
                        skipDirNames: [".Trash", "Recently Deleted"],
                        skipDirSubstrings: [],
                        skipAccountDirs: false
                    )
                    totalVisited += files.count
                    var entries: [String: LaunchHackTraceEntry] = [:]
                    for file in files where !file.isDirectory && !file.isSymlink {
                        let relative = file.path.hasPrefix(target.rootPath + "/")
                            ? String(file.path.dropFirst(target.rootPath.count + 1))
                            : file.name
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
                if stage == .baseline {
                    self.traceCheckpoints = [checkpoint]
                } else {
                    self.traceCheckpoints.removeAll { $0.stage == stage }
                    self.traceCheckpoints.append(checkpoint)
                    self.traceCheckpoints.sort { $0.createdAt < $1.createdAt }
                }
                let saved = LaunchHackTraceStore.save(self.traceCheckpoints)
                let count = containers.reduce(0) { $0 + $1.entries.count }
                let incomplete = containers.filter { $0.truncated }.count
                self.trackingMessage = "「\(stage.title)」已记录：\(containers.count) 个容器、\(count) 个文件、\(hashedFiles) 个 MD5；\(incomplete) 个容器达到扫描上限，\(failed.count) 个容器未能读取。\(saved ? "已保存到本机" : "本机保存失败，请检查存储空间")。"
            }
        }
    }

    func clearTrace() {
        traceCheckpoints = []
        trackingMessage = LaunchHackTraceStore.save(traceCheckpoints)
            ? "本机追踪记录已清空。"
            : "无法更新本机追踪文件，请检查存储空间。"
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

                    // 读取偏好设置、应用支持目录和广告特征配置，建立只读关联索引。
                    // 每容器最多读取 160 个配置、总计 24 MiB；单文件上限 512 KiB。
                    var configEvidence: [LaunchHackContentEvidence] = []
                    var configBytesRead: UInt64 = 0
                    for config in files where !config.isDirectory && !config.isSymlink
                        && LaunchHackContentAnalyzer.isReadableConfig(config.path, size: config.size) {
                        if configEvidence.count >= 160 { break }
                        if configBytesRead + config.size > 24 * 1024 * 1024 { continue }

                        let relative = config.path.hasPrefix(target.rootPath + "/")
                            ? String(config.path.dropFirst(target.rootPath.count + 1))
                            : config.name
                        guard let data = try? channel.read(config.path, maxBytes: 512 * 1024) else { continue }
                        configBytesRead += UInt64(data.count)
                        guard let evidence = LaunchHackContentAnalyzer.analyze(
                            path: relative, relativePath: relative, data: data
                        ) else { continue }
                        configEvidence.append(evidence)
                    }

                    for file in files where !file.isDirectory && !file.isSymlink {
                        let relative = file.path.hasPrefix(target.rootPath + "/")
                            ? String(file.path.dropFirst(target.rootPath.count + 1))
                            : file.name
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
    @StateObject private var model = LaunchHackModel()
    @State private var selectedTraceStage: LaunchHackTraceStage = .afterFreeze
    @State private var pendingRuleCandidate: LaunchHackCandidate?
    @State private var showUploadConfirmation = false

    /// 只把配置文件中实际读出的 URL 作为静态来源线索；不声称这是运行时网络请求。
    private var domainFindings: [LaunchHackDomainFinding] {
        let urlPrefixes = ["[内容已读取] 配置 URL：", "[内容已读取] 关联 URL："]
        var findings: [String: LaunchHackDomainFinding] = [:]

        for candidate in model.candidates {
            // 先在单个候选的证据范围内收集 URL 与配置路径，避免把其他候选的配置错误归到同一域名。
            let urls = candidate.evidence.compactMap { evidence -> String? in
                guard let prefix = urlPrefixes.first(where: { evidence.hasPrefix($0) }) else { return nil }
                return String(evidence.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let configPaths = candidate.evidence.compactMap { evidence -> String? in
                let prefix = "[关联配置] "
                guard evidence.hasPrefix(prefix) else { return nil }
                return String(evidence.dropFirst(prefix.count))
            }

            for rawURL in urls {
                guard let components = URLComponents(string: rawURL),
                      let host = components.host?.lowercased(), !host.isEmpty else { continue }
                var finding = findings[host] ?? LaunchHackDomainFinding(
                    host: host, urls: [], configPaths: [], resourcePaths: []
                )
                if !finding.urls.contains(rawURL) { finding.urls.append(rawURL) }
                for configPath in configPaths where !finding.configPaths.contains(configPath) {
                    finding.configPaths.append(configPath)
                }
                finding.resourcePaths.insert(candidate.relativePath)
                findings[host] = finding
            }
        }

        return findings.values.sorted {
            if $0.resourceCount != $1.resourceCount { return $0.resourceCount > $1.resourceCount }
            return $0.host.localizedStandardCompare($1.host) == .orderedAscending
        }
    }

    /// LaunchHack 始终跟随主页当前选中的单个目标，不读取批量勾选范围。
    private var selectedApps: [ContainerInfo] {
        guard state.targetChosen, !state.isWhitelisted(state.target.bundleID) else { return [] }
        return model.apps.filter { $0.bundleID == state.target.bundleID }
    }

    @ViewBuilder
    private var scanSections: some View {
        introduction
        scanPanel
        if !model.candidates.isEmpty {
            sourceIntelPanel
        }
    }

    @ViewBuilder
    private var resultSections: some View {
        tracePanel
        if !model.candidates.isEmpty {
            candidatePanel
        }
        draftPanel
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    scanSections
                    resultSections
                }
                .padding(16)
                .frame(maxWidth: 720)
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
        .confirmationDialog("将精准定位的广告资源同步到 LaunchShield？",
                            isPresented: Binding(
                                get: { pendingRuleCandidate != nil },
                                set: { if !$0 { pendingRuleCandidate = nil } }
                            ),
                            titleVisibility: .visible) {
            Button("备份、清零并冻结", role: .destructive) {
                if let candidate = pendingRuleCandidate,
                   let bundleID = candidate.bundleID {
                    state.importLaunchHackCandidate(bundleID: bundleID,
                                                     appName: candidate.appName,
                                                     relativePath: candidate.relativePath,
                                                     expectedSize: candidate.size,
                                                     expectedModifiedAt: candidate.modifiedAt,
                                                     expectedMD5: candidate.md5)
                }
                pendingRuleCandidate = nil
            }
            Button("取消", role: .cancel) { pendingRuleCandidate = nil }
        } message: {
            Text("仅对已关联宿主 App 的图片/视频资源执行。LaunchShield 会先校验文件、备份原件，再清零并冻结；配置文件和未关联共享组不会直接执行。")
        }
        .confirmationDialog("上传本次识别数据？", isPresented: $showUploadConfirmation, titleVisibility: .visible) {
            Button("仅上传识别元数据") {
                model.uploadRecognitionData()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("只上传 App 标识、相对路径、文件 MD5、证据标签和脱敏后的 URL；不会上传图片、视频、文件内容或 URL 查询参数。")
        }
    }

    @Environment(\.dismiss) private var dismiss

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentCyan)
                Text("广告检测与资源分析")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.primaryText)
            }
            Text("仅针对 LaunchShield 主页当前选中的 App。通过 WQ 扫描该 App 容器及能够可靠关联的共享组，寻找开屏广告文件、缓存与配置线索。")
                .font(.system(size: 13))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("只读检测 · 不执行冻结 · 不修改目标 App")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentCyan)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var scanPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("扫描范围")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                Spacer()
                Text(selectedApps.first?.name ?? "请先在主页选择一个 App")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentCyan)
                    .lineLimit(1)
            }

            HStack {
                Label(selectedApps.isEmpty ? "未选择目标 App" : "单个目标 App", systemImage: "app")
                Spacer()
                Label("\(selectedApps.first.map { state.associatedGroups(for: $0.bundleID).count } ?? 0) 个关联共享组", systemImage: "folder")
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.secondaryText)

            Button {
                beginScan()
            } label: {
                HStack(spacing: 8) {
                    if model.isScanning {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                    Text(model.isScanning ? "正在扫描…" : "扫描当前 App")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Color.accentCyan, in: RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)
            .disabled(model.isScanning || model.isTracking || selectedApps.isEmpty || !state.channel.isAvailable)

            if model.isScanning {
                ProgressView(value: Double(model.scannedContainers),
                             total: Double(max(model.totalContainers, 1)))
                Text("容器 \(model.scannedContainers)/\(model.totalContainers) · 已访问 \(model.visitedFiles) 个文件")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.secondaryText)
            }

            Text(model.scanMessage)
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .panel()
    }

    private var sourceIntelPanel: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("广告来源线索")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                Spacer()
                Text("静态配置分析")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentCyan)
            }

            Text("以下域名来自目标 App 可读取的 plist、JSON 或 XML 配置内容，并已与候选资源建立关联。它们不是运行时请求记录，不能单凭域名认定为广告服务器。")
                .font(.system(size: 11))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if domainFindings.isEmpty {
                Text("本次扫描没有从可读取配置中提取到可关联的域名。动态下发、加密配置或不可访问的数据仍可能存在。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
            } else {
                ForEach(domainFindings.prefix(20)) { finding in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(finding.host)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.primaryText)
                                .textSelection(.enabled)
                            Spacer()
                            Text("\(finding.resourceCount) 个关联资源")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.accentCyan)
                        }
                        ForEach(finding.urls.prefix(3), id: \.self) { url in
                            Text(url)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.secondaryText)
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
                        if !finding.configPaths.isEmpty {
                            Text("关联配置：\(finding.configPaths.prefix(2).joined(separator: "、"))")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.secondaryText)
                                .lineLimit(2)
                        }
                        Text("证据等级：配置引用 · 需要进一步验证")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.orange)
                    }
                    .padding(.vertical, 7)
                    if finding.id != domainFindings.prefix(20).last?.id {
                        Divider().overlay(Color.primaryText.opacity(0.08))
                    }
                }
                if domainFindings.count > 20 {
                    Text("另有 \(domainFindings.count - 20) 个域名线索未展开。")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondaryText)
                }
            }
        }
        .padding(16)
        .panel()
    }

    private var tracePanel: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("广告复显追踪")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                Spacer()
                if model.checkpoint(for: .baseline) != nil {
                    Button("清空记录") { model.clearTrace() }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.red)
                }
            }
            Text("按阶段手动记录容器快照。每个阶段与基线比较新增、删除、内容变化及冻结状态变化；不会自动操作目标 App。")
                .font(.system(size: 11))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("MD5 每个检查点最多计算 250 个候选文件（单个不超过 16 MiB，累计不超过 128 MiB）；其余文件按路径、大小、修改时间和冻结状态比较，不能确认元数据完全相同的内容替换。")
                .font(.system(size: 10))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                model.captureCheckpoint(stage: .baseline, targets: trackingTargets, channel: state.channel)
            } label: {
                Label(model.checkpoint(for: .baseline) == nil ? "建立基线" : "重新建立基线（清除旧阶段）",
                      systemImage: "flag.checkered")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.accentCyan)
            .disabled(model.isTracking || model.isScanning || !state.channel.isAvailable)

            HStack(spacing: 7) {
                ForEach([LaunchHackTraceStage.afterFreeze, .afterRestart, .adReappeared]) { stage in
                    Button(stage.title) {
                        model.captureCheckpoint(stage: stage, targets: trackingTargets, channel: state.channel)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.checkpoint(for: stage) == nil ? Color.accentCyan : Color.primaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.primaryText.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    .disabled(model.isTracking || model.isScanning || model.checkpoint(for: .baseline) == nil || !state.channel.isAvailable)
                }
            }

            if model.isTracking {
                ProgressView()
            }
            Text(model.trackingMessage)
                .font(.system(size: 11))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if model.checkpoint(for: .baseline) != nil {
                Picker("对比阶段", selection: $selectedTraceStage) {
                    Text("冻结后").tag(LaunchHackTraceStage.afterFreeze)
                    Text("重启后").tag(LaunchHackTraceStage.afterRestart)
                    Text("复显后").tag(LaunchHackTraceStage.adReappeared)
                }
                .pickerStyle(.segmented)

                if let result = model.traceChanges(for: selectedTraceStage) {
                    let added = result.changes.filter { $0.status.contains("新增") }.count
                    let deleted = result.changes.filter { $0.status.contains("删除") }.count
                    let replaced = result.changes.filter { $0.status.contains("内容替换") }.count
                    let frozen = result.changes.filter { $0.status.contains("冻结状态变化") }.count
                    let candidateMatched = result.changes.filter { isCandidateTraceMatch($0) }.count
                    HStack(spacing: 8) {
                        traceMetric("新增", added)
                        traceMetric("删除", deleted)
                        traceMetric("内容替换", replaced)
                        traceMetric("冻结变化", frozen)
                    }
                    Text("其中 \(candidateMatched) 项与当前扫描候选资源路径匹配（仅表示路径关联，仍需人工确认）。")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondaryText)
                    if !result.incomplete.isEmpty {
                        Text("有 \(result.incomplete.count) 个容器扫描不完整或缺少对应检查点，已跳过这些容器的差异判断。")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.orange)
                    }
                    if result.changes.isEmpty {
                        Text("该阶段没有检测到可比较的文件变化。")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondaryText)
                    } else {
                        ForEach(result.changes.prefix(35)) { change in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .top) {
                                    Text(change.status)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(change.status.contains("新增") ? Color.accentCyan : Color.primaryText)
                                    Spacer()
                                    Text(change.containerName)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.secondaryText)
                                }
                                Text(change.relativePath)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Color.secondaryText)
                                    .textSelection(.enabled)
                                if isCandidateTraceMatch(change) {
                                    Text("与当前扫描候选资源匹配 · 待人工确认")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Color.accentCyan)
                                }
                                Text(change.detail)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.secondaryText)
                            }
                            .padding(.vertical, 5)
                        }
                        if result.changes.count > 35 {
                            Text("仅显示前 35 项，共 \(result.changes.count) 项变化。")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.secondaryText)
                        }
                    }
                } else {
                    Text("尚未记录「\(selectedTraceStage.title)」阶段。")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondaryText)
                }
            }
        }
        .padding(16)
        .panel()
    }

    private func isCandidateTraceMatch(_ change: LaunchHackTraceChange) -> Bool {
        model.candidates.contains {
            $0.appName == change.containerName && $0.relativePath == change.relativePath
        }
    }

    private func traceMetric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(Color.secondaryText)
            Text(String(value))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trackingTargets: [LaunchHackScanTarget] {
        var targets: [LaunchHackScanTarget] = []
        for app in selectedApps {
            targets.append(LaunchHackScanTarget(bundleID: app.bundleID, appName: app.name,
                                                 rootPath: app.path, groupID: nil))
            // 只纳入 AppState 已按容器标识关联的共享组，不扫描其他 App 的共享容器。
            targets.append(contentsOf: state.associatedGroups(for: app.bundleID).filter { !$0.path.isEmpty }.map {
                LaunchHackScanTarget(bundleID: nil, appName: "共享容器 · \($0.bundleID)",
                                     rootPath: $0.path, groupID: $0.bundleID)
            })
        }
        var seen = Set<String>()
        return targets.filter { seen.insert($0.rootPath).inserted }
    }

    private var candidatePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("发现的候选资源")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                Spacer()
                Text("\(model.candidates.count) 项")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryText)
                Button("上传识别数据") {
                    showUploadConfirmation = true
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentCyan)
                .disabled(model.candidates.isEmpty || model.isUploading)
            }
            Text("优先级只用于安排核验顺序，不代表广告已被确认。[内容已读取] 表示读取到的配置内容；[关联证据] 表示配置与本地资源存在文件名或 URL-MD5 对应；[路径推测] 仅依据路径特征。")
                .font(.system(size: 10))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if !model.uploadMessage.isEmpty {
                Text(model.uploadMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(model.uploadMessage.contains("成功") ? Color.green : Color.secondaryText)
            }

            ForEach(model.candidates) { candidate in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(candidate.appName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.primaryText)
                            Text(candidate.relativePath)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.secondaryText)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 8)
                        Text(candidate.priorityText)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(candidate.score >= 80 ? Color.green : Color.accentCyan)
                    }
                    HStack(spacing: 10) {
                        Text(candidate.kindText)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: candidate.size), countStyle: .file))
                        Text(candidate.isFrozen ? "已冻结" : "未冻结")
                        if candidate.md5 != nil { Text("已计算 MD5") }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondaryText)

                    if let details = candidate.mediaDetails {
                        Text(details)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.primaryText)
                        if let data = candidate.previewData, let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .frame(maxHeight: 150)
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                    }

                    ForEach(candidate.evidence, id: \.self) { evidence in
                        Text("• \(evidence)")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondaryText)
                    }

                    HStack {
                        Button("加入规则草稿") {
                            model.addDraft(candidate)
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentCyan)

                        if let bundleID = candidate.bundleID,
                           FileKind.of(candidate.relativePath) == .image || FileKind.of(candidate.relativePath) == .video {
                            Button("同步到 LaunchShield 并冻结") {
                                pendingRuleCandidate = candidate
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.accentCyan)
                        } else if candidate.groupID != nil {
                            Text("共享组未关联宿主 App，暂不能执行")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.orange)
                        } else {
                            Text("配置/索引仅作定位证据")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.secondaryText)
                        }

                        Spacer()
                        if let md5 = candidate.md5 {
                            Button("复制 MD5") { UIPasteboard.general.string = md5 }
                                .font(.system(size: 11))
                                .foregroundStyle(Color.secondaryText)
                        }
                    }
                }
                .padding(.vertical, 10)
                if candidate.id != model.candidates.last?.id {
                    Divider().overlay(Color.primaryText.opacity(0.06))
                }
            }
        }
        .padding(16)
        .panel()
    }

    private var draftPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("本地规则草稿")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                Spacer()
                Text("\(model.drafts.count) 项")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryText)
            }

            if model.drafts.isEmpty {
                Text("扫描到候选资源后，可以手动加入草稿。草稿保存在本机，不会自动进入正式冻结规则。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
            } else {
                ForEach(model.drafts) { draft in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(draft.candidate.appName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.primaryText)
                        Text(draft.candidate.relativePath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.secondaryText)
                            .textSelection(.enabled)
                        HStack {
                            Text(draft.status)
                            Spacer()
                            Button("移除") { model.removeDraft(draft) }
                                .foregroundStyle(Color.red)
                        }
                        .font(.system(size: 11))
                    }
                    .padding(.vertical, 7)
                }
            }
        }
        .padding(16)
        .panel()
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
        let targets = trackingTargets
        guard !selectedApps.isEmpty, !targets.isEmpty else {
            model.scanMessage = "请先返回 LaunchShield 主页，选择一个可访问的用户 App。"
            return
        }
        model.scan(targets: targets, channel: state.channel)
    }
}
