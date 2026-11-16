import Foundation
import CryptoKit

struct BackupManager {
    let store: LibraryStore

    /// Backs the target's current bytes up with a streaming copy, then checks
    /// the copy's MD5 against the source before returning the record.
    func backup(path: String,
                relativePath: String,
                bundleID: String,
                appName: String,
                source: String,
                channel: Channel) throws -> BackupRecord {
        guard let item = channel.item(at: path), !item.isDirectory else {
            throw ChannelFailure("这个路径不是文件，没法备份")
        }
        let id = UUID()
        let fileName = (relativePath as NSString).lastPathComponent
        let directory = store.backupDirectoryURL(for: id)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ChannelFailure("建备份文件夹失败：\(error.localizedDescription)")
        }
        let local = directory.appendingPathComponent(fileName)
        try channel.copyToLocal(path: path, destination: local.path)
        let copiedMD5: String
        do {
            copiedMD5 = try BackupManager.md5(of: local)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw ChannelFailure("读备份文件失败：\(error.localizedDescription)")
        }
        let sourceMD5 = try channel.md5(path)
        guard copiedMD5 == sourceMD5 else {
            try? FileManager.default.removeItem(at: directory)
            throw ChannelFailure("备份校验不一致，已放弃这次备份（没有改动目标文件）")
        }
        return BackupRecord(id: id,
                            bundleID: bundleID,
                            appName: appName,
                            relativePath: relativePath,
                            localFileName: fileName,
                            originalSize: item.size,
                            md5: sourceMD5,
                            createdAt: Date(),
                            source: source)
    }

    /// Writes the saved bytes back, then verifies the target's MD5.
    @discardableResult
    func restore(_ record: BackupRecord, container: String, channel: Channel) throws -> String {
        let local = store.backupFileURL(for: record)
        guard FileManager.default.fileExists(atPath: local.path) else {
            throw ChannelFailure("备份文件不在了，无法恢复")
        }
        let target = container + "/" + record.relativePath
        if channel.exists(target), channel.isImmutable(target) {
            try channel.setImmutable(target, false)
        }
        try channel.restore(path: target, from: local.path)
        let restored = try channel.md5(target)
        guard restored == record.md5 else {
            throw ChannelFailure("写回后校验不一致：现在是 \(restored.prefix(8))…，应为 \(record.md5.prefix(8))…")
        }
        return restored
    }

    /// The first backup of a path is the original material (later ones may
    /// hold a re-downloaded ad), so restores use the oldest record.
    func originalBackup(bundleID: String, relativePath: String) -> BackupRecord? {
        store.file.backups
            .filter { $0.bundleID == bundleID && $0.relativePath == relativePath }
            .sorted { $0.createdAt < $1.createdAt }
            .first
    }

    func originalBackups() -> [BackupRecord] {
        var seen = Set<String>()
        var result: [BackupRecord] = []
        for record in store.file.backups.sorted(by: { $0.createdAt < $1.createdAt }) {
            let key = record.bundleID + "\n" + record.relativePath
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(record)
        }
        return result
    }

    static func md5(of url: URL) throws -> String {
        var hasher = Insecure.MD5()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
