import SwiftUI

struct BackupsView: View {
    @EnvironmentObject private var state: AppState
    @State private var showRestoreAll = false
    @State private var showDeleteAll = false
    @State private var recordToDelete: BackupRecord?

    var body: some View {
        SheetPage("备份记录") {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if state.backups.isEmpty {
                        Text("还没有备份。清零操作会先备份每个文件，备份记录出现在这里。")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondaryText)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .panel()
                    } else {
                        HStack {
                            Text("共 \(state.backups.count) 份，备份里存的是原文件字节；还原后会核对 MD5。")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("全部删除") {
                                showDeleteAll = true
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.red)
                            .buttonStyle(.plain)
                            Button("全部还原") {
                                showRestoreAll = true
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentCyan)
                            .buttonStyle(.plain)
                        }
                        ForEach(state.backups) { record in
                            card(record)
                        }
                    }
                }
                .padding(20)
            }
        }
        .confirmationDialog("确定要全部还原吗？", isPresented: $showRestoreAll, titleVisibility: .visible) {
            Button("逐个写回并核对 MD5", role: .destructive) {
                state.restoreAll()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("请先完全退出目标应用。")
        }
        .confirmationDialog("确定要删除全部备份吗？", isPresented: $showDeleteAll, titleVisibility: .visible) {
            Button("全部删除", role: .destructive) {
                state.deleteAllBackups()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("删了之后，这些素材就没有备份了，之后想还原也还原不了。")
        }
        .confirmationDialog("确定要删除这份备份吗？", isPresented: Binding(
            get: { recordToDelete != nil },
            set: { if !$0 { recordToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let record = recordToDelete { state.deleteBackup(record) }
                recordToDelete = nil
            }
            Button("取消", role: .cancel) { recordToDelete = nil }
        } message: {
            Text("删了之后，这条素材就没有备份了，之后想还原也还原不了。")
        }
    }

    private func card(_ record: BackupRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(record.appName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                StatusBadge(text: record.source, tint: .cyan)
                Spacer()
                Text(record.sizeText)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryText)
            }
            Text(record.relativePath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.8))
                .lineLimit(3)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                Text("MD5 \(record.shortMD5)…")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.secondaryText)
                Text("·")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.secondaryText.opacity(0.6))
                Text(Format.date(record.createdAt))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondaryText)
                Spacer()
                Button("删除") {
                    recordToDelete = record
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.red)
                .buttonStyle(.plain)
                Button("恢复这个") {
                    state.restore(record)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentCyan)
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}
