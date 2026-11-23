import SwiftUI

/// 使用教程：一级三条入口（如何使用 / LaunchHack / 已守护应用），
/// 点进去是各自的二级页。原「如何手动搜索广告」一节已删：找广告
/// 页早已下线，手动找广告由 LaunchHack 接手（第 58 条）。
/// 文案与首页实际按钮名保持一致（例如清零按钮就叫「全部清零」）。
struct TutorialView: View {
    var body: some View {
        SheetPage("使用教程") {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("三个教程，点进去看。")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.secondaryText)

                    NavigationLink {
                        HowToUseView()
                    } label: {
                        menuRow(icon: "book", title: "如何使用",
                                subtitle: "从选应用、扫描、去除到还原，五步走完一遍")
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        LaunchHackGuideView()
                    } label: {
                        menuRow(icon: "magnifyingglass", title: "LaunchHack：自己认图找广告",
                                subtitle: "规则没覆盖到的广告，自己认图把它揪出来")
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        GuardedGuideView()
                    } label: {
                        menuRow(icon: "shield", title: "已守护应用",
                                subtitle: "守护了哪些文件和文件夹，怎么移除、怎么结束守护")
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
            }
        }
    }

    private func menuRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 19))
                .foregroundStyle(Color.accentCyan)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundStyle(Color.primaryText)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.secondaryText)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: 18)
    }
}

// MARK: - 教程共用小件

private func tutorialStep<Mock: View>(_ number: Int, _ title: String, _ text: String,
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

private func tutorialMockRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: 8) { content() }
}

private func tutorialChip(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 11))
        .foregroundStyle(Color.secondaryText)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Color.primaryText.opacity(0.07), in: Capsule())
}

private func tutorialMockButton(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(Color.accentCyan)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentCyan.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
}

private func tutorialSolidButton(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentCyan, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
}

/// 二级页：如何使用。
struct HowToUseView: View {
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                tutorialStep(1, "第一次打开，先开权限",
                     "弹窗问联网时，点允许。联网是上传日志、更新规则和检查更新用的。") {
                    tutorialMockRow { Text("联网").font(.system(size: 13)).foregroundStyle(Color.primaryText); Spacer(); tutorialChip("允许") }
                }
                tutorialStep(2, "选要去广告的应用",
                     "省事就点「一键勾选」，装的应用一次全选上（游戏除外）；只想处理一个，就点「浏览应用列表」单独选。列表里只有你装的应用，系统应用不显示。") {
                    tutorialMockRow {
                        tutorialMockButton("一键勾选")
                        Spacer()
                        tutorialMockButton("浏览应用列表")
                    }
                }
                tutorialStep(3, "扫描，看广告藏在哪",
                     "点素材清单下方的「扫描」，扫完会按广告商分好类，告诉你每个应用里有几家的广告素材。") {
                    tutorialMockRow {
                        tutorialMockButton("↻ 扫描")
                    }
                }
                tutorialStep(4, "开始去除广告",
                     "确认列表没问题，点「开始去除广告」。会先自动备份，再把广告素材清空；同一个文件夹里的素材会整夹一起处理，文件夹也会冻住并登记守护——以后新广告再落回这个文件夹，打开 LaunchShield 时会自动一并清掉。处理前记得先把目标应用完全退出。") {
                    tutorialMockRow {
                        tutorialSolidButton("开始去除广告")
                        Spacer()
                        tutorialChip("已冻结 ❄")
                    }
                }
                tutorialStep(5, "想恢复，随时还原",
                     "去除前都自动留了备份。在「备份记录」里点全部还原，素材会原样写回去，应用恢复原状。") {
                    tutorialMockRow {
                        Text("备份记录").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.primaryText)
                        Spacer()
                        tutorialMockButton("全部还原")
                    }
                }
                tutorialStep(6, "每天自动复查，不用打开应用",
                     "打开系统「快捷指令」，切到「自动化」，点右上角＋号选「特定时间」：挑一个时间（比如每天早上 8 点）、重复选「每天」、选「立即运行」。下一步添加操作，搜 LaunchShield，选「复查并去除复发」。存好以后，每天到点会自动把新冒出来的广告文件备份、去除并冻结，跟你打开应用时做的那一轮一样；跑没跑、清了几个，打开应用看日志就知道。第一次装好新版后，先打开一次 LaunchShield，快捷指令里才会出现这个操作。") {
                    tutorialMockRow {
                        Text("快捷指令 · 自动化").font(.system(size: 13)).foregroundStyle(Color.primaryText)
                        Spacer()
                        tutorialChip("每天 · 立即运行")
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
        .background(Color.appBackground)
        .navigationTitle("如何使用")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 二级页：LaunchHack——自己认图找广告（第 58 条新增）。
struct LaunchHackGuideView: View {
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                tutorialStep(1, "先在主页选好一个应用",
                     "LaunchHack 一次只查一个应用。先回主页把要查的应用选好；如果选了多个，点进来会先提醒你改成一个。") {
                    tutorialMockRow {
                        Text("百度网盘").font(.system(size: 13)).foregroundStyle(Color.primaryText)
                        Spacer()
                        tutorialChip("已找到")
                    }
                }
                tutorialStep(2, "点 LaunchHack 开始扫描",
                     "在主页点蓝色大按钮「LaunchHack」，进来点「开始扫描」。它会把这个应用里的文件全盘点一遍，把像广告的大图挑出来。") {
                    tutorialMockRow {
                        tutorialSolidButton("LaunchHack")
                        Spacer()
                        tutorialMockButton("开始扫描")
                    }
                }
                tutorialStep(3, "在图片墙里认图、标记",
                     "扫完会有一面图片墙，只列大图（小图自动略过）。点开看大图，认出是广告就点「就是这张，标记为广告图」。标记过的图，右上角会有一个绿勾。") {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(LinearGradient(colors: [Color(red: 0.23, green: 0.29, blue: 0.39), Color(red: 0.14, green: 0.18, blue: 0.26)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(height: 56)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.green)
                                    .padding(4)
                            }
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.29, blue: 0.18), Color(red: 0.24, green: 0.17, blue: 0.11)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(height: 56)
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(LinearGradient(colors: [Color(red: 0.31, green: 0.23, blue: 0.37), Color(red: 0.17, green: 0.13, blue: 0.22)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(height: 56)
                    }
                }
                tutorialStep(4, "回主页去除处理",
                     "标记会自己同步到主页的素材清单（单独一组）。关掉 LaunchHack，回主页点「开始去除广告」就处理了。关页面、关应用，标记都不会丢。") {
                    tutorialMockRow {
                        Text("LaunchHack 手动标记 · 27 项").font(.system(size: 13)).foregroundStyle(Color.primaryText)
                        Spacer()
                        tutorialSolidButton("开始去除广告")
                    }
                }
            }
            .padding(20)
        }
        .background(Color.appBackground)
        .navigationTitle("LaunchHack：自己认图找广告")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 二级页：已守护应用（第 58 条新增）。
struct GuardedGuideView: View {
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                tutorialStep(1, "在哪看",
                     "主页「已守护应用」点「全部」进来。一个应用一张卡，卡上写着它一共有几个文件、冻住了几个。") {
                    tutorialMockRow {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("百度网盘").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.primaryText)
                            Text("共 2140 个 · 已冻结 2140 个 · 文件夹 12 个")
                                .font(.system(size: 11)).foregroundStyle(Color.secondaryText)
                        }
                        Spacer()
                        tutorialChip("守护中")
                    }
                }
                tutorialStep(2, "点开看明细",
                     "点应用卡展开：上面是它守护的文件夹，下面是单个文件。文件夹守护的意思是，这个文件夹被冻住了；以后新广告落进这个文件夹，你打开 LaunchShield 时会被一并清掉。") {
                    VStack(alignment: .leading, spacing: 7) {
                        tutorialMockRow {
                            Text("📁 文件夹守护（12 个）").font(.system(size: 12)).foregroundStyle(Color.primaryText)
                            Spacer()
                        }
                        tutorialMockRow {
                            Text("splash_ad_01.png").font(.system(size: 12)).foregroundStyle(Color.primaryText)
                            Spacer()
                            tutorialChip("已冻结 ❄")
                        }
                    }
                }
                tutorialStep(3, "移除单个文件夹守护",
                     "在展开区里点某个文件夹右边的「移除」，这个文件夹就解冻、今后不再巡查它。文件那边的守护不受影响。") {
                    tutorialMockRow {
                        Text("Library/Caches/com.csj.plist.v4")
                            .font(.system(size: 11.5)).foregroundStyle(Color.secondaryText)
                            .lineLimit(1)
                        Spacer()
                        Text("移除")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                }
                tutorialStep(4, "结束一个应用的守护",
                     "点应用卡上的「结束守护」，这个应用的文件和文件夹会全部解冻，并从守护名单里移除。文件还是 0 字节，应用自己会重新生成，广告可能再出现。") {
                    tutorialMockRow {
                        Text("百度网盘").font(.system(size: 13)).foregroundStyle(Color.primaryText)
                        Spacer()
                        Text("结束守护")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(20)
        }
        .background(Color.appBackground)
        .navigationTitle("已守护应用")
        .navigationBarTitleDisplayMode(.inline)
    }
}
