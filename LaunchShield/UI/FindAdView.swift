import SwiftUI

struct FindAdView: View {
    @EnvironmentObject private var state: AppState
    @State private var showConfirm = false

    var body: some View {
        SheetPage("找广告（前后对比）") {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    guideCard
                    snapshotCard
                    if state.beforeSnapshot != nil && state.candidates.isEmpty {
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
            Text("请先完全退出 \(state.target.name)。")
        }
    }

    private var guideCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("怎么找")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text("① 拍第一次快照  →  ② 去 \(state.target.name) 里让开屏广告完整播一次  →  ③ 回来拍第二次快照  →  ④ 勾选刚出现或明显变大的文件。")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
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
                    .foregroundStyle(.white)
                Spacer()
                if let before = state.beforeSnapshot {
                    StatusBadge(text: "第一次 \(before.fileCount) 个文件", tint: .cyan)
                }
                if let after = state.afterSnapshot {
                    StatusBadge(text: "第二次 \(after.fileCount) 个文件", tint: .green)
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
                .disabled(state.beforeSnapshot == nil)
                .opacity(state.beforeSnapshot == nil ? 0.45 : 1)
            }
            if let before = state.beforeSnapshot {
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
                Text("现在去打开\(state.target.name)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
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

    private var candidateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("候选（\(state.candidates.count)）")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
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
                    Button {
                        toggle(candidate)
                    } label: {
                        row(candidate)
                    }
                    .buttonStyle(.plain)
                    if candidate.id != state.candidates.last?.id {
                        Divider()
                            .overlay(Color.white.opacity(0.06))
                            .padding(.leading, 48)
                    }
                }
            }
            .padding(.horizontal, 12)
            .panel()

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
                .foregroundStyle(.white)
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
    }

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
            ThumbnailView(path: state.containerPath.map { $0 + "/" + candidate.relativePath } ?? candidate.relativePath,
                          kind: candidate.kind,
                          side: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.relativePath)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.middle)
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
