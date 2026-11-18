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
        guard Self.isSafeRelativePath(relativePath) else {
            throw ChannelFailure("文件相对路径不安全，已取消备份")
        }
        guard let item = channel.item(at: path), !item.isDirectory, !item.isSymlink else {
            throw ChannelFailure("目标不是普通文件（或是符号链接），已取消备份")
        }
        let id = UUID()
        let fileName = (relativePath as NSString).lastPathComponent
        guard Self.isSafeFileName(fileName) else {
            throw ChannelFailure("备份文件名不安全，已取消备份")
        }
        let directory = store.backupDirectoryURL(for: id)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.validateBackupDirectory(directory, root: store.backupRoot)
        } catch {
            throw ChannelFailure("建备份文件夹失败：\(error.localizedDescription)")
        }
        let local = directory.appendingPathComponent(fileName)
        do {
            try channel.copyToLocal(path: path, destination: local.path)
            try Self.validateLocalBackup(local, expectedSize: item.size)
            let copiedMD5 = try BackupManager.md5(of: local)
            let sourceMD5 = try channel.md5(path)
            guard copiedMD5 == sourceMD5 else {
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
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if let failure = error as? ChannelFailure { throw failure }
            throw ChannelFailure("备份失败：\(error.localizedDescription)")
        }
    }

    /// Validates the saved bytes before touching the target, then verifies
    /// the restored target. A previously immutable target is re-frozen if
    /// the restore operation fails.
    @discardableResult
    func restore(_ record: BackupRecord, container: String, channel: Channel) throws -> String {
        guard Self.isSafeRelativePath(record.relativePath),
              Self.isSafeFileName(record.localFileName),
              record.localFileName == (record.relativePath as NSString).lastPathComponent,
              record.md5.count == 32,
              record.md5.allSatisfy({ $0.isHexDigit }) else {
            throw ChannelFailure("备份记录不完整或路径不安全，拒绝恢复")
        }
        guard container.hasPrefix("/"),
              !container.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw ChannelFailure("目标容器路径不安全，拒绝恢复")
        }

        let directory = store.backupDirectoryURL(for: record.id)
        let local = store.backupFileURL(for: record)
        do {
            try Self.validateBackupDirectory(directory, root: store.backupRoot)
            try Self.validateLocalBackup(local, expectedSize: record.originalSize)
        } catch {
            throw ChannelFailure("备份文件校验失败，未改动目标：\(error.localizedDescription)")
        }
        let backupMD5 = try BackupManager.md5(of: local)
        guard backupMD5.caseInsensitiveCompare(record.md5) == .orderedSame else {
            throw ChannelFailure("备份文件 MD5 与记录不一致，拒绝恢复（未改动目标）")
        }

        let target = container + "/" + record.relativePath
        let existing = channel.item(at: target)
        if let existing, existing.isSymlink {
            throw ChannelFailure("目标是符号链接，拒绝覆盖")
        }
        if let existing, existing.isDirectory {
            throw ChannelFailure("目标是文件夹，拒绝按文件恢复")
        }

        // Preserve the current target before overwriting it. If the write or
        // post-write verification fails, put these exact bytes back.
        let rollbackDirectory = store.backupRoot.appendingPathComponent(
            ".restore-" + UUID().uuidString, isDirectory: true)
        var rollbackFile: URL?
        var previousMD5: String?
        if let existing {
            do {
                try FileManager.default.createDirectory(at: rollbackDirectory,
                                                        withIntermediateDirectories: true)
                try Self.validateBackupDirectory(rollbackDirectory, root: store.backupRoot)
                let snapshot = rollbackDirectory.appendingPathComponent("before-restore")
                try channel.copyToLocal(path: target, destination: snapshot.path)
                try Self.validateLocalBackup(snapshot, expectedSize: existing.size)
                let sourceDigest = try channel.md5(target)
                let copiedDigest = try Self.md5(of: snapshot)
                guard sourceDigest.caseInsensitiveCompare(copiedDigest) == .orderedSame else {
                    throw ChannelFailure("恢复前快照校验失败，目标未改动")
                }
                rollbackFile = snapshot
                previousMD5 = sourceDigest
            } catch {
                try? FileManager.default.removeItem(at: rollbackDirectory)
                if let failure = error as? ChannelFailure { throw failure }
                throw ChannelFailure("无法保护当前文件，取消恢复：\(error.localizedDescription)")
            }
        }

        let wasImmutable = existing != nil && channel.isImmutable(target)
        do {
            if wasImmutable {
                try channel.setImmutable(target, false)
            }
            try channel.restore(path: target, from: local.path)
            let restored = try channel.md5(target)
            guard restored.caseInsensitiveCompare(record.md5) == .orderedSame else {
                throw ChannelFailure("写回后校验不一致：现在是 \(restored.prefix(8))…，应为 \(record.md5.prefix(8))…")
            }
            try? FileManager.default.removeItem(at: rollbackDirectory)
            return restored
        } catch {
            var rollbackResult = "未能确认原文件恢复状态"
            if let rollbackFile, let previousMD5 {
                do {
                    try channel.restore(path: target, from: rollbackFile.path)
                    let digest = try channel.md5(target)
                    guard digest.caseInsensitiveCompare(previousMD5) == .orderedSame else {
                        throw ChannelFailure("回滚后的 MD5 不一致")
                    }
                    rollbackResult = "已恢复原文件"
                } catch {
                    rollbackResult = "自动回滚失败：\(error.localizedDescription)"
                }
            } else if existing == nil {
                do {
                    if channel.item(at: target) != nil {
                        try channel.delete(target)
                    }
                    rollbackResult = "已清理本次创建的残留文件"
                } catch {
                    rollbackResult = "清理残留文件失败：\(error.localizedDescription)"
                }
            }
            if wasImmutable {
                try? channel.setImmutable(target, true)
            }
            try? FileManager.default.removeItem(at: rollbackDirectory)
            throw ChannelFailure("恢复失败：\(error.localizedDescription)；\(rollbackResult)")
        }
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

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value == 0 }) else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private static func validateBackupDirectory(_ directory: URL, root: URL) throws {
        let rootURL = root.standardizedFileURL
        let directoryURL = directory.standardizedFileURL
        let rootValues = try rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let directoryValues = try directoryURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
              directoryURL.path.hasPrefix(rootPrefix),
              directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
            throw ChannelFailure("备份目录结构不安全")
        }
    }

    private static func validateLocalBackup(_ url: URL, expectedSize: UInt64) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ChannelFailure("备份不是普通文件或是符号链接")
        }
        guard let fileSize = values.fileSize, fileSize >= 0,
              UInt64(fileSize) == expectedSize else {
            throw ChannelFailure("备份文件大小与记录不一致")
        }
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
