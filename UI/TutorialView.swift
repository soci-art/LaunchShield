import SwiftUI

/// 使用教程：三级结构。一级只有两条入口（如何使用 / 如何手动搜索广告），
/// 点进去是各自的二级页；手动搜索广告的二级页列四个方法，点进去是三级详情。
/// 文案与首页实际按钮名保持一致（例如清零按钮就叫「全部清零」）。
struct TutorialView: View {
    var body: some View {
        SheetPage("使用教程") {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("两个教程，点进去看。")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.secondaryText)

                    NavigationLink {
                        HowToUseView()
                    } label: {
                        menuRow(icon: "book", title: "如何使用",
                                subtitle: "从选应用、扫描、清零到还原，五步走完一遍")
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        FindAdGuideView()
                    } label: {
                        menuRow(icon: "magnifyingglass", title: "如何手动搜索广告",
                                subtitle: "名单里没有的广告，用这四招自己把它揪出来")
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

/// 二级页：如何使用（原教程原样搬来）。
struct HowToUseView: View {
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                step(1, "第一次打开，先开权限",
                     "弹窗问联网时，点允许。联网是上传日志、更新规则和检查更新用的。") {
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
        .background(Color.appBackground)
        .navigationTitle("如何使用")
        .navigationBarTitleDisplayMode(.inline)
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

/// 二级页：如何手动搜索广告——四个方法，每行点进三级详情。
struct FindAdGuideView: View {
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                Text("扫描是按名单找的，名单里没收录的广告扫不到，得自己揪。下面四招从准到广排列，点进去看每招怎么做。找到以后勾上清零就行；再把找广告结果上传一次，这类广告以后就能被直接扫出来了。")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondaryText)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(FindAdMethod.allCases) { method in
                    NavigationLink {
                        FindAdMethodView(method: method)
                    } label: {
                        methodRow(method)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .background(Color.appBackground)
        .navigationTitle("如何手动搜索广告")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func methodRow(_ method: FindAdMethod) -> some View {
        HStack(spacing: 12) {
            Image(systemName: method.icon)
                .font(.system(size: 19))
                .foregroundStyle(Color.accentCyan)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(method.title)
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundStyle(Color.primaryText)
                Text(method.subtitle)
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

enum FindAdMethod: CaseIterable, Identifiable {
    case compare
    case bigFiles
    case searchName
    case deepScan

    var id: Self { self }

    var icon: String {
        switch self {
        case .compare: return "camera.viewfinder"
        case .bigFiles: return "doc.text.magnifyingglass"
        case .searchName: return "text.magnifyingglass"
        case .deepScan: return "scope"
        }
    }

    var title: String {
        switch self {
        case .compare: return "前后对比找广告"
        case .bigFiles: return "大文件榜"
        case .searchName: return "搜文件名"
        case .deepScan: return "深扫"
        }
    }

    var subtitle: String {
        switch self {
        case .compare: return "最准：让广告自己下载下来，前后一对比就现形"
        case .bigFiles: return "按大小排队，开屏图和视频个头都不小"
        case .searchName: return "拿关键词搜文件名，顺藤摸瓜"
        case .deepScan: return "扫描时多猜一层，实在找不到时再开"
        }
    }

    var steps: [String] {
        switch self {
        case .compare:
            return [
                "在主页选好要处理的应用（或一键勾选），进「找广告」。",
                "先点「先清一次缓存」，把旧缓存清干净，不然新旧混在一起分不清。",
                "点「拍快照」，记下现在应用里都有哪些文件。",
                "切到那个应用，打开它，等开屏广告播完，再随便多点几个页面，让广告都下载下来。",
                "回到「找广告」，点「再拍一次快照」。新增和变大的文件会列出来，带「疑似广告」标记的优先看。",
                "认准是广告的勾上，点清零，就处理完了。",
            ]
        case .bigFiles:
            return [
                "进「找广告」，再点进「大文件榜 / 搜文件名」。",
                "点「列出最大的 100 个文件」，等它列完。",
                "开屏图一般是全屏大图、视频更大，先从排前面的图片和视频看起，带「疑似广告」标记的排在最前面。",
                "认准的勾上，点「加进找广告候选」，回到候选列表再确认清零。",
            ]
        case .searchName:
            return [
                "进「找广告」，再点进「大文件榜 / 搜文件名」，切到「搜文件名」。",
                "输入关键词点「搜」。常用的词：splash（就是开屏）、ad、video、banner。",
                "在结果里挑路径或名字带广告字样的，勾上后「加进找广告候选」，回候选列表确认清零。",
            ]
        case .deepScan:
            return [
                "在主页扫描前，先打开「深扫」开关，再点扫描。",
                "深扫会多猜一层：路径里带广告关键词的、尺寸正好是全屏的图片，都会标成「疑似广告」列出来。",
                "逐个核对，确认是广告的再清零。",
            ]
        }
    }

    var note: String {
        switch self {
        case .compare:
            return "注意：广告得真的播出来、下载到手机里才抓得到；两次快照间隔别太久，隔久了别的新文件也会混进来。有的广告是打开时联网现播、不存文件的，这种抓不到。"
        case .bigFiles:
            return "注意：「只看图片、视频和疑似广告」开着时，不是图片视频的文件不显示；要是觉得该有的没列出来，把这个开关关掉再看。"
        case .searchName:
            return "注意：搜的是文件名，名字里不带关键词的搜不到。这一招适合顺着已知线索扩大战果，和大文件榜配合着用。"
        case .deepScan:
            return "注意：深扫是猜的，可能把不是广告的文件也标出来，清之前一定逐个看清楚，别误清。深扫比普通扫描慢，平时不用开。"
        }
    }
}

/// 三级页：一个方法的详细步骤。
struct FindAdMethodView: View {
    let method: FindAdMethod

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(method.steps.enumerated()), id: \.offset) { index, text in
                        HStack(alignment: .top, spacing: 9) {
                            Text("\(index + 1)")
                                .font(.system(size: 12.5, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(Color.accentCyan, in: Circle())
                            Text(text)
                                .font(.system(size: 13.5))
                                .foregroundStyle(Color.primaryText)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel(radius: 18)

                HStack(alignment: .top, spacing: 8) {
                    Text("⚠️")
                        .font(.system(size: 12.5))
                    Text(method.note)
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
        .navigationTitle(method.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
