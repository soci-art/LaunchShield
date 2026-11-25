import SwiftUI
import UIKit

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct LogsView: View {
    @EnvironmentObject private var state: AppState

    @State private var shareItem: ShareItem?
    @State private var showClear = false
    @State private var showExportOptions = false
    @State private var showStoreUpload = false

    var body: some View {
        SheetPage("运行日志") {
            VStack(spacing: 12) {
                diagnostics
                HStack(spacing: 10) {
                    actionButton("复制全部", symbol: "doc.on.doc") {
                        UIPasteboard.general.string = state.exportLogText()
                    }
                    actionButton("导出", symbol: "square.and.arrow.up") {
                        showExportOptions = true
                    }
                    actionButton("清空", symbol: "trash") {
                        showClear = true
                    }
                }
                actionButton("上传诊断文件", symbol: "doc.badge.gearshape") {
                    showStoreUpload = true
                }
                LogTable(logs: state.logs)
            }
            .padding(20)
        }
        .appAlert(state, active: shareItem == nil)
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        // 弹窗重构（Grace 2026-11-26）：导出/清空/上传诊断统一走居中
        // 卡片对话框（诊断上传原来那张自家卡片就此并入同一套组件）。
        .overlay {
            if showExportOptions {
                AppDialog(icon: "square.and.arrow.up",
                          title: "导出日志",
                          message: "选一个方式把日志拿出来。",
                          actions: [
                              AppDialogAction(title: "分享或保存") {
                                  showExportOptions = false
                                  export()
                              },
                              AppDialogAction(title: "上传", style: .quiet) {
                                  showExportOptions = false
                                  state.uploadLog()
                              }
                          ],
                          onCancel: { showExportOptions = false })
            } else if showClear {
                AppDialog(icon: "trash", iconTint: .red,
                          title: "清空日志？",
                          actions: [AppDialogAction(title: "清空", style: .destructive) {
                              showClear = false
                              state.logs.clear()
                          }],
                          onCancel: { showClear = false })
            } else if showStoreUpload {
                AppDialog(icon: "doc.badge.gearshape",
                          title: "上传诊断文件？",
                          actions: [AppDialogAction(title: "上传") {
                              showStoreUpload = false
                              state.uploadDiagnosticStore()
                          }],
                          onCancel: { showStoreUpload = false })
            }
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 10) {
            InfoLine(label: "应用版本", value: state.appVersionText)
            InfoLine(label: "系统版本", value: state.systemText)
            InfoLine(label: "设备", value: UIDevice.current.model)
            InfoLine(label: "访问路线", value: state.channel.routeDetail)
            InfoLine(label: "共享组", value: state.channel.groupText)
            InfoLine(label: "应用容器", value: "\(state.containers.count) 个")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func actionButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Color.accentCyan)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(Color.accentCyan.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func export() {
        let text = state.exportLogText()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchShield-日志.txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            shareItem = ShareItem(url: url)
        } catch {
            state.log("导出日志失败：\(error.localizedDescription)", .warning)
        }
    }
}

struct LogTable: View {
    @ObservedObject var logs: LogStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if logs.lines.isEmpty {
                    Text("还没有日志。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondaryText)
                } else {
                    ForEach(logs.lines.reversed()) { line in
                        HStack(alignment: .top, spacing: 9) {
                            Circle()
                                .fill(logTint(line.level))
                                .frame(width: 6, height: 6)
                                .padding(.top, 5)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(line.message)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.primaryText.opacity(0.9))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("\(Format.fullDate(line.date)) · \(line.level.label)")
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
}
