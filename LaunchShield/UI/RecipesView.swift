import SwiftUI

/// 已守护应用（Grace 2026-11-26 定案）：只到应用一级——一个应用
/// 一行，看得到数量和状态，点不进去；没有单个文件、单个文件夹的
/// 移除，守护和结束都按整个应用来（几百条明细展开会非常卡，简单
/// 和流畅优先）。底层按条目的函数保留不动，这一页不再调用它们。
struct RecipesView: View {
    @EnvironmentObject private var state: AppState
    @State private var showClearMissing = false
    @State private var appToEndGuard: String?

    var body: some View {
        SheetPage("已守护应用") {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if state.recipes.isEmpty && state.directoryGuards.isEmpty {
                        emptyCard
                    } else {
                        HStack(spacing: 10) {
                            if state.recipes.contains(where: { $0.frozen }) {
                                topButton("全部解冻", symbol: "sun.max", tint: Color.accentCyan) {
                                    state.unfreezeAll()
                                }
                            }
                            if missingCount > 0 {
                                topButton("清除不见的（\(missingCount)）", symbol: "trash", tint: Color.red) {
                                    showClearMissing = true
                                }
                            }
                            Spacer()
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
                    }
                    Text("守护只到应用一级：一个应用一行，结束守护就是整包解冻、移出名单。文件 0 字节＝正常；变大＝已复发；冻结的文件删不掉也换不掉。")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
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
        // 弹窗重构（Grace 2026-11-26）：确认框统一走居中卡片对话框。
        .overlay {
            if showClearMissing {
                AppDialog(icon: "trash", iconTint: .red,
                          title: "清除文件不见了的条目？",
                          message: "这些文件已经不在了，清掉只是把名单删干净，守护不再白查它们。",
                          actions: [AppDialogAction(title: "清除 \(missingCount) 个", style: .destructive) {
                              showClearMissing = false
                              state.clearMissingRecipes()
                          }],
                          onCancel: { showClearMissing = false })
            } else if let bundleID = appToEndGuard {
                AppDialog(icon: "shield",
                          title: "结束这个应用的守护？",
                          message: "只结束这一个应用：它的条目会从守护列表全部移除，冻结的文件和文件夹都会解冻。文件还是 0 字节，应用自己会重新生成，广告可能再出现。",
                          actions: [AppDialogAction(title: "结束守护", style: .destructive) {
                              appToEndGuard = nil
                              state.endGuard(forApp: bundleID)
                          }],
                          onCancel: { appToEndGuard = nil })
            }
        }
    }

    private var missingCount: Int {
        state.recipes.filter { $0.lastState == RecipeState.missing.rawValue }.count
    }

    /// 一个应用一组的统一分组（第 57 条）：文件配方和文件夹
    /// 守护都归到同一个应用名下，分组口径不变，只是展示只到应用一级。
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

    private func topButton(_ title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(tint.opacity(0.10), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 一个应用一行：图标＋名字＋数量一行，右侧状态标＋结束守护。
    private func appRow(_ group: GuardedAppGroup) -> some View {
        let frozen = group.items.filter { $0.frozen }.count
        let recurred = group.items.filter { $0.lastState == RecipeState.recurred.rawValue }.count
        let missing = group.items.filter { $0.lastState == RecipeState.missing.rawValue }.count
        return HStack(spacing: 12) {
            AppIconView(bundleID: group.bundleID, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                    .lineLimit(1)
                Text("共 \(group.items.count) 个 · 已冻结 \(frozen) 个" + (recurred > 0 ? " · 复发 \(recurred) 个" : "") + (missing > 0 ? " · 不见了 \(missing) 个" : "") + (group.guards.isEmpty ? "" : " · 文件夹 \(group.guards.count) 个"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if recurred > 0 {
                    StatusBadge(text: "有复发", tint: .orange)
                } else if missing > 0 && missing == group.items.count && !group.items.isEmpty {
                    StatusBadge(text: "文件不见了", tint: .red)
                } else {
                    StatusBadge(text: "守护中", tint: Color.primaryText)
                }
                // 「结束守护」和备份页的「还原」一个样：白色胶囊按钮，
                // 整块都能点（Grace 2026-11-26）。
                Button {
                    appToEndGuard = group.bundleID
                } label: {
                    Text("结束守护")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.appBackground)
                        .padding(.horizontal, 17)
                        .frame(height: 36)
                        .background(Color.primaryText, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 13)
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("还没有配方")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.primaryText)
            Text("去除广告素材后，会自动把「Bundle ID ＋ 相对路径」存成配方，下次打开时按配方复查。")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}
