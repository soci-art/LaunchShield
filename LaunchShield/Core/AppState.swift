import Foundation
import UIKit
import ImageIO
import AVFoundation


/// 更新提醒的种类：应用新版或规则新版（清单第 12 条）。
enum UpdateAlertKind {
    case app
    case rules
}

final class AppState: ObservableObject {
    /// LaunchShield 自己的 Bundle ID：永远排除在扫描/勾选/守护范围之外。
    /// 备份就存在自己的容器里，扫自己会把存着的别家广告图备份当素材
    /// 再备份一遍（备份套备份）；自己的容器一律不碰。
    static let ownBundleID = Bundle.main.bundleIdentifier ?? "com.sociart.launchshield"

    let channel = Channel.shared
    let logs = LogStore()
    let store = LibraryStore()
    let guardService = GuardService.shared

    @Published var target: AppTarget = .baidu
    /// 目标是否已由用户选定。默认未选择：打开先是空的，选了或一键勾选才有目标。
    @Published var targetChosen = false
    /// 用户手动标记的广告文件（持久化在 UserDefaults）。
    @Published var manualMarks: [ManualMark] = []
    @Published var containers: [ContainerInfo] = []
    /// 共享组（App Group）容器列表，按组标识命名。
    @Published var groupContainers: [ContainerInfo] = []
    /// 通道就绪改成异步探明：冷启动先出界面，不再被通道发现堵住首帧。
    @Published private(set) var channelReady = false
    @Published private(set) var channelChecking = true
    /// 自动识别的签名方式："cert" / "free" / "livecontainer"。
    @Published private(set) var signMethod: String? = nil
    /// 当前目标的容器路径（异步刷新缓存，界面读这个，不在渲染时现算）。
    @Published private(set) var targetPath: String?
    /// App 排除白名单：以 Bundle ID 为唯一标识，保存在本机。
    @Published var appWhitelist: [String: String] =
        UserDefaults.standard.dictionary(forKey: "ls.appWhitelist") as? [String: String] ?? [:]
    var whitelistedBundleIDs: Set<String> { Set(appWhitelist.keys.map { $0.lowercased() }) }
    func isWhitelisted(_ bundleID: String) -> Bool {
        whitelistedBundleIDs.contains(bundleID.lowercased())
    }
    func whitelistName(for bundleID: String) -> String {
        appWhitelist[bundleID.lowercased()] ?? containers.first(where: { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame })?.name ?? bundleID
    }
    func addToWhitelist(_ container: ContainerInfo) {
        addWhitelistBundleID(container.bundleID, displayName: container.name)
    }
    @discardableResult
    func addWhitelistBundleID(_ rawID: String, displayName: String? = nil) -> Bool {
        let bundleID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard bundleID.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil else {
            alertText = "Bundle ID 格式不正确，请输入类似 com.example.app 的标识符。"
            return false
        }
        let key = bundleID.lowercased()
        appWhitelist[key] = displayName?.isEmpty == false ? displayName! : (containers.first(where: { $0.bundleID.lowercased() == key })?.name ?? bundleID)
        UserDefaults.standard.set(appWhitelist, forKey: "ls.appWhitelist")
        checkedIDs = Set(checkedIDs.filter { $0.lowercased() != key })
        scanTargets.removeAll { $0.bundleID.lowercased() == key }
        candidates.removeAll { $0.bundleID.lowercased() == key }
        beforeSnapshots = beforeSnapshots.filter { $0.key.lowercased() != key }
        afterSnapshots = afterSnapshots.filter { $0.key.lowercased() != key }
        log("已将应用加入排除白名单：\\(appWhitelist[key] ?? bundleID)（\\(bundleID)）", .notice)
        return true
    }
    func removeFromWhitelist(_ bundleID: String) {
        let key = bundleID.lowercased()
        appWhitelist.removeValue(forKey: key)
        UserDefaults.standard.set(appWhitelist, forKey: "ls.appWhitelist")
        log("已从排除白名单移除：\\(bundleID)，该应用恢复正常处理", .notice)
    }
    /// 一键勾选选中的应用（批量扫描/清零的目标集）；为空时按单个目标走。
    @Published var checkedIDs: Set<String> = []
    /// 最近一次扫描的识别数据（供上传攒指纹库用）。
    @Published var lastRecognition: [AppRecognition] = []
    /// 最近一次扫描跳过的已冻结 0 字节文件数（去重：不重复清零、不重复备份）。
    @Published var lastScanSkippedFrozen = 0
    @Published var updateStatus = ""
    @Published var rulesStatus = ""
    @Published var availableVersion: String?
    /// 有新版时要弹的更新提醒（清单第 12 条的新弹窗：一句话＋取消／更新两个按钮）。
    @Published var updateAlert: UpdateAlertKind?
    /// GitHub 最新正式版安装包的直达地址：查到新版时记下，下载时按三级顺序用。
    var availableDownloadURL: URL?
    @Published var downloadProgress: Double?
    @Published var downloadedIPA: URL?
    @Published var recipes: [Recipe] = []
    @Published var backups: [BackupRecord] = []
    @Published var scanTargets: [TargetFile] = []
    @Published var splash: SplashResolution?
    @Published var isBusy = false
    @Published var busyText = ""
    @Published var alertText: String? {
        didSet {
            // 更新提醒排在别的弹窗后面时先候着：当前弹窗一关，候着的
            // 更新提醒接着弹，不再被顶掉（两个检查同批完成时发生过）。
            if alertText == nil { promotePendingUpdateAlert() }
        }
    }
    /// 等当前弹窗关掉后要补弹的更新提醒（应用或规则，二选一候着）。
    private var pendingUpdateAlert: UpdateAlertKind?

    /// 弹更新提醒：正有别的弹窗占着就先候着，不互相顶掉。
    func presentUpdateAlert(_ kind: UpdateAlertKind) {
        if updateAlert == nil, alertText == nil {
            updateAlert = kind
        } else {
            pendingUpdateAlert = kind
        }
    }

    private func promotePendingUpdateAlert() {
        guard updateAlert == nil, let pending = pendingUpdateAlert else { return }
        pendingUpdateAlert = nil
        updateAlert = pending
    }

    /// 更新提醒里点了「更新」：应用就下载新版，规则就更新规则。
    func confirmUpdateAlert() {
        let kind = updateAlert
        updateAlert = nil
        switch kind {
        case .app: downloadUpdate()
        case .rules: updateRules()
        case nil: break
        }
        promotePendingUpdateAlert()
    }

    /// 更新提醒里点了「取消」：关掉，有候着的接着弹。
    func cancelUpdateAlert() {
        updateAlert = nil
        promotePendingUpdateAlert()
    }
    /// 上次跑启动提醒检查（应用＋规则）的时间；回前台补查的节流用。
    private var lastReminderCheckAt: Date?
    /// 实时检测的定时器（清单第 12 条）：应用开着时每 30 分钟查一次。
    private var reminderTimer: Timer?
    @Published var guardInterruption: Date?
    @Published var beforeSnapshot: ContainerSnapshot?
    @Published var afterSnapshot: ContainerSnapshot?
    /// Per-app snapshots for the find-ad flow, keyed by bundle ID. The scope
    /// follows the check state: every checked app, or the single target.
    @Published var beforeSnapshots: [String: ContainerSnapshot] = [:]
    @Published var afterSnapshots: [String: ContainerSnapshot] = [:]
    @Published var candidates: [DiffCandidate] = []
    @Published var selectedCandidatePaths: Set<String> = []

    private let backupManager: BackupManager
    private let work = DispatchQueue(label: "com.sociart.launchshield.work", qos: .userInitiated)
    /// 全盘扫描（iOS 26 这类系统读不到应用列表时的兜底）：底层开扫前
    /// 先发通知问界面，用户点了开始才扫；进度也经通知回来。
    struct FullScanPrompt {
        let ids: Int64
        let seconds: Double
    }
    @Published var fullScanPrompt: FullScanPrompt?
    @Published var fullScanProgress: (done: Int64, total: Int64)?
    @Published var didLoadContainers = false
    private var fullScanTotalIds: Int64 = 0

    private var didBootstrap = false
    private var reportedNewFiles = Set<String>()

    init() {
        backupManager = BackupManager(store: store)
        UserDefaults.standard.removeObject(forKey: "ls.signMethod")
        signMethod = channel.signMethod
        // 实时检测（清单第 12 条）：应用开着时每 30 分钟自动查一次
        // 更新（应用＋规则），有新版马上提醒，不用等重启或切回前台。
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            self?.runReminderChecks()
        }
        NotificationCenter.default.addObserver(forName: Notification.Name("LSFullScanConfirmRequested"),
                                               object: nil, queue: .main) { [weak self] note in
            let ids = (note.userInfo?["ids"] as? NSNumber)?.int64Value ?? 0
            let seconds = (note.userInfo?["seconds"] as? NSNumber)?.doubleValue ?? 0
            self?.fullScanTotalIds = ids
            self?.fullScanPrompt = FullScanPrompt(ids: ids, seconds: seconds)
        }
        NotificationCenter.default.addObserver(forName: Notification.Name("LSFullScanProgress"),
                                               object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            if (note.userInfo?["finished"] as? NSNumber)?.boolValue ?? false {
                self.fullScanProgress = nil
            } else {
                let done = (note.userInfo?["done"] as? NSNumber)?.int64Value ?? 0
                let total = (note.userInfo?["total"] as? NSNumber)?.int64Value ?? 0
                self.fullScanProgress = (done: done, total: total)
            }
        }
    }

    /// 用户在全盘扫描确认卡上点了开始/先不：把答复递给底层等着的那条线。
    func answerFullScan(_ yes: Bool) {
        fullScanPrompt = nil
        if yes { fullScanProgress = (done: 0, total: fullScanTotalIds) }
        channel.answerFullScan(yes)
    }

    func stopFullScan() {
        channel.stopFullScan()
    }

    // MARK: - Derived values

    var channelDetail: String {
        channel.isAvailable ? "\(channel.routeName)：\(channel.groupText)" : channel.unavailableReason
    }
    var containerPath: String? { channel.containerPath(for: target.bundleID) }
    var targetContainer: ContainerInfo? { channel.container(for: target.bundleID) }

    var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var systemText: String {
        "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    }

    var healthyRecipeCount: Int {
        recipes.filter { (RecipeState(rawValue: $0.lastState) ?? .unknown).isHealthy }.count
    }

    var recurredRecipeCount: Int {
        recipes.filter { RecipeState(rawValue: $0.lastState) == .recurred }.count
    }

    func targetCount(for group: String) -> Int {
        scanTargets.filter { $0.group == group }.count
    }

    // MARK: - Startup

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        recipes = store.file.recipes
        backups = store.file.backups.sorted { $0.createdAt > $1.createdAt }
        loadMarks()
        runReminderChecks()
        log("LaunchShield \(appVersionText) 已启动", .info)
        log("已请求系统下次启动不使用界面快照（界面重影对策）", .info)
        log("系统 \(systemText)，设备 \(UIDevice.current.model)", .info)
        if let when = guardService.interruption {
            guardInterruption = when
            log("守护曾在 \(Format.fullDate(when)) 中断；上次不是一直运行", .warning)
        }
        guardService.log = { [weak self] message, level in
            guard let self = self else { return }
            self.log(message, level)
        }
        guardService.poll = { [weak self] deep in
            guard let self = self else { return }
            self.guardTick(deep: deep)
        }
        firstLaunchChecks()
        recheckChannel()
    }

    /// 签名方式由应用自动识别，不再由用户手动选择。

    /// 功能门拦下一次使用时记一笔（清单第 10 条：日志要记全用户动作）。
    func noteSignGateBlocked() {
        log("签名方式未能自动识别，拦下了一次功能使用", .warning)
    }

    /// 只清理可重新生成的数据：更新 IPA、Caches 与 tmp；云端规则文件保留。
    /// 配方、备份、守护名单、用户标记和持久运行日志均属于用户数据，不碰。
    func clearCache() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let temporary = fm.temporaryDirectory
        var freed: Int64 = 0
        var removed: [String] = []

        func sizeOfItem(at url: URL) -> Int64 {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { return 0 }
            if values?.isDirectory == true {
                let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey])
                var total: Int64 = 0
                while let child = enumerator?.nextObject() as? URL {
                    let childValues = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
                    if childValues?.isSymbolicLink == true {
                        enumerator?.skipDescendants()
                    } else if childValues?.isDirectory != true {
                        total += Int64(childValues?.fileSize ?? 0)
                    }
                }
                return total
            }
            return Int64(values?.fileSize ?? 0)
        }

        func removeItem(_ url: URL, label: String) {
            guard fm.fileExists(atPath: url.path) else { return }
            let size = sizeOfItem(at: url)
            do {
                try fm.removeItem(at: url)
                freed += size
                removed.append(label)
            } catch {
                log("缓存清理失败：\(label)，\(error.localizedDescription)", .warning)
            }
        }

        let updateIPA = downloadedIPA ?? docs.appendingPathComponent("LaunchShield-新版.ipa")
        if updateIPA.standardizedFileURL.path.hasPrefix(docs.standardizedFileURL.path + "/"), updateIPA.pathExtension.lowercased() == "ipa" {
            removeItem(updateIPA, label: "更新下载的 IPA")
        }

        // Caches 中只放可重建数据：扫描索引、缩略图、识别/目录缓存等。
        // 清空其内容但保留目录本身，避免影响后续写入。
        if let children = try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil) {
            for child in children {
                removeItem(child, label: "应用缓存")
            }
        }

        // tmp 仅用于解压和处理中间文件；不清理 Documents/Application Support。
        if downloadProgress == nil {
            if let children = try? fm.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil) {
                for child in children {
                    removeItem(child, label: "临时文件")
                }
            }
        } else {
            log("缓存清理：检测到更新正在下载，暂时跳过临时目录", .notice)
        }

        if removed.contains("更新下载的 IPA") || downloadedIPA != nil { downloadedIPA = nil }

        if removed.isEmpty {
            alertText = "没有可清的缓存。"
            log("清除缓存：没有可清的东西", .info)
        } else {
            let sizeText = freed >= 1_000_000
                ? String(format: "约 %.1f MB", Double(freed) / 1_000_000)
                : "\(max(1, Int(freed) / 1000)) KB"
            alertText = "缓存清完了：\(Array(Set(removed)).joined(separator: "、"))，一共腾出 \(sizeText)。"
            log("清除缓存：\(Array(Set(removed)).joined(separator: "、"))，腾出 \(freed) 字节", .success)
        }
    }

    /// 通道发现放到后台：界面先出来，就绪后再补上容器、配方复查和启动补扫。
    /// 签名方式由底层读取签名配置自动识别。
    func recheckChannel() {
        work.async {
            let detectedMethod = self.channel.signMethod
            let ok = self.channel.isAvailable
            let route = self.channel.routeDetail
            let group = self.channel.groupText
            DispatchQueue.main.async {
                self.signMethod = detectedMethod
                self.channelReady = ok
                self.channelChecking = false
                self.log("访问路线：\(route)", .info)
                if ok {
                    self.log("文件通道就绪（\(self.channel.routeName)），\(group)", .success)
                } else {
                    self.log(self.channel.unavailableReason, .warning)
                }
                guard ok else { return }
                self.refreshTargetPath()
                self.refreshContainers {
                    self.work.async { self.sweepAdDirectories(reason: "启动补扫") }
                }
                self.checkRecipes(silent: true)
                // 上次守护还开着、是被杀进程/装新版断掉的：自动续上，
                // 不用用户再手动开一遍。手动关掉的不会续（标记在关的时候就清了）。
                if self.guardService.wasActiveAtLaunch, !self.guardService.isRunning {
                    if let error = self.guardService.start(hidden: true) {
                        self.log("守护没能自动续上：\(error)", .warning)
                    } else {
                        self.guardInterruption = nil
                        self.log("守护已自动续上：上次开着，App 重开后接着守", .success)
                    }
                }
            }
        }
    }

    /// 首次打开检查权限：通知（被挤通知要用）当场请一次；联网靠真发一次
    /// 请求探明（顺带触发系统的数据权限弹窗），结果写进日志。
    private func firstLaunchChecks() {
        let key = "app.didFirstLaunchChecks"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            GuardService.requestNotificationPermission()
            GitHubUpdate.fetchLatest { info, _ in
                self?.log(info != nil ? "首次检查：联网正常" : "首次检查：暂时连不上服务器，上传、更新规则和检查更新需要联网",
                          .info)
            }
            self?.log("首次打开：已检查通知与联网权限", .info)
        }
    }

    func refreshTargetPath() {
        let bundleID = target.bundleID
        work.async {
            let path = self.channel.containerPath(for: bundleID)
            DispatchQueue.main.async {
                if self.target.bundleID == bundleID {
                    self.targetPath = path
                }
            }
        }
    }

    func refresh() {
        refreshContainers()
        checkRecipes()
    }

    func dismissAlert() {
        alertText = nil
    }

    func dismissInterruption() {
        guardInterruption = nil
    }

    // MARK: - Logging

    func log(_ message: String, _ level: LogLevel = .info) {
        logs.add(message, level: level)
    }

    func exportLogText() -> String {
        var text = logs.exportText(header: [
            "LaunchShield 运行日志",
            "应用版本：\(appVersionText)",
            "系统版本：\(systemText)",
            "设备：\(UIDevice.current.model)",
            "访问路线：\(channel.routeDetail)",
            "签名方式：\(signMethod == "cert" ? "证书签名（自动识别）" : (signMethod == "livecontainer" ? "LiveContainer（自动识别）" : (signMethod == "free" ? "免费 ID 签名（自动识别）" : "无法识别")))",
            "共享组：\(channel.groupText)",
            "导出时间：\(Format.fullDate(Date()))"
        ])
        // The channel layer keeps its own detailed log (wq_log); include it so
        // a failure inside the machinery is visible in the export.
        let accessLog = wq_log_text()
        if !accessLog.isEmpty {
            text += "\n\n———— 底层通道日志 ————\n" + accessLog
        }
        return text
    }

    // MARK: - Containers and target

    func refreshContainers(completion: (() -> Void)? = nil) {
        guard channel.isAvailable else {
            containers = []
            completion?()
            return
        }
        work.async {
            let all = self.channel.containers()
            // 把自己从容器列表里拿掉：选择应用、一键勾选、扫描、找广告、
            // 文件工具、守护补扫的范围全从这份列表来，一处排除处处生效。
            let list = all.filter { $0.bundleID != AppState.ownBundleID }
            if list.count != all.count {
                self.log("已把 LaunchShield 自己排除在处理范围外（不扫自己的容器）", .info)
            }
            let groups = self.channel.groupContainers()
            DispatchQueue.main.async {
                self.containers = list
                self.groupContainers = groups
                self.didLoadContainers = true
                if list.isEmpty {
                    self.log("没有读到应用容器列表，可能是系统版本不支持或权限被拒", .warning)
                }
                completion?()
            }
        }
    }

    func select(_ container: ContainerInfo) {
        target = AppTarget(bundleID: container.bundleID, name: container.name)
        targetChosen = true
        scanTargets = []
        lastScanSkippedFrozen = 0
        splash = nil
        candidates = []
        selectedCandidatePaths = []
        beforeSnapshot = nil
        afterSnapshot = nil
        beforeSnapshots = [:]
        afterSnapshots = [:]
        targetPath = container.path
        log("目标应用切换为 \(container.name)（\(container.bundleID)）", .notice)
    }

    // MARK: - 一键勾选

    var checkedContainers: [ContainerInfo] {
        containers.filter { checkedIDs.contains($0.bundleID) && !isWhitelisted($0.bundleID) }
    }

    /// 找广告的范围：一键勾选时是全部勾选的应用，否则是当前单个目标。
    var findAdScope: [ContainerInfo] {
        if !checkedIDs.isEmpty && checkedContainers.isEmpty { return [] }
        if checkedIDs.isEmpty && (!targetChosen || isWhitelisted(target.bundleID)) { return [] }
        let base: [ContainerInfo]
        if !checkedIDs.isEmpty {
            base = checkedContainers
        } else if !targetChosen {
            return []
        } else if let match = containers.first(where: { $0.bundleID == target.bundleID }) {
            base = [match]
        } else if let group = groupContainers.first(where: { $0.bundleID == target.bundleID }) {
            base = [group]
        } else if let path = targetPath {
            base = [ContainerInfo(bundleID: target.bundleID, path: path, name: target.name,
                                  isSystem: false, category: "")]
        } else {
            return []
        }
        // 关联到的共享组容器一并纳入：广告 SDK 把素材放共享组时不再是盲区。
        var extra: [ContainerInfo] = []
        for info in base where !info.isGroup {
            for group in associatedGroups(for: info.bundleID) {
                guard !base.contains(where: { $0.path == group.path }),
                      !extra.contains(where: { $0.path == group.path }) else { continue }
                extra.append(ContainerInfo(bundleID: group.bundleID, path: group.path,
                                           name: info.name + " 共享组", isSystem: false,
                                           category: "", isGroup: true))
            }
        }
        return base + extra
    }

    /// 按名字规律把共享组容器关联到应用：组标识去掉 group. 前缀后，
    /// 与应用 Bundle ID 相同、一方是另一方的前缀段，都算关联
    /// （如 group.com.baidu.netdisk ↔ com.baidu.netdisk、
    /// group.com.baidu ↔ 百度全家桶）。哈希组名关联不上，靠选择页单独选。
    func associatedGroups(for bundleID: String) -> [ContainerInfo] {
        let bid = bundleID.lowercased()
        return groupContainers.filter { group in
            var gid = group.bundleID.lowercased()
            if gid == bid { return true }
            if gid.hasPrefix("group.") { gid = String(gid.dropFirst(6)) }
            if gid == bid { return true }
            if gid.hasPrefix(bid + ".") { return true }
            if bid.hasPrefix(gid + ".") { return true }
            return false
        }
    }

    /// Names of apps the latest scan found ad material in (for the find-ad guide).
    var appsWithAds: [String] {
        let fromRecognition = lastRecognition
            .filter { $0.groups.values.reduce(0, +) > 0 }
            .map { $0.name }
        if !fromRecognition.isEmpty { return fromRecognition }
        var seen: [String] = []
        for file in scanTargets where !seen.contains(file.appName) {
            seen.append(file.appName)
        }
        return seen
    }

    var allUserAppsChecked: Bool {
        let userApps = containers.filter { !$0.isSystem && !$0.isGame && !isWhitelisted($0.bundleID) }
        return !userApps.isEmpty && userApps.allSatisfy { checkedIDs.contains($0.bundleID) }
    }

    /// 一键勾选：把用户安装的应用全勾上（游戏除外，系统应用不算）；
    /// 已经全勾上时再点一次就是全部取消。
    func toggleCheckAllUserApps() {
        guard requireChannel() else { return }
        if containers.isEmpty {
            alertText = "应用列表还没读到，稍等一下再点。"
            refreshContainers()
            return
        }
        if allUserAppsChecked {
            checkedIDs = []
            beforeSnapshots = [:]
            afterSnapshots = [:]
            candidates = []
            selectedCandidatePaths = []
            log("一键勾选已取消，回到单个目标", .notice)
            alertText = "已取消一键勾选，现在按单个目标应用处理。"
            return
        }
        let userApps = containers.filter { !$0.isSystem && !$0.isGame && !isWhitelisted($0.bundleID) }
        let games = containers.filter { !$0.isSystem && $0.isGame }
        guard !userApps.isEmpty else {
            alertText = "当前没有可勾选的应用（可能都已加入排除白名单）。"
            return
        }
        checkedIDs = Set(userApps.map { $0.bundleID })
        beforeSnapshots = [:]
        afterSnapshots = [:]
        candidates = []
        selectedCandidatePaths = []
        scanTargets = []
        log("一键勾选：勾上 \(userApps.count) 个应用，跳过游戏 \(games.count) 个", .notice)
        alertText = "已勾选 \(userApps.count) 个应用（游戏除外）。点「扫描」会一起扫，点「全部清零」会一起清。"
    }

    // MARK: - Scan and batch clear

    /// 扫描范围：一键勾选有勾选时扫全部勾选的应用，否则只扫当前单个目标。
    /// 软件自营的推导目前只对百度网盘成立，其余应用只扫第三方 SDK 分组。
    func scanBaidu(deep: Bool = false, completion: (() -> Void)? = nil) {
        guard requireChannel() else { return }
        let scanSet: [ContainerInfo]
        if !checkedIDs.isEmpty {
            scanSet = checkedContainers
            if scanSet.isEmpty {
                alertText = "勾选的应用一个都没读到容器，先等应用列表出来再扫。"
                return
            }
        } else if !targetChosen {
            alertText = "先选一个应用，或者点「一键勾选」，再扫描。"
            return
        } else if isWhitelisted(target.bundleID) {
            alertText = "当前目标应用已加入排除白名单，LaunchShield 不会对它执行任何操作。"
            return
        } else if let group = groupContainers.first(where: { $0.bundleID == target.bundleID }) {
            scanSet = [group]
        } else if let info = channel.container(for: target.bundleID) {
            scanSet = [info]
        } else {
            alertText = "没有找到\(target.name)，请先安装并打开一次。"
            log("没有找到\(target.name)的数据容器", .warning)
            return
        }
        let singleBaidu = scanSet.count == 1 && scanSet[0].bundleID == BaiduNetdisk.bundleID
        isBusy = true
        busyText = deep
            ? (scanSet.count == 1 ? "正在深扫\(scanSet[0].name)…" : "正在深扫 \(scanSet.count) 个应用…")
            : (scanSet.count == 1 ? "正在扫描\(scanSet[0].name)的素材…" : "正在扫描 \(scanSet.count) 个应用的素材…")
        work.async {
            var allTargets: [TargetFile] = []
            var baiduSplash: SplashResolution?
            var recognition: [AppRecognition] = []
            var skippedFrozen = 0
            for info in scanSet {
                let isBaidu = info.bundleID == BaiduNetdisk.bundleID
                let splash = isBaidu ? BaiduNetdisk.resolveSplash(container: info.path, channel: self.channel) : nil
                if isBaidu { baiduSplash = splash }
                var found = BaiduNetdisk.targets(container: info.path, channel: self.channel, splash: splash,
                                                 ownerBundleID: info.bundleID, ownerName: info.name)
                // 关联的共享组容器一并扫，素材算在所属应用名下。
                let groups = info.isGroup ? [] : self.associatedGroups(for: info.bundleID)
                for group in groups {
                    let groupFound = BaiduNetdisk.targets(container: group.path, channel: self.channel, splash: nil,
                                                          ownerBundleID: info.bundleID, ownerName: info.name)
                    if !groupFound.isEmpty {
                        self.log("\(info.name) 的共享组容器（\(group.bundleID)）：找到 \(groupFound.count) 个素材", .notice)
                    }
                    found.append(contentsOf: groupFound)
                }
                // 深扫：名单之外再按关键词和全屏尺寸翻一遍，命中进「疑似广告」组。
                if deep {
                    let knownPaths = Set(found.map { $0.path })
                    var extra = self.deepScanTargets(container: info.path, ownerBundleID: info.bundleID,
                                                     ownerName: info.name)
                    for group in groups {
                        extra.append(contentsOf: self.deepScanTargets(container: group.path, ownerBundleID: info.bundleID,
                                                                      ownerName: info.name))
                    }
                    let fresh = extra.filter { !knownPaths.contains($0.path) }
                    if !fresh.isEmpty {
                        self.log("\(info.name)：深扫多找到 \(fresh.count) 个疑似广告文件", .notice)
                    }
                    found.append(contentsOf: fresh)
                }
                // 去重：此刻是 0 字节并且正冻着的文件跳过待清零清单——
                // 不重复清零、不重复备份；变大或没冻上的照常列出，复发漏不掉。
                // 识别计数仍按全量 found 算，攒指纹库的数据不失真。
                for file in found {
                    if file.size == 0, self.channel.isImmutable(file.path) {
                        skippedFrozen += 1
                    } else {
                        allTargets.append(file)
                    }
                }
                recognition.append(AppRecognition(bundleID: info.bundleID,
                                                  name: info.name,
                                                  groups: Dictionary(grouping: found, by: { $0.group }).mapValues { $0.count },
                                                  unknownDirs: self.unknownDirectories(container: info.path)))
            }
            DispatchQueue.main.async {
                self.isBusy = false
                self.busyText = ""
                self.splash = baiduSplash
                self.scanTargets = allTargets
                self.lastRecognition = recognition
                self.lastScanSkippedFrozen = skippedFrozen
                if skippedFrozen > 0 {
                    self.log("扫描跳过已冻结的 0 字节文件 \(skippedFrozen) 个（不重复清零、不重复备份）", .info)
                }
                if singleBaidu, let splash = baiduSplash {
                    let root = scanSet[0].path
                    if splash.exists {
                        let relative = BaiduNetdisk.relativePath(container: root, path: splash.path)
                        self.log("软件自营开屏素材：\(relative)", .info)
                        self.log("推导依据：\(splash.url) → MD5 \(splash.md5)", .info)
                    } else {
                        let relative = BaiduNetdisk.relativePath(container: root, path: splash.path)
                        self.log("按广告记录算出了素材路径，但那个文件现在不存在：\(relative)（网址 \(splash.url)）", .notice)
                    }
                } else if singleBaidu {
                    self.log("没有读到开屏广告记录，可能广告还没缓存过，或记录文件暂时读不到", .notice)
                }
                if scanSet.count == 1 {
                    let groups = Dictionary(grouping: allTargets, by: { $0.group })
                    var groupOrder = ["软件自营"] + BaiduNetdisk.thirdPartyCacheGroups.map { $0.group }
                    for name in groups.keys where !groupOrder.contains(name) { groupOrder.append(name) }
                    for name in groupOrder {
                        guard let list = groups[name], !list.isEmpty else { continue }
                        let small = list.filter { $0.isSmallConfig }.count
                        let suffix = small > 0 ? "，其中清单小文件 \(small) 个" : ""
                        self.log("\(name)：\(list.count) 个文件\(suffix)", .info)
                    }
                } else {
                    for info in scanSet {
                        let mine = allTargets.filter { $0.bundleID == info.bundleID }
                        self.log("\(info.name)：\(mine.count) 个素材文件", .info)
                    }
                }
                self.log("扫描完成，共 \(allTargets.count) 个素材文件", .success)
                completion?()
            }
        }
    }

    /// 指纹库没登记过的顶层目录名（只记名字，供上传攒指纹库时人工核对）。
    private func unknownDirectories(container: String) -> [String] {
        var known = Set<String>()
        for group in BaiduNetdisk.thirdPartyCacheGroups {
            for directory in group.directories {
                var prefix = ""
                for part in directory.components(separatedBy: "/") {
                    prefix = prefix.isEmpty ? part : prefix + "/" + part
                    known.insert(prefix)
                }
            }
        }
        known.insert(BaiduNetdisk.splashCacheRoot)
        var result: [String] = []
        for parent in ["Library/Caches", "Library", "tmp", "Library/Application Support"] {
            guard let items = try? channel.children(of: container + "/" + parent) else { continue }
            for item in items where item.isDirectory {
                let relative = parent + "/" + item.name
                if !known.contains(relative) {
                    result.append(relative)
                }
            }
        }
        return Array(result.prefix(80))
    }

    /// 完成弹窗延后呈现：干活完成的那一刻要同时撤忙碌遮罩、重载清单，
    /// 完成弹窗若挤在同一瞬间弹出，在 iOS 27.2 beta 2 上会把界面合成弄出重影
    /// （真机对照实验定案：只扫描不弹完成弹窗就没事，扫描＋清零收尾必犯）。
    /// 先让界面安顿约半秒，再单独弹窗。
    func presentCompletionAlert(_ message: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.alertText = message
        }
    }

    func clearAllAfterScan() {
        if scanTargets.isEmpty {
            scanBaidu { [weak self] in
                self?.performClear()
            }
        } else {
            performClear()
        }
    }

    private func performClear() {
        guard requireChannel() else { return }
        guard !scanTargets.isEmpty else {
            alertText = "没有可清零的素材，先扫描一次。"
            return
        }
        let targets = scanTargets.filter { !isWhitelisted($0.bundleID) }
        guard !targets.isEmpty else {
            scanTargets = []
            alertText = "待处理文件均属于白名单应用，已全部跳过。"
            return
        }
        isBusy = true
        busyText = "正在清零 \(targets.count) 个文件…"
        log("开始清零：\(targets.count) 个文件，逐个先备份再截断", .notice)

        work.async {
            var done = 0
            var frozenCount = 0
            var freezeFailureCount = 0
            var failures: [String] = []
            var skippedDB = 0
            var newBackups: [BackupRecord] = []
            var newRecipes: [Recipe] = []

            for targetFile in targets {
                // 数据库文件被所属应用常驻锁着：写尝试必然失败，还会把
                // 界面弄出双份（构建 43 定案），直接跳过——不备份、
                // 不清零、不冻结，也不再反复往备份里堆。
                if DatabaseFile.matches(relativePath: targetFile.relativePath) {
                    skippedDB += 1
                    self.log("跳过数据库文件：\(targetFile.relativePath)", .info)
                    continue
                }
                do {
                    if self.channel.isImmutable(targetFile.path) {
                        try self.channel.setImmutable(targetFile.path, false)
                        self.log("先解冻：\(targetFile.relativePath)", .notice)
                    }
                    let size = self.channel.item(at: targetFile.path)?.size ?? 0
                    if size == 0 {
                        self.log("已经是 0 字节，跳过：\(targetFile.relativePath)", .info)
                    } else {
                        let ownerID = targetFile.bundleID.isEmpty ? BaiduNetdisk.bundleID : targetFile.bundleID
                        let ownerName = targetFile.appName.isEmpty ? BaiduNetdisk.displayName : targetFile.appName
                        let record = try self.backupManager.backup(path: targetFile.path,
                                                                   relativePath: targetFile.relativePath,
                                                                   bundleID: ownerID,
                                                                   appName: ownerName,
                                                                   source: targetFile.group,
                                                                   channel: self.channel)
                        try self.store.registerBackup(record)
                        newBackups.append(record)
                        try self.channel.truncate(targetFile.path)
                        done += 1
                        self.log("已清零：\(targetFile.relativePath)（\(Format.bytes(size))）", .success)
                        // 清零过的都登记进守护名单，不再挑组：以前只有「软件自营」
                        // 才登记，优量汇、穿山甲这些清完不进名单、守护巡不到。
                        // 只登记文件本体在该应用自己容器里的：共享组里的文件路径
                        // 是按组容器算的，配方按应用容器定位会找错地方，暂不登记。
                        let root = String(targetFile.path.dropLast(targetFile.relativePath.count + 1))
                        if self.channel.containerPath(for: ownerID) == root {
                            newRecipes.append(Recipe(id: UUID(),
                                                     bundleID: ownerID,
                                                     appName: ownerName,
                                                     relativePath: targetFile.relativePath,
                                                     createdAt: Date(),
                                                     frozen: false,
                                                     placeholder: false,
                                                     lastCheckedAt: Date(),
                                                     lastState: RecipeState.normal.rawValue))
                        }
                    }
                    // 清零后顺手把每个文件都冻上，广告就写不回这些文件了。
                    // 冻结失败不算清零失败，只记下来在总结里说明。
                    if self.channel.isImmutable(targetFile.path) {
                        frozenCount += 1
                    } else {
                        do {
                            try self.channel.setImmutable(targetFile.path, true)
                            frozenCount += 1
                            self.log("已冻结：\(targetFile.relativePath)", .success)
                        } catch {
                            freezeFailureCount += 1
                            self.log("冻结失败：\(targetFile.relativePath)：\(error.localizedDescription)", .warning)
                        }
                    }
                } catch {
                    // 一个文件清不动就跳过它，其余照清，最后在总结里汇总。
                    failures.append("\(targetFile.relativePath)：\(error.localizedDescription)")
                    self.log("跳过这个文件（清不动）：\(targetFile.relativePath)：\(error.localizedDescription)", .warning)
                }
            }

            // 文件都清完后，把广告商的专属文件夹本身也冻上（空文件夹也算），
            // 这样它们连新建文件备货都做不到。文件夹冻结失败只警告，不算清零失败。
            var frozenDirCount = 0
            var freezeDirFailureCount = 0
            if true {
                let owners = Set(targets.map { $0.bundleID.isEmpty ? BaiduNetdisk.bundleID : $0.bundleID })
                for owner in owners {
                    guard let root = self.channel.containerPath(for: owner) else { continue }
                    for relative in BaiduNetdisk.freezeDirectories(container: root, channel: self.channel) {
                        let full = root + "/" + relative
                        if self.channel.isImmutable(full) {
                            frozenDirCount += 1
                            continue
                        }
                        do {
                            try self.channel.setImmutable(full, true)
                            frozenDirCount += 1
                            self.log("已冻结文件夹：\(relative)", .success)
                        } catch {
                            freezeDirFailureCount += 1
                            self.log("冻结文件夹失败：\(relative)：\(error.localizedDescription)", .warning)
                        }
                    }
                }
            }

            DispatchQueue.main.async {
                self.isBusy = false
                self.busyText = ""
                for recipe in newRecipes {
                    let exists = self.store.file.recipes.contains {
                        $0.bundleID == recipe.bundleID && $0.relativePath == recipe.relativePath
                    }
                    if !exists { self.store.file.recipes.append(recipe) }
                }
                self.store.save()
                self.recipes = self.store.file.recipes
                self.backups = self.store.file.backups.sorted { $0.createdAt > $1.createdAt }

                self.log("清零完成：\(done) 个文件已截断为 0 字节", .success)
                if frozenCount > 0 {
                    self.log("清零的文件已全部冻结：\(frozenCount) 个", .success)
                }
                if freezeFailureCount > 0 {
                    self.log("有 \(freezeFailureCount) 个文件没冻上，详情看上面", .warning)
                }
                if frozenDirCount > 0 {
                    self.log("广告商的文件夹已冻结：\(frozenDirCount) 个", .success)
                }
                if freezeDirFailureCount > 0 {
                    self.log("有 \(freezeDirFailureCount) 个文件夹没冻上，详情看上面", .warning)
                }
                let dbNote = skippedDB > 0
                    ? "另有 \(skippedDB) 个数据库文件已跳过（被应用占用着、清不动，也不是广告素材）。"
                    : ""
                let completionText: String
                if failures.isEmpty {
                    completionText = (frozenCount > 0
                        ? "清零完成：\(done) 个文件已截断为 0 字节，全部已冻结。请把处理过的应用完全退出，再重新打开看看。"
                        : "清零完成：\(done) 个文件已截断为 0 字节。请把处理过的应用完全退出，再重新打开看看。") + dbNote
                } else {
                    self.log("有 \(failures.count) 个文件清不动、已跳过：\(failures.joined(separator: "；"))", .warning)
                    completionText = "清零完成：\(done) 个文件已清掉。另有 \(failures.count) 个文件清不动、已经跳过（多半是正被应用占用着），详情看日志。" + dbNote
                }
                self.scanTargets = []
                self.checkRecipes(silent: true)
                self.presentCompletionAlert(completionText)
            }
        }
    }

    // MARK: - Backups

    func restoreAll() {
        guard requireChannel() else { return }
        let records = backupManager.originalBackups().filter { !isWhitelisted($0.bundleID) }
        guard !records.isEmpty else {
            alertText = "还没有备份可以还原。"
            return
        }
        performRestore(records)
    }

    /// 批量还原选中的备份：只还原选中里属于「原件」的那几份
    /// （同一文件有多份备份时写回最早的那份，和全部还原一个口径）。
    func restoreBackups(_ selected: [BackupRecord]) {
        guard requireChannel() else { return }
        let ids = Set(selected.map { $0.id })
        let records = backupManager.originalBackups().filter { ids.contains($0.id) && !isWhitelisted($0.bundleID) }
        guard !records.isEmpty else {
            alertText = "选中的备份里没有可还原的原件。"
            return
        }
        performRestore(records)
    }

    private func performRestore(_ records: [BackupRecord]) {
        let records = records.filter { !isWhitelisted($0.bundleID) }
        guard !records.isEmpty else {
            alertText = "选中的备份均属于白名单应用，已跳过还原。"
            return
        }
        isBusy = true
        busyText = "正在还原 \(records.count) 个文件…"
        log("开始还原：\(records.count) 个备份，逐个写回并核对 MD5", .notice)

        work.async {
            var restored = 0
            var failures: [String] = []
            var skippedDB = 0
            // 文件夹冻着的话先解开，还原才算全套撤销。
            for owner in Set(records.map { $0.bundleID }) {
                guard let root = self.channel.containerPath(for: owner) else { continue }
                for relative in BaiduNetdisk.freezeDirectories(container: root, channel: self.channel) {
                    let full = root + "/" + relative
                    if self.channel.isImmutable(full) {
                        try? self.channel.setImmutable(full, false)
                        self.log("已解冻文件夹：\(relative)", .notice)
                    }
                }
            }
            for record in records {
                // 数据库文件同清零：写回必然失败、还会弄坏界面，跳过。
                if DatabaseFile.matches(relativePath: record.relativePath) {
                    skippedDB += 1
                    self.log("跳过数据库文件的还原：\(record.relativePath)", .info)
                    continue
                }
                do {
                    guard let root = self.channel.containerPath(for: record.bundleID) else {
                        throw ChannelFailure("找不到 \(record.appName) 的数据容器")
                    }
                    _ = try self.backupManager.restore(record, container: root, channel: self.channel)
                    restored += 1
                    self.log("已还原并核对 MD5：\(record.relativePath)", .success)
                } catch {
                    failures.append("\(record.relativePath)：\(error.localizedDescription)")
                    self.log("跳过这个文件（还原不了）：\(record.relativePath)：\(error.localizedDescription)", .warning)
                }
            }
            DispatchQueue.main.async {
                self.isBusy = false
                self.busyText = ""
                let dbNote = skippedDB > 0
                    ? "另有 \(skippedDB) 个数据库文件已跳过（被应用占用着，还原不了）。"
                    : ""
                let completionText: String
                if failures.isEmpty {
                    self.log("还原完成：\(restored) 个文件已写回，MD5 全部一致", .success)
                    completionText = "还原完成：\(restored) 个文件已写回，MD5 全部一致。" + dbNote
                } else {
                    self.log("还原完成：\(restored) 个已写回，\(failures.count) 个没还原成、已跳过：\(failures.joined(separator: "；"))", .warning)
                    completionText = "还原完成：\(restored) 个文件已写回；\(failures.count) 个没还原成、已跳过（多半是正被应用占着），详情看日志。" + dbNote
                }
                self.checkRecipes(silent: true)
                self.presentCompletionAlert(completionText)
            }
        }
    }

    func restore(_ record: BackupRecord) {
        guard requireChannel() else { return }
        if DatabaseFile.matches(relativePath: record.relativePath) {
            alertText = "这是数据库文件，正被应用占用着，还原不了，已跳过。"
            return
        }
        guard let root = channel.containerPath(for: record.bundleID) else {
            alertText = "找不到 \(record.appName) 的数据容器。"
            return
        }
        isBusy = true
        busyText = "正在还原…"
        work.async {
            do {
                _ = try self.backupManager.restore(record, container: root, channel: self.channel)
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.busyText = ""
                    self.log("已还原并核对 MD5：\(record.relativePath)", .success)
                    self.checkRecipes(silent: true)
                    self.alertText = "已还原：\(record.relativePath)，MD5 一致。"
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.busyText = ""
                    self.log("还原失败：\(error.localizedDescription)", .warning)
                    self.alertText = "还原失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func deleteBackup(_ record: BackupRecord) {
        store.file.backups.removeAll { $0.id == record.id }
        try? FileManager.default.removeItem(at: store.backupDirectoryURL(for: record.id))
        store.save()
        backups = store.file.backups.sorted { $0.createdAt > $1.createdAt }
        log("已删除一份备份：\(record.relativePath)", .info)
        alertText = "已删除这份备份。"
    }

    func deleteAllBackups() {
        let records = store.file.backups
        guard !records.isEmpty else {
            alertText = "还没有备份可以删。"
            return
        }
        for record in records {
            try? FileManager.default.removeItem(at: store.backupDirectoryURL(for: record.id))
        }
        store.file.backups = []
        store.save()
        backups = []
        log("已清空全部备份：\(records.count) 份", .notice)
        alertText = "已清空全部备份：\(records.count) 份。"
    }

    /// 按应用删除备份：只删这一个应用的全部备份，其他应用的不动。
    func deleteBackups(forApp bundleID: String) {
        let records = store.file.backups.filter { $0.bundleID == bundleID }
        guard !records.isEmpty else {
            alertText = "这个应用没有备份可以删。"
            return
        }
        for record in records {
            try? FileManager.default.removeItem(at: store.backupDirectoryURL(for: record.id))
        }
        store.file.backups.removeAll { $0.bundleID == bundleID }
        store.save()
        backups = store.file.backups.sorted { $0.createdAt > $1.createdAt }
        let name = records.first?.appName ?? bundleID
        log("已删除 \(name) 的全部备份：\(records.count) 份", .notice)
        alertText = "已删除 \(name) 的全部备份：\(records.count) 份。"
    }

    /// 批量删除选中的备份（多选模式用）：只删选中的，其他备份不动。
    func deleteBackups(_ selected: [BackupRecord]) {
        let ids = Set(selected.map { $0.id })
        let records = store.file.backups.filter { ids.contains($0.id) }
        guard !records.isEmpty else {
            alertText = "先勾选要删除的备份。"
            return
        }
        for record in records {
            try? FileManager.default.removeItem(at: store.backupDirectoryURL(for: record.id))
        }
        store.file.backups.removeAll { ids.contains($0.id) }
        store.save()
        backups = store.file.backups.sorted { $0.createdAt > $1.createdAt }
        log("已批量删除备份：\(records.count) 份", .notice)
        alertText = "已删除 \(records.count) 份备份。"
    }

    // MARK: - Before/after diff

    func takeSnapshot(before: Bool) {
        guard requireChannel() else { return }
        let scope = findAdScope
        guard !scope.isEmpty else {
            alertText = "先选一个目标应用，或先用一键勾选。"
            return
        }
        if !before && beforeSnapshots.isEmpty {
            alertText = "请先拍第一次快照。"
            return
        }
        let multi = scope.count > 1
        isBusy = true
        busyText = before ? "正在拍第一次快照…" : "正在拍第二次快照…"
        work.async {
            var snaps: [String: ContainerSnapshot] = [:]
            var failedNames: [String] = []
            for container in scope {
                // 共享组容器不在应用容器登记里，直接用它自己的路径。
                let resolvedRoot = container.isGroup ? container.path : self.channel.containerPath(for: container.bundleID)
                guard let root = resolvedRoot else {
                    failedNames.append(container.name)
                    continue
                }
                do {
                    snaps[container.bundleID] = try SnapshotDiff.take(bundleID: container.bundleID,
                                                                       root: root,
                                                                       channel: self.channel)
                } catch {
                    failedNames.append(container.name)
                }
            }
            DispatchQueue.main.async {
                self.isBusy = false
                self.busyText = ""
                let totalFiles = snaps.values.reduce(0) { $0 + $1.fileCount }
                if before {
                    self.beforeSnapshots = snaps
                    self.afterSnapshots = [:]
                    self.beforeSnapshot = snaps.values.first
                    self.afterSnapshot = nil
                    self.candidates = []
                    self.selectedCandidatePaths = []
                    let incomplete = snaps.values.filter { $0.truncated }.count
                    self.log("第一次快照完成：\(snaps.count) 个应用，共 \(totalFiles) 个文件\(incomplete > 0 ? "；其中 \(incomplete) 个扫描不完整" : "")",
                             incomplete > 0 ? .warning : .success)
                    let nextStep = multi
                        ? "现在去打开有广告的应用，让开屏广告播一次，再回来拍第二次快照。"
                        : "现在去打开\(scope[0].name)，让开屏广告播一次，再回来拍第二次快照。"
                    self.alertText = incomplete > 0
                        ? "有 \(incomplete) 个应用未能完整扫描。请先检查日志/访问权限，再进行对比；\(nextStep)"
                        : nextStep
                } else {
                    self.afterSnapshots = snaps
                    self.afterSnapshot = snaps.values.first
                    var all: [DiffCandidate] = []
                    var incompleteNames: [String] = []
                    for container in scope {
                        guard let first = self.beforeSnapshots[container.bundleID],
                              let second = snaps[container.bundleID] else {
                            incompleteNames.append(container.name)
                            continue
                        }
                        guard !first.truncated, !second.truncated else {
                            incompleteNames.append(container.name)
                            continue
                        }
                        all += SnapshotDiff.diff(before: first, after: second, appName: container.name)
                    }
                    all.sort { first, second in
                        if first.isNew != second.isNew { return first.isNew }
                        if first.isNew { return first.modified > second.modified }
                        return first.delta > second.delta
                    }
                    self.candidates = Array(all.prefix(400))
                    self.selectedCandidatePaths = incompleteNames.isEmpty
                        ? Set(self.candidates.filter { $0.autoVerdict }.map { $0.id })
                        : []
                    self.log("第二次快照完成：\(snaps.count) 个应用，共 \(totalFiles) 个文件，\(self.candidates.count) 个候选\(incompleteNames.isEmpty ? "" : "；扫描不完整：\(incompleteNames.joined(separator: "、"))")",
                             incompleteNames.isEmpty ? .success : .warning)
                    if !incompleteNames.isEmpty {
                        self.alertText = "以下应用扫描不完整，已跳过它们的前后对比：\(incompleteNames.joined(separator: "、"))。请检查日志/访问权限后重新拍快照。"
                    } else {
                        self.alertText = self.candidates.isEmpty
                            ? "完整扫描后没有发现新文件或变大的文件。可以再让广告播一次试试。"
                            : "请勾选确实是广告素材的文件，再点清零。"
                    }
                }
                if !failedNames.isEmpty {
                    self.log("这些应用没拍上快照（找不到容器）：\(failedNames.joined(separator: "、"))", .warning)
                }
            }
        }
    }

    /// 找广告「自动判定」一组：把选择换成自动判定的候选，供一键清零用。
    func selectAutoCandidates() {
        let completeBundleIDs = Set(afterSnapshots.values.filter { !$0.truncated }.map { $0.bundleID })
        selectedCandidatePaths = Set(candidates.filter {
            completeBundleIDs.contains($0.bundleID) && $0.autoVerdict
        }.map { $0.id })
    }

    func clearSelectedCandidates() {
        guard requireChannel() else { return }
        let selected = candidates.filter { selectedCandidatePaths.contains($0.id) }
        guard !selected.isEmpty else {
            alertText = "请先勾选要清零的文件。"
            return
        }
        isBusy = true
        busyText = "正在清零确认的素材…"
        work.async {
            var done = 0
            var failure: String?
            var skippedDB = 0
            var newBackups: [BackupRecord] = []
            var newRecipes: [Recipe] = []
            for candidate in selected {
                let root = candidate.containerRoot.isEmpty
                    ? (self.channel.containerPath(for: candidate.bundleID) ?? "")
                    : candidate.containerRoot
                guard !root.isEmpty else {
                    failure = "\(candidate.appName)：找不到容器"
                    continue
                }
                let appBundleID = candidate.bundleID.isEmpty ? self.target.bundleID : candidate.bundleID
                let appName = candidate.appName.isEmpty ? self.target.name : candidate.appName
                let parts = candidate.relativePath.split(separator: "/", omittingEmptySubsequences: false)
                guard !candidate.relativePath.isEmpty, !candidate.relativePath.hasPrefix("/"),
                      !candidate.relativePath.contains("\\"), !candidate.relativePath.unicodeScalars.contains(where: { $0.value == 0 }),
                      parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                    failure = "\(candidate.appName)：候选路径不安全，已跳过"
                    continue
                }
                let full = root.hasSuffix("/") ? root + candidate.relativePath : root + "/" + candidate.relativePath
                if DatabaseFile.matches(relativePath: candidate.relativePath) {
                    skippedDB += 1
                    self.log("跳过数据库文件：\(appName) \(candidate.relativePath)", .info)
                    continue
                }
                let wasImmutable = self.channel.isImmutable(full)
                do {
                    guard let current = self.channel.item(at: full),
                          !current.isDirectory, !current.isSymlink else {
                        throw ChannelFailure("目标已不存在、不是普通文件或已变成符号链接")
                    }
                    guard current.size == candidate.size,
                          abs(current.modified.timeIntervalSince(candidate.modified)) <= 2 else {
                        throw ChannelFailure("文件在第二次快照后发生变化，已取消清零；请重新扫描")
                    }
                    if wasImmutable { try self.channel.setImmutable(full, false) }
                    let record = try self.backupManager.backup(path: full,
                                                               relativePath: candidate.relativePath,
                                                               bundleID: appBundleID,
                                                               appName: appName,
                                                               source: "前后对比确认",
                                                               channel: self.channel)
                    try self.store.registerBackup(record)
                    newBackups.append(record)
                    let sourceMD5AfterBackup = try self.channel.md5(full)
                    guard sourceMD5AfterBackup.caseInsensitiveCompare(record.md5) == .orderedSame else {
                        throw ChannelFailure("备份后源文件内容发生变化，已取消清零")
                    }
                    try self.channel.truncate(full)
                    done += 1
                    self.log("已清零确认的素材：\(appName) \(candidate.relativePath)", .success)
                    newRecipes.append(Recipe(id: UUID(),
                                             bundleID: appBundleID,
                                             appName: appName,
                                             relativePath: candidate.relativePath,
                                             createdAt: Date(),
                                             frozen: false,
                                             placeholder: false,
                                             lastCheckedAt: Date(),
                                             lastState: RecipeState.normal.rawValue))
                } catch {
                    if wasImmutable {
                        do {
                            if self.channel.item(at: full) != nil { try self.channel.setImmutable(full, true) }
                        } catch {
                            self.log("恢复原冻结状态失败：\(appName) \(candidate.relativePath)：\(error.localizedDescription)", .warning)
                        }
                    }
                    if failure == nil {
                        failure = "\(candidate.relativePath)：\(error.localizedDescription)"
                    }
                    self.log("清零这个文件失败：\(appName) \(candidate.relativePath)：\(error.localizedDescription)", .warning)
                }
            }
            DispatchQueue.main.async {
                self.isBusy = false
                self.busyText = ""
                for recipe in newRecipes {
                    let exists = self.store.file.recipes.contains {
                        $0.bundleID == recipe.bundleID && $0.relativePath == recipe.relativePath
                    }
                    if !exists { self.store.file.recipes.append(recipe) }
                }
                self.store.save()
                self.recipes = self.store.file.recipes
                self.backups = self.store.file.backups.sorted { $0.createdAt > $1.createdAt }
                let dbNote = skippedDB > 0
                    ? "另有 \(skippedDB) 个数据库文件已跳过（被应用占用着、清不动，也不是广告素材）。"
                    : ""
                let completionText: String
                if let failure {
                    self.log("清零候选没有全部完成，没清成的：\(failure)", .warning)
                    completionText = "清零完成了一部分：\(done) 个已经清掉，有文件没清成（多半是正被应用占用着），详情看日志。" + dbNote
                } else {
                    self.log("确认的素材已清零：\(done) 个，配方已存入守护列表", .success)
                    completionText = "已清零 \(done) 个素材，并加入已守护应用。" + dbNote
                    self.candidates = []
                    self.selectedCandidatePaths = []
                }
                self.alertText = completionText
            }
        }
    }

    // MARK: - 文件工具（大文件榜 / 搜文件名，找广告的辅助）

    @Published var bigFiles: [FoundFile] = []
    @Published var fileSearchResults: [FoundFile] = []
    @Published var fileToolsBusy = false

    /// 递归走一遍范围内的容器收集文件；keyword 非空时只收文件名命中的
    /// （上限 500 条），keyword 为空时全收（供大文件榜排序）。
    /// 深扫：名单之外翻文件，命中两条线——相对路径带广告关键词，或者
    /// 图片尺寸正好是手机全屏那几档。结果都进「疑似广告」组，清之前在
    /// 清单里过目。系统启动图目录（SplashBoard）是系统自己的画面，排除。
    /// 这些散文件清零时只冻文件本身：文件夹冻结只认规则目录，不会连累公共目录。
    private func deepScanTargets(container: String, ownerBundleID: String, ownerName: String) -> [TargetFile] {
        let keywords = Set(RulesStore.keywords.map { $0.lowercased() } + ["appopen", "openad", "splashad"])
        let fullscreen: Set<String> = ["1080x1920", "1920x1080", "1125x2436", "2436x1125", "1242x2688", "2688x1242",
                                       "1170x2532", "2532x1170", "1179x2556", "2556x1179", "1290x2796", "2796x1290",
                                       "1206x2622", "2622x1206", "1320x2868", "2868x1320", "750x1334", "1334x750",
                                       "828x1792", "1792x828", "1080x2340", "2340x1080", "720x1280", "1280x720"]
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "gif"]
        var results: [TargetFile] = []
        var visited = 0
        var dimsChecked = 0
        func consider(item: FileItem) {
            let relative = String(item.path.dropFirst(container.count + 1))
            if relative.hasPrefix("Library/SplashBoard") { return }
            // 个人内容（聊天图、短视频、表情包）不算疑似广告，深扫直接绕开。
            if PersonalMedia.isPersonal(bundleID: ownerBundleID, relativePath: relative) { return }
            let lower = relative.lowercased()
            if keywords.contains(where: { lower.contains($0) }) {
                results.append(TargetFile(path: item.path, relativePath: relative, group: "疑似广告",
                                          note: "深扫：路径带广告关键词", size: item.size, isSmallConfig: item.size < 65536,
                                          bundleID: ownerBundleID, appName: ownerName))
                return
            }
            let ext = (item.name as NSString).pathExtension.lowercased()
            if imageExts.contains(ext), LaunchImageHint.matches(lower) {
                results.append(TargetFile(path: item.path, relativePath: relative, group: "疑似广告",
                                          note: "深扫：启动图/引导图", size: item.size, isSmallConfig: false,
                                          bundleID: ownerBundleID, appName: ownerName))
                return
            }
            if imageExts.contains(ext), item.size >= 30_000, dimsChecked < 50 {
                dimsChecked += 1
                if let data = try? channel.read(item.path, maxBytes: 128 * 1024),
                   let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                   let w = props[kCGImagePropertyPixelWidth as String] as? Int,
                   let h = props[kCGImagePropertyPixelHeight as String] as? Int,
                   fullscreen.contains("\(w)x\(h)") {
                    results.append(TargetFile(path: item.path, relativePath: relative, group: "疑似广告",
                                              note: "深扫：全屏尺寸图片 \(w)×\(h)", size: item.size, isSmallConfig: false,
                                              bundleID: ownerBundleID, appName: ownerName))
                }
            }
        }
        func walk(dir: String) {
            guard visited < 8000, results.count < 300 else { return }
            guard let items = try? channel.children(of: dir) else { return }
            for item in items {
                visited += 1
                if item.isDirectory { walk(dir: item.path) } else { consider(item: item) }
            }
        }
        for root in ["Library", "tmp", "Documents"] {
            walk(dir: container + "/" + root)
        }
        return results
    }

    /// 找广告第 0 步（只对单个目标应用）：先把缓存和临时文件清干净，
    /// 再自动拍第一次快照当干净底子——广告图早就缓存好时，
    /// 只有这样它重新下载的那一份才会在对比里现形。
    /// 删是真删、不冻结；冻住的文件删不掉，自动跳过并计数。
    func clearCacheBeforeSnapshot() {
        guard requireChannel() else { return }
        guard checkedIDs.isEmpty, targetChosen else {
            alertText = "这一步只对单个应用用：先取消一键勾选，只选一个应用。"
            return
        }
        guard let info = containers.first(where: { $0.bundleID == target.bundleID }) ?? channel.container(for: target.bundleID) else {
            alertText = "没找到\(target.name)的容器。"
            return
        }
        isBusy = true
        busyText = "正在清\(info.name)的缓存…"
        work.async {
            var deleted = 0
            var skippedFrozen = 0
            var failed = 0
            for root in ["Library/Caches", "tmp"] {
                var visited = 0
                func walk(dir: String) {
                    guard visited < 30000 else { return }
                    guard let items = try? self.channel.children(of: dir) else { return }
                    for item in items {
                        visited += 1
                        if item.isDirectory {
                            walk(dir: item.path)
                        } else {
                            do {
                                try self.channel.delete(item.path)
                                deleted += 1
                            } catch {
                                if self.channel.isImmutable(item.path) { skippedFrozen += 1 } else { failed += 1 }
                            }
                        }
                    }
                }
                walk(dir: info.path + "/" + root)
            }
            DispatchQueue.main.async {
                self.isBusy = false
                self.busyText = ""
                self.log("先清缓存：\(info.name) 删掉 \(deleted) 个缓存文件，冻住的跳过 \(skippedFrozen) 个，删不掉的 \(failed) 个", .notice)
                self.takeSnapshot(before: true)
                self.alertText = "缓存清完了，已顺手拍好第一次快照。现在去打开\(info.name)，让广告播一次，再回来拍第二次快照。"
            }
        }
    }

    private func walkFoundFiles(scope: [ContainerInfo], keyword: String) -> [FoundFile] {
        var results: [FoundFile] = []
        let needle = keyword.lowercased()
        // 走访上限按容器分别算：一键勾选几十个应用时，每个容器都有自己的
        // 6000 条预算，不会排前面的先耗光、后面的扫不到。
        for container in scope {
            var visited = 0
            func walk(dir: String) {
                guard visited < 6000 else { return }
                guard let items = try? channel.children(of: dir) else { return }
                for item in items {
                    visited += 1
                    if item.isDirectory {
                        walk(dir: item.path)
                    } else if needle.isEmpty || item.name.lowercased().contains(needle) {
                        let relative = String(item.path.dropFirst(container.path.count + 1))
                        results.append(FoundFile(path: item.path, containerPath: container.path,
                                                 relativePath: relative, size: item.size,
                                                 bundleID: container.bundleID, appName: container.name))
                        if !needle.isEmpty && results.count >= 500 { return }
                    }
                }
            }
            walk(dir: container.path)
            if !needle.isEmpty && results.count >= 500 { break }
        }
        return results
    }

    func loadBigFiles() {
        let scope = findAdScope
        guard !scope.isEmpty else {
            alertText = "先选一个目标应用，再看大文件榜。"
            return
        }
        fileToolsBusy = true
        work.async {
            let all = self.walkFoundFiles(scope: scope, keyword: "")
            let top = Array(all.sorted { $0.size > $1.size }.prefix(100))
            DispatchQueue.main.async {
                self.fileToolsBusy = false
                self.bigFiles = top
                self.log("大文件榜：范围内共 \(all.count) 个文件，列出最大的 \(top.count) 个", .info)
            }
        }
    }

    func searchFiles(keyword: String) {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        let scope = findAdScope
        guard !scope.isEmpty else {
            alertText = "先选一个目标应用，再搜文件名。"
            return
        }
        fileToolsBusy = true
        work.async {
            let found = self.walkFoundFiles(scope: scope, keyword: kw)
            DispatchQueue.main.async {
                self.fileToolsBusy = false
                self.fileSearchResults = found
                self.log("按文件名搜「\(kw)」：找到 \(found.count) 个", .info)
            }
        }
    }

    /// 大文件榜/搜索里选中的文件加进找广告候选：自动勾选、自动打上
    /// 「我标记的」，之后在候选列表里确认清零；上传找广告结果时一并带上。
    func addToolCandidates(_ files: [FoundFile]) {
        guard !files.isEmpty else { return }
        for file in files {
            let candidate = DiffCandidate(relativePath: file.relativePath, size: file.size,
                                          modified: Date(), reason: "从大文件榜/文件名搜索找到的",
                                          isNew: true, delta: Int64(file.size),
                                          appName: file.appName, bundleID: file.bundleID,
                                          containerRoot: file.containerPath)
            if !candidates.contains(where: { $0.id == candidate.id }) { candidates.append(candidate) }
            selectedCandidatePaths.insert(candidate.id)
            if !isMarked(bundleID: file.bundleID, relativePath: file.relativePath) {
                manualMarks.append(ManualMark(bundleID: file.bundleID, appName: file.appName,
                                              relativePath: file.relativePath, size: file.size,
                                              markedAt: Date()))
            }
        }
        saveMarks()
        log("已把 \(files.count) 个文件加进找广告候选（已勾选、已标记为广告）", .success)
        alertText = "已加进找广告候选 \(files.count) 个，回到候选列表确认清零。"
    }

    // MARK: - Recipes

    func checkRecipes(silent: Bool = false) {
        let list = recipes
        guard !list.isEmpty, channel.isAvailable else { return }
        work.async {
            var updated = list
            var normal = 0
            var recurred = 0
            var other = 0
            for index in updated.indices {
                updated[index].lastCheckedAt = Date()
                guard let container = self.channel.containerPath(for: updated[index].bundleID) else {
                    updated[index].lastState = RecipeState.missing.rawValue
                    other += 1
                    continue
                }
                let status = RecipeEngine.status(updated[index], container: container, channel: self.channel)
                updated[index].lastState = status.state.rawValue
                // 冻结标记按磁盘真实状态回写：以前建记录时写了 false 就再没更新，
                // 「已冻结 N 个」的计数因此一直是 0，其实文件冻得好好的。
                updated[index].frozen = status.state == .frozen
                switch status.state {
                case .normal, .frozen: normal += 1
                case .recurred: recurred += 1
                default: other += 1
                }
            }
            DispatchQueue.main.async {
                self.recipes = updated
                self.store.file.recipes = updated
                self.store.save()
                if !silent {
                    self.log("配方复查完成：正常 \(normal) 个，复发 \(recurred) 个，其他 \(other) 个",
                             recurred > 0 ? .warning : .info)
                }
            }
        }
    }

    func replaceRecipe(_ recipe: Recipe) {
        guard requireChannel() else { return }
        guard let root = channel.containerPath(for: recipe.bundleID) else {
            alertText = "找不到 \(recipe.appName) 的数据容器。"
            return
        }
        isBusy = true
        busyText = "正在重新清零…"
        work.async {
            if DatabaseFile.matches(relativePath: recipe.relativePath) {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.busyText = ""
                    self.alertText = "这是数据库文件，正被应用占用着，重新清零不了，已跳过。"
                }
                return
            }
            do {
                let full = RecipeEngine.fullPath(recipe, container: root)
                if self.channel.isImmutable(full) {
                    try self.channel.setImmutable(full, false)
                }
                let size = self.channel.item(at: full)?.size ?? 0
                if size > 0 {
                    let record = try self.backupManager.backup(path: full,
                                                               relativePath: recipe.relativePath,
                                                               bundleID: recipe.bundleID,
                                                               appName: recipe.appName,
                                                               source: "复发后重新清零",
                                                               channel: self.channel)
                    try self.store.registerBackup(record)
                }
                try self.channel.truncate(full)
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.busyText = ""
                    self.log("已重新清零：\(recipe.relativePath)", .success)
                    self.checkRecipes(silent: true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.busyText = ""
                    self.log("重新清零失败：\(recipe.relativePath)：\(error.localizedDescription)", .warning)
                    self.alertText = "重新清零失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func setFrozen(_ recipe: Recipe, frozen: Bool) {
        guard requireChannel() else { return }
        guard let root = channel.containerPath(for: recipe.bundleID) else { return }
        work.async {
            do {
                let full = RecipeEngine.fullPath(recipe, container: root)
                try self.channel.setImmutable(full, frozen)
                DispatchQueue.main.async {
                    if let index = self.recipes.firstIndex(where: { $0.id == recipe.id }) {
                        self.recipes[index].frozen = frozen
                        self.store.file.recipes = self.recipes
                        self.store.save()
                    }
                    self.log(frozen ? "已冻结：\(recipe.relativePath)" : "已解冻：\(recipe.relativePath)", .success)
                    self.checkRecipes(silent: true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.log(frozen ? "冻结失败：\(error.localizedDescription)" : "解冻失败：\(error.localizedDescription)", .warning)
                    self.alertText = "改冻结状态失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func setPlaceholder(_ recipe: Recipe, enabled: Bool) {
        guard requireChannel() else { return }
        guard let root = channel.containerPath(for: recipe.bundleID) else { return }
        isBusy = true
        busyText = enabled ? "正在做同名文件夹占位…" : "正在取消占位…"
        work.async {
            do {
                let full = RecipeEngine.fullPath(recipe, container: root)
                if enabled {
                    if self.channel.isImmutable(full) {
                        try self.channel.setImmutable(full, false)
                    }
                    if let item = self.channel.item(at: full), !item.isDirectory {
                        if item.size > 0 {
                            let record = try self.backupManager.backup(path: full,
                                                                       relativePath: recipe.relativePath,
                                                                       bundleID: recipe.bundleID,
                                                                       appName: recipe.appName,
                                                                       source: "占位前备份",
                                                                       channel: self.channel)
                            try self.store.registerBackup(record)
                        }
                        try self.channel.delete(full)
                    }
                    try self.channel.createDirectory(full)
                } else {
                    if self.channel.isDirectory(full) {
                        let children = try? self.channel.children(of: full)
                        guard (children?.isEmpty ?? true) else {
                            throw ChannelFailure("占位文件夹里还有东西，先手动清空再取消占位")
                        }
                        try self.channel.delete(full)
                    }
                    if let record = self.backupManager.originalBackup(bundleID: recipe.bundleID,
                                                                      relativePath: recipe.relativePath) {
                        guard let targetRoot = self.channel.containerPath(for: record.bundleID) else {
                            throw ChannelFailure("找不到目标应用的数据容器")
                        }
                        _ = try self.backupManager.restore(record, container: targetRoot, channel: self.channel)
                    } else {
                        try self.channel.write(full, data: Data())
                    }
                }
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.busyText = ""
                    if let index = self.recipes.firstIndex(where: { $0.id == recipe.id }) {
                        self.recipes[index].placeholder = enabled
                        self.store.file.recipes = self.recipes
                        self.store.save()
                    }
                    self.log(enabled ? "已做同名文件夹占位：\(recipe.relativePath)" : "已取消占位并写回文件：\(recipe.relativePath)", .success)
                    self.checkRecipes(silent: true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.busyText = ""
                    self.log("占位操作失败：\(error.localizedDescription)", .warning)
                    self.alertText = "占位操作失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 移出守护列表时默认解冻：不能只删名单、把文件还冻在原地没人管。
    func removeRecipe(_ recipe: Recipe) {
        let finish = {
            self.recipes.removeAll { $0.id == recipe.id }
            self.store.file.recipes = self.recipes
            self.store.save()
            self.log("已从守护列表移除：\(recipe.relativePath)", .notice)
        }
        guard recipe.frozen || recipe.placeholder, let root = channel.containerPath(for: recipe.bundleID) else {
            finish()
            return
        }
        work.async {
            let full = RecipeEngine.fullPath(recipe, container: root)
            if recipe.frozen {
                try? self.channel.setImmutable(full, false)
            }
            if recipe.placeholder {
                try? self.channel.delete(full)
            }
            DispatchQueue.main.async {
                if recipe.frozen { self.log("已解冻：\(recipe.relativePath)", .notice) }
                finish()
            }
        }
    }

    /// 批量移除选中的守护条目（多选模式用）：和逐个移除一个口径——
    /// 冻着的先解冻、占位文件夹删掉，再从名单里拿掉。其他条目不动。
    func removeRecipes(_ selected: [Recipe]) {
        let ids = Set(selected.map { $0.id })
        let targets = recipes.filter { ids.contains($0.id) }
        guard !targets.isEmpty else {
            alertText = "先勾选要移除的条目。"
            return
        }
        let finish = {
            self.recipes.removeAll { ids.contains($0.id) }
            self.store.file.recipes = self.recipes
            self.store.save()
            self.log("已批量移除 \(targets.count) 个守护条目", .notice)
            self.alertText = "已移除 \(targets.count) 个守护条目，冻着的文件都解冻了。"
        }
        let needWork = targets.filter { $0.frozen || $0.placeholder }
        guard !needWork.isEmpty else {
            finish()
            return
        }
        guard requireChannel() else { return }
        isBusy = true
        busyText = "正在移除 \(targets.count) 个守护条目…"
        work.async {
            for recipe in needWork {
                guard let root = self.channel.containerPath(for: recipe.bundleID) else { continue }
                let full = RecipeEngine.fullPath(recipe, container: root)
                if recipe.frozen {
                    try? self.channel.setImmutable(full, false)
                }
                if recipe.placeholder {
                    try? self.channel.delete(full)
                }
            }
            DispatchQueue.main.async {
                self.isBusy = false
                self.busyText = ""
                finish()
            }
        }
    }

    /// 清除功能：一键清掉所有「文件不见了」的守护条目。
    /// 文件本身已经没了，只删名单，守护也就不再白查它们。
    /// 一键冻结已复发文件：把所有又变大的配方文件重新备份、清零、冻结。
    /// 光冻不清空等于把广告内容锁在里面，所以顺序是先备份、清零、再冻。
    func refreezeRelapsed() {
        guard requireChannel() else { return }
        let targets = recipes.filter {
            $0.lastState == RecipeState.recurred.rawValue && !$0.placeholder
        }
        guard !targets.isEmpty else {
            alertText = "现在没有已复发的文件。"
            return
        }
        isBusy = true
        busyText = "正在重新冻结已复发的文件…"
        work.async {
            var done = 0
            var newBackups: [BackupRecord] = []
            for recipe in targets {
                guard let root = self.channel.containerPath(for: recipe.bundleID) else { continue }
                let full = RecipeEngine.fullPath(recipe, container: root)
                guard let item = self.channel.item(at: full), !item.isDirectory, item.size > 0 else { continue }
                if DatabaseFile.matches(relativePath: recipe.relativePath) { continue }
                do {
                    if self.channel.isImmutable(full) { try self.channel.setImmutable(full, false) }
                    let record = try self.backupManager.backup(path: full,
                                                                relativePath: recipe.relativePath,
                                                                bundleID: recipe.bundleID,
                                                                appName: recipe.appName,
                                                                source: "复发重冻",
                                                                channel: self.channel)
                    try self.store.registerBackup(record)
                    newBackups.append(record)
                    try self.channel.truncate(full)
                    try self.channel.setImmutable(full, true)
                    done += 1
                    self.log("已重新冻结复发文件：\(recipe.appName) · \(recipe.relativePath)", .success)
                } catch {
                    self.log("重新冻结失败：\(recipe.relativePath)：\(error.localizedDescription)", .warning)
                }
            }
            DispatchQueue.main.async {
                self.isBusy = false
                self.busyText = ""
                if !newBackups.isEmpty {
                    self.backups = self.store.file.backups.sorted { $0.createdAt > $1.createdAt }
                }
                let completionText = done > 0
                    ? "已把 \(done) 个复发文件重新清零并冻结。"
                    : "复发文件都没能处理，详情看日志。"
                self.checkRecipes(silent: true)
                self.alertText = completionText
            }
        }
    }

    func clearMissingRecipes() {
        let missing = recipes.filter { $0.lastState == RecipeState.missing.rawValue }
        guard !missing.isEmpty else {
            alertText = "没有「文件不见了」的条目要清。"
            return
        }
        recipes.removeAll { $0.lastState == RecipeState.missing.rawValue }
        store.file.recipes = recipes
        store.save()
        log("已清除 \(missing.count) 个「文件不见了」的守护条目", .notice)
        alertText = "已清除 \(missing.count) 个文件不见了的条目。"
    }

    /// 按应用结束守护：这个应用的条目一次全移除，冻结的文件默认解冻、
    /// 占位文件夹删掉、广告文件夹也一并解冻（跟移出单个文件的口径一致，
    /// 不能把文件还冻在原地没人管）。其他应用的守护不动。
    func endGuard(forApp bundleID: String) {
        guard requireChannel() else { return }
        let targets = recipes.filter { $0.bundleID == bundleID }
        guard !targets.isEmpty else {
            alertText = "这个应用没有在守护的条目。"
            return
        }
        let name = targets.first?.appName ?? bundleID
        isBusy = true
        busyText = "正在结束 \(name) 的守护…"
        work.async {
            var unfrozen = 0, dirs = 0, failures = 0
            if let info = self.channel.container(for: bundleID) {
                for recipe in targets {
                    let full = RecipeEngine.fullPath(recipe, container: info.path)
                    if recipe.frozen {
                        do {
                            try self.channel.setImmutable(full, false)
                            unfrozen += 1
                        } catch { failures += 1 }
                    }
                    if recipe.placeholder {
                        try? self.channel.delete(full)
                    }
                }
                for relative in self.adDirectoryTree(container: info.path) {
                    let full = info.path + "/" + relative
                    guard self.channel.isImmutable(full) else { continue }
                    do {
                        try self.channel.setImmutable(full, false)
                        dirs += 1
                    } catch { failures += 1 }
                }
            }
            DispatchQueue.main.async {
                self.isBusy = false
                self.busyText = ""
                self.recipes.removeAll { $0.bundleID == bundleID }
                self.store.file.recipes = self.recipes
                self.store.save()
                self.log("已结束 \(name) 的守护：移除 \(targets.count) 个条目，解冻文件 \(unfrozen) 个、文件夹 \(dirs) 个，失败 \(failures) 个",
                         failures == 0 ? .success : .warning)
                self.alertText = "已结束 \(name) 的守护：\(targets.count) 个条目已移除，文件和文件夹都解冻了。文件还是 0 字节，应用自己会重新生成。"
                self.checkRecipes(silent: true)
            }
        }
    }

    /// 全部解冻：所有配方文件 + 广告商文件夹一起解，不依赖备份。
    /// 解完文件仍是 0 字节，应用自己会重新生成。
    func unfreezeAll() {
        guard requireChannel() else { return }
        let allowedRecipes = recipes.filter { !isWhitelisted($0.bundleID) }
        guard !allowedRecipes.isEmpty else {
            alertText = "白名单应用不会执行解冻操作。"
            return
        }
        isBusy = true
        busyText = "正在全部解冻…"
        work.async {
            var files = 0, dirs = 0, failures = 0
            for bundleID in Set(allowedRecipes.map { $0.bundleID }) {
                guard let info = self.channel.container(for: bundleID) else { continue }
                for recipe in allowedRecipes where recipe.bundleID == bundleID && recipe.frozen {
                    do {
                        try self.channel.setImmutable(RecipeEngine.fullPath(recipe, container: info.path), false)
                        files += 1
                    } catch { failures += 1 }
                }
                for relative in self.adDirectoryTree(container: info.path) {
                    let full = info.path + "/" + relative
                    guard self.channel.isImmutable(full) else { continue }
                    do {
                        try self.channel.setImmutable(full, false)
                        dirs += 1
                    } catch { failures += 1 }
                }
            }
            DispatchQueue.main.async {
                self.isBusy = false
                self.busyText = ""
                for index in self.recipes.indices { self.recipes[index].frozen = false }
                self.store.file.recipes = self.recipes
                self.store.save()
                self.log("全部解冻完成：文件 \(files) 个、文件夹 \(dirs) 个，失败 \(failures) 个", failures == 0 ? .success : .warning)
                self.alertText = "已全部解冻：文件 \(files) 个、文件夹 \(dirs) 个。文件还是 0 字节，应用自己会重新生成。"
                self.checkRecipes(silent: true)
            }
        }
    }

    /// 广告商目录树（规则分组目录 + 全部子目录），深的在前。冻结/解冻共用。
    private func adDirectoryTree(container: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        func addTree(_ relative: String) {
            let full = container + "/" + relative
            guard channel.isDirectory(full) else { return }
            if seen.insert(relative).inserted { result.append(relative) }
            if let items = try? channel.children(of: full) {
                for item in items where item.isDirectory {
                    addTree(relative + "/" + item.name)
                }
            }
        }
        for group in BaiduNetdisk.thirdPartyCacheGroups {
            for directory in group.directories { addTree(directory) }
        }
        addTree(BaiduNetdisk.splashCacheRoot)
        return result.sorted { $0.components(separatedBy: "/").count > $1.components(separatedBy: "/").count }
    }

    // MARK: - 手动标记

    private func loadMarks() {
        if let data = UserDefaults.standard.data(forKey: "ls.manualMarks"),
           let marks = try? JSONDecoder().decode([ManualMark].self, from: data) {
            manualMarks = marks
        }
    }

    private func saveMarks() {
        if let data = try? JSONEncoder().encode(manualMarks) {
            UserDefaults.standard.set(data, forKey: "ls.manualMarks")
        }
    }

    func isMarked(bundleID: String, relativePath: String) -> Bool {
        manualMarks.contains { $0.bundleID == bundleID && $0.relativePath == relativePath }
    }

    func toggleMark(bundleID: String, appName: String, relativePath: String, size: UInt64) {
        if isMarked(bundleID: bundleID, relativePath: relativePath) {
            manualMarks.removeAll { $0.bundleID == bundleID && $0.relativePath == relativePath }
            log("已取消标记：\(relativePath)", .notice)
        } else {
            manualMarks.append(ManualMark(bundleID: bundleID, appName: appName,
                                          relativePath: relativePath, size: size, markedAt: Date()))
            log("已标记为广告：\(appName) · \(relativePath)", .success)
        }
        saveMarks()
    }

    private func marksPayload() -> [[String: Any]] {
        manualMarks.map { mark in
            ["bundleID": mark.bundleID, "app": mark.appName, "path": mark.relativePath,
             "size": mark.size, "markedAt": Format.fullDate(mark.markedAt)]
        }
    }

    // MARK: - Guard

    var guardRunning: Bool { guardService.isRunning }

    func setGuard(_ enabled: Bool) {
        if enabled {
            guard requireChannel() else { return }
            if let error = guardService.start() {
                alertText = error
                log("守护没有开启：\(error)", .warning)
            } else {
                guardInterruption = nil
                log("守护已开启：每 3 秒检查配方大小，每 30 秒比对一次目录", .success)
                alertText = "守护已开启。它靠一个小画中画窗口让系统保持本应用运行，被系统终止后这里会显示中断记录。"
            }
        } else {
            guardService.stop()
            log("守护已停止", .notice)
        }
    }

    /// 「一键开启并隐藏」：守护直接以隐藏窗口启动；已经在守护中就只把
    /// 窗口压到 0.1 藏起来。
    func startGuardAndHide() {
        if guardService.isRunning {
            guardService.setPiPHidden(true)
            alertText = "守护窗口已隐藏。"
            return
        }
        guard requireChannel() else { return }
        if let error = guardService.start(hidden: true) {
            alertText = error
            log("守护没有开启：\(error)", .warning)
        } else {
            guardInterruption = nil
            log("守护已开启并隐藏：每 3 秒检查配方大小，每 30 秒比对一次目录", .success)
            alertText = "守护已开启，窗口已隐藏。被系统终止后这里会显示中断记录。"
        }
    }

    private func guardTick(deep: Bool) {
        guard guardService.isRunning else { return }
        let list = recipes.filter { !isWhitelisted($0.bundleID) }
        guard !list.isEmpty else { return }

        var truncated = 0
        for recipe in list where !recipe.placeholder {
            guard let root = channel.containerPath(for: recipe.bundleID) else { continue }
            let full = RecipeEngine.fullPath(recipe, container: root)
            guard let item = channel.item(at: full), !item.isDirectory, item.size > 0 else { continue }
            if DatabaseFile.matches(relativePath: recipe.relativePath) { continue }
            do {
                if channel.isImmutable(full) {
                    try channel.setImmutable(full, false)
                }
                try channel.truncate(full)
                truncated += 1
                log("值守重新清零：\(recipe.appName) · \(recipe.relativePath)（\(Format.bytes(item.size))）", .success)
            } catch {
                log("值守清零失败：\(recipe.relativePath)：\(error.localizedDescription)", .warning)
            }
        }
        if truncated > 0 {
            DispatchQueue.main.async {
                self.checkRecipes(silent: true)
            }
        }

        if deep {
            compareRecipeDirectories(list)
            sweepAdDirectories(reason: "值守")
        }
    }

    // MARK: - 目录补扫（守护深查与启动时共用）

    /// 目录自动处理：把已知广告目录里新冒出来的非零文件当场备份、清零
    /// 冻结并存入守护列表；名字带冷开/开屏的新目录也一样自动压。
    /// 范围：有配方的应用＋当前目标＋一键勾选的应用。守护的「目录自动
    /// 处理」关掉时不做。必须在后台队列调用。
    private func sweepAdDirectories(reason: String) {
        guard channel.isAvailable, guardService.dirWatch else { return }
        var bundleIDs = Set(recipes.map { $0.bundleID })
        if targetChosen { bundleIDs.insert(target.bundleID) }
        bundleIDs.formUnion(checkedIDs)
        bundleIDs = Set(bundleIDs.filter { !isWhitelisted($0) })
        var cleared = 0
        var newBackups: [BackupRecord] = []
        var newRecipes: [Recipe] = []
        for bundleID in bundleIDs {
            guard cleared < 300, let info = channel.container(for: bundleID) else { continue }
            let files = BaiduNetdisk.targets(container: info.path, channel: channel, splash: nil,
                                             ownerBundleID: info.bundleID, ownerName: info.name)
            for file in files where file.size > 0 {
                guard cleared < 300 else { break }
                // 数据库文件是应用的统计/索引库，常驻占用、清不动，也不是广告素材，跳过。
                if DatabaseFile.matches(relativePath: file.relativePath) { continue }
                if autoClearFile(file, source: file.group, newBackups: &newBackups, newRecipes: &newRecipes) {
                    cleared += 1
                    log("\(reason)清掉新文件：\(info.name) · \(file.relativePath)", .success)
                }
            }
            cleared += sweepColdLaunchDirs(info: info, cleared: cleared,
                                           newBackups: &newBackups, newRecipes: &newRecipes)
        }
        if cleared > 0 {
            log("\(reason)：共清掉 \(cleared) 个新冒出来的广告文件，已备份并冻结", .notice)
        }
        if !newBackups.isEmpty || !newRecipes.isEmpty {
            let backupsToAdd = newBackups
            let recipesToAdd = newRecipes
            DispatchQueue.main.async {
                for recipe in recipesToAdd {
                    let exists = self.store.file.recipes.contains {
                        $0.bundleID == recipe.bundleID && $0.relativePath == recipe.relativePath
                    }
                    if !exists { self.store.file.recipes.append(recipe) }
                }
                self.store.save()
                self.recipes = self.store.file.recipes
                self.backups = self.store.file.backups.sorted { $0.createdAt > $1.createdAt }
            }
        } else if cleared > 0 {
            DispatchQueue.main.async { self.checkRecipes(silent: true) }
        }
    }

    /// 自动清一个文件：先备份（备份失败就跳过、不动原文件），再清零
    /// 冻结，并登记成配方。成功返回 true。
    private func autoClearFile(_ file: TargetFile, source: String,
                               newBackups: inout [BackupRecord], newRecipes: inout [Recipe]) -> Bool {
        if DatabaseFile.matches(relativePath: file.relativePath) { return false }
        let ownerID = file.bundleID.isEmpty ? BaiduNetdisk.bundleID : file.bundleID
        let ownerName = file.appName.isEmpty ? BaiduNetdisk.displayName : file.appName
        do {
            if channel.isImmutable(file.path) {
                try channel.setImmutable(file.path, false)
            }
            let record = try backupManager.backup(path: file.path,
                                                  relativePath: file.relativePath,
                                                  bundleID: ownerID,
                                                  appName: ownerName,
                                                  source: source,
                                                  channel: channel)
            try store.registerBackup(record)
            newBackups.append(record)
            try channel.truncate(file.path)
            try channel.setImmutable(file.path, true)
            newRecipes.append(Recipe(id: UUID(),
                                     bundleID: ownerID,
                                     appName: ownerName,
                                     relativePath: file.relativePath,
                                     createdAt: Date(),
                                     frozen: true,
                                     placeholder: false,
                                     lastCheckedAt: Date(),
                                     lastState: RecipeState.normal.rawValue))
            return true
        } catch {
            log("自动清文件失败：\(file.relativePath)：\(error.localizedDescription)", .warning)
            return false
        }
    }

    /// 冷开目录自动压：在缓存区里找名字带 cold_launch/coldlaunch/splash
    /// 的目录（系统 SplashBoard 除外），里面的非零文件逐个自动清掉，
    /// 最后把目录本身也冻上，这一档期的包就回不来。返回清掉的文件数。
    private func sweepColdLaunchDirs(info: ContainerInfo, cleared: Int,
                                     newBackups: inout [BackupRecord], newRecipes: inout [Recipe]) -> Int {
        var count = 0
        var visited = 0
        var matched: [String] = []
        func walk(relative: String, depth: Int) {
            guard depth <= 5, visited < 3000, cleared + count < 300 else { return }
            guard let items = try? channel.children(of: info.path + "/" + relative) else { return }
            for item in items where item.isDirectory {
                visited += 1
                let rel = relative.isEmpty ? item.name : relative + "/" + item.name
                let lower = item.name.lowercased()
                if lower.contains("cold_launch") || lower.contains("coldlaunch") || lower.contains("splash"),
                   !rel.lowercased().contains("splashboard") {
                    matched.append(rel)
                } else {
                    walk(relative: rel, depth: depth + 1)
                }
            }
        }
        for root in ["Library/Caches", "Library/reshub", "Documents"] {
            if channel.isDirectory(info.path + "/" + root) {
                walk(relative: root, depth: 1)
            }
        }
        for dir in matched {
            guard cleared + count < 300 else { break }
            var dirCleared = 0
            var stack: [(path: String, relative: String)] = [(info.path + "/" + dir, dir)]
            var subdirs: [String] = []
            var fileBudget = 0
            while let current = stack.popLast() {
                guard let items = try? channel.children(of: current.path) else { continue }
                for item in items {
                    let rel = current.relative + "/" + item.name
                    if item.isDirectory {
                        subdirs.append(item.path)
                        stack.append((path: item.path, relative: rel))
                    } else if item.size > 0, fileBudget < 300, cleared + count < 300 {
                        fileBudget += 1
                        let file = TargetFile(path: item.path, relativePath: rel, group: "冷开广告",
                                              note: "目录名命中冷开/开屏，守护自动压",
                                              size: item.size, isSmallConfig: false,
                                              bundleID: info.bundleID, appName: info.name)
                        if autoClearFile(file, source: "冷开广告", newBackups: &newBackups, newRecipes: &newRecipes) {
                            dirCleared += 1
                            count += 1
                        }
                    }
                }
            }
            for sub in subdirs.sorted(by: { $0.count > $1.count }) {
                try? channel.setImmutable(sub, true)
            }
            try? channel.setImmutable(info.path + "/" + dir, true)
            if dirCleared > 0 {
                log("自动压：\(info.name) 冷开广告目录 \(dir) 清了 \(dirCleared) 个文件", .success)
            }
        }
        return count
    }

    // MARK: - 上传与更新

    /// 日志页「导出 → 上传」：把运行日志传到收集箱。
    func uploadLog() {
        var text = exportLogText()
        // 上传封顶（清单第 10 条）：日志太长就只传最后约 1.5 MB，
        // 开头注明截过，免得一份日志把收集箱撑爆。
        if text.utf8.count > 1_500_000 {
            let tail = String(decoding: Data(text.utf8.suffix(1_500_000)), as: UTF8.self)
            text = "（日志太长，只传了最后约 1.5 MB）\n" + String(tail.drop(while: { $0 != "\n" }))
        }
        CollectUploader.upload(kind: "log", contentType: "text/plain; charset=utf-8", body: Data(text.utf8)) { [weak self] ok, message in
            guard let self = self else { return }
            self.log(ok ? "日志已上传" : "日志上传失败：\(message)", ok ? .success : .warning)
            self.alertText = ok ? "日志已上传。" : "日志上传失败：\(message)"
        }
    }

    /// 深度采集（上传时现采）：目录树、图片/视频文件清单（带尺寸/时长）、
    /// 小配置文件的键名结构。有了文件级数据才能定位每个应用的广告文件在哪。
    private func collectDeepData(info: ContainerInfo) -> DeepAppData {
        var dirs: [String] = []
        var files: [CollectedFile] = []
        var configs: [CollectedConfig] = []
        let mediaExts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "mp4", "mov", "m4v", "heic"]
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic"]
        var visited = 0
        var dimsRead = 0
        var durationsRead = 0
        func walk(_ relative: String, depth: Int) {
            guard depth <= 5, visited < 6000 else { return }
            guard let items = try? channel.children(of: info.path + "/" + relative) else { return }
            for item in items {
                visited += 1
                let rel = relative.isEmpty ? item.name : relative + "/" + item.name
                if item.isDirectory {
                    if dirs.count < 900 { dirs.append(rel) }
                    walk(rel, depth: depth + 1)
                } else {
                    let ext = (item.name as NSString).pathExtension.lowercased()
                    if mediaExts.contains(ext), files.count < 500 {
                        var collected = CollectedFile(path: rel, size: item.size)
                        if imageExts.contains(ext), dimsRead < 40, item.size > 0, item.size < 3_000_000,
                           let data = try? channel.read(item.path),
                           let source = CGImageSourceCreateWithData(data as CFData, nil),
                           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
                            collected.width = props[kCGImagePropertyPixelWidth as String] as? Int
                            collected.height = props[kCGImagePropertyPixelHeight as String] as? Int
                            dimsRead += 1
                        }
                        if ["mp4", "mov", "m4v"].contains(ext), durationsRead < 10, item.size > 0 {
                            let asset = AVURLAsset(url: URL(fileURLWithPath: item.path))
                            let seconds = CMTimeGetSeconds(asset.duration)
                            if seconds.isFinite, seconds > 0 {
                                collected.duration = seconds
                                durationsRead += 1
                            }
                        }
                        files.append(collected)
                    }
                    if (ext == "plist" || ext == "json"), item.size > 0, item.size < 65536, configs.count < 30,
                       let data = try? channel.read(item.path) {
                        var keys: [String] = []
                        if ext == "plist",
                           let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                           let dict = object as? [String: Any] {
                            keys = Array(dict.keys)
                        } else if ext == "json",
                                  let object = try? JSONSerialization.jsonObject(with: data),
                                  let dict = object as? [String: Any] {
                            keys = Array(dict.keys)
                        }
                        if !keys.isEmpty {
                            configs.append(CollectedConfig(path: rel, size: item.size, keys: keys.sorted()))
                        }
                    }
                }
            }
        }
        for root in ["Library/Caches", "Library", "tmp", "Documents"] {
            if channel.isDirectory(info.path + "/" + root) {
                if dirs.count < 900 { dirs.append(root) }
                walk(root, depth: 1)
            }
        }
        return DeepAppData(bundleID: info.bundleID, name: info.name, dirs: dirs, files: files, configs: configs)
    }

    /// 上传识别数据 v2：分组计数 + 未知目录 + 文件级清单 + 目录树 +
    /// 配置结构 + 用户手动标记 +「清完还出广告」反馈。
    func uploadRecognition(stillSeesAds: Bool) {
        guard !lastRecognition.isEmpty else {
            alertText = "先点一次「扫描」，有了识别结果才能上传。"
            return
        }
        let base = lastRecognition
        isBusy = true
        busyText = "正在收集文件数据…"
        work.async {
            var apps: [[String: Any]] = []
            for item in base {
                var entry: [String: Any] = ["bundleID": item.bundleID,
                                            "name": item.name,
                                            "groups": item.groups,
                                            "unknownDirs": item.unknownDirs]
                if let info = self.channel.container(for: item.bundleID) {
                    let deep = self.collectDeepData(info: info)
                    entry["dirs"] = deep.dirs
                    entry["files"] = deep.files.map { file -> [String: Any] in
                        var dict: [String: Any] = ["path": file.path, "size": file.size]
                        if let width = file.width, let height = file.height {
                            dict["width"] = width
                            dict["height"] = height
                        }
                        if let duration = file.duration { dict["duration"] = duration }
                        return dict
                    }
                    entry["configs"] = deep.configs.map { ["path": $0.path, "size": $0.size, "keys": $0.keys] }
                }
                apps.append(entry)
            }
            let payload: [String: Any] = [
                "appVersion": self.appVersionText,
                "system": self.systemText,
                "device": UIDevice.current.model,
                "time": Format.fullDate(Date()),
                "stillSeesAds": stillSeesAds,
                "manualMarks": self.marksPayload(),
                "apps": apps
            ]
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            DispatchQueue.main.async {
                self.isBusy = false
                self.busyText = ""
                guard let data else { return }
                CollectUploader.upload(kind: "recognition", contentType: "application/json", body: data) { [weak self] ok, message in
                    guard let self = self else { return }
                    if ok {
                        self.log(stillSeesAds ? "已反馈：清完还出广告（附识别数据 v2）" : "识别数据已上传（v2）", .success)
                        self.alertText = stillSeesAds ? "已反馈，我们会照着这份数据找漏掉的广告商。" : "识别数据已上传，谢谢帮忙攒指纹库。"
                    } else {
                        self.log("识别数据上传失败：\(message)", .warning)
                        self.alertText = "上传失败：\(message)"
                    }
                }
            }
        }
    }

    /// 上传找广告结果：差分候选（是否疑似、是否勾选、是否人工标记）+ 手动标记，
    /// 和识别数据一起攒规则素材。
    func uploadFindings() {
        guard !candidates.isEmpty else {
            alertText = "还没有找广告结果可上传，先拍两次快照比一比。"
            return
        }
        let payload: [String: Any] = [
            "appVersion": appVersionText,
            "system": systemText,
            "device": UIDevice.current.model,
            "time": Format.fullDate(Date()),
            "apps": findAdScope.map { ["bundleID": $0.bundleID, "name": $0.name] },
            "candidates": candidates.map { candidate in
                ["app": candidate.appName,
                 "bundleID": candidate.bundleID,
                 "path": candidate.relativePath,
                 "isNew": candidate.isNew,
                 "reason": candidate.reason,
                 "size": candidate.size,
                 "likelyAd": candidate.likelyAd,
                 "selected": selectedCandidatePaths.contains(candidate.id),
                 "marked": isMarked(bundleID: candidate.bundleID, relativePath: candidate.relativePath)]
            },
            "manualMarks": marksPayload()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        CollectUploader.upload(kind: "findad", contentType: "application/json", body: data) { [weak self] ok, message in
            guard let self = self else { return }
            self.log(ok ? "找广告结果已上传" : "找广告结果上传失败：\(message)", ok ? .success : .warning)
            self.alertText = ok ? "这次找广告的结果已上传。" : "上传失败：\(message)"
        }
    }

    /// 检测应用更新：只查正式版，测试版不算。
    /// 「更新规则」：从服务器下载最新识别规则到本地，扫描随即按新规则走。
    func updateRules() {
        rulesStatus = "正在更新规则…"
        RulesStore.update { [weak self] ok, message in
            guard let self else { return }
            self.rulesStatus = message
            self.log(message, ok ? .success : .warning)
            // 成功失败都弹窗：只写在按钮下面那行小字里，用户容易看不见。
            self.alertText = message
        }
    }

    /// 启动提醒检查（应用更新＋规则更新）串行跑：先应用后规则，
    /// 免得两个弹窗互相顶掉。启动时跑一次；应用回前台时由
    /// recheckRemindersIfStale 按节流补跑——发版时应用正开着、
    /// 进程没重启的情况靠补跑才不会漏掉提醒。
    private func runReminderChecks() {
        lastReminderCheckAt = Date()
        checkUpdateOnLaunch { [weak self] in
            self?.checkRulesOnLaunch()
        }
    }

    /// 回前台补查提醒：距上次检查不到 1 小时就不查，免得频繁打扰
    /// 服务器；同一版本一天最多弹一次的闸门在各检查里把着。
    func recheckRemindersIfStale() {
        if let last = lastReminderCheckAt, Date().timeIntervalSince(last) < 3600 { return }
        runReminderChecks()
    }

    /// 启动时悄悄查一次规则：服务器版本比本地新才提醒（同一个版本一天
    /// 最多提醒一次），弹窗里点「更新规则」直接下载套用；没网、查不到、
    /// 已经是最新都安安静静，不弹窗、不报错。要是应用更新弹窗正占着，
    /// 规则提醒先候着，等那个弹窗关了再补弹，不互相顶掉。
    private func checkRulesOnLaunch() {
        RulesStore.checkLatestVersion { [weak self] latest in
            guard let self, let latest else { return }
            let current = RulesStore.currentVersion
            guard latest > current else { return }
            let day = DateFormatter()
            day.dateFormat = "yyyy-MM-dd"
            let stamp = "\(latest)@\(day.string(from: Date()))"
            guard UserDefaults.standard.string(forKey: "rules.updateReminded") != stamp else { return }
            UserDefaults.standard.set(stamp, forKey: "rules.updateReminded")
            self.rulesStatus = "有新规则（第 \(latest) 版）"
            self.presentUpdateAlert(.rules)
            self.log("检测规则：服务器第 \(latest) 版，本地\(current == 0 ? "内置规则" : "第 \(current) 版")", .info)
        }
    }

    /// 启动时悄悄查一次正式版：有新版才提醒（同一个版本一天最多提醒
    /// 一次），没有就什么都不说——像 Drift 那样，不用用户自己去点。
    private func checkUpdateOnLaunch(completion: @escaping () -> Void = {}) {
        GitHubUpdate.fetchLatest { [weak self] info, _ in
            guard let self else { completion(); return }
            defer { completion() }
            guard let info else { return }
            let current = self.appVersionText.components(separatedBy: " ").first ?? "0.1.0"
            guard Self.isVersion(info.version, newerThan: current) else { return }
            let day = DateFormatter()
            day.dateFormat = "yyyy-MM-dd"
            let stamp = "\(info.version)@\(day.string(from: Date()))"
            guard UserDefaults.standard.string(forKey: "app.updateReminded") != stamp else { return }
            UserDefaults.standard.set(stamp, forKey: "app.updateReminded")
            self.availableVersion = info.version
            self.availableDownloadURL = info.downloadURL
            self.updateStatus = "有新版本 \(info.version)"
            self.presentUpdateAlert(.app)
            self.log("检测更新：正式版 \(info.version)，当前 \(current)", .info)
        }
    }

    func checkForUpdate() {
        updateStatus = "正在检查…"
        availableVersion = nil
        availableDownloadURL = nil
        downloadedIPA = nil
        GitHubUpdate.fetchLatest { [weak self] info, message in
            guard let self = self else { return }
            guard let info else {
                self.updateStatus = "检查失败"
                self.alertText = "检测更新失败：\(message)"
                return
            }
            let current = self.appVersionText.components(separatedBy: " ").first ?? "0.1.0"
            if Self.isVersion(info.version, newerThan: current) {
                self.updateStatus = "有新版本 \(info.version)"
                self.availableVersion = info.version
                self.availableDownloadURL = info.downloadURL
                self.alertText = "正式版有新版本：\(info.version)。点「下载新版」就能下载，下载完分享出去签名。"
            } else {
                self.updateStatus = "已是最新"
                self.alertText = "已经是最新版本（\(current)）。"
            }
            self.log("检测更新：正式版 \(info.version)，当前 \(current)", .info)
        }
    }

    /// 下载正式版新版安装包（带进度），下完存在本应用文稿里，等用户分享出去签名。
    func downloadUpdate() {
        guard availableVersion != nil, let directURL = availableDownloadURL, downloadProgress == nil else { return }
        downloadProgress = 0
        GitHubUpdate.downloadIPA(from: directURL, progress: { [weak self] value in
            self?.downloadProgress = value
        }, completion: { [weak self] url, message in
            guard let self = self else { return }
            self.downloadProgress = nil
            if let url {
                self.downloadedIPA = url
                self.updateStatus = "已下载，去签名"
                self.log("新版安装包已下载：\(url.lastPathComponent)", .success)
                self.alertText = "新版已经下载好了，点「分享」把它存下来，再用签名工具导入安装。"
            } else {
                self.log("下载新版失败：\(message)", .warning)
                self.alertText = "下载失败：\(message)"
            }
        })
    }

    private static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func compareRecipeDirectories(_ list: [Recipe]) {
        var current = Set<String>()
        for recipe in list {
            guard let root = channel.containerPath(for: recipe.bundleID) else { continue }
            let directory = (RecipeEngine.fullPath(recipe, container: root) as NSString).deletingLastPathComponent
            guard let items = try? channel.children(of: directory) else { continue }
            let known = Set(list.filter { $0.bundleID == recipe.bundleID }
                .map { ($0.relativePath as NSString).lastPathComponent })
            for item in items where !item.isDirectory && !known.contains(item.name) {
                current.insert(item.path)
            }
        }
        let added = current.subtracting(reportedNewFiles)
        reportedNewFiles = current
        guard !added.isEmpty else { return }
        let names = added.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: "、")
        log("值守发现 \(added.count) 个新文件，没有自动处理：\(names)", .notice)
    }

    // MARK: - Helpers

    @discardableResult
    private func requireChannel() -> Bool {
        if channel.isAvailable { return true }
        alertText = channel.unavailableReason
        log(channel.unavailableReason, .warning)
        return false
    }
}
