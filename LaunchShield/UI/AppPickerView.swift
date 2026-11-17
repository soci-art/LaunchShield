import SwiftUI

struct AppPickerView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""

    private var filteredGroups: [ContainerInfo] {
        guard !query.isEmpty else { return state.groupContainers }
        return state.groupContainers.filter {
            $0.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    private var filtered: [ContainerInfo] {
        guard !query.isEmpty else { return state.containers }
        return state.containers.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        SheetPage("选择目标应用") {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.secondaryText)
                    TextField("搜索应用名或 Bundle ID", text: $query)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.primaryText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .panel(radius: 14)

                if !state.channelReady {
                    Text(state.channel.unavailableReason)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .panel()
                } else if state.containers.isEmpty {
                    Text("正在读取应用列表…")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondaryText)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .panel()
                }

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { container in
                            Button {
                                state.select(container)
                                dismiss()
                            } label: {
                                row(container)
                            }
                            .buttonStyle(.plain)
                            if container.id != filtered.last?.id {
                                Divider()
                                    .overlay(Color.primaryText.opacity(0.06))
                                    .padding(.leading, 46)
                            }
                        }
                    }
                    .padding(.horizontal, 15)
                    .panel()
                }

                if !filteredGroups.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("共享组容器（关联不上的也能单独选）")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.primaryText)
                        Text("跟某个应用关联上的共享组，选那个应用时会自动一并扫描、拍快照；这里是把它们单独当目标用。")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(filteredGroups) { group in
                                    Button {
                                        state.select(group)
                                        dismiss()
                                    } label: {
                                        row(group)
                                    }
                                    .buttonStyle(.plain)
                                    if group.id != filteredGroups.last?.id {
                                        Divider()
                                            .overlay(Color.primaryText.opacity(0.06))
                                            .padding(.leading, 46)
                                    }
                                }
                            }
                            .padding(.horizontal, 15)
                        }
                        .frame(maxHeight: 190)
                        .panel()
                    }
                }
            }
            .padding(20)
        }
        .onAppear {
            if state.containers.isEmpty {
                state.refreshContainers()
            }
        }
    }

    private func row(_ container: ContainerInfo) -> some View {
        let checked = state.checkedIDs.contains(container.bundleID)
        return HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(checked ? Color.accentCyan : Color.primaryText.opacity(0.06))
                    .frame(width: 34, height: 34)
                Image(systemName: checked ? "checkmark" : (container.isSystem ? "gearshape" : "app"))
                    .font(.system(size: 14, weight: checked ? .bold : .regular))
                    .foregroundStyle(checked ? Color.white : Color.primaryText.opacity(0.7))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(container.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.primaryText)
                    .lineLimit(1)
                Text(container.bundleID)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            if container.bundleID == state.target.bundleID {
                StatusBadge(text: "当前", tint: .cyan)
            }
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}
