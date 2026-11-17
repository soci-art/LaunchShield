import SwiftUI

/// 找广告的辅助工具：大文件榜（按大小倒序前 100）+ 按文件名递归深搜。
/// 定位是补快照对比的盲区——没拍到之前快照、或想快速揪大图大视频时用。
/// 选中的文件加进找广告候选（自动勾选、自动算「我标记的」），
/// 之后回候选列表走现成的确认清零流程，本页不直接动文件。
struct FileToolsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var mode = 0
    @State private var keyword = ""
    @State private var selectedPaths: Set<String> = []

    private var currentList: [FoundFile] {
        mode == 0 ? state.bigFiles : state.fileSearchResults
    }
    private var selectedFiles: [FoundFile] {
        currentList.filter { selectedPaths.contains($0.path) }
    }

    var body: some View {
        SheetPage("大文件榜 / 搜文件名") {
            VStack(alignment: .leading, spacing: 12) {
                Text("范围和找广告一样：当前目标应用（加一键勾选的应用）连同关联的共享组容器。选中的文件会加进找广告候选，并算作你标记的广告；清零仍在候选列表里确认，这里不动文件。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if state.findAdScope.isEmpty {
                    Text("还没选目标应用。先在主页选一个应用，或者一键勾选，再回来用这个工具。")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .panel()
                }

                Picker("", selection: $mode) {
                    Text("最大文件").tag(0)
                    Text("搜文件名").tag(1)
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) { _, _ in selectedPaths = [] }

                if mode == 0 {
                    Button {
                        state.loadBigFiles()
                    } label: {
                        Text(state.bigFiles.isEmpty ? "列出最大的 100 个文件" : "重新列一遍")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(Color.accentCyan, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(state.fileToolsBusy || state.findAdScope.isEmpty)
                } else {
                    HStack(spacing: 8) {
                        TextField("文件名关键词，如 splash、ad、mp4", text: $keyword)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.primaryText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(.horizontal, 12)
                            .frame(height: 42)
                            .panel(radius: 12)
                        Button {
                            state.searchFiles(keyword: keyword)
                        } label: {
                            Text("搜")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.white)
                                .frame(width: 58, height: 42)
                                .background(Color.accentCyan, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(state.fileToolsBusy || state.findAdScope.isEmpty)
                    }
                }

                if state.fileToolsBusy {
                    Text("正在找，稍等…")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondaryText)
                } else if currentList.isEmpty {
                    Text(mode == 0 ? "还没有榜单，点上面的按钮列一遍。" : "还没有搜索结果，输入关键词点「搜」。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondaryText)
                } else {
                    Text("共 \(currentList.count) 个，点行勾选。")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondaryText)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(currentList) { file in
                                Button {
                                    if selectedPaths.contains(file.path) {
                                        selectedPaths.remove(file.path)
                                    } else {
                                        selectedPaths.insert(file.path)
                                    }
                                } label: {
                                    row(file)
                                }
                                .buttonStyle(.plain)
                                if file.id != currentList.last?.id {
                                    Divider()
                                        .overlay(Color.primaryText.opacity(0.06))
                                        .padding(.leading, 46)
                                }
                            }
                        }
                        .padding(.horizontal, 15)
                        .panel()
                    }
                }

                Button {
                    state.addToolCandidates(selectedFiles)
                    selectedPaths = []
                    dismiss()
                } label: {
                    Text("加进找广告候选（\(selectedFiles.count)）")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(selectedFiles.isEmpty ? Color.secondaryText.opacity(0.4) : Color.accentCyan,
                                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(selectedFiles.isEmpty)
            }
            .padding(20)
        }
        .onAppear {
            if state.bigFiles.isEmpty && !state.findAdScope.isEmpty {
                state.loadBigFiles()
            }
        }
    }

    private func row(_ file: FoundFile) -> some View {
        let selected = selectedPaths.contains(file.path)
        return HStack(spacing: 11) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17))
                .foregroundStyle(selected ? Color.accentCyan : Color.secondaryText)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primaryText)
                    .lineLimit(1)
                Text("\(file.appName) · \(file.relativePath)")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(2)
            }
            Spacer()
            Text(file.sizeText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.primaryText)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
