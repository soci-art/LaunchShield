import SwiftUI
import UIKit
import AVFoundation

extension Color {
    /// 界面颜色跟着系统走：浅色模式下自动变浅，不再写死深色。
    static let appBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1)
            : UIColor(red: 0.929, green: 0.969, blue: 0.957, alpha: 1)
    })
    static let panel = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.066, green: 0.066, blue: 0.066, alpha: 1)
            : UIColor.white
    })
    static let secondaryText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.62, green: 0.62, blue: 0.62, alpha: 1)
            : UIColor(red: 0.322, green: 0.478, blue: 0.447, alpha: 1)
    })
    static let primaryText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white
            : UIColor(red: 0.031, green: 0.082, blue: 0.070, alpha: 1)
    })
    /// 主题强调色：薄荷青（Grace 2026-11-26 定）——深色亮薄荷、浅色深青。
    /// 名字还叫 accentCyan 是历史包袱：全 App 都引这个名，逐处改名风险大，
    /// 只换它的值。广告商图标的一家一色和删除按钮的红不在此列、保持原样。
    static let accentCyan = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.176, green: 0.831, blue: 0.749, alpha: 1)
            : UIColor(red: 0.051, green: 0.580, blue: 0.533, alpha: 1)
    })
    /// 强调色的淡底版（卡片底、胶囊底、顶部光晕用）：深色模式不带绿，
    /// 用白色淡底（压在纯黑上是浅灰）；浅色模式才是薄荷淡底。
    /// Grace 2026-11-26 定：深色就纯黑，绿只留强调色本体。
    static let accentWash = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white
            : UIColor(red: 0.051, green: 0.580, blue: 0.533, alpha: 1)
    })
}

func recipeTint(_ state: RecipeState) -> Color {
    switch state {
    case .normal: return .secondaryText
    case .frozen: return .accentCyan
    case .recurred: return .orange
    case .placeholder: return .secondaryText
    case .missing: return .red
    case .unknown: return .secondaryText
    }
}

func logTint(_ level: LogLevel) -> Color {
    switch level {
    case .info: return .secondaryText
    case .notice: return .primaryText
    case .success: return .accentCyan
    case .warning: return .orange
    }
}

struct PanelModifier: ViewModifier {
    var radius: CGFloat = 16

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
    func panel(radius: CGFloat = 16) -> some View {
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
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primaryText.opacity(0.88))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .panel(radius: 16)
    }
}

extension View {
    /// 全局提示弹窗：同一时间只许最上面那一页的那一份是活的（active）。
    /// 教训：七份一起活，系统挑了主页那份弹，子页面被连带关掉（构建 15
    /// 日志页实测）；只留主页一份，子页面里出结果时主页那份一弹，子页面
    /// 照样被关（构建 19 找广告页实测）。所以每页都挂，但靠 active 保证
    /// 只有最上层那份能弹：主页在任一子页面打开时不活，子页面在它自己的
    /// 下级页面打开时不活。
    func appAlert(_ state: AppState, active: Bool = true) -> some View {
        overlay {
            if active, let text = state.alertText {
                AppDialog(icon: "info.circle", title: "提醒", message: text,
                          actions: [AppDialogAction(title: "好") { state.alertText = nil }],
                          cancelTitle: nil)
            }
        }
    }

    /// 更新提醒弹窗（清单第 12 条）：只显示一句话，不带版本号和说明，
    /// 按钮只有「更新」和「取消」。
    func updateAlert(_ state: AppState, active: Bool = true) -> some View {
        overlay {
            if active, let kind = state.updateAlert {
                AppDialog(icon: "arrow.down.circle", title: "提醒",
                          message: kind == .rules ? "有新规则更新" : "有新版本更新",
                          actions: [AppDialogAction(title: "更新") { state.confirmUpdateAlert() }],
                          onCancel: { state.cancelUpdateAlert() })
            }
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
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(20)
        .frame(maxWidth: 240)
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// 带真进度的等待卡（清单第 22 条）：有总数画条＋已完成/总数，
/// 没总数只报已处理数，数字都是实际数出来的，不估不编。
struct WorkProgressOverlay: View {
    let progress: WorkProgress

    var body: some View {
        VStack(spacing: 10) {
            Text(progress.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .truncationMode(.tail)
            if let total = progress.total, total > 0 {
                ProgressView(value: Double(min(progress.done, total)), total: Double(total))
                    .tint(.white)
            } else {
                ProgressView()
                    .tint(.white)
            }
            Text(progress.fractionText)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            if let detail = progress.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(20)
        .frame(maxWidth: 280)
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct InfoLine: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(logTint(line.level))
                            .frame(width: 6, height: 6)
                            .padding(.top, 4)
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
            RoundedRectangle(cornerRadius: 8, style: .continuous)
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
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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

/// 对话框按钮（居中卡片对话框专用）：整块都是按钮，不只是文字能点。
struct AppDialogAction {
    enum Style { case normal, destructive, quiet }
    let title: String
    var style: Style = .normal
    let handler: () -> Void
}

/// 居中卡片对话框（弹窗重构定稿，Grace 2026-11-26）：全 App 的确认框
/// 和提示框统一用它，不再用系统对话框。图标＋居中标题＋居中说明＋
/// 整块按钮；危险操作红按钮；取消单独一张卡放在下面。和第 27 条
/// 「上传诊断文件」那张自家卡片同一套样子，这次全 App 统一。
struct AppDialog: View {
    var icon: String = "info.circle"
    var iconTint: Color = .accentCyan
    let title: String
    var message: String? = nil
    let actions: [AppDialogAction]
    var cancelTitle: String? = "取消"
    var onCancel: () -> Void = {}

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
            VStack(spacing: 10) {
                VStack(spacing: 0) {
                    ZStack {
                        Circle().fill(iconTint.opacity(0.13))
                        Image(systemName: icon)
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(iconTint)
                    }
                    .frame(width: 52, height: 52)
                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.primaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 13)
                    if let message {
                        Text(message)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.secondaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 9)
                    }
                    VStack(spacing: 10) {
                        ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                            Button {
                                action.handler()
                            } label: {
                                Text(action.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(textColor(action.style))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)
                                    .background(background(action.style), in: Capsule())
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 18)
                }
                .padding(22)
                .frame(maxWidth: .infinity)
                .panel(radius: 28)
                if let cancelTitle {
                    Button {
                        onCancel()
                    } label: {
                        Text(cancelTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.primaryText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .panel(radius: 26)
                }
            }
            .frame(maxWidth: 340)
            .padding(.horizontal, 36)
        }
    }

    private func background(_ style: AppDialogAction.Style) -> Color {
        switch style {
        case .normal: return Color.primaryText
        case .destructive: return Color.red.opacity(0.16)
        case .quiet: return Color.primaryText.opacity(0.07)
        }
    }

    private func textColor(_ style: AppDialogAction.Style) -> Color {
        switch style {
        case .normal: return Color.appBackground
        case .destructive: return .red
        case .quiet: return Color.primaryText
        }
    }
}

/// 固定尺寸的开关：系统 Toggle 在白名单列表里会被拉成长胶囊
/// （0.3.1 真机实测），自己画一个 51×31 的，整块都能点，大小不变。
struct SwitchToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color.accentCyan : Color.primaryText.opacity(0.18))
                Circle()
                    .fill(Color.white)
                    .frame(width: 27, height: 27)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .padding(2)
            }
            .frame(width: 51, height: 31)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        ZStack {
            Color.appBackground.ignoresSafeArea()
            NavigationStack {
                content
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("关闭") { dismiss() }
                                .foregroundStyle(Color.accentCyan)
                        }
                    }
            }
            // 宽屏封顶居中（清单第 28 条）：折叠屏展开、横屏时整页
            // 最多 620 宽、居中，和主页一致；推进来的子页同样受限，
            // 不让卡片和行在宽屏上无限拉满。背景在外层照旧铺满。
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
    }
}
