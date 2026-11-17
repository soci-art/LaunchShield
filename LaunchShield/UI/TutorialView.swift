import SwiftUI

/// 使用教程二级页：五步讲清从选应用到还原的完整流程，文案与首页
/// 实际按钮名保持一致（例如清零按钮就叫「全部清零」）。
struct TutorialView: View {
    var body: some View {
        SheetPage("使用教程") {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    step(1, "第一次打开，先开权限",
                         "第一次打开，弹窗问联网时点允许。联网是上传日志、更新规则和检查更新用的。") {
                        VStack(spacing: 8) {
                            mockRow { Text("联网").font(.system(size: 13)).foregroundStyle(Color.primaryText); Spacer(); chip("允许") }
                        }
                    }
                    step(2, "选要去广告的应用",
                         "省事就点「一键勾选」，装的应用一次全选上（游戏除外）；只想处理一个，就点「浏览应用列表」单独选。") {
                        mockRow {
                            mockButton("一键勾选")
                            Spacer()
                            mockButton("浏览应用列表")
                        }
                    }
                    step(3, "扫描，看广告藏在哪",
                         "点素材清单右边的「扫描」，扫完会按广告商分好类，告诉你每个应用里有几家的广告素材。") {
                        mockRow {
                            Text("素材清单").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.primaryText)
                            Spacer()
                            mockButton("↻ 扫描")
                        }
                    }
                    step(4, "全部清零",
                         "确认列表没问题，点「全部清零」。会先自动备份，再把广告素材清空并冻住，开屏广告就出不来了。处理前记得先把目标应用完全退出。") {
                        mockRow {
                            Text("全部清零")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.accentCyan, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            Spacer()
                            chip("已冻结 ❄")
                        }
                    }
                    step(5, "想恢复，随时还原",
                         "清零前都自动留了备份。在「备份记录」里点全部还原，素材会原样写回去，应用恢复原状。") {
                        mockRow {
                            Text("备份记录").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.primaryText)
                            Spacer()
                            mockButton("全部还原")
                        }
                    }
                    HStack(alignment: .top, spacing: 8) {
                        Text("⚠️")
                            .font(.system(size: 12.5))
                        Text("提醒：只有证书签名装的才能用，免费 ID 签的不行。处理应用前，先把那个应用完全退出再操作。")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color(red: 0.54, green: 0.35, blue: 0.0))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(20)
            }
        }
    }

    // MARK: - Pieces

    private func step<Mock: View>(_ number: Int, _ title: String, _ text: String,
                                  @ViewBuilder mock: () -> Mock) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Text("\(number)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 23, height: 23)
                    .background(Color.accentCyan, in: Circle())
                Text(title)
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundStyle(Color.primaryText)
            }
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color.secondaryText)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            mock()
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primaryText.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: 18)
    }

    private func mockRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color.secondaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Color.primaryText.opacity(0.07), in: Capsule())
    }

    private func mockButton(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Color.accentCyan)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.accentCyan.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
