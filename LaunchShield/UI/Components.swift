import SwiftUI
import UIKit
import AVFoundation

extension Color {
    /// 界面颜色跟着系统走：浅色模式下自动变浅，不再写死深色。
    static let appBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.045, green: 0.055, blue: 0.075, alpha: 1)
            : UIColor(red: 0.945, green: 0.953, blue: 0.965, alpha: 1)
    })
    static let panel = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.085, green: 0.10, blue: 0.13, alpha: 1)
            : UIColor.white
    })
    static let secondaryText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.58, green: 0.63, blue: 0.70, alpha: 1)
            : UIColor(red: 0.38, green: 0.42, blue: 0.48, alpha: 1)
    })
    static let primaryText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white
            : UIColor(red: 0.07, green: 0.09, blue: 0.12, alpha: 1)
    })
    static let accentCyan = Color(red: 0.35, green: 0.85, blue: 0.95)
}

func recipeTint(_ state: RecipeState) -> Color {
    switch state {
    case .normal: return .green
    case .frozen: return .cyan
    case .recurred: return .orange
    case .placeholder: return .purple
    case .missing: return .red
    case .unknown: return .secondaryText
    }
}

func logTint(_ level: LogLevel) -> Color {
    switch level {
    case .info: return .secondaryText
    case .notice: return .cyan
    case .success: return .green
    case .warning: return .orange
    }
}

struct PanelModifier: ViewModifier {
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background(Color.panel, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.primaryText.opacity(0.08), lineWidth: 1)
            )
    }
}

extension View {
    func panel(radius: CGFloat = 18) -> some View {
        modifier(PanelModifier(radius: radius))
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.primaryText)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryText)
            }
        }
    }
}

struct StatusBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

struct SummaryTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Color.primaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primaryText.opacity(0.88))
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .panel(radius: 16)
    }
}

extension View {
    /// 全局提示弹窗：原来顶部横幅条的文字现在都在原地用弹窗提醒。
    /// 主页和各个子页面各挂一份，哪个页面在前面就由哪个弹。
    func appAlert(_ state: AppState) -> some View {
        alert("提醒", isPresented: Binding(
            get: { state.alertText != nil },
            set: { if !$0 { state.alertText = nil } }
        )) {
            Button("好") { state.alertText = nil }
        } message: {
            Text(state.alertText ?? "")
        }
    }
}

struct BusyOverlay: View {
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
        .padding(22)
        .frame(maxWidth: 240)
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct InfoLine: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.secondaryText)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(Color.primaryText.opacity(0.9))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LogPreview: View {
    @ObservedObject var logs: LogStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if logs.lines.isEmpty {
                Text("还没有日志。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
            } else {
                ForEach(Array(logs.lines.suffix(4))) { line in
                    HStack(alignment: .top, spacing: 9) {
                        Circle()
                            .fill(logTint(line.level))
                            .frame(width: 6, height: 6)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(line.message)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.primaryText.opacity(0.88))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(Format.time(line.date))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Color.secondaryText.opacity(0.8))
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

struct ThumbnailView: View {
    let path: String
    let kind: FileKind
    var side: CGFloat = 44

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primaryText.opacity(0.06))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: kind.symbol)
                    .font(.system(size: side * 0.34))
                    .foregroundStyle(Color.secondaryText)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .task(id: path) {
            guard kind != .other else { return }
            image = await ThumbnailLoader.load(path: path, kind: kind)
        }
    }
}

enum ThumbnailLoader {
    static func load(path: String, kind: FileKind) async -> UIImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: render(path: path, kind: kind))
            }
        }
    }

    private static func render(path: String, kind: FileKind) -> UIImage? {
        switch kind {
        case .image:
            guard let data = try? Channel.shared.read(path, maxBytes: 16_000_000),
                  let image = UIImage(data: data) else { return nil }
            return downscale(image, to: 240)
        case .video:
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            guard let cgImage = try? generator.copyCGImage(at: CMTime(seconds: 0.2, preferredTimescale: 600),
                                                           actualTime: nil) else { return nil }
            return UIImage(cgImage: cgImage)
        case .other:
            return nil
        }
    }

    private static func downscale(_ image: UIImage, to maxSide: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide, longest > 0 else { return image }
        let scale = maxSide / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A sheet with the app's dark look, a title and a close button.
struct SheetPage<Content: View>: View {
    let title: String
    private let content: Content

    @Environment(\.dismiss) private var dismiss

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()
                content
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(Color.accentCyan)
                }
            }
        }
    }
}

/// The tiny, barely visible host view the PiP window animates from.
struct PiPAnchorView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
        view.backgroundColor = .black
        view.alpha = 0.02
        GuardService.shared.attach(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
