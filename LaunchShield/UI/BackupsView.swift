import SwiftUI

/// 备份记录（界面重设计定稿，Grace 2026-11-26 亲定）：只到应用一级——
/// 一个应用一行，行尾一个「还原」，把这个应用的备份整包写回；点不进去，
/// 看不到具体备份文件。单个文件的恢复/删除入口随之撤下（底层函数不动），
/// 应用级删除藏在长按菜单里，全部还原/全部删除保留在页首。
struct BackupsView: View {
    @EnvironmentObject private var state: AppState
    @State private var showRestoreAll = false
    @State private var showDeleteAll = false
    @State private var appToDelete: String?
    @State private var appToRestore: String?

    var body: some View {
        SheetPage("备份记录") {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if state.backups.isEmpty {
                        Text("还没有备份。去除操作会先备份每个文件，备份记录出现在这里。")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondaryText)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .panel()
                    } else {
                        summaryCard
                        HStack(spacing: 10) {
                            framedButton("全部删除", tint: Color.red) { showDeleteAll = true }
                            framedButton("全部还原", tint: Color.accentCyan) { showRestoreAll = true }
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(appGroups.enumerated()), id: \.element.bundleID) { index, group in
                                if index > 0 {
                                    Divider().overlay(Color.primaryText.opacity(0.06)).padding(.leading, 60)
                                }
                                appRow(group)
                            }
                        }
                        .padding(.horizontal, 16)
                        .panel()
                        Text("备份里具体是哪些文件看不到，也不用看——还原就是整包写回去。长按一个应用可以删掉它的全部备份。")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
        }
        .appAlert(state)
        .overlay {
            if state.isBusy, let progress = state.workProgress {
                ZStack {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                    WorkProgressOverlay(progress: progress)
                }
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
            Text("会先把备份恢复回文件，再删除备份；恢复失败的那几份会留着不删，并告诉你。数据库文件的备份还原不了、会直接删除；原来的位置已不存在的，也会直接删除。")
        }
        .confirmationDialog("把这个应用的备份全部还原吗？", isPresented: Binding(
            get: { appToRestore != nil },
            set: { if !$0 { appToRestore = nil } }
        ), titleVisibility: .visible) {
            Button("逐个写回并核对 MD5", role: .destructive) {
                if let bundleID = appToRestore,
                   let group = appGroups.first(where: { $0.bundleID == bundleID }) {
                    state.restoreBackups(group.records)
                }
                appToRestore = nil
            }
            Button("取消", role: .cancel) { appToRestore = nil }
        } message: {
            Text("只还原这个应用的备份，其他应用的不动。请先完全退出这个应用。同一文件有多份备份时，写回最早的那份。")
        }
        .confirmationDialog("确定要删除这个应用的全部备份吗？", isPresented: Binding(
            get: { appToDelete != nil },
            set: { if !$0 { appToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("全部删除", role: .destructive) {
                if let bundleID = appToDelete { state.deleteBackups(forApp: bundleID) }
                appToDelete = nil
            }
            Button("取消", role: .cancel) { appToDelete = nil }
        } message: {
            Text("只动这个应用的备份，其他应用的不动。会先把备份恢复回文件，再删除；恢复失败的会留着不删（原来的位置已不存在的直接删除）。")
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(appGroups.count) 个应用有备份")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.primaryText)
            Text("共 \(state.backups.count) 份 · 占用约 \(Format.bytes(state.backups.reduce(0) { $0 + $1.originalSize }))")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func framedButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primaryText.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// 按应用归并：一个应用一行（图标＋名字＋份数/最近时间＋还原）。
    private var appGroups: [(bundleID: String, name: String, records: [BackupRecord])] {
        Dictionary(grouping: state.backups, by: { $0.bundleID }).map { bundleID, records in
            (bundleID: bundleID,
             name: records.first?.appName ?? bundleID,
             records: records.sorted { $0.createdAt > $1.createdAt })
        }.sorted { $0.name < $1.name }
    }

    private func appRow(_ group: (bundleID: String, name: String, records: [BackupRecord])) -> some View {
        HStack(spacing: 12) {
            AppIconView(bundleID: group.bundleID, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.primaryText)
                    .lineLimit(1)
                Text("\(group.records.count) 份 · 最近 \(Format.date(group.records.first?.createdAt ?? Date()))")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryText)
            }
            Spacer(minLength: 8)
            Button {
                appToRestore = group.bundleID
            } label: {
                Text("还原")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appBackground)
                    .padding(.horizontal, 17)
                    .frame(height: 36)
                    .background(Color.primaryText, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                appToRestore = group.bundleID
            } label: {
                Label("还原这个应用的备份", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                appToDelete = group.bundleID
            } label: {
                Label("删除这个应用的备份", systemImage: "trash")
            }
        }
    }
}
