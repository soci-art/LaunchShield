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
    var unavailableReason: String { raw.unavailableReason }

    func containers() -> [ContainerInfo] {
        raw.appContainers().map {
            ContainerInfo(bundleID: $0.identifier, path: $0.path, name: $0.name, isSystem: $0.isSystem)
        }
    }

    func container(for bundleID: String) -> ContainerInfo? {
        guard let item = raw.container(forBundleID: bundleID) else { return nil }
        return ContainerInfo(bundleID: item.identifier, path: item.path, name: item.name, isSystem: item.isSystem)
    }

    func containerPath(for bundleID: String) -> String? {
        raw.container(forBundleID: bundleID)?.path
    }

    func children(of path: String) throws -> [FileItem] {
        let op = raw.listDirectory(path)
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
        guard op.ok else { throw ChannelFailure(op.error ?? "清零失败") }
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
