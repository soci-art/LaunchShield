import Foundation

struct ChannelFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// One place for every container operation. The Objective-C layer underneath
/// obtains the sandbox token for each path (WQAccess), so callers never handle
/// paths that the system would refuse.
final class Channel {
    static let shared = Channel()

    private let raw = WQChannel.shared()

    var isAvailable: Bool { raw.available }
    var groupID: String? { raw.groupID }
    var signMethod: String? { raw.signMethod }
    var unavailableReason: String { raw.unavailableReason }

    /// 按用户选的签名方式判出的路线名；没路线时是中文说明（未选择/系统不支持）。
    var routeName: String { raw.routeName }
    var routeDetail: String { raw.routeDetail }
    var groupText: String { raw.groupText }

    /// 系统应用数据库（.csstore）文件本身的路径；找不到时为 nil。
    /// 只给日志页的「上传诊断文件」用：文件读得到，但 iOS 26 的版式还没啃通。
    func lsStorePath() -> String? { wq_ls_store_path() }

    /// 全盘扫描：把界面的答复（开始/先不）递给底层等着的那条线；停止同理。
    func answerFullScan(_ yes: Bool) { raw.answerFullScan(yes) }
    func stopFullScan() { raw.stopFullScan() }

    /// 重新读取签名配置并让底层重判路线。
    func resetRoute() { raw.resetRoute() }

    func containers() -> [ContainerInfo] {
        raw.appContainers().map {
            ContainerInfo(bundleID: $0.identifier, path: $0.path, name: $0.name, isSystem: $0.isSystem, category: $0.category ?? "")
        }
    }

    func groupContainers() -> [ContainerInfo] {
        raw.groupContainers().map {
            ContainerInfo(bundleID: $0.identifier, path: $0.path, name: $0.name, isSystem: $0.isSystem, category: $0.category ?? "", isGroup: true)
        }
    }

    func container(for bundleID: String) -> ContainerInfo? {
        guard let item = raw.container(forBundleID: bundleID) else { return nil }
        return ContainerInfo(bundleID: item.identifier, path: item.path, name: item.name, isSystem: item.isSystem, category: item.category ?? "")
    }

    func containerPath(for bundleID: String) -> String? {
        raw.container(forBundleID: bundleID)?.path
    }

    /// 配方和备份记录定位用：带组标识的是共享组里的文件，去组容器里找根；
    /// 没有组标识的是应用自己容器里的文件。组容器不在应用容器登记里，
    /// 只能从组容器列表里按组标识对。
    func rootPath(bundleID: String, groupID: String?) -> String? {
        if let groupID {
            return groupContainers().first { $0.bundleID == groupID }?.path
        }
        return containerPath(for: bundleID)
    }

    func children(of path: String) throws -> [FileItem] {
        let op = raw.listDirectory(path)
        guard op.ok, let items = op.value as? [WQFileItem] else {
            throw ChannelFailure(op.error ?? "打不开这个文件夹")
        }
        return items.map { FileItem($0) }
    }

    /// 深扫专用的一次性批量走访：整个子树在底层一遍走完，只回文件
    /// （不排序）。跳过的目录整棵不走，语义由调用方保证等价。
    /// onVisit 收到的是累计已走条数（文件＋目录）。
    func walkFiles(at path: String, limit: Int,
                   skipDirNames: Set<String> = [],
                   skipDirSubstrings: [String] = [],
                   skipAccountDirs: Bool = false,
                   onVisit: ((Int) -> Void)? = nil) throws -> [FileItem] {
        let op = raw.walkFiles(path, limit: limit,
                               skipDirNames: skipDirNames,
                               skipDirSubstrings: skipDirSubstrings,
                               skipAccountDirs: skipAccountDirs,
                               progress: onVisit.map { callback in { visited in callback(visited) } })
        guard op.ok, let items = op.value as? [WQFileItem] else {
            throw ChannelFailure(op.error ?? "打不开这个文件夹")
        }
        return items.map { FileItem($0) }
    }

    func item(at path: String) -> FileItem? {
        let op = raw.statPath(path)
        guard op.ok, let item = op.value as? WQFileItem else { return nil }
        return FileItem(item)
    }

    /// Safety-critical callers must distinguish a genuinely missing path from
    /// an access/stat failure. Treating both as nil could make restore attempt
    /// a create operation against an existing but unreadable target.
    func inspectItem(at path: String) throws -> FileItem? {
        let op = raw.statPath(path)
        if op.ok, let item = op.value as? WQFileItem {
            return FileItem(item)
        }
        if op.error == "目标不存在" { return nil }
        throw ChannelFailure(op.error ?? "无法检查目标文件")
    }

    func read(_ path: String, maxBytes: Int = 0) throws -> Data {
        let op = raw.readFile(path, maxBytes: UInt(maxBytes))
        guard op.ok, let data = op.value as? Data else {
            throw ChannelFailure(op.error ?? "读不了这个文件")
        }
        return data
    }

    func write(_ path: String, data: Data) throws {
        let op = raw.writeData(path, data: data)
        guard op.ok else { throw ChannelFailure(op.error ?? "写不进去") }
    }

    /// The 0-byte replacement. WQAccess backs the old bytes up first and
    /// writes through the existing inode, so owner, mode and xattrs stay.
    func truncate(_ path: String) throws {
        let op = raw.truncateFile(path)
        guard op.ok else { throw ChannelFailure(op.error ?? "去除失败") }
    }


    func restore(path: String, from localPath: String) throws {
        // Overwriting needs the existing inode; a file that was deleted (for a
        // same-name placeholder, or a recipe that lost it) has to be created.
        let op = raw.fileExists(path)
            ? raw.write(fromLocalFile: path, source: localPath)
            : raw.create(fromLocalFile: path, source: localPath)
        guard op.ok else { throw ChannelFailure(op.error ?? "写回失败") }
    }

    func copyToLocal(path: String, destination: String) throws {
        let op = raw.copy(toLocalFile: path, destination: destination)
        guard op.ok else { throw ChannelFailure(op.error ?? "备份失败") }
    }

    func delete(_ path: String) throws {
        let op = raw.deletePath(path)
        guard op.ok else { throw ChannelFailure(op.error ?? "删不掉") }
    }

    func createDirectory(_ path: String) throws {
        let op = raw.createDirectory(path)
        guard op.ok else { throw ChannelFailure(op.error ?? "建不了文件夹") }
    }

    func rename(_ path: String, to newName: String) throws {
        let op = raw.renamePath(path, newName: newName)
        guard op.ok else { throw ChannelFailure(op.error ?? "改名失败") }
    }

    func setImmutable(_ path: String, _ frozen: Bool) throws {
        let op = raw.setImmutable(frozen, forPath: path)
        guard op.ok else { throw ChannelFailure(op.error ?? "改不了冻结状态") }
    }

    func setMode(_ path: String, mode: UInt16) throws {
        let op = raw.setMode(UInt32(mode), forPath: path)
        guard op.ok else { throw ChannelFailure(op.error ?? "改不了权限") }
    }

    func isImmutable(_ path: String) -> Bool {
        raw.isImmutable(path)
    }

    func md5(_ path: String) throws -> String {
        let op = raw.md5(ofFile: path)
        guard op.ok, let digest = op.value as? String else {
            throw ChannelFailure(op.error ?? "算不了校验值")
        }
        return digest
    }

    func exists(_ path: String) -> Bool {
        raw.fileExists(path)
    }

    func isDirectory(_ path: String) -> Bool {
        raw.isDirectory(path)
    }
}

private extension FileItem {
    init(_ item: WQFileItem) {
        self.init(name: item.name,
                  path: item.path,
                  isDirectory: item.isDirectory,
                  isSymlink: item.isSymlink,
                  size: item.size,
                  modified: Date(timeIntervalSince1970: item.modified),
                  isImmutable: item.isImmutable)
    }
}
