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
                        referenceText: Set<String>) -> LaunchHackVisualMatch? {
        let kind = FileKind.of(relativePath)
        guard kind == .image || kind == .video else { return nil }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchHackVisual-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let ext = (relativePath as NSString).pathExtension
            let localURL = folder.appendingPathComponent("asset.\(ext.isEmpty ? "bin" : ext)")
            try channel.copyToLocal(path: path, destination: localURL.path)
            let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
            guard size > 0, size <= 40 * 1024 * 1024 else { return nil }

            var frames: [CGImage] = []
            var detail = ""
            if kind == .image {
                guard let source = CGImageSourceCreateWithURL(localURL as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
                frames = [image]
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? image.width
                let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? image.height
                detail = "图片 · \(width) × \(height)"
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

@MainActor
private final class LaunchHackModel: ObservableObject {
    @Published var candidates: [LaunchHackCandidate] = []
    @Published var isRunning = false
    @Published var visitedFiles = 0
    @Published var checkedMedia = 0
    @Published var totalContainers = 0
    @Published var status = "导入广告截图后，LaunchHack 会自动检索可访问的应用容器。"
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
        var targets: [LaunchHackScanTarget] = []
        let allowedApps = containers.filter { !$0.isGroup && !AppState.isSystemApp($0) }
        for app in allowedApps where !state.isWhitelisted(app.bundleID) {
            targets.append(LaunchHackScanTarget(bundleID: app.bundleID, appName: app.name,
                                                 rootPath: app.path, groupID: nil))
            for group in state.associatedGroups(for: app.bundleID) where !group.path.isEmpty {
                targets.append(LaunchHackScanTarget(bundleID: app.bundleID,
                    appName: app.name + "（共享容器）", rootPath: group.path, groupID: group.bundleID))
            }
        }
        var seen = Set<String>()
        targets = targets.filter { seen.insert($0.rootPath).inserted }
        guard !targets.isEmpty else {
            status = "没有可访问的用户应用容器。请确认签名通道已就绪。"
            return
        }

        isRunning = true
        candidates = []
        visitedFiles = 0
        checkedMedia = 0
        totalContainers = targets.count
        status = "正在分析截图并检索 \(targets.count) 个应用/共享容器…"
        onLog?("LaunchHack 截图流水线启动：\(targets.count) 个容器，OCR 提取 \(referenceText.count) 个文本词项", .info)
        let channel = state.channel

        DispatchQueue.global(qos: .userInitiated).async {
            var matches: [LaunchHackCandidate] = []
            var visited = 0
            var mediaCount = 0
            var hitCap = false
            var failures: [String] = []
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
                    for file in files where !file.isDirectory && !file.isSymlink
                        && file.path.hasPrefix(target.rootPath + "/")
                        && !PersonalMedia.isPersonal(bundleID: target.bundleID,
                            relativePath: String(file.path.dropFirst(target.rootPath.count + 1))) {
                        let relative = String(file.path.dropFirst(target.rootPath.count + 1))
                        let kind = FileKind.of(relative)
                        guard kind == .image || kind == .video,
                              file.size > 0, file.size <= 40 * 1024 * 1024 else { continue }
                        // 分析上限单列：撞上时要留标记，完成状态必须明说
                        // 后面的应用没检查，不许静默截断、假装查全了。
                        if mediaCount >= 320 { hitCap = true; continue }
                        mediaCount += 1
                        if mediaCount % 20 == 0 {
                            let snapshot = mediaCount
                            DispatchQueue.main.async { self.checkedMedia = snapshot }
                        }
                        guard let match = LaunchHackVisualMatcher.inspect(path: file.path,
                            relativePath: relative, channel: channel,
                            reference: referenceFeature, referenceText: referenceText),
                              match.isStrong else { continue }
                        let md5 = file.size <= 32 * 1024 * 1024 ? try? channel.md5(file.path) : nil
                        let candidate = LaunchHackCandidate(bundleID: target.bundleID,
                            groupID: target.groupID, appName: target.appName,
                            relativePath: relative, size: file.size, modifiedAt: file.modified,
                            md5: md5, isFrozen: channel.isImmutable(file.path),
                            score: match.score, evidence: match.evidence,
                            mediaDetails: match.mediaDetails, previewData: match.previewData)
                        matches.append(candidate)
                    }
                } catch {
                    failures.append("\(target.appName)：\(error.localizedDescription)")
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
                var statusText = failures.isEmpty
                    ? "检索完成：分析 \(mediaCount) 个媒体文件，找到 \(ordered.count) 个高置信度匹配。"
                    : "检索完成但有 \(failures.count) 个容器未能完整读取；结果可能不完整。"
                if hitCap {
                    statusText += "已达到 320 个媒体文件的分析上限，后面的应用没有检查，结果不完整。"
                }
                self.status = statusText
                self.onLog?(statusText, (failures.isEmpty && !hitCap) ? .success : .warning)
                if hitCap {
                    self.onLog?("LaunchHack 已达媒体分析上限（320 个），后续应用未检查", .warning)
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
            Text("只需导入真实广告界面截图。LaunchHack 自动提取视觉与文字特征，检索可访问的应用资源，并将高置信度匹配结果同步到 LaunchShield。")
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
                ProgressView()
                Text("已访问 \(model.visitedFiles) 个文件，已分析 \(model.checkedMedia) 个媒体资源")
                    .font(.system(size: 11)).foregroundStyle(Color.secondaryText)
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
