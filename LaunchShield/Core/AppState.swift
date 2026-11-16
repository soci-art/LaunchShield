import Foundation
import UIKit

final class AppState: ObservableObject {
    let channel = Channel.shared
    let logs = LogStore()
    let store = LibraryStore()
    let guardService = GuardService.shared

    @Published var target: AppTarget = .baidu
    @Published var containers: [ContainerInfo] = []
    @Published var recipes: [Recipe] = []
    @Published var backups: [BackupRecord] = []
    @Published var scanTargets: [TargetFile] = []
    @Published var splash: SplashResolution?
    @Published var isBusy = false
    @Published var busyText = ""
    @Published var banner: String?
    @Published var guardInterruption: Date?
    @Published var beforeSnapshot: ContainerSnapshot?
    @Published var afterSnapshot: ContainerSnapshot?
    @Published var candidates: [DiffCandidate] = []
    @Published var selectedCandidatePaths: Set<String> = []

    private let backupManager: BackupManager
    private let work = DispatchQueue(label: "com.sociart.launchshield.work", qos: .userInitiated)
    private var didBootstrap = false
    private var reportedNewFiles = Set<String>()

    init() {
        backupManager = BackupManager(store: store)
    }

    // MARK: - Derived values

    var channelReady: Bool { channel.isAvailable }
    var channelDetail: String {
        channel.isAvailable ? (channel.groupID ?? "共享组已就绪") : channel.unavailableReason
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
        log("LaunchShield \(appVersionText) 已启动", .info)
        log("系统 \(systemText)，设备 \(UIDevice.current.model)", .info)
        if channel.isAvailable {
            log("文件通道就绪，共享组：\(channel.groupID ?? "未命名")", .success)
        } else {
            log(channel.unavailableReason, .warning)
        }
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
        refreshContainers()
        checkRecipes(silent: true)
    }

    func refresh() {
        refreshContainers()
        checkRecipes()
    }

    func dismissBanner() {
        banner = nil
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
            "共享组：\(channel.groupID ?? "没有拿到")",
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

    func refreshContainers() {
        guard channel.isAvailable else {
            containers = []
            return
        }
        work.async {
            let list = self.channel.containers()
            DispatchQueue.main.async {
                self.containers = list
                if list.isEmpty {
                    self.log("没有读到应用容器列表，可能是系统版本不支持或权限被拒", .warning)
                }
            }
        }
    }

    func select(_ container: ContainerInfo) {
        target = AppTarget(bundleID: container.bundleID, name: container.name)
        scanTargets = []
        splash = nil
        candidates = []
        selectedCandidatePaths = []
        beforeSnapshot = nil
        afterSnapshot = nil
        log("目标应用切换为 \(container.name)（\(container.bundleID)）", .notice)
    }

    // MARK: - Scan and batch clear

    func scanBaidu(completion: (() -> Void)? = nil) {
        guard requireChannel() else { return }
        guard let root = channel.containerPath(for: BaiduNetdisk.bundleID) else {
            banner = "没有找到百度网盘，请先安装并打开一次。"
            log("没有找到百度网盘的数据容器", .warning)
            return
        }
        isBusy = true
        busyText = "正在扫描百度网盘的素材…"
        work.async {
            let splash = BaiduNetdisk.resolveSplash(container: root, channel: self.channel)
            let targets = BaiduNetdisk.targets(container: root, channel: self.channel, splash: splash)
            DispatchQueue.main.async {
                self.isBusy = false
                self.busyText = ""
                self.splash = splash
                self.scanTargets = targets
                if let splash {
                    if splash.exists {
                        let relative = BaiduNetdisk.relativePath(container: root, path: splash.path)
                        self.log("自营开屏素材：\(relative)", .info)
                        self.log("推导依据：\(splash.url) → MD5 \(splash.md5)", .info)
                    } else {
                        let relative = BaiduNetdisk.relativePath(container: root, path: splash.path)
                        self.log("按广告记录算出了素材路径，但那个文件现在不存在：\(relative)（网址 \(splash.url)）", .notice)
                    }
                } else {
                    self.log("没有读到开屏广告记录，可能广告还没缓存过，或记录文件暂时读不到", .notice)
                }
                let groups = Dictionary(grouping: targets, by: { $0.group })
                for name in ["百度自营", "优量汇", "穿山甲", "BeiZi"] {
                    guard let list = groups[name], !list.isEmpty else { continue }
                    let small = list.filter { $0.isSmallConfig }.count
                    let suffix = small > 0 ? "，其中清单小文件 \(small) 个" : ""
                    self.log("\(name)：\(list.count) 个文件\(suffix)", .info)
                }
                self.log("扫描完成，共 \(targets.count) 个素材文件", .success)
                completion?()
            }
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
            banner = "没有可清零的素材，先扫描一次。"
            return
        }
        let targets = scanTargets
        isBusy = true
        busyText = "正在清零 \(targets.count) 个文件…"
        log("开始清零：\(targets.count) 个文件，逐个先备份再截断", .notice)

        work.async {
            var done = 0
            var frozenCount = 0
            var freezeFailureCount = 0
            var failure: String?
            var newBackups: [BackupRecord] = []
            var newRecipes: [Recipe] = []

            for targetFile in targets {
                do {
                    if self.channel.isImmutable(targetFile.path) {
                        try self.channel.setImmutable(targetFile.path, false)
                        self.log("先解冻：\(targetFile.relativePath)", .notice)
                    }
                    let size = self.channel.item(at: targetFile.path)?.size ?? 0
                    if size == 0 {
                        self.log("已经是 0 字节，跳过：\(targetFile.relativePath)", .info)
                    } else {
                        let record = try self.backupManager.backup(path: targetFile.path,
                                                                   relativePath: targetFile.relativePath,
                                                                   bundleID: BaiduNetdisk.bundleID,
                                                                   appName: BaiduNetdisk.displayName,
                                                                   source: targetFile.group,
                                                                   channel: self.channel)
                        newBackups.append(record)
                        try self.channel.truncate(targetFile.path)
                        done += 1
                        self.log("已清零：\(targetFile.relativePath)（\(Format.bytes(size))）", .success)
                        if targetFile.group == "百度自营" {
                            newRecipes.append(Recipe(id: UUID(),
                                                     bundleID: BaiduNetdisk.bundleID,
                                                     appName: BaiduNetdisk.displayName,
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
                    failure = "\(targetFile.relativePath)：\(error.localizedDescription)"
                    break
                }
            }

            DispatchQueue.main.async {
                self.isBusy = false
                self.busyText = ""
                if !newBackups.isEmpty {
                    self.store.file.backups.append(contentsOf: newBackups)
                }
                for recipe in newRecipes {
                    let exists = self.store.file.recipes.contains {
                        $0.bundleID == recipe.bundleID && $0.relativePath == recipe.relativePath
                    }
                    if !exists { self.store.file.recipes.append(recipe) }
                }
                self.store.save()
                self.recipes = self.store.file.recipes
                self.backups = self.store.file.backups.sorted { $0.createdAt > $1.createdAt }

                if let failure {
                    self.log("清零没有全部完成，停在：\(failure)", .warning)
                    self.banner = "清零没有全部完成，已经停在出问题的文件，详情看日志。"
                } else {
                    self.log("清零完成：\(done) 个文件已截断为 0 字节", .success)
                    if frozenCount > 0 {
                        self.log("清零的文件已全部冻结：\(frozenCount) 个", .success)
                    }
                    if freezeFailureCount > 0 {
                        self.log("有 \(freezeFailureCount) 个文件没冻上，详情看上面", .warning)
                    }
                    self.banner = frozenCount > 0
                        ? "清零完成：\(done) 个文件已截断为 0 字节，全部已冻结。请强退百度网盘再冷启动看看。"
                        : "清零完成：\(done) 个文件已截断为 0 字节。请强退百度网盘再冷启动看看。"
                    self.scanTargets = []
                }
                self.checkRecipes(silent: true)
            }
        }
    }

    // MARK: - Backups

    func restoreAll() {
        guard requireChannel() else { return }
        let records = backupManager.originalBackups()
        guard !records.isEmpty else {
            banner = "还没有备份可以还原。"
            return
        }
        isBusy = true
        busyText = "正在还原 \(records.count) 个文件…"
        log("开始还原：\(records.count) 个备份，逐个写回并核对 MD5", .notice)

        work.async {
            var restored = 0
            var failure: String?
            for record in records {
                do {
                    guard let root = self.channel.containerPath(for: record.bundleID) else {
                        throw ChannelFailure("找不到 \(record.appName) 的数据容器")
                    }
                    _ = try self.backupManager.restore(record, container: root, channel: self.channel)
                    restored += 1
                    self.log("已还原并核对 MD5：\(record.relativePath)", .success)
                } catch {
                    failure = "\(record.relativePath)：\(error.localizedDescription)"
                    break
                }
            }
            DispatchQueue.main.async {
                self.isBusy = false
                self.busyText = ""
                if let failure {
                    self.log("还原没有全部完成，停在：\(failure)", .warning)
                    self.banner = "还原没有全部完成，已经停在出问题的文件，详情看日志。"
                } else {
                    self.log("还原完成：\(restored) 个文件已写回，MD5 全部一致", .success)
                    self.banner = "还原完成：\(restored) 个文件已写回，MD5 全部一致。"
                }
                self.checkRecipes(silent: true)
            }
        }
    }

    func restore(_ record: BackupRecord) {
        guard requireChannel() else { return }
        guard let root = channel.containerPath(for: record.bundleID) else {
            banner = "找不到 \(record.appName) 的数据容器。"
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
                    self.banner = "已还原：\(record.relativePath)，MD5 一致。"
                    self.checkRecipes(silent: true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.busyText = ""
                    self.log("还原失败：\(error.localizedDescription)", .warning)
                    self.banner = "还原失败：\(error.localizedDescription)"
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
        banner = "已删除这份备份。"
    }

    func deleteAllBackups() {
        let records = store.file.backups
        guard !records.isEmpty else {
            banner = "还没有备份可以删。"
            return
        }
        for record in records {
            try? FileManager.default.removeItem(at: store.backupDirectoryURL(for: record.id))
        }
        store.file.backups = []
        store.save()
        backups = []
        log("已清空全部备份：\(records.count) 份", .notice)
        banner = "已清空全部备份：\(records.count) 份。"
    }

    // MARK: - Before/after diff

    func takeSnapshot(before: Bool) {
        guard requireChannel() else { return }
        guard let root = channel.containerPath(for: target.bundleID) else {
            banner = "找不到 \(target.name) 的数据容器，请先打开一次这个应用。"
            return
        }
        let bundleID = target.bundleID
        let appName = target.name
        isBusy = true
        busyText = before ? "正在拍第一次快照…" : "正在拍第二次快照…"
        work.async {
            do {
                let snapshot = try SnapshotDiff.take(bundleID: bundleID, root: root, channel: self.channel)
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.busyText = ""
                    if before {
                        self.beforeSnapshot = snapshot
                        self.afterSnapshot = nil
                        self.candidates = []
                        self.selectedCandidatePaths = []
                        self.log("第一次快照完成：\(snapshot.fileCount) 个文件，共 \(Format.bytes(snapshot.totalBytes))", .success)
                        self.banner = "现在去打开\(appName)，让开屏广告播一次，再回来拍第二次快照。"
                    } else {
                        guard let first = self.beforeSnapshot else {
                            self.banner = "请先拍第一次快照。"
                            return
                        }
                        self.afterSnapshot = snapshot
                        self.candidates = SnapshotDiff.diff(before: first, after: snapshot)
                        self.selectedCandidatePaths = Set(self.candidates.filter { $0.kind != .other }.map { $0.id })
                        self.log("第二次快照完成：\(snapshot.fileCount) 个文件，\(self.candidates.count) 个候选", .success)
                        self.banner = self.candidates.isEmpty
                            ? "这次没有发现新文件或变大的文件。可以再让广告播一次试试。"
                            : "请勾选确实是广告素材的文件，再点清零。"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.busyText = ""
                    self.log("快照失败：\(error.localizedDescription)", .warning)
                    self.banner = "快照失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func clearSelectedCandidates() {
        guard requireChannel() else { return }
        guard let root = containerPath else {
            banner = "找不到目标应用的数据容器。"
            return
        }
        let selected = candidates.filter { selectedCandidatePaths.contains($0.id) }
        guard !selected.isEmpty else {
            banner = "请先勾选要清零的文件。"
            return
        }
        let app = target
        isBusy = true
        busyText = "正在清零确认的素材…"
        work.async {
            var done = 0
            var failure: String?
            var newBackups: [BackupRecord] = []
            var newRecipes: [Recipe] = []
            for candidate in selected {
                let full = root + "/" + candidate.relativePath
                do {
                    if self.channel.isImmutable(full) {
                        try self.channel.setImmutable(full, false)
                    }
                    let record = try self.backupManager.backup(path: full,
                                                               relativePath: candidate.relativePath,
                                                               bundleID: app.bundleID,
                                                               appName: app.name,
                                                               source: "前后对比确认",
                                                               channel: self.channel)
                    newBackups.append(record)
                    try self.channel.truncate(full)
                    done += 1
                    self.log("已清零确认的素材：\(candidate.relativePath)", .success)
                    newRecipes.append(Recipe(id: UUID(),
                                             bundleID: app.bundleID,
                                             appName: app.name,
                                             relativePath: candidate.relativePath,
                                             createdAt: Date(),
                                             frozen: false,
                                             placeholder: false,
                                             lastCheckedAt: Date(),
                                             lastState: RecipeState.normal.rawValue))
                } catch {
                    failure = "\(candidate.relativePath)：\(error.localizedDescription)"
                    break
                }
            }
            DispatchQueue.main.async {
                self.isBusy = false
                self.busyText = ""
                self.store.file.backups.append(contentsOf: newBackups)
                for recipe in newRecipes {
                    let exists = self.store.file.recipes.contains {
                        $0.bundleID == recipe.bundleID && $0.relativePath == recipe.relativePath
                    }
                    if !exists { self.store.file.recipes.append(recipe) }
                }
                self.store.save()
                self.recipes = self.store.file.recipes
                self.backups = self.store.file.backups.sorted { $0.createdAt > $1.createdAt }
                if let failure {
                    self.log("清零候选没有全部完成，停在：\(failure)", .warning)
                    self.banner = "清零没有全部完成，已经停在出问题的文件，详情看日志。"
                } else {
                    self.log("确认的素材已清零：\(done) 个，配方已存入守护列表", .success)
                    self.banner = "已清零 \(done) 个素材，并加入已守护应用。"
                    self.candidates = []
                    self.selectedCandidatePaths = []
                }
            }
        }
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
            banner = "找不到 \(recipe.appName) 的数据容器。"
            return
        }
        isBusy = true
        busyText = "正在重新清零…"
        work.async {
            do {
                let full = RecipeEngine.fullPath(recipe, container: root)
                if self.channel.isImmutable(full) {
                    try self.channel.setImmutable(full, false)
                }
                let size = self.channel.item(at: full)?.size ?? 0
                if size > 0 {
                    _ = try self.backupManager.backup(path: full,
                                                      relativePath: recipe.relativePath,
                                                      bundleID: recipe.bundleID,
                                                      appName: recipe.appName,
                                                      source: "复发后重新清零",
                                                      channel: self.channel)
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
                    self.banner = "重新清零失败：\(error.localizedDescription)"
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
                    self.banner = "改冻结状态失败：\(error.localizedDescription)"
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
                            _ = try self.backupManager.backup(path: full,
                                                              relativePath: recipe.relativePath,
                                                              bundleID: recipe.bundleID,
                                                              appName: recipe.appName,
                                                              source: "占位前备份",
                                                              channel: self.channel)
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
                    self.banner = "占位操作失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func removeRecipe(_ recipe: Recipe) {
        recipes.removeAll { $0.id == recipe.id }
        store.file.recipes = recipes
        store.save()
        log("已从守护列表移除：\(recipe.relativePath)", .notice)
    }

    // MARK: - Guard

    var guardRunning: Bool { guardService.isRunning }

    func setGuard(_ enabled: Bool) {
        if enabled {
            guard requireChannel() else { return }
            if let error = guardService.start() {
                banner = error
                log("守护没有开启：\(error)", .warning)
            } else {
                guardInterruption = nil
                log("守护已开启：每 3 秒检查配方大小，每 30 秒比对一次目录", .success)
                banner = "守护已开启。它靠一个小画中画窗口让系统保持本应用运行，被系统终止后这里会显示中断记录。"
            }
        } else {
            guardService.stop()
            log("守护已停止", .notice)
        }
    }

    private func guardTick(deep: Bool) {
        guard guardService.isRunning else { return }
        let list = recipes
        guard !list.isEmpty else { return }

        var truncated = 0
        for recipe in list where !recipe.placeholder {
            guard let root = channel.containerPath(for: recipe.bundleID) else { continue }
            let full = RecipeEngine.fullPath(recipe, container: root)
            guard let item = channel.item(at: full), !item.isDirectory, item.size > 0 else { continue }
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
        }
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
        banner = channel.unavailableReason
        log(channel.unavailableReason, .warning)
        return false
    }
}
