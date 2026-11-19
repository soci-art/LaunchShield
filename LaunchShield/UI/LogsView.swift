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
                VStack(spacing: 6) {
                    actionButton("上传诊断文件", symbol: "doc.badge.gearshape") {
                        showStoreUpload = true
                    }
                    Text("iOS 26 上读不到应用列表时，把系统数据库传给开发者帮忙修。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                LogTable(logs: state.logs)
            }
            .padding(20)
        }
        .appAlert(state, active: shareItem == nil)
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .confirmationDialog("导出日志", isPresented: $showExportOptions, titleVisibility: .visible) {
            Button("分享或保存") {
                export()
            }
            Button("上传") {
                state.uploadLog()
            }
            Button("取消", role: .cancel) { }
        }
        .confirmationDialog("上传诊断文件？", isPresented: $showStoreUpload, titleVisibility: .visible) {
            Button("上传") {
                state.uploadDiagnosticStore()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("会把这台手机的系统应用数据库文件传给开发者，只用来修 iOS 26 读不到应用列表的问题。文件里有这台手机装了哪些应用，不含账号密码和应用里的内容。服务器只存几天就自动删。")
        }
        .confirmationDialog("清空日志？", isPresented: $showClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                state.logs.clear()
            }
            Button("取消", role: .cancel) { }
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
