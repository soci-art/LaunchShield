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
    @State private var ipaShareItem: ShareItem?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        announcementEntry
                        signCard
                        tutorialEntry
                        targetCard
                        fullScanCards
                        summarySection
                        actionsSection
                        sourceSection
                        if !state.templateTargets.isEmpty {
                            templateSection
                        }
                        recipesSection
                        logSection
                        updateSection
                        footer
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 30)
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
                state.recheckRemindersIfStale()
                // 第 76 条：前台期间实时检测复发。
                state.startForegroundRecurrenceMonitor()
            } else if phase == .background {
                state.stopForegroundRecurrenceMonitor()
            }
        }
        .onAppear {
            // 第 76 条：刚打开 App 时 scenePhase 不一定触发
            // onChange，这里直接启动前台实时检测。
            state.startForegroundRecurrenceMonitor()
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
        .alert("请选择单个应用", isPresented: $showSingleAppEntryAlert) {
            Button("好", role: .cancel) { }
        } message: {
            Text("LaunchHack 只对单个应用检测。主页现在选了多个应用，先改成只选一个再来。")
        }
        .alert("还没有扫描到素材", isPresented: $showNeedScanAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text("开始去除广告只处理已经扫描到的素材。你还没有扫描，先去扫描一遍，扫完再回来去除。")
        }
        .confirmationDialog("清除扫描结果？", isPresented: $showClearScanConfirm, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                state.clearScanResults()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("会把扫描到的结果和 LaunchHack 标记全部清掉，清完要重新扫描、重新标记。不动任何文件、不去除、不解冻。")
        }
        .confirmationDialog("把已复发的文件重新去除并冻结？", isPresented: $showRefreezeConfirm, titleVisibility: .visible) {
            Button("重新去除并冻结 \(state.recurredRecipeCount) 个") {
                state.refreezeRelapsed()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("会先备份，再把这些又变大的文件去除并冻结。")
        }
        .confirmationDialog("确定要去除这些素材吗？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("先备份，再开始去除广告", role: .destructive) {
                state.clearAllAfterScan()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("请先完全退出目标应用（上滑关闭）。每个文件都会先备份，任何一步失败就停下，并告诉你停在哪个文件。")
        }
        .confirmationDialog("确定要清除缓存吗？", isPresented: $showClearCacheConfirm, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                state.clearCache()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("会清理更新 IPA、扫描索引、缩略图、识别缓存和临时文件；云端规则、备份、配方、守护名单、用户设置及运行日志均会保留。")
        }
        .confirmationDialog("确定要全部还原吗？", isPresented: $showRestoreConfirm, titleVisibility: .visible) {
            Button("逐个写回并核对 MD5", role: .destructive) {
                state.restoreAll()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("请先完全退出目标应用。还原会用备份覆盖现在的文件。")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(LinearGradient(colors: [Color.cyan.opacity(0.95), Color.blue.opacity(0.78)],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                    .frame(width: 54, height: 54)
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("LaunchShield")
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .layoutPriority(1)
                    // 「预发行」标签只许出现在真预发行包里：按更新通道
                    // 判断（预发行工作流会在 Info.plist 盖
                    // LSUpdateChannel=prerelease，正式版没有）。正式版
                    // 界面永远不带这几个字（第 85 条）。
                    if GitHubUpdate.isPrereleaseChannel {
                        Text("预发行")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 7)
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
                HStack(spacing: 5) {
                    Circle()
                        .fill(state.channelReady ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(state.channelChecking ? "正在检测通道" : (state.channelReady ? "通道就绪" : "通道不可用"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.secondaryText)
                        .fixedSize()
                }
            }
        }
    }

    // MARK: - Signature method

    private var signCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("签名方式")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.primaryText)
            Text(state.signMethod == "cert" ? "已识别：证书签名" : (state.signMethod == "livecontainer" ? "已识别：LiveContainer" : (state.signMethod == "free" ? "已识别：免费 ID 签名" : "正在识别签名方式…")))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(state.signMethod == nil ? Color.secondaryText : Color.accentCyan)
            Text("应用会读取自身签名配置自动判断。")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: 24)
    }

    /// 仅在底层无法识别签名方式时拦截文件功能；教程、日志、设置和维护类入口不走这里。
    private func requireSign() -> Bool {
        guard state.signMethod == nil else { return true }
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
            HStack(spacing: 10) {
                Text("📣")
                    .font(.system(size: 16))
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
            .background(Color.accentCyan.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tutorial entry

    private var tutorialEntry: some View {
        Button {
            showTutorial = true
        } label: {
            HStack(spacing: 10) {
                Text("📖")
                    .font(.system(size: 16))
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
            .background(Color.accentCyan.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                VStack(alignment: .leading, spacing: 10) {
                    Text("需要先全盘扫描一次")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.primaryText)
                    Text("这台设备读不到应用列表（系统把直接查的路关了）。全盘扫描能把所有应用找出来，大约要 \(max(1, Int(ceil(prompt.seconds / 60)))) 分钟，只用完整扫这一次，之后会记住；中途停下，下次能接着扫。扫描时请让应用留在前台，最好插着电。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button { state.answerFullScan(false) } label: {
                            Text("先不扫")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(Color.primaryText)
                                .padding(.horizontal, 16).padding(.vertical, 9)
                                .background(Color.primaryText.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Button { if requireSign() { state.answerFullScan(true) } } label: {
                            Text("开始扫描")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16).padding(.vertical, 9)
                                .background(Color.accentCyan, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                }
                .padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else if let progress = state.fullScanProgress {
                VStack(alignment: .leading, spacing: 10) {
                    Text("正在全盘扫描，找齐所有应用…")
                        .font(.system(size: 15, weight: .bold))
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
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Color.primaryText)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(Color.primaryText.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel(radius: 18)
            } else if state.didLoadContainers && state.containers.isEmpty && state.channelReady {
                VStack(alignment: .leading, spacing: 10) {
                    Text("还没读到应用列表")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.primaryText)
                    Text("这台设备需要全盘扫描一次，才能把应用找齐。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.secondaryText)
                    Button { if requireSign() { state.refreshContainers() } } label: {
                        Text("开始全盘扫描")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(Color.accentCyan, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                        .padding(.vertical, 7)
                        .background(Color.accentCyan.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Color.primaryText.opacity(0.08))
                        .frame(width: 54, height: 54)
                    // 第 92 条：选了单个应用时这里显示它的图标；
                    // 没选、批量勾选时还是原来的云朵（Grace 定）。
                    if state.checkedIDs.isEmpty && state.targetChosen,
                       let icon = state.appIcons[state.target.bundleID] {
                        Image(uiImage: icon)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 54, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
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
                    VStack(alignment: .leading, spacing: 5) {
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
                    VStack(alignment: .leading, spacing: 5) {
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
                    VStack(alignment: .leading, spacing: 5) {
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
                HStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "viewfinder")
                        .font(.system(size: 17, weight: .semibold))
                    Text("LaunchHack")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(LinearGradient(colors: [Color.cyan.opacity(0.92), Color.blue.opacity(0.84)],
                                           startPoint: .leading,
                                           endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                Image(systemName: "hand.raised.slash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentCyan)
                    .frame(width: 30, height: 30)
                    .background(Color.accentCyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
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
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentCyan)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(Color.primaryText.opacity(0.035), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            Label("操作前请先完全退出目标应用", systemImage: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
        }
        .padding(17)
        .panel(radius: 22)
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
            .background(Color.accentCyan.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Summary

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "素材清单", subtitle: "扫描到的文件会按来源分类显示")
                if state.lastScanSkippedFrozen > 0 {
                    Text("已冻结的跳过了 \(state.lastScanSkippedFrozen) 个，不会重复去除、不会重复备份。")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer()
            }
            // 第 59 条：扫描改成横排带框按钮，跟备份页三个按钮
            // 一个待遇。第 93 条：深扫已删，只剩扫描一个按钮。
            HStack(spacing: 10) {
                scanActionButton(title: "扫描", symbol: "arrow.clockwise") {
                    state.scanBaidu()
                }
            }
            HStack(spacing: 10) {
                SummaryTile(title: "素材文件",
                            value: "\(state.scanTargets.count)",
                            detail: state.scanTargets.isEmpty ? "等待扫描" : "个待处理",
                            symbol: "doc.text.magnifyingglass",
                            tint: .cyan)
                SummaryTile(title: "配方",
                            value: "\(state.recipes.count)",
                            detail: "\(state.recurredRecipeCount) 个复发",
                            symbol: "shield.lefthalf.filled",
                            tint: .orange)
                SummaryTile(title: "已备份",
                            value: "\(state.backups.count)",
                            detail: "份",
                            symbol: "externaldrive",
                            tint: .green)
            }
        }
    }

    /// 第 59 条的带框扫描按钮：面板底色＋细描边，跟第 56 条
    /// 备份页按钮同款。
    private func scanActionButton(title: String, symbol: String,
                                  action: @escaping () -> Void) -> some View {
        Button {
            if requireSign() { action() }
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentCyan)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.panel,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primaryText.opacity(0.08), lineWidth: 1))
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
                .padding(.vertical, 11)
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
        VStack(spacing: 0) {
            sourceRow(name: "软件自营", symbol: "building.2.crop.circle", tint: .cyan, group: "软件自营")
            rowDivider
            sourceRow(name: "优量汇", symbol: "rectangle.stack", tint: .blue, group: "优量汇")
            rowDivider
            sourceRow(name: "穿山甲", symbol: "leaf", tint: .green, group: "穿山甲")
            rowDivider
            sourceRow(name: "BeiZi", symbol: "square.grid.2x2", tint: .orange, group: "BeiZi")
            rowDivider
            sourceRow(name: "美数", symbol: "target", tint: .purple, group: "美数")
            rowDivider
            sourceRow(name: "UBIX", symbol: "cube", tint: .teal, group: "UBIX")
            rowDivider
            sourceRow(name: "趣盟", symbol: "link", tint: .yellow, group: "趣盟")
            rowDivider
            sourceRow(name: "AdMob", symbol: "globe", tint: .pink, group: "AdMob")
            rowDivider
            sourceRow(name: "其他广告", symbol: "ellipsis.circle", tint: .gray, group: "其他广告")
            if state.targetCount(for: AppState.launchHackTargetGroup) > 0 {
                sourceRow(name: "LaunchHack 识别", symbol: "viewfinder", tint: .cyan, group: AppState.launchHackTargetGroup)
            }
        }
        .padding(.horizontal, 15)
        .panel()
    }

    private func sourceRow(name: String, symbol: String, tint: Color, group: String) -> some View {
        let count = state.targetCount(for: group)
        return HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 34)
            Text(name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.primaryText)
            Spacer()
            Text(sourceRowStatus(count: count, total: state.vendorTotals[group] ?? 0))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(state.scanTargets.isEmpty && (state.vendorTotals[group] ?? 0) == 0 ? Color.secondaryText : Color.accentCyan)
        }
        .padding(.vertical, 11)
    }

    /// 第 72 条：广告商行尾只显示数量——有待处理的显示这次的
    /// 个数，清零后待处理没了、显示累计识别数（只数字、不带
    /// 「累计」字样，Grace 定）；两者都没有才是「未扫描」。
    private func sourceRowStatus(count: Int, total: Int) -> String {
        if !state.scanTargets.isEmpty { return "\(count) 个" }
        return total > 0 ? "\(total)" : "未扫描"
    }

    private var rowDivider: some View {
        Divider().overlay(Color.primaryText.opacity(0.06)).padding(.leading, 39)
    }

    /// 第 95 条：模板命中单独成卡。按长相认出来的目录，可能认错，
    /// 用户逐组看过、点「加入处理」才进待处理清单，之后跟普通素材
    /// 一样走备份、去除、守护。
    private var templateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "模板命中（待确认）",
                          subtitle: "这些目录名字对不上名单，但长得像广告缓存，可能认错。确认是广告的，点加入处理。")
            VStack(spacing: 0) {
                ForEach(Array(state.templateHitGroups.enumerated()), id: \.element.id) { index, hit in
                    if index > 0 { rowDivider }
                    HStack(spacing: 11) {
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
                            Text("\(hit.files.count) 个文件 · \(Format.bytes(hit.totalSize))")
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
                                    .stroke(Color.accentCyan.opacity(0.5), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 15)
            .panel()
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "操作", subtitle: "每个文件独立备份与处理")
            // 第 71 条：清除扫描/更新规则归到操作板块，改成带框
            // 并排按钮，排在全部清零上面（原来在素材清单区里）。
            // 第 73 条：更新规则带上当前规则版本；还没下载过规则
            // （版本 0）时只显示「更新规则」。
            HStack(spacing: 10) {
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
            // 第 75 条：「一键冻结已复发」从已守护应用页挪到这里，
            // 排在全部清零上面；尺寸和全部清零一样（整条大卡片），
            // 橙色填满。有复发才出现，确认与重冻行为和原来一样。
            if state.recurredRecipeCount > 0 {
                Button {
                    showRefreezeConfirm = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "snowflake")
                            .font(.system(size: 18, weight: .semibold))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("一键冻结已复发（\(state.recurredRecipeCount)）")
                                .font(.system(size: 16, weight: .semibold))
                            Text("把又变大的文件重新去除并冻结")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.76))
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 17)
                    .frame(height: 68)
                    .background(LinearGradient(colors: [Color.orange.opacity(0.92), Color.red.opacity(0.78)],
                                               startPoint: .leading,
                                               endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Button {
                if requireSign() {
                    if state.scanTargets.isEmpty {
                        showNeedScanAlert = true
                    } else {
                        showClearConfirm = true
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "eraser.fill")
                        .font(.system(size: 18, weight: .semibold))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("开始去除广告")
                            .font(.system(size: 16, weight: .semibold))
                        Text("先备份，再把素材文件截断为 0 字节")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.76))
                    }
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 17)
                .frame(height: 68)
                .background(LinearGradient(colors: [Color.cyan.opacity(0.88), Color.blue.opacity(0.82)],
                                           startPoint: .leading,
                                           endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                if requireSign() { showRestoreConfirm = true }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.system(size: 19, weight: .semibold))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("全部还原")
                            .font(.system(size: 16, weight: .semibold))
                        Text("将已备份的素材逐个写回，并核对 MD5")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.secondaryText)
                }
                .foregroundStyle(Color.primaryText)
                .padding(.horizontal, 17)
                .frame(height: 68)
                .panel(radius: 17)
            }
            .buttonStyle(.plain)

            // 第 60 条：备份记录也做成整条框卡片，跟全部清零、
            // 全部还原并排成一组；颜色用紫色调，跟全部还原的
            // 深灰面板区分开。
            Button {
                if requireSign() { showBackups = true }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 19, weight: .semibold))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("备份记录")
                            .font(.system(size: 16, weight: .semibold))
                        Text("共 \(state.backups.count) 份备份，可逐个或全部还原")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 17)
                .frame(height: 68)
                .background(LinearGradient(colors: [Color.purple.opacity(0.75), Color.indigo.opacity(0.85)],
                                           startPoint: .leading,
                                           endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
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
                .padding(.horizontal, 15)
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
            HStack(spacing: 11) {
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
        .padding(.vertical, 7)
    }

    private func recipeRow(_ recipe: Recipe) -> some View {
        let stateValue = RecipeState(rawValue: recipe.lastState) ?? .unknown
        return HStack(spacing: 11) {
            Image(systemName: recipe.frozen ? "snowflake" : (recipe.placeholder ? "folder" : "shield.lefthalf.filled"))
                .font(.system(size: 15))
                .foregroundStyle(recipeTint(stateValue))
                .frame(width: 26, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(recipe.appName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primaryText)
                Text(recipe.relativePath)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            StatusBadge(text: stateValue.label, tint: recipeTint(stateValue))
        }
        .padding(.vertical, 11)
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
        VStack(alignment: .leading, spacing: 10) {
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
            if let progress = state.downloadProgress {
                VStack(alignment: .leading, spacing: 5) {
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
            RoundedRectangle(cornerRadius: 9, style: .continuous)
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
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
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
            !$0.isGroup && $0.bundleID != AppState.ownBundleID && !AppState.isSystemApp($0)
        }
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        SheetPage("排除白名单") {
            // 整页可滚：已排除名单再长也不会把下面的添加区挤没。
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("加入白名单的应用不会被扫描、清理或守护。规则只按 Bundle ID 匹配。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("已排除应用")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.primaryText)
                        Spacer()
                        Text("\(state.appWhitelist.count) 个")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.accentCyan)
                    }
                    if state.appWhitelist.isEmpty {
                        Text("还没有添加应用")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondaryText)
                            .padding(.vertical, 5)
                    } else {
                        // 名单封顶高、卡内自己滚，不再无限长下去挤占整页。
                        ScrollView {
                            VStack(alignment: .leading, spacing: 9) {
                                ForEach(state.appWhitelist.keys.sorted(), id: \.self) { bundleID in
                                    HStack(spacing: 9) {
                                        AppIconView(bundleID: bundleID, size: 32)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(state.whitelistName(for: bundleID))
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(Color.primaryText)
                                            Text(bundleID)
                                                .font(.system(size: 9, design: .monospaced))
                                                .foregroundStyle(Color.secondaryText)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Button("移除") { state.removeFromWhitelist(bundleID) }
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Color.orange)
                                            .buttonStyle(.plain)
                                    }
                                    .padding(.vertical, 5)
                                }
                            }
                        }
                        .frame(maxHeight: 240)
                    }
                }
                .padding(13)
                .panel(radius: 16)

                VStack(alignment: .leading, spacing: 8) {
                    Text("从已安装应用添加")
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
                    .padding(11)
                    .background(Color.primaryText.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredApps) { app in
                                HStack(spacing: 9) {
                                    AppIconView(bundleID: app.bundleID, size: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(Color.primaryText)
                                        Text(app.bundleID)
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(Color.secondaryText)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if state.isWhitelisted(app.bundleID) {
                                        Text("已排除")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(Color.secondaryText)
                                    } else {
                                        Button("添加") { state.addToWhitelist(app) }
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Color.accentCyan)
                                            .buttonStyle(.plain)
                                    }
                                }
                                .padding(.vertical, 9)
                                if app.id != filteredApps.last?.id {
                                    Divider().overlay(Color.primaryText.opacity(0.06))
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
                .padding(13)
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
                            .padding(11)
                            .background(Color.primaryText.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
                        Button("添加") {
                            if state.addWhitelistBundleID(manualBundleID) { manualBundleID = "" }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentCyan)
                        .disabled(manualBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(13)
                .panel(radius: 16)
                Spacer(minLength: 0)
            }
            .padding(18)
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
            VStack(alignment: .leading, spacing: 14) {
                if let announcement = state.announcement {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(announcement.title)
                            .font(.system(size: 17, weight: .bold))
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
                    .panel(radius: 18)
                } else {
                    Text("暂无新公告")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.secondaryText)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .panel(radius: 18)
                }
                Button {
                    dismiss()
                } label: {
                    Text("知道了")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.accentCyan, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .padding(18)
        }
    }
}
