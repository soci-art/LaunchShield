import SwiftUI
import UIKit

struct ContentView: View {
    @State private var showUnavailableAlert = false
    @State private var logs: [LogEntry] = [
        LogEntry(time: "刚刚", message: "LaunchShield 测试版已启动", kind: .info),
        LogEntry(time: "刚刚", message: "当前为界面预览，文件访问功能尚未接入", kind: .notice)
    ]

    private let targetName = "百度网盘"
    private let bundleID = "com.baidu.netdisk"

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    targetCard
                    summarySection
                    actionsSection
                    logSection
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 30)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
        }
        .alert("功能尚未接入", isPresented: $showUnavailableAlert) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text("当前版本先完成界面。文件扫描、备份、清零和还原模块尚未接入，不会修改百度网盘中的任何文件。")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(LinearGradient(colors: [Color.cyan.opacity(0.95), Color.blue.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 54, height: 54)
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("LaunchShield")
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("测试版")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.cyan)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.cyan.opacity(0.13), in: Capsule())
                }
                Text("启动素材管理工具")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondaryText)
            }
            Spacer()
            Circle().fill(Color.orange).frame(width: 7, height: 7)
            Text("预览模式")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.secondaryText)
        }
    }

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("当前目标应用", systemImage: "app.badge")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.secondaryText)
                Spacer()
                Text("首测目标")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.cyan)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Color.cyan.opacity(0.12), in: Capsule())
            }
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 54, height: 54)
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 25))
                        .foregroundStyle(Color.white.opacity(0.88))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(targetName).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    Text(bundleID).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.secondaryText.opacity(0.7))
            }
            Divider().overlay(Color.white.opacity(0.07))
            Label("操作前请先完全退出百度网盘", systemImage: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
        }
        .padding(17)
        .background(Color.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("素材清单", subtitle: "扫描到的文件会按来源分类显示")
            HStack(spacing: 10) {
                SummaryTile(title: "文件总数", value: "—", detail: "等待扫描", symbol: "doc.text.magnifyingglass", tint: .cyan)
                SummaryTile(title: "待清理", value: "—", detail: "尚未计算", symbol: "sparkles", tint: .orange)
                SummaryTile(title: "已备份", value: "0", detail: "份", symbol: "externaldrive", tint: .green)
            }
            VStack(spacing: 0) {
                SourceRow(name: "百度自营开屏素材", path: "SDImageCache", symbol: "building.2.crop.circle", tint: .cyan)
                rowDivider
                SourceRow(name: "优量汇", path: "tencent_gdtimg · tencent_gdtres", symbol: "rectangle.stack", tint: .blue)
                rowDivider
                SourceRow(name: "穿山甲", path: "CSJDImageCache", symbol: "leaf", tint: .green)
                rowDivider
                SourceRow(name: "BeiZi", path: "BeiZiMaterial", symbol: "square.grid.2x2", tint: .orange)
            }
            .padding(.horizontal, 15)
            .background(Color.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.06), lineWidth: 1))
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("操作", subtitle: "每个文件独立备份与处理")
            Button { showUnavailableAlert = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "eraser.fill").font(.system(size: 18, weight: .semibold))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("全部清零").font(.system(size: 16, weight: .semibold))
                        Text("先备份，再将素材文件清空").font(.system(size: 11)).foregroundStyle(.white.opacity(0.76))
                    }
                    Spacer()
                    Image(systemName: "arrow.right").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white).padding(.horizontal, 17).frame(height: 68)
                .background(LinearGradient(colors: [Color.cyan.opacity(0.88), Color.blue.opacity(0.82)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
            Button { showUnavailableAlert = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.uturn.backward.circle").font(.system(size: 19, weight: .semibold))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("全部还原").font(.system(size: 16, weight: .semibold))
                        Text("将已备份的素材逐个写回").font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "arrow.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.secondaryText)
                }
                .foregroundStyle(.white).padding(.horizontal, 17).frame(height: 68)
                .background(Color.panel, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.white.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("运行日志", subtitle: "记录操作结果与失败原因")
                Spacer()
                Button {
                    UIPasteboard.general.string = logs.map { "[\($0.time)] \($0.message)" }.joined(separator: "\n")
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.cyan)
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(logs) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(item.kind.tint).frame(width: 7, height: 7).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.message).font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.88)).fixedSize(horizontal: false, vertical: true)
                            Text(item.time).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.secondaryText.opacity(0.75))
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.06), lineWidth: 1))
        }
    }

    private var footer: some View {
        HStack {
            Text("LaunchShield · 测试版")
            Spacer()
            Text("界面原型 0.1.0")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Color.secondaryText.opacity(0.65))
        .padding(.top, 2)
    }

    private var rowDivider: some View {
        Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 39)
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(Color.secondaryText)
        }
    }
}

private struct SummaryTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.white.opacity(0.88))
                Text(detail).font(.system(size: 9)).foregroundStyle(Color.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(13)
        .background(Color.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}

private struct SourceRow: View {
    let name: String
    let path: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(tint).frame(width: 28, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                Text(path).font(.system(size: 10)).foregroundStyle(Color.secondaryText).lineLimit(1)
            }
            Spacer()
            Text("未扫描").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.secondaryText)
        }
        .padding(.vertical, 11)
    }
}

private struct LogEntry: Identifiable {
    enum Kind {
        case info, notice
        var tint: Color { self == .info ? .cyan : .orange }
    }
    let id = UUID()
    let time: String
    let message: String
    let kind: Kind
}

private extension Color {
    static let appBackground = Color(red: 0.045, green: 0.055, blue: 0.075)
    static let panel = Color(red: 0.085, green: 0.10, blue: 0.13)
    static let secondaryText = Color(red: 0.58, green: 0.63, blue: 0.70)
}

#Preview {
    ContentView()
}
