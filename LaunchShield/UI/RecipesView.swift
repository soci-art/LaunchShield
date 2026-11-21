import SwiftUI

struct RecipesView: View {
    @EnvironmentObject private var state: AppState
    @State private var expandedApps: Set<String> = []
    @State private var showClearMissing = false
    @State private var appToEndGuard: String?
    @State private var selecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var selectedGuardIDs: Set<UUID> = []
    @State private var showBatchRemove = false
    @State private var showBatchRestore = false

    var body: some View {
        SheetPage("已守护应用") {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if state.recipes.isEmpty && state.directoryGuards.isEmpty {
                        emptyCard
                    } else {
                        HStack(spacing: 10) {
                            if state.recipes.contains(where: { $0.frozen }) {
                                Button {
                                    state.unfreezeAll()
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: "sun.max")
                                        Text("全部解冻")
                                    }
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.accentCyan)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 11)
                                    .background(Color.accentCyan.opacity(0.10), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                            if missingCount > 0 {
                                Button {
                                    showClearMissing = true
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: "trash")
                                        Text("清除不见的（\(missingCount)）")
                                    }
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.red)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 11)
                                    .background(Color.red.opacity(0.10), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                            Button {
                                selecting.toggle()
                                if !selecting { selectedIDs = []; selectedGuardIDs = [] }
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "checklist")
                                    Text(selecting ? "完成" : "多选")
                                }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.accentCyan)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)
                                .background(Color.accentCyan.opacity(0.10), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(appGroups) { group in
                            appGroupSection(group)
                        }
                    }
                    Text("配方只记录 Bundle ID 和容器内的相对路径。文件 0 字节＝正常；变大＝已复发；冻结的文件删不掉也换不掉。从守护列表移除一个文件时，会先把这个文件解冻。")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    batchBar
                }
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
        .confirmationDialog("清除文件不见了的条目？", isPresented: $showClearMissing, titleVisibility: .visible) {
            Button("清除 \(missingCount) 个", role: .destructive) {
                state.clearMissingRecipes()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("这些文件已经不在了，清掉只是把名单删干净，守护不再白查它们。")
        }
        .confirmationDialog("结束这个应用的守护？", isPresented: Binding(
            get: { appToEndGuard != nil },
            set: { if !$0 { appToEndGuard = nil } }
        ), titleVisibility: .visible) {
            Button("结束守护", role: .destructive) {
                if let bundleID = appToEndGuard { state.endGuard(forApp: bundleID) }
                appToEndGuard = nil
            }
            Button("取消", role: .cancel) { appToEndGuard = nil }
        } message: {
            Text("只结束这一个应用：它的条目会从守护列表全部移除，冻结的文件和文件夹都会解冻。文件还是 0 字节，应用自己会重新生成，广告可能再出现。")
        }
        .confirmationDialog("把选中条目的文件从备份恢复吗？", isPresented: $showBatchRestore, titleVisibility: .visible) {
            Button("恢复 \(selectedBackupRecords.count) 个文件") {
                state.restoreBackups(selectedBackupRecords)
                selecting = false
                selectedIDs = []
                selectedGuardIDs = []
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("请先完全退出对应的目标应用。选中的条目里有 \(selectedBackupRecords.count) 个能找到备份，其余的没有备份、恢复不了。")
        }
        .confirmationDialog("批量移除选中的守护条目？", isPresented: $showBatchRemove, titleVisibility: .visible) {
            Button("移除 \(selectedTotalCount) 个", role: .destructive) {
                if !selectedRecipes.isEmpty {
                    state.removeRecipes(selectedRecipes)
                }
                if !selectedGuards.isEmpty {
                    state.removeDirectoryGuards(selectedGuards)
                }
                selecting = false
                selectedIDs = []
                selectedGuardIDs = []
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("冻着的文件和文件夹都会先解冻再移除，不会把它们冻在原地没人管。文件还是 0 字节，应用自己会重新生成。")
        }
    }

    private var missingCount: Int {
        state.recipes.filter { $0.lastState == RecipeState.missing.rawValue }.count
    }

    /// 一个应用一组的统一分组（第 57 条）：文件配方和文件夹
    /// 守护都归到同一个应用名下，文件夹守护不再单独成段。
    private struct GuardedAppGroup: Identifiable {
        let bundleID: String
        let name: String
        let items: [Recipe]
        let guards: [DirectoryGuard]
        var id: String { bundleID }
    }

    private var appGroups: [GuardedAppGroup] {
        let recipesByApp = Dictionary(grouping: state.recipes, by: { $0.bundleID })
        var guardsByApp: [String: [DirectoryGuard]] = [:]
        var names: [String: String] = [:]
        for item in state.directoryGuards {
            guardsByApp[item.bundleID, default: []].append(item)
            if names[item.bundleID] == nil { names[item.bundleID] = item.appName }
        }
        for (bundleID, items) in recipesByApp {
            names[bundleID] = items.first?.appName ?? bundleID
        }
        return Set(recipesByApp.keys).union(guardsByApp.keys).map {
            GuardedAppGroup(bundleID: $0, name: names[$0] ?? $0,
                            items: recipesByApp[$0] ?? [],
                            guards: guardsByApp[$0] ?? [])
        }.sorted { $0.name < $1.name }
    }

    private func appGroupSection(_ group: GuardedAppGroup) -> some View {
        let frozen = group.items.filter { $0.frozen }.count
        let recurred = group.items.filter { $0.lastState == RecipeState.recurred.rawValue }.count
        let missing = group.items.filter { $0.lastState == RecipeState.missing.rawValue }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if selecting && (!group.items.isEmpty || !group.guards.isEmpty) {
                    Button {
                        toggleGroup(group)
                    } label: {
                        Image(systemName: groupFullySelected(group) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 19))
                            .foregroundStyle(Color.accentCyan)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    if expandedApps.contains(group.bundleID) {
                        expandedApps.remove(group.bundleID)
                    } else {
                        expandedApps.insert(group.bundleID)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: expandedApps.contains(group.bundleID) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.secondaryText)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.primaryText)
                            Text("共 \(group.items.count) 个 · 已冻结 \(frozen) 个" + (recurred > 0 ? " · 复发 \(recurred) 个" : "") + (missing > 0 ? " · 不见了 \(missing) 个" : "") + (group.guards.isEmpty ? "" : " · 文件夹 \(group.guards.count) 个"))
                                .font(.system(size: 11))
                                .foregroundStyle(Color.secondaryText)
                        }
                        Spacer(minLength: 8)
                        if recurred > 0 {
                            StatusBadge(text: "有复发", tint: .orange)
                        } else if missing > 0 && missing == group.items.count {
                            StatusBadge(text: "文件不见了", tint: .red)
                        } else {
                            StatusBadge(text: "守护中", tint: .green)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button("结束守护") {
                    appToEndGuard = group.bundleID
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.red)
                .buttonStyle(.plain)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
            if expandedApps.contains(group.bundleID) {
                if !group.guards.isEmpty {
                    folderGuardsCard(group)
                }
                ForEach(group.items) { recipe in
                    card(recipe)
                }
            }
        }
    }

    /// 文件夹守护卡（第 57 条）：收进对应应用的折叠展开区，
    /// 跟它的文件配方放一起，不再单独成段平铺。
    private func folderGuardsCard(_ group: GuardedAppGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color.accentCyan)
                Text("文件夹守护（\(group.guards.count) 个）")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
            }
            Text("清零时连文件夹一起冻住的都在这里。新广告落回这些文件夹，打开 LaunchShield 时会一并清掉。移除后文件夹会解冻，今后不再巡查这个文件夹。")
                .font(.system(size: 11))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(group.guards) { guardItem in
                HStack(alignment: .top, spacing: 10) {
                    if selecting {
                        Image(systemName: selectedGuardIDs.contains(guardItem.id) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 17))
                            .foregroundStyle(Color.accentCyan)
                    }
                    Image(systemName: "folder")
                        .foregroundStyle(Color.secondaryText)
                    Text(guardItem.relativePath)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if !selecting {
                        Button {
                            state.removeDirectoryGuard(guardItem)
                        } label: {
                            Text("移除")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.red)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.red.opacity(0.10), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture {
                    if selecting {
                        if selectedGuardIDs.contains(guardItem.id) {
                            selectedGuardIDs.remove(guardItem.id)
                        } else {
                            selectedGuardIDs.insert(guardItem.id)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("还没有配方")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.primaryText)
            Text("清零广告素材后，会自动把「Bundle ID ＋ 相对路径」存成配方，下次打开时按配方复查。")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func card(_ recipe: Recipe) -> some View {
        let stateValue = RecipeState(rawValue: recipe.lastState) ?? .unknown
        let backup = state.backups.last {
            $0.bundleID == recipe.bundleID && $0.relativePath == recipe.relativePath && $0.groupID == recipe.groupID
        }
        return HStack(alignment: .top, spacing: 10) {
            if selecting {
                Image(systemName: selectedIDs.contains(recipe.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(Color.accentCyan)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: recipe.frozen ? "snowflake" : (recipe.placeholder ? "folder" : "shield.lefthalf.filled"))
                    .font(.system(size: 16))
                    .foregroundStyle(recipeTint(stateValue))
                VStack(alignment: .leading, spacing: 3) {
                    Text(recipe.appName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.primaryText)
                    Text(recipe.bundleID)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer()
                StatusBadge(text: stateValue.label, tint: recipeTint(stateValue))
            }
            Text(recipe.relativePath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.primaryText.opacity(0.8))
                .lineLimit(3)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                if recipe.frozen {
                    StatusBadge(text: "已冻结", tint: .cyan)
                }
                if recipe.placeholder {
                    StatusBadge(text: "文件夹占位", tint: .purple)
                }
                if recipe.groupID != nil {
                    StatusBadge(text: "共享组", tint: .orange)
                }
                if let checked = recipe.lastCheckedAt {
                    Text("上次检查 \(Format.date(checked))")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer()
                if !selecting {
                Menu {
                    Button("重新清零") {
                        state.replaceRecipe(recipe)
                    }
                    Button(recipe.frozen ? "解冻" : "冻结") {
                        state.setFrozen(recipe, frozen: !recipe.frozen)
                    }
                    Button(recipe.placeholder ? "取消同名文件夹占位" : "同名文件夹占位") {
                        state.setPlaceholder(recipe, enabled: !recipe.placeholder)
                    }
                    if let backup {
                        Button("从备份恢复（\(backup.sizeText)）") {
                            state.restore(backup)
                        }
                    }
                    Divider()
                    Button("从守护列表移除", role: .destructive) {
                        state.removeRecipe(recipe)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text("操作")
                        Image(systemName: "ellipsis.circle")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentCyan)
                }
                }
            }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .onTapGesture {
            if selecting {
                if selectedIDs.contains(recipe.id) {
                    selectedIDs.remove(recipe.id)
                } else {
                    selectedIDs.insert(recipe.id)
                }
            }
        }
    }

    // MARK: - 多选

    private var selectedRecipes: [Recipe] {
        state.recipes.filter { selectedIDs.contains($0.id) }
    }

    /// 第 77 条：多选把文件夹守护也算进来，和文件一个流程删。
    private var selectedGuards: [DirectoryGuard] {
        state.directoryGuards.filter { selectedGuardIDs.contains($0.id) }
    }

    private var selectedTotalCount: Int {
        selectedIDs.count + selectedGuardIDs.count
    }

    private func groupFullySelected(_ group: GuardedAppGroup) -> Bool {
        (!group.items.isEmpty || !group.guards.isEmpty)
            && group.items.allSatisfy { selectedIDs.contains($0.id) }
            && group.guards.allSatisfy { selectedGuardIDs.contains($0.id) }
    }

    /// 选中条目里能找到备份的，取每个文件的那份备份（批量恢复用）。
    private var selectedBackupRecords: [BackupRecord] {
        selectedRecipes.compactMap { recipe in
            state.backups.last { $0.bundleID == recipe.bundleID && $0.relativePath == recipe.relativePath && $0.groupID == recipe.groupID }
        }
    }

    private func toggleGroup(_ group: GuardedAppGroup) {
        if groupFullySelected(group) {
            group.items.forEach { selectedIDs.remove($0.id) }
            group.guards.forEach { selectedGuardIDs.remove($0.id) }
        } else {
            group.items.forEach { selectedIDs.insert($0.id) }
            group.guards.forEach { selectedGuardIDs.insert($0.id) }
        }
    }

    private var allSelected: Bool {
        let total = state.recipes.count + state.directoryGuards.count
        return total > 0 && selectedTotalCount == total
    }

    private var batchBar: some View {
        HStack(spacing: 10) {
            Button {
                if allSelected {
                    selectedIDs.removeAll()
                    selectedGuardIDs.removeAll()
                } else {
                    selectedIDs = Set(state.recipes.map(\.id))
                    selectedGuardIDs = Set(state.directoryGuards.map(\.id))
                }
            } label: {
                Text(allSelected ? "取消全选" : "全选")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentCyan)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.accentCyan.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            Button {
                showBatchRestore = true
            } label: {
                Text("批量恢复（\(selectedIDs.count)）")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.accentCyan.opacity(selectedIDs.isEmpty ? 0.3 : 1),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(selectedIDs.isEmpty)
            Button {
                showBatchRemove = true
            } label: {
                Text("批量移除（\(selectedTotalCount)）")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.red.opacity(selectedTotalCount == 0 ? 0.3 : 1),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(selectedTotalCount == 0)
        }
        .padding(16)
        .background(Color.appBackground)
    }
}
