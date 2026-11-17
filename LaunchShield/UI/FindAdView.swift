import SwiftUI

struct FindAdView: View {
    @EnvironmentObject private var state: AppState
    @State private var showConfirm = false

    var body: some View {
        SheetPage("找广告（前后对比）") {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    guideCard
                    if !state.checkedIDs.isEmpty {
                        appsWithAdsCard
                    }
                    snapshotCard
                    if !state.beforeSnapshots.isEmpty && state.candidates.isEmpty {
                        instructionCard
                    }
                    if !state.candidates.isEmpty {
                        candidateSection
                    }
                    Text("只有你勾选并确认的文件才会被改动；确认之前不会动任何东西。")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondaryText)
                }
                .padding(20)
            }
        }
        .confirmationDialog("清零选中的素材？", isPresented: $showConfirm, titleVisibility: .visible) {
            Button("先备份，再清零 \(state.selectedCandidatePaths.count) 个文件", role: .destructive) {
                state.clearSelectedCandidates()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text(state.checkedIDs.isEmpty && state.targetChosen
                 ? "请先完全退出 \(state.target.name)。"
                 : "请先完全退出要处理的应用。")
        }
    }

    private var guideCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("怎么找")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primaryText)
            Text(state.checkedIDs.isEmpty
                 ? "① 拍第一次快照  →  ② 去 \(state.target.name) 里让开屏广告完整播一次  →  ③ 回来拍第二次快照  →  ④ 勾选刚出现或明显变大的文件。"
                 : "① 拍第一次快照（勾选的应用一起拍）  →  ② 去有广告的应用里让开屏广告完整播一次  →  ③ 回来拍第二次快照  →  ④ 勾选刚出现或明显变大的文件。")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var appsWithAdsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("有广告的应用")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primaryText)
            if state.appsWithAds.isEmpty {
                Text("先在主页点一次「扫描」，这里会列出扫到广告素材的应用。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(state.appsWithAds.joined(separator: "、"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var snapshotCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("快照")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                Spacer()
                if !state.beforeSnapshots.isEmpty {
                    StatusBadge(text: "第一次 \(state.beforeSnapshots.values.reduce(0) { $0 + $1.fileCount }) 个文件", tint: .cyan)
                }
                if !state.afterSnapshots.isEmpty {
                    StatusBadge(text: "第二次 \(state.afterSnapshots.values.reduce(0) { $0 + $1.fileCount }) 个文件", tint: .green)
                }
            }
            HStack(spacing: 10) {
                Button {
                    state.takeSnapshot(before: true)
                } label: {
                    actionLabel("拍第一次快照", symbol: "camera")
                }
                .buttonStyle(.plain)
                Button {
                    state.takeSnapshot(before: false)
                } label: {
                    actionLabel("拍第二次快照", symbol: "camera.viewfinder")
                }
                .buttonStyle(.plain)
                .disabled(state.beforeSnapshots.isEmpty)
                .opacity(state.beforeSnapshots.isEmpty ? 0.45 : 1)
            }
            if let before = state.beforeSnapshots.values.first {
                Text("第一次快照时间：\(Format.fullDate(before.createdAt))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.secondaryText)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var instructionCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 15))
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.checkedIDs.isEmpty ? "现在去打开\(state.target.name)" : "现在去打开有广告的应用")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                Text("让开屏广告完整播一次，然后回到这里拍第二次快照。不要先强退本应用。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var clearButton: some View {
        Button {
            showConfirm = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "eraser.fill")
                    .font(.system(size: 15, weight: .semibold))
                Text("清零选中的 \(state.selectedCandidatePaths.count) 个文件")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(Color.primaryText)
            .padding(.horizontal, 17)
            .frame(height: 56)
            .background(LinearGradient(colors: [Color.cyan.opacity(0.88), Color.blue.opacity(0.82)],
                                       startPoint: .leading,
                                       endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(state.selectedCandidatePaths.isEmpty)
        .opacity(state.selectedCandidatePaths.isEmpty ? 0.5 : 1)
    }

    private var candidateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            clearButton
            Button {
                state.uploadFindings()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "icloud.and.arrow.up")
                    Text("上传这次找广告的结果")
                    Spacer()
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentCyan)
                .padding(.horizontal, 17)
                .frame(height: 44)
                .background(Color.accentCyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            HStack {
                Text("候选（\(state.candidates.count)）")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                Spacer()
                Button(state.selectedCandidatePaths.count == state.candidates.count ? "全不选" : "全选") {
                    if state.selectedCandidatePaths.count == state.candidates.count {
                        state.selectedCandidatePaths = []
                    } else {
                        state.selectedCandidatePaths = Set(state.candidates.map { $0.id })
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.accentCyan)
                .buttonStyle(.plain)
            }
            VStack(spacing: 0) {
                ForEach(state.candidates) { candidate in
                    HStack(spacing: 0) {
                        Button {
                            toggle(candidate)
                        } label: {
                            row(candidate)
                        }
                        .buttonStyle(.plain)
                        Button {
                            state.toggleMark(bundleID: candidate.bundleID, appName: candidate.appName,
                                             relativePath: candidate.relativePath, size: candidate.size)
                        } label: {
                            Image(systemName: state.isMarked(bundleID: candidate.bundleID, relativePath: candidate.relativePath) ? "flag.fill" : "flag")
                                .font(.system(size: 14))
                                .foregroundStyle(state.isMarked(bundleID: candidate.bundleID, relativePath: candidate.relativePath) ? Color.orange : Color.secondaryText)
                                .frame(width: 36, height: 44)
                        }
                        .buttonStyle(.plain)
                    }
                    if candidate.id != state.candidates.last?.id {
                        Divider()
                            .overlay(Color.primaryText.opacity(0.06))
                            .padding(.leading, 48)
                    }
                }
            }
            .padding(.horizontal, 12)
            .panel()

    private func toggle(_ candidate: DiffCandidate) {
        if state.selectedCandidatePaths.contains(candidate.id) {
            state.selectedCandidatePaths.remove(candidate.id)
        } else {
            state.selectedCandidatePaths.insert(candidate.id)
        }
    }

    private func row(_ candidate: DiffCandidate) -> some View {
        HStack(spacing: 10) {
            Image(systemName: state.selectedCandidatePaths.contains(candidate.id) ? "checkmark.square.fill" : "square")
                .font(.system(size: 16))
                .foregroundStyle(state.selectedCandidatePaths.contains(candidate.id) ? Color.accentCyan : Color.secondaryText)
            ThumbnailView(path: candidate.containerRoot.isEmpty ? candidate.relativePath : candidate.containerRoot + "/" + candidate.relativePath,
                          kind: candidate.kind,
                          side: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(candidate.relativePath)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if state.isMarked(bundleID: candidate.bundleID, relativePath: candidate.relativePath) {
                        Text("我标记的")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.orange, in: Capsule())
                    }
                    if candidate.likelyAd {
                        Text("疑似广告")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.14), in: Capsule())
                    }
                }
                if !state.checkedIDs.isEmpty && !candidate.appName.isEmpty {
                    Text(candidate.appName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.accentCyan)
                }
                HStack(spacing: 6) {
                    Text(candidate.reason)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(candidate.isNew ? Color.green : Color.orange)
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondaryText.opacity(0.6))
                    Text(candidate.sizeText)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondaryText)
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondaryText.opacity(0.6))
                    Text(candidate.modifiedText)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondaryText)
                }
            }
            Spacer()
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private func actionLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(Color.accentCyan)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(Color.accentCyan.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
