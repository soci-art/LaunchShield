import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase

    @State private var showAppPicker = false
    @State private var showWhitelist = false
    @State private var showTutorial = false
    @State private var showAnnouncement = false
    @State private var showLaunchHack = false
    @State private var showRecipes = false
    @State private var showBackups = false
    @State private var showLogs = false
    @State private var showClearConfirm = false
    @State private var showRefreezeConfirm = false
    @State private var showNeedScanAlert = false
    @State private var showClearScanConfirm = false
    @State private var showSingleAppEntryAlert = false
    @State private var showClearCacheConfirm = false
    @State private var showRestoreConfirm = false
    @State private var showMismatchAlert = false
    @State private var ipaShareItem: ShareItem?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    LinearGradient(colors: [Color.accentWash.opacity(0.10), Color.accentWash.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 280)
                    Spacer(minLength: 0)
                }
                .ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                            .disabled(state.editionMismatch)
                            .opacity(state.editionMismatch ? 0.45 : 1)
                        announcementEntry
                            .disabled(state.editionMismatch)
                            .opacity(state.editionMismatch ? 0.45 : 1)
                        if state.editionMismatch {
                            mismatchCard
                        } else if state.kernelSupported {
                            kernelCard
                        } else {
                            heroCard
                        }
                        tutorialEntry
                            .disabled(state.editionMismatch)
                            .opacity(state.editionMismatch ? 0.45 : 1)
                        targetCard
                            .disabled(state.editionMismatch)
                            .opacity(state.editionMismatch ? 0.45 : 1)
                        fullScanCards
                            .disabled(state.editionMismatch)
                            .opacity(state.editionMismatch ? 0.45 : 1)
                        flowSection
                            .disabled(state.editionMismatch)
                            .opacity(state.editionMismatch ? 0.45 : 1)
                        sourceSection
                            .disabled(state.editionMismatch)
                            .opacity(state.editionMismatch ? 0.45 : 1)
                        if !state.templateTargets.isEmpty {
                            templateSection
                                .disabled(state.editionMismatch)
                                .opacity(state.editionMismatch ? 0.45 : 1)
                        }
                        recipesSection
                            .disabled(state.editionMismatch)
                            .opacity(state.editionMismatch ? 0.45 : 1)
                        logSection
                            .disabled(state.editionMismatch)
                            .opacity(state.editionMismatch ? 0.45 : 1)
                        updateSection
                        footer
                            .disabled(state.editionMismatch)
                            .opacity(state.editionMismatch ? 0.45 : 1)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                }
                if state.isBusy {
                    // 第 78 条：忙碌提示统一弹窗形式——背景变暗、
                    // 居中一张卡；有真进度画进度条，没有就转圈。
                    ZStack {
                        Color.black.opacity(0.45)
                            .ignoresSafeArea()
                        if let progress = state.workProgress {
                            WorkProgressOverlay(progress: progress)
                        } else {
                            BusyOverlay(text: state.busyText.isEmpty ? "正在处理…" : state.busyText)
                        }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .appAlert(state, active: !(showAppPicker || showWhitelist || showTutorial || showAnnouncement || showLaunchHack || showRecipes || showBackups || showLogs))
        .updateAlert(state, active: !(showAppPicker || showWhitelist || showTutorial || showAnnouncement || showLaunchHack || showRecipes || showBackups || showLogs))
        .onChange(of: scenePhase) { _, phase in
            // 回到前台时补查一次更新提醒（节流在 AppState 里）：
            // 发版时应用正开着的情况，靠这次补查才不会漏弹。
            if phase == .active {
                // 第 92 条：不再回前台重新武装。沙箱逃逸之后没有任何功能还需要
                // 内核读写（文件、容器、广告都走普通系统调用），所以控制
                // socket 的 icmp6filt 在逃逸成功那一刻就已经恢复并一直保持
                // 恢复状态——这样无论进程在什么时候被杀，都不会把整机打崩。
                state.recheckRemindersIfStale()
                // 第 76 条：前台期间实时检测复发。
                state.startForegroundRecurrenceMonitor()
            } else {
                // 第 92 条：用户随时可能划掉应用。控制 socket 的 icmp6filt 还
                // 指着 rw 的 PCB 时退出，内核会把这个字段当 32 字节对象释放，
                // 整机 panic（panic 报告："not in the expected zone
                // data.kalloc.32"）。一旦离开前台就恢复成合法缓冲区；.inactive
                // 比 .background 早，留的余量更大。
                // 兜底：万一逃逸后恢复没成功（kexploit_filter_set 报了错），
                // 离开前台时再试一次。已经恢复时这一步是空操作。
                if wq_kernel_active() && !wq_kernel_quiesced() {
                    _ = wq_kernel_set_quiesced(true)
                }
                if phase == .background {
                    state.stopForegroundRecurrenceMonitor()
                }
            }
        }
        .onAppear {
            // 第 76 条：刚打开 App 时 scenePhase 不一定触发
            // onChange，这里直接启动前台实时检测。
            state.startForegroundRecurrenceMonitor()
            // 版本与系统不对应：每次打开都弹一次窗说明，
            // 界面本身已经置灰、只剩「应用更新」能用。
            if state.editionMismatch {
                showMismatchAlert = true
            }
        }
        .alert("这个版本不支持你的系统", isPresented: $showMismatchAlert) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text("此版本为 iOS 17/18 系统内核专用版本，请使用正式版。正式版在本仓库的最新正式发行版里，下载装好后，这个内核专用版可以删掉。")
        }
        .sheet(isPresented: $showAppPicker) {
            AppPickerView().environmentObject(state)
        }
        .sheet(isPresented: $showWhitelist) {
            AppWhitelistView().environmentObject(state)
        }
        .sheet(isPresented: $showTutorial) {
            TutorialView()
        }
        .sheet(isPresented: $showAnnouncement, onDismiss: { state.markAnnouncementSeen() }) {
            AnnouncementView().environmentObject(state)
        }
        .onChange(of: state.announcementPopupReady) { _, ready in
            if ready {
                state.announcementPopupReady = false
                showAnnouncement = true
            }
        }
        .sheet(isPresented: $showLaunchHack) {
            LaunchHackView().environmentObject(state)
        }
        .sheet(isPresented: $showRecipes) {
            RecipesView().environmentObject(state)
        }
        .sheet(isPresented: $showBackups) {
            BackupsView().environmentObject(state)
        }
        .sheet(isPresented: $showLogs) {
            LogsView().environmentObject(state)
        }
        .sheet(item: $ipaShareItem) { item in
            ShareSheet(items: [item.url])
        }
        // 弹窗重构（Grace 2026-11-26）：主页的确认框和提示框统一走
        // 居中卡片对话框，不再用系统对话框；同一时间只出一张。
        .overlay {
            if showMismatchAlert {
                AppDialog(icon: "exclamationmark.triangle", iconTint: .orange,
                          title: "这个版本不支持你的系统",
                          message: "你装的是正式版，它只支持 iOS 26/27。你的系统是 iOS 17/18，要用内核专用版：到下面「应用更新」里打开「内核专用更新」，再点「检测更新」，就能下载内核专用版。其他功能暂时用不了。",
                          actions: [AppDialogAction(title: "知道了") { showMismatchAlert = false }],
                          cancelTitle: nil)
            } else if showSingleAppEntryAlert {
                AppDialog(icon: "info.circle",
                          title: "请选择单个应用",
                          message: "LaunchHack 只对单个应用检测。主页现在选了多个应用，先改成只选一个再来。",
                          actions: [AppDialogAction(title: "好") { showSingleAppEntryAlert = false }],
                          cancelTitle: nil)
            } else if showNeedScanAlert {
                AppDialog(icon: "magnifyingglass",
                          title: "还没有扫描到素材",
                          message: "开始去除广告只处理已经扫描到的素材。你还没有扫描，先去扫描一遍，扫完再回来去除。",
                          actions: [AppDialogAction(title: "确定") { showNeedScanAlert = false }],
                          cancelTitle: nil)
            } else if showClearScanConfirm {
                AppDialog(icon: "trash", iconTint: .red,
                          title: "清除扫描结果？",
                          message: "会把扫描到的结果和 LaunchHack 标记全部清掉，清完要重新扫描、重新标记。不动任何文件、不去除、不解冻。",
                          actions: [AppDialogAction(title: "清除", style: .destructive) {
                              showClearScanConfirm = false
                              state.clearScanResults()
                          }],
                          onCancel: { showClearScanConfirm = false })
            } else if showRefreezeConfirm {
                AppDialog(icon: "shield",
                          title: "把已复发的文件重新去除并冻结？",
                          message: "会先备份，再把这些又变大的文件去除并冻结。",
                          actions: [AppDialogAction(title: "重新去除并冻结 \(state.recurredRecipeCount) 个", style: .destructive) {
                              showRefreezeConfirm = false
                              state.refreezeRelapsed()
                          }],
                          onCancel: { showRefreezeConfirm = false })
            } else if showClearConfirm {
                AppDialog(icon: "shield",
                          title: "确定要去除这些素材吗？",
                          message: "请先完全退出目标应用（上滑关闭）。每个文件都会先备份，任何一步失败就停下，并告诉你停在哪个文件。",
                          actions: [AppDialogAction(title: "先备份，再开始去除广告", style: .destructive) {
                              showClearConfirm = false
                              state.clearAllAfterScan()
                          }],
                          onCancel: { showClearConfirm = false })
            } else if showClearCacheConfirm {
                AppDialog(icon: "trash", iconTint: .red,
                          title: "确定要清除缓存吗？",
                          message: "会清理更新 IPA、扫描索引、缩略图、识别缓存和临时文件；云端规则、备份、配方、守护名单、用户设置及运行日志均会保留。",
                          actions: [AppDialogAction(title: "清除", style: .destructive) {
                              showClearCacheConfirm = false
                              state.clearCache()
                          }],
                          onCancel: { showClearCacheConfirm = false })
            } else if showRestoreConfirm {
                AppDialog(icon: "arrow.uturn.backward",
                          title: "确定要全部还原吗？",
                          message: "请先完全退出目标应用。还原会用备份覆盖现在的文件。",
                          actions: [AppDialogAction(title: "逐个写回并核对 MD5", style: .destructive) {
                              showRestoreConfirm = false
                              state.restoreAll()
                          }],
                          onCancel: { showRestoreConfirm = false })
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primaryText.opacity(0.08), lineWidth: 1)
                    )
                    .frame(width: 52, height: 52)
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.accentCyan)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("LaunchShield")
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .layoutPriority(1)
                    // 通道标签按更新通道显示：预发行包写「预发行」，
                    // 内核包写「内核专用」（各线工作流会在 Info.plist
                    // 盖 LSUpdateChannel）。正式版没有标记，永远不显示
                    // （第 85 条）。
                    if let badge = channelBadgeText {
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                            .fixedSize()
                    }
                }
                Text("去除应用的开屏广告")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(state.channelReady ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(pillText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.secondaryText)
                        .fixedSize()
                }
            }
        }
    }

    /// 主界面顶部的通道标签：预发行 / 内核专用，正式版为 nil。
    private var channelBadgeText: String? {
        switch GitHubUpdate.channel {
        case .prerelease: return "预发行"
        case .kernel: return "内核专用"
        case .formal: return nil
        }
    }

    private var pillText: String {
        if state.editionMismatch { return "版本不对应" }
        if state.channelChecking { return "正在检测通道" }
        if state.channelReady { return "通道就绪" }
        if state.kernelSupported && state.kernelState != .failed { return "内核链路待启动" }
        return "通道不可用"
    }

    // MARK: - Edition mismatch (kernel edition on iOS 26/27)

    /// 内核专用版装在 iOS 26/27 上：整页已置灰，只剩这张说明卡和
    /// 下面的「应用更新」能用，指用户去装正式版。
    private var mismatchCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("版本与系统不对应")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.primaryText)
            Text("此版本为 iOS 17/18 系统内核专用版本，请使用正式版。")
                .font(.system(size: 13))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("正式版在本仓库的最新正式发行版里。下载装好正式版之后，这个内核专用版可以删掉。")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: 16)
    }

    // MARK: - Kernel chain (iOS 17/18)

    /// iOS 17/18 走内核链路：不用共享组、不用识别签名方式，
    /// 但内核链路得手动启动（失败可能重启应用）。
    private var kernelCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("内核链路")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.primaryText)
                Spacer()
                Text(kernelStatusText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(state.kernelState == .active ? Color.green
                                     : state.kernelState == .failed ? Color.orange : Color.secondaryText)
            }
            Text("这台设备是 iOS 17/18，走内核链路：不用共享组，也不用识别签名方式。启动后应用能访问所有应用的数据，全部功能都能用。")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            // 口径说明：内核链路是竞争型漏洞利用，成功率本就只有五成左右。
            // 不写清楚，用户会把「启动失败 + 手机重启」当成应用有 bug。
            VStack(alignment: .leading, spacing: 4) {
                Text("关于成功率（重要）")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                Text("内核链路本身的成功率大约五成，失败一次手机就会重启一次——这不是应用有 bug，是这类内核漏洞利用的固有概率。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("重启后请等两分钟，再重新打开应用点「启动内核链路」，通常第二次就能过。设备跑起来之后可以一直用，不需要再启动。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.22), lineWidth: 1)
            )
            Text("启动通常要 1–3 分钟，期间请保持应用在前台。")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if state.kernelBootWaitSeconds > 0 {
                Text("刚重启完：还要等 \(state.kernelBootWaitSeconds) 秒才能启动。")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                state.startKernel()
            } label: {
                HStack(spacing: 8) {
                    if state.kernelState == .running {
                        ProgressView().tint(.white)
                    }
                    Text(state.kernelState == .active ? "内核链路已就绪"
                         : state.kernelState == .running ? "正在启动…" : "启动内核链路")
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.accentCyan.opacity(state.kernelState == .active ? 0.25 : 0.9),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .foregroundStyle(state.kernelState == .active ? Color.accentCyan : .white)
            }
            .buttonStyle(.plain)
            .disabled(state.kernelState == .running || state.kernelState == .active
                      || state.kernelBootWaitSeconds > 0)
            .padding(.top, 7)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: 24)
    }

    private var kernelStatusText: String {
        switch state.kernelState {
        case .active: return "已就绪"
        case .running: return "正在启动…"
        case .failed: return "启动失败"
        case .idle: return "还没启动"
        }
    }

    // MARK: - Hero status card

    /// 状态大卡（界面重设计定稿）：圆环＋守护状态＋三个数
    /// （已登记素材/备份份数/规则版本）。签名方式并进状态行，
    /// 不再单独一张卡。
    private var heroCard: some View {
        let total = state.recipes.count
        let frozen = state.recipes.filter { $0.frozen }.count
        let fraction = total > 0 ? Double(frozen) / Double(total) : 0
        return VStack(spacing: 0) {
            HStack(spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(Color.primaryText.opacity(0.10), lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(Color.accentCyan, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Color.accentCyan)
                }
                .frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 6) {
                    Text(heroTitle)
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(Color.primaryText)
                    Text(heroStateLine)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.secondaryText)
                    if state.recurredRecipeCount > 0 {
                        Text("有 \(state.recurredRecipeCount) 个文件复发，记得重新冻结")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.orange)
                    }
                }
                Spacer(minLength: 0)
            }
            Divider()
                .overlay(Color.primaryText.opacity(0.07))
                .padding(.vertical, 16)
            HStack(spacing: 0) {
                heroStat(value: "\(total)", label: "已登记素材")
                heroDivider
                heroStat(value: "\(state.backups.count)", label: "备份份数")
                heroDivider
                heroStat(value: RulesStore.currentVersion > 0 ? RulesStore.currentDisplayVersion : "—", label: "广告规则版本")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: 24)
    }

    /// 大卡标题（Grace 2026-11-26 定）：通道没就绪先报通道状态；
    /// 通道就绪后看有没有冻住的素材——有＝守护中，没有＝未守护。
    /// 全部还原会把素材解冻，还原完自动回到未守护。
    private var heroTitle: String {
        if state.channelChecking { return "正在检测通道" }
        if !state.channelReady { return "通道不可用" }
        return state.recipes.contains { $0.frozen } ? "守护中" : "未守护"
    }

    private var heroStateLine: String {
        let sign: String
        switch state.signMethod {
        case "cert": sign = "证书签名"
        case "livecontainer": sign = "LiveContainer"
        case "free": sign = "免费 ID 签名"
        default: sign = "正在识别签名方式"
        }
        let channel = state.channelReady ? "通道就绪" : (state.channelChecking ? "正在检测通道" : "通道不可用")
        return "\(sign) · \(channel)"
    }

    private func heroStat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primaryText)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroDivider: some View {
        Rectangle()
            .fill(Color.primaryText.opacity(0.08))
            .frame(width: 1, height: 34)
            .padding(.trailing, 14)
    }

    /// 仅在底层无法识别签名方式时拦截文件功能；教程、日志、设置和维护类入口不走这里。
    private func requireSign() -> Bool {
        // iOS 17/18 的内核链路与签名方式无关：识别不出签名也不该拦。
        guard state.signMethod == nil, !state.kernelSupported else { return true }
        state.noteSignGateBlocked()
        state.alertText = "暂时无法自动识别签名方式，文件通道功能已暂停。请重新安装应用；如果仍无法识别，请导出运行日志排查。"
        return false
    }

    // MARK: - Announcement entry

    /// 更新公告入口（清单第 20 条）：主页最上方、签名方式卡上面，
    /// 跟「使用教程」一行同款式；未读带红点，点开看公告卡。
    /// 更新公告＋使用教程两个入口行并成一组：宽屏（折叠屏内屏等）
    /// 下并排双列，窄屏上下排列（清单第 28 条）。
    private var entryPair: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
            announcementEntry
            tutorialEntry
        }
    }

    private var announcementEntry: some View {
        Button {
            showAnnouncement = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "megaphone")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentCyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("更新公告")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentCyan)
                    Text(state.announcement?.title ?? "暂无新公告")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                if state.announcementUnread {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentCyan)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.accentWash.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tutorial entry

    private var tutorialEntry: some View {
        Button {
            showTutorial = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "book")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentCyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("使用教程")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentCyan)
                    Text("第一次用，先看这里")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentCyan)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.accentWash.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }


    // MARK: - Full scan (iOS 26 fallback)

    /// iOS 26 这类系统上直接查不到应用列表，底层要先全盘扫描一次：
    /// 确认卡（开始/先不）、进度卡（可停止）、还没扫时的入口卡，三选一。
    private var fullScanCards: some View {
        Group {
            if let prompt = state.fullScanPrompt {
                VStack(alignment: .leading, spacing: 12) {
                    Text("需要先全盘扫描一次")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.primaryText)
                    Text("这台设备读不到应用列表（系统把直接查的路关了）。全盘扫描能把所有应用找出来，大约要 \(max(1, Int(ceil(prompt.seconds / 60)))) 分钟，只用完整扫这一次，之后会记住；中途停下，下次能接着扫。扫描时请让应用留在前台，最好插着电。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button { state.answerFullScan(false) } label: {
                            Text("先不扫")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.primaryText)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(Color.primaryText.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Button { if requireSign() { state.answerFullScan(true) } } label: {
                            Text("开始扫描")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.appBackground)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(Color.primaryText, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if let progress = state.fullScanProgress {
                VStack(alignment: .leading, spacing: 12) {
                    Text("正在全盘扫描，找齐所有应用…")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.primaryText)
                    if progress.total > 0 {
                        ProgressView(value: Double(progress.done), total: Double(progress.total))
                            .tint(Color.accentCyan)
                        Text("已扫 \(progress.done) / \(progress.total)")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondaryText)
                    } else {
                        ProgressView()
                            .tint(Color.accentCyan)
                    }
                    Button { state.stopFullScan() } label: {
                        Text("停止")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.primaryText)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Color.primaryText.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel(radius: 16)
            } else if state.didLoadContainers && state.containers.isEmpty && state.channelReady {
                VStack(alignment: .leading, spacing: 12) {
                    Text("还没读到应用列表")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.primaryText)
                    Text("这台设备需要全盘扫描一次，才能把应用找齐。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondaryText)
                    Button { if requireSign() { state.refreshContainers() } } label: {
                        Text("开始全盘扫描")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.appBackground)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Color.primaryText, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    // MARK: - Target

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("当前目标应用", systemImage: "app.badge")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.secondaryText)
                Spacer()
                Button {
                    if requireSign() { showAppPicker = true }
                } label: {
                    Text(state.checkedIDs.isEmpty ? "更换" : "浏览应用列表")
                        .font(.system(size: state.checkedIDs.isEmpty ? 14 : 13, weight: .semibold))
                        .foregroundStyle(Color.accentCyan)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.accentWash.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primaryText.opacity(0.08))
                        .frame(width: 52, height: 52)
                    // 第 92 条：选了单个应用时这里显示它的图标；
                    // 没选、批量勾选时还是原来的云朵（Grace 定）。
                    if state.checkedIDs.isEmpty && state.targetChosen,
                       let icon = state.appIcons[state.target.bundleID] {
                        Image(uiImage: icon)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else if state.checkedIDs.isEmpty && state.targetChosen {
                        Image(systemName: "app")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.primaryText.opacity(0.7))
                    } else {
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 25))
                            .foregroundStyle(Color.primaryText.opacity(0.88))
                    }
                }
                if state.checkedIDs.isEmpty && !state.targetChosen {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("未选择应用")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.primaryText)
                        Text("先选择一个应用，再开始检测广告资源")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondaryText)
                    }
                    Spacer()
                    StatusBadge(text: "未选择", tint: .orange)
                } else if state.checkedIDs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.target.name)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.primaryText)
                        Text(state.isWhitelisted(state.target.bundleID) ? "已加入排除白名单" : state.target.bundleID)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondaryText)
                    }
                    Spacer()
                    StatusBadge(text: state.isWhitelisted(state.target.bundleID) ? "已排除" : (state.targetPath == nil ? "没有容器" : "已找到"),
                                tint: state.isWhitelisted(state.target.bundleID) || state.targetPath == nil ? .orange : .green)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("已勾选 \(state.checkedIDs.count) 个应用")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.primaryText)
                        Text("游戏除外，扫描和去除会一起处理")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondaryText)
                    }
                    Spacer()
                }
            }
            Divider().overlay(Color.primaryText.opacity(0.07))
            HStack {
                smallButton(state.allUserAppsChecked ? "取消批量选择" : "批量选择应用", symbol: "checklist") {
                    if requireSign() { state.toggleCheckAllUserApps() }
                }
                Spacer(minLength: 0)
            }
            Button {
                if state.checkedIDs.count >= 2 {
                    showSingleAppEntryAlert = true
                } else if requireSign() {
                    if !state.targetChosen || state.targetPath == nil || state.isWhitelisted(state.target.bundleID) {
                        state.alertText = "请先选择一个可访问、未加入白名单的 App。"
                    } else {
                        showLaunchHack = true
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "viewfinder")
                        .font(.system(size: 17, weight: .semibold))
                    Text("LaunchHack")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(Color.appBackground)
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(Color.primaryText,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            HStack(spacing: 12) {
                Image(systemName: "hand.raised.slash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentCyan)
                    .frame(width: 30, height: 30)
                    .background(Color.accentWash.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("排除白名单")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.primaryText)
                    Text(state.appWhitelist.isEmpty ? "指定应用完全跳过扫描、清理和守护" : "已排除 \(state.appWhitelist.count) 个应用")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer()
                Button { showWhitelist = true } label: {
                    HStack(spacing: 4) {
                        Text("管理")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentCyan)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primaryText.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Label("操作前请先完全退出目标应用", systemImage: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
        }
        .padding(16)
        .panel(radius: 16)
    }

    private func smallButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(Color.accentCyan)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Color.accentWash.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Flow (scan first, then clear)

    /// 两步流程卡（界面重设计定稿，顺序由 Grace 定）：先扫描 → 再去广告；
    /// 卡底一排全部还原/备份记录。清除扫描与更新规则排在卡下面一行，
    /// 复发重冻卡再下面。素材计数在状态大卡里，这里不再重复摆方块。
    private var flowSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                flowStep(number: 1,
                         title: "先扫描",
                         detail: state.scanTargets.isEmpty ? "找出目标应用里的广告素材，列出来给你看" : "已找到 \(state.scanTargets.count) 个素材，可以去除",
                         buttonTitle: "开始扫描",
                         symbol: "arrow.clockwise",
                         filled: true) {
                    state.scanBaidu()
                }
                Divider().overlay(Color.primaryText.opacity(0.06)).padding(.leading, 56)
                flowStep(number: 2,
                         title: "再去广告",
                         detail: "把扫到的素材冻起来，打开应用不再弹",
                         buttonTitle: "开始去除",
                         symbol: "eraser.fill",
                         filled: false) {
                    if state.scanTargets.isEmpty {
                        showNeedScanAlert = true
                    } else {
                        showClearConfirm = true
                    }
                }
                Divider().overlay(Color.primaryText.opacity(0.06))
                HStack(spacing: 0) {
                    flowMiniAction(title: "全部还原", symbol: "arrow.uturn.backward") {
                        showRestoreConfirm = true
                    }
                    Rectangle().fill(Color.primaryText.opacity(0.06)).frame(width: 1, height: 44)
                    flowMiniAction(title: "备份记录", symbol: "externaldrive") {
                        showBackups = true
                    }
                }
            }
            .panel(radius: 20)
            HStack(spacing: 12) {
                opsPairButton(title: "清除扫描", symbol: "trash",
                              disabled: state.scanTargets.isEmpty && state.launchHackMarks.isEmpty && state.launchHackFindings.isEmpty) {
                    showClearScanConfirm = true
                }
                opsPairButton(title: RulesStore.currentVersion > 0 ? "更新规则 · 第 \(RulesStore.currentDisplayVersion) 版" : "更新规则",
                              symbol: "arrow.triangle.2.circlepath",
                              disabled: false) {
                    state.updateRules()
                }
            }
            if !state.rulesStatus.isEmpty {
                Text(state.rulesStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryText)
            }
            if state.lastScanSkippedFrozen > 0 {
                Text("已冻结的跳过了 \(state.lastScanSkippedFrozen) 个，不会重复去除、不会重复备份。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryText)
            }
            if state.recurredRecipeCount > 0 {
                Button {
                    showRefreezeConfirm = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "snowflake")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("一键冻结已复发（\(state.recurredRecipeCount)）")
                                .font(.system(size: 16, weight: .semibold))
                            Text("把又变大的文件重新去除并冻结")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.secondaryText)
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.orange)
                    }
                    .foregroundStyle(Color.primaryText)
                    .padding(.horizontal, 16)
                    .frame(height: 68)
                    .background(Color.orange.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func flowStep(number: Int, title: String, detail: String,
                          buttonTitle: String, symbol: String, filled: Bool,
                          action: @escaping () -> Void) -> some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(filled ? Color.accentCyan : Color.clear)
                    .overlay(Circle().stroke(filled ? Color.clear : Color.secondaryText.opacity(0.5), lineWidth: 1.5))
                    .frame(width: 27, height: 27)
                Text("\(number)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(filled ? Color.appBackground : Color.secondaryText)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                if requireSign() { action() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                    Text(buttonTitle)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Color.appBackground)
                .padding(.horizontal, 15)
                .frame(height: 38)
                .background(filled ? Color.accentCoral : Color.primaryText, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    private func flowMiniAction(title: String, symbol: String,
                                action: @escaping () -> Void) -> some View {
        Button {
            if requireSign() { action() }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.accentCyan)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 第 71 条的操作区并排按钮：跟第 59 条扫描按钮同款（面板
    /// 底色＋细描边）；不走 requireSign，保持两个按钮原来的行为。
    private func opsPairButton(title: String, symbol: String, disabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentCyan)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.panel,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primaryText.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    private var sourceSection: some View {
        // 第 96 条：这一列的数字按配方汇总，现算现显示，跟配方增减实时同步。
        let tallies = state.recipeTallies
        return VStack(spacing: 0) {
            sourceRow(name: "软件自营", symbol: "building.2.crop.circle", tint: .cyan, count: tallies["软件自营"] ?? 0)
            rowDivider
            sourceRow(name: "优量汇", symbol: "rectangle.stack", tint: .blue, count: tallies["优量汇"] ?? 0)
            rowDivider
            sourceRow(name: "穿山甲", symbol: "leaf", tint: .green, count: tallies["穿山甲"] ?? 0)
            rowDivider
            sourceRow(name: "BeiZi", symbol: "square.grid.2x2", tint: .orange, count: tallies["BeiZi"] ?? 0)
            rowDivider
            sourceRow(name: "美数", symbol: "target", tint: .purple, count: tallies["美数"] ?? 0)
            rowDivider
            sourceRow(name: "UBIX", symbol: "cube", tint: .teal, count: tallies["UBIX"] ?? 0)
            rowDivider
            sourceRow(name: "趣盟", symbol: "link", tint: .yellow, count: tallies["趣盟"] ?? 0)
            rowDivider
            sourceRow(name: "AdMob", symbol: "globe", tint: .pink, count: tallies["AdMob"] ?? 0)
            rowDivider
            sourceRow(name: "其他广告", symbol: "ellipsis.circle", tint: .gray, count: tallies["其他广告"] ?? 0)
            if (tallies[AppState.launchHackTargetGroup] ?? 0) > 0 {
                sourceRow(name: "LaunchHack 识别", symbol: "viewfinder", tint: Color.accentCyan, count: tallies[AppState.launchHackTargetGroup] ?? 0)
            }
        }
        .padding(.horizontal, 16)
        .panel()
    }

    private func sourceRow(name: String, symbol: String, tint: Color, count: Int) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint)
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            .frame(width: 28, height: 28)
            Text(name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.primaryText)
            Spacer()
            // 第 96 条（取代第 72 条口径）：行尾是这家广告商的配方数，
            // 按配方现算；没有就是 0 个，不再有「未扫描」。
            Text("\(count) 个")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(count > 0 ? Color.accentCyan : Color.secondaryText)
        }
        .padding(.vertical, 12)
    }

    private var rowDivider: some View {
        Divider().overlay(Color.primaryText.opacity(0.06)).padding(.leading, 40)
    }

    /// 第 95 条：模板命中单独成卡。按长相认出来的目录，可能认错，
    /// 用户逐组看过、点「加入处理」才进待处理清单，之后跟普通素材
    /// 一样走备份、去除、守护。第 97 条的结构指纹命中、第 98 条的
    /// 穿山甲索引命中也进这张卡，行里标明是哪种命中。
    private var templateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "模板命中（待确认）",
                          subtitle: "这些目录名字对不上名单，但长得像广告缓存，可能认错。确认是广告的，点加入处理。")
            VStack(spacing: 0) {
                ForEach(Array(state.templateHitGroups.enumerated()), id: \.element.id) { index, hit in
                    if index > 0 { rowDivider }
                    HStack(spacing: 12) {
                        AppIconView(bundleID: hit.bundleID, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(hit.appName) · \(hit.group)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.primaryText)
                                .lineLimit(1)
                            Text(hit.root)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.secondaryText)
                                .lineLimit(2)
                            Text("\(hit.isIndex ? "索引命中" : hit.isFingerprint ? "指纹命中" : "模板命中") · \(hit.files.count) 个文件 · \(Format.bytes(hit.totalSize))")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.secondaryText)
                        }
                        Spacer()
                        Button {
                            state.includeTemplateHitGroup(hit)
                        } label: {
                            Text("加入处理")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.accentCyan)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.accentWash.opacity(0.5), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 16)
            .panel()
        }
    }

    // MARK: - Recipes

    private var recipesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "已守护应用", subtitle: "每次打开本应用都会复查配方状态")
                Spacer()
                Button {
                    if requireSign() { showRecipes = true }
                } label: {
                    Text("全部")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.accentCyan)
                }
                .buttonStyle(.plain)
            }
            if state.recipes.isEmpty {
                Text("还没有配方。去除广告素材后，会自动把去除过的文件存进来，下次打开自动复查。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel()
            } else {
                VStack(spacing: 0) {
                    let preview = Array(recipeSummaries.prefix(4))
                    ForEach(Array(preview.enumerated()), id: \.offset) { index, summary in
                        appRecipeRow(summary)
                        if index < preview.count - 1 {
                            rowDivider
                        }
                    }
                }
                .padding(.horizontal, 16)
                .panel()
            }
        }
    }

    /// 主页按应用归并：一个应用一行，不管它守了多少个文件。
    private var recipeSummaries: [(bundleID: String, name: String, count: Int, frozen: Int, recurred: Int)] {
        Dictionary(grouping: state.recipes, by: { $0.bundleID }).map { bundleID, items in
            (bundleID: bundleID,
             name: items.first?.appName ?? bundleID,
             count: items.count,
             frozen: items.filter { $0.frozen }.count,
             recurred: items.filter { $0.lastState == RecipeState.recurred.rawValue }.count)
        }.sorted { $0.name < $1.name }
    }

    private func appRecipeRow(_ summary: (bundleID: String, name: String, count: Int, frozen: Int, recurred: Int)) -> some View {
        Button {
            if requireSign() { showRecipes = true }
        } label: {
            HStack(spacing: 12) {
                AppIconView(bundleID: summary.bundleID, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.primaryText)
                    Text("共 \(summary.count) 个文件 · 已冻结 \(summary.frozen) 个")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer()
                if summary.recurred > 0 {
                    StatusBadge(text: "有复发", tint: .orange)
                } else {
                    StatusBadge(text: "守护中", tint: .green)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.secondaryText.opacity(0.7))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)
    }

    private func recipeRow(_ recipe: Recipe) -> some View {
        let stateValue = RecipeState(rawValue: recipe.lastState) ?? .unknown
        return HStack(spacing: 12) {
            Image(systemName: recipe.frozen ? "snowflake" : (recipe.placeholder ? "folder" : "shield.lefthalf.filled"))
                .font(.system(size: 15))
                .foregroundStyle(recipeTint(stateValue))
                .frame(width: 26, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(recipe.appName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primaryText)
                Text(recipe.relativePath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            StatusBadge(text: stateValue.label, tint: recipeTint(stateValue))
        }
        .padding(.vertical, 12)
    }

    // MARK: - Logs and footer

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "运行日志", subtitle: "记录操作结果与失败原因")
                Spacer()
                Button {
                    showLogs = true
                } label: {
                    Text("全部")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.accentCyan)
                }
                .buttonStyle(.plain)
            }
            LogPreview(logs: state.logs)
        }
    }

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("应用更新", systemImage: "arrow.down.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                Spacer()
                Button {
                    state.checkForUpdate()
                } label: {
                    Text("检测更新")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentCyan)
                }
                .buttonStyle(.plain)
            }
            Text(state.updateStatus.isEmpty ? "当前版本 \(state.appVersionText)" : state.updateStatus)
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
            // 「内核专用更新」只在版本不对应时出现：正式版装在
            // iOS 17/18 上才有这一行，26/27 和其他通道都不显示。
            if GitHubUpdate.channel == .formal, state.editionMismatch {
                Toggle(isOn: $state.checkKernelUpdates) {
                    Text("内核专用更新")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.primaryText)
                }
                .tint(Color.accentCyan)
            }
            if let progress = state.downloadProgress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                        .tint(Color.accentCyan)
                    Text("正在下载新版… \(Int(progress * 100))%")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondaryText)
                }
            } else if let url = state.downloadedIPA {
                Button {
                    ipaShareItem = ShareItem(url: url)
                } label: {
                    Label("分享安装包（拿去签名）", systemImage: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentCyan)
                }
                .buttonStyle(.plain)
            } else if state.availableVersion != nil {
                Button {
                    state.downloadUpdate()
                } label: {
                    Label("下载新版", systemImage: "arrow.down.to.line")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentCyan)
                }
                .buttonStyle(.plain)
            }
            Divider().overlay(Color.primaryText.opacity(0.07))
            HStack {
                Label("清除缓存", systemImage: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                Spacer()
                Button {
                    showClearCacheConfirm = true
                } label: {
                    Text("清除")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentCyan)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var footer: some View {
        HStack {
            Text("LaunchShield")
            Spacer()
            Text("版本 \(state.appVersionText)")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Color.secondaryText.opacity(0.65))
        .padding(.top, 2)
    }
}


/// 第 86/89/92 条共用：应用图标（state.appIcons 里同一套），
/// 还没取到的用通用图样占位。
struct AppIconView: View {
    @EnvironmentObject private var state: AppState
    let bundleID: String
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primaryText.opacity(0.06))
            if let icon = state.appIcons[bundleID] {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "app")
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(Color.primaryText.opacity(0.7))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// App 排除白名单管理：可从已识别应用选择，也可手动录入 Bundle ID。
private struct AppWhitelistView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var manualBundleID = ""

    private var filteredApps: [ContainerInfo] {
        // 第 79 条：和选目标应用一个口径，系统自带应用不显示。
        let apps = state.containers.filter {
            !$0.isGroup && $0.bundleID != AppState.ownBundleID &&
            !AppState.isSystemApp($0) && state.isMainApp($0)
        }
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    /// 白名单里的排前面。用一次分组代替排序比较器：原来每比较一次要查两次
    /// isWhitelisted，上千个应用就是上万次比较。
    private func orderedApps(_ apps: [ContainerInfo]) -> [ContainerInfo] {
        let whitelisted = state.whitelistIndex
        var first: [ContainerInfo] = []
        var second: [ContainerInfo] = []
        first.reserveCapacity(apps.count)
        second.reserveCapacity(apps.count)
        for app in apps {
            if whitelisted.contains(app.bundleID.lowercased()) { first.append(app) } else { second.append(app) }
        }
        return first + second
    }

    var body: some View {
        // 每渲染一次只算一次：原来筛选＋排序写在 ForEach 的每一行里（还用
        // filteredApps.last 做分隔线判断），一千多行会把整个列表重算一千多次。
        let rows = orderedApps(filteredApps)
        return SheetPage("排除白名单") {
            // 整页可滚：已排除名单再长也不会把下面的添加区挤没。
            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("加入白名单的应用不会被扫描、清理或守护。规则只按 Bundle ID 匹配。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color(red: 0.48, green: 0.53, blue: 0.60))
                            Image(systemName: "nosign")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.white)
                        }
                        .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("已排除 \(state.appWhitelist.count) 个应用")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.primaryText)
                            Text("开关打开的应用会被完全跳过，不扫也不冻")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.secondaryText)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(12)
                .panel(radius: 16)

                VStack(alignment: .leading, spacing: 8) {
                    Text("全部应用 · 开关就是加不加白名单")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.primaryText)
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Color.secondaryText)
                        TextField("搜索应用名或 Bundle ID", text: $query)
                            .font(.system(size: 12))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .padding(12)
                    .background(Color.primaryText.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { app in
                                HStack(spacing: 8) {
                                    AppIconView(bundleID: app.bundleID, size: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(Color.primaryText)
                                        Text(state.isWhitelisted(app.bundleID) ? "在白名单里 · 完全跳过" : app.bundleID)
                                            .font(.system(size: 10, design: state.isWhitelisted(app.bundleID) ? .default : .monospaced))
                                            .foregroundStyle(Color.secondaryText)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    SwitchToggle(isOn: Binding(
                                        get: { state.isWhitelisted(app.bundleID) },
                                        set: { on in
                                            if on { state.addToWhitelist(app) }
                                            else { state.removeFromWhitelist(app.bundleID) }
                                        }
                                    ))
                                }
                                .padding(.vertical, 8)
                                if app.id != rows.last?.id {
                                    Divider().overlay(Color.primaryText.opacity(0.06))
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 470)
                }
                .padding(12)
                .panel(radius: 16)

                VStack(alignment: .leading, spacing: 8) {
                    Text("手动添加 Bundle ID")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.primaryText)
                    HStack(spacing: 8) {
                        TextField("com.example.app", text: $manualBundleID)
                            .font(.system(size: 12, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(12)
                            .background(Color.primaryText.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                        Button("添加") {
                            if state.addWhitelistBundleID(manualBundleID) { manualBundleID = "" }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentCyan)
                        .disabled(manualBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(12)
                .panel(radius: 16)
                Spacer(minLength: 0)
            }
            .padding(16)
            }
        }
        .appAlert(state)
        .onAppear {
            if state.containers.isEmpty { state.refreshContainers() }
        }
    }
}

/// 公告卡（清单第 20 条）：标题＋版本日期＋正文＋「知道了」。
/// 没有公告时进来就是一句「暂无新公告」。
struct AnnouncementView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetPage("更新公告") {
            VStack(alignment: .leading, spacing: 16) {
                if let announcement = state.announcement {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(announcement.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.primaryText)
                        Text(announcement.date.isEmpty
                             ? "版本 \(announcement.version)"
                             : "版本 \(announcement.version) · \(announcement.date)")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondaryText)
                        if !announcement.body.isEmpty {
                            Text(announcement.body)
                                .font(.system(size: 14))
                                .foregroundStyle(Color.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel(radius: 16)
                } else {
                    Text("暂无新公告")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.secondaryText)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .panel(radius: 16)
                }
                Button {
                    dismiss()
                } label: {
                    Text("知道了")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.appBackground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.primaryText, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }
}
