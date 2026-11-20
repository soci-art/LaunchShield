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
    private static func assess(relativePath: String) -> (score: Int, evidence: [String]) {
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
    @Published var apps: [ContainerInfo] = []
    @Published var candidates: [LaunchHackCandidate] = []
    @Published var drafts: [LaunchHackRuleDraft] = LaunchHackDraftStore.load()
    @Published var isScanning = false
    @Published var scannedContainers = 0
    @Published var totalContainers = 0
    @Published var visitedFiles = 0
    @Published var scanMessage = "扫描只读取 WQ 当前可访问的容器，不会修改目标 App 文件。"

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

    func removeDraft(_ draft: LaunchHackRuleDraft) {
        drafts.removeAll { $0.id == draft.id }
        LaunchHackDraftStore.save(drafts)
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
    @State private var selectedBundleIDs: Set<String> = []
    @State private var selectionInitialized = false
    @State private var showAppSelection = false

    private var selectedApps: [ContainerInfo] {
        model.apps.filter { selectedBundleIDs.contains($0.bundleID) && !state.isWhitelisted($0.bundleID) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    introduction
                    scanPanel
                    if !model.candidates.isEmpty {
                        candidatePanel
                    }
                    draftPanel
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
            initializeSelectionIfNeeded()
        }
        .sheet(isPresented: $showAppSelection) {
            appSelectionSheet
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
            Text("面向所有已安装 App。通过 WQ 扫描当前可访问的应用容器和关联资源，寻找开屏广告文件、缓存与配置线索。")
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
                Button("选择应用") { showAppSelection = true }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentCyan)
            }

            HStack {
                Label("\(selectedApps.count) 个应用", systemImage: "app")
                Spacer()
                Label("\(state.groupContainers.count) 个共享组", systemImage: "folder")
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
                    Text(model.isScanning ? "正在扫描…" : "扫描所有选中 App")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Color.accentCyan, in: RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)
            .disabled(model.isScanning || !state.channel.isAvailable)

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
            }
            Text("优先级只用于安排核验顺序，不代表广告已被确认。[内容已读取] 表示读取到的配置内容；[关联证据] 表示配置与本地资源存在文件名或 URL-MD5 对应；[路径推测] 仅依据路径特征。")
                .font(.system(size: 10))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

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

    private var appSelectionSheet: some View {
        NavigationStack {
            List {
                Section {
                    Button("全选所有用户 App") {
                        selectedBundleIDs = Set(model.apps.map(\.bundleID))
                    }
                    Button("清空选择") {
                        selectedBundleIDs.removeAll()
                    }
                }
                Section("用户 App") {
                    ForEach(model.apps) { app in
                        Toggle(isOn: Binding(
                            get: { selectedBundleIDs.contains(app.bundleID) },
                            set: { selected in
                                if selected { selectedBundleIDs.insert(app.bundleID) }
                                else { selectedBundleIDs.remove(app.bundleID) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name)
                                Text(app.bundleID)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(state.isWhitelisted(app.bundleID))
                    }
                }
            }
            .navigationTitle("选择扫描应用")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showAppSelection = false }
                }
            }
        }
    }

    private func loadApps() {
        if state.didLoadContainers {
            model.setApps(state.containers)
            initializeSelectionIfNeeded()
        } else {
            state.refreshContainers {
                model.setApps(state.containers)
                initializeSelectionIfNeeded()
            }
        }
    }

    private func initializeSelectionIfNeeded() {
        guard !selectionInitialized, !model.apps.isEmpty else { return }
        selectedBundleIDs = Set(model.apps.map(\.bundleID))
        selectionInitialized = true
    }

    private func beginScan() {
        let apps = selectedApps
        guard !apps.isEmpty else {
            model.scanMessage = "请至少选择一个用户 App。"
            return
        }

        var targets = apps.map {
            LaunchHackScanTarget(bundleID: $0.bundleID, appName: $0.name,
                                 rootPath: $0.path, groupID: nil)
        }
        // 共享组独立扫描，先记录真实 groupID，不伪造宿主 App 归属。
        let groups = state.groupContainers.filter { !$0.path.isEmpty }
        targets.append(contentsOf: groups.map {
            LaunchHackScanTarget(bundleID: nil, appName: "共享容器 · \($0.bundleID)",
                                 rootPath: $0.path, groupID: $0.bundleID)
        })
        var seen = Set<String>()
        targets = targets.filter { seen.insert($0.rootPath).inserted }
        model.scan(targets: targets, channel: state.channel)
    }
}
