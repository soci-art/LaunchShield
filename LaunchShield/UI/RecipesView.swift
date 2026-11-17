import SwiftUI

struct RecipesView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        SheetPage("已守护应用") {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if state.recipes.isEmpty {
                        emptyCard
                    } else {
                        ForEach(state.recipes) { recipe in
                            card(recipe)
                        }
                    }
                    Text("配方只记录 Bundle ID 和容器内的相对路径。文件 0 字节＝正常；变大＝已复发；冻结的文件删不掉也换不掉。")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
        }
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("还没有配方")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.primaryText)
            Text("用「找广告」确认素材并清零后，会自动把「Bundle ID ＋ 相对路径」存成配方。软件自营开屏素材清零时也会自动存。")
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
            $0.bundleID == recipe.bundleID && $0.relativePath == recipe.relativePath
        }
        return VStack(alignment: .leading, spacing: 10) {
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
                if let checked = recipe.lastCheckedAt {
                    Text("上次检查 \(Format.date(checked))")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer()
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}
