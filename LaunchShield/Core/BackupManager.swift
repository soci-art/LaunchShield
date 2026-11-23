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
                groupID: String? = nil,
                channel: Channel) throws -> BackupRecord {
        guard Self.isSafeRelativePath(relativePath) else {
            throw ChannelFailure("文件相对路径不安全，已取消备份")
        }
        guard let expectedRoot = channel.rootPath(bundleID: bundleID, groupID: groupID) else {
            throw ChannelFailure("找不到备份所属容器，已取消备份")
        }
        let expectedPath = expectedRoot.hasSuffix("/") ? expectedRoot + relativePath : expectedRoot + "/" + relativePath
        guard path == expectedPath else {
            throw ChannelFailure("备份文件路径与所属容器不一致，已取消备份")
        }
        guard let item = try channel.inspectItem(at: path), !item.isDirectory, !item.isSymlink else {
            throw ChannelFailure("目标不是普通文件（或是符号链接），已取消备份")
        }
        let sourceVersion = try channel.fileVersion(path)
        guard sourceVersion.size == item.size else { throw ChannelFailure("目标文件在备份前发生变化，已取消备份") }
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
            let finalVersion = try channel.fileVersion(path)
            guard finalVersion == sourceVersion else { throw ChannelFailure("备份期间目标文件身份或内容发生变化，已放弃这次备份") }
            guard copiedMD5 == sourceMD5 else {
                throw ChannelFailure("备份校验不一致，已放弃这次备份（没有改动目标文件）")
            }
            var record = BackupRecord(id: id,
                                       bundleID: bundleID,
                                       groupID: groupID,
                                       appName: appName,
                                       relativePath: relativePath,
                                       localFileName: fileName,
                                       originalSize: item.size,
                                       md5: sourceMD5,
                                       createdAt: Date(),
                                       source: source)
            record.sourceVersion = sourceVersion
            return record
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
        guard Self.isSafeAbsoluteContainerPath(container) else {
            throw ChannelFailure("目标容器路径不安全，拒绝恢复")
        }
        guard let expectedRoot = channel.rootPath(bundleID: record.bundleID, groupID: record.groupID),
              expectedRoot == container else {
            throw ChannelFailure("备份记录与目标容器不匹配，拒绝恢复")
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
        let existing = try channel.inspectItem(at: target)
        var existingVersion: ChannelFileVersion?
        if let existing, existing.isSymlink {
            throw ChannelFailure("目标是符号链接，拒绝覆盖")
        }
        if let existing, existing.isDirectory {
            throw ChannelFailure("目标是文件夹，拒绝按文件恢复")
        }
        // 第 104 条：文件不在、连它所在的文件夹都没了（多半是应用
        // 把临时文件夹整夹删了）——没有地方可写，单独报清楚，
        // 别混进笼统的恢复失败。
        if existing == nil {
            let parent = (target as NSString).deletingLastPathComponent
            if !channel.exists(parent) {
                throw ChannelFailure("原来的位置已经不存在了（文件夹已被应用删掉），备份写不回去")
            }
        }

        // Preserve the current target before overwriting it. If the write or
        // post-write verification fails, put these exact bytes back.
        let rollbackDirectory = store.backupRoot.appendingPathComponent(
            ".restore-" + UUID().uuidString, isDirectory: true)
        var rollbackFile: URL?
        var previousMD5: String?
        if let existing {
            do {
                let versionBeforeSnapshot = try channel.fileVersion(target)
                guard versionBeforeSnapshot.size == existing.size else { throw ChannelFailure("恢复前目标文件身份或大小发生变化") }
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
                let versionAfterSnapshot = try channel.fileVersion(target)
                guard versionAfterSnapshot == versionBeforeSnapshot else { throw ChannelFailure("恢复前目标文件在快照期间发生变化，已取消恢复") }
                existingVersion = versionBeforeSnapshot
                rollbackFile = snapshot
                previousMD5 = sourceDigest
            } catch {
                try? FileManager.default.removeItem(at: rollbackDirectory)
                if let failure = error as? ChannelFailure { throw failure }
                throw ChannelFailure("无法保护当前文件，取消恢复：\(error.localizedDescription)")
            }
        }

        let wasImmutable = existing?.isImmutable ?? false
        var appliedVersion: ChannelFileVersion?
        do {
            if wasImmutable {
                try channel.setImmutable(target, false)
            }
            try channel.restore(path: target, from: local.path, matching: existingVersion, expectedMD5: previousMD5)
            appliedVersion = try channel.fileVersion(target)
            let restored = try channel.md5(target)
            guard restored.caseInsensitiveCompare(record.md5) == .orderedSame else {
                throw ChannelFailure("写回后校验不一致：现在是 \(restored.prefix(8))…，应为 \(record.md5.prefix(8))…")
            }
            if wasImmutable {
                try channel.setImmutable(target, true)
                guard channel.isImmutable(target) else {
                    throw ChannelFailure("文件内容已还原，但原冻结状态未能恢复")
                }
            }
            try? FileManager.default.removeItem(at: rollbackDirectory)
            return restored
        } catch {
            var rollbackResult = "未能确认原文件恢复状态"
            var rollbackCanWrite = true
            var rollbackContentRestored = false
            var rollbackLockRestored = !wasImmutable
            var rollbackIdentityMatches = true
            let expectedRollbackVersion = appliedVersion ?? existingVersion

            if let expectedRollbackVersion {
                do {
                    let currentVersion = try channel.fileVersion(target)
                    guard currentVersion.isSameObject(as: expectedRollbackVersion) else {
                        throw ChannelFailure("目标文件身份已变化")
                    }
                } catch {
                    rollbackIdentityMatches = false
                    rollbackCanWrite = false
                    rollbackLockRestored = false
                    rollbackResult = "目标文件身份已变化，自动回滚停止：\(error.localizedDescription)"
                }
            }

            if wasImmutable && rollbackCanWrite {
                do {
                    try channel.setImmutable(target, false)
                } catch {
                    rollbackCanWrite = false
                    rollbackResult = "无法解冻目标，自动回滚未执行：\(error.localizedDescription)"
                }
            }

            if rollbackCanWrite, let rollbackFile, let previousMD5 {
                do {
                    let currentVersion = try channel.fileVersion(target)
                    let digest = try channel.md5(target)
                    if digest.caseInsensitiveCompare(previousMD5) == .orderedSame {
                        rollbackResult = "原文件内容仍在，跳过覆盖回滚"
                        rollbackContentRestored = true
                    } else {
                        guard let appliedVersion,
                              currentVersion.isSameObject(as: appliedVersion),
                              digest.caseInsensitiveCompare(record.md5) == .orderedSame else {
                            throw ChannelFailure("目标文件已被外部修改，拒绝自动覆盖回滚")
                        }
                        try channel.restore(path: target, from: rollbackFile.path,
                                            matching: appliedVersion, expectedMD5: record.md5)
                        let rollbackDigest = try channel.md5(target)
                        guard rollbackDigest.caseInsensitiveCompare(previousMD5) == .orderedSame else {
                            throw ChannelFailure("回滚后的 MD5 不一致")
                        }
                        rollbackResult = "已恢复原文件"
                        rollbackContentRestored = true
                    }
                } catch {
                    rollbackResult = "自动回滚失败：\(error.localizedDescription)"
                }
            } else if rollbackCanWrite, existing == nil {
                do {
                    if let appliedVersion {
                        let currentVersion = try channel.fileVersion(target)
                        let digest = try channel.md5(target)
                        guard currentVersion.isSameObject(as: appliedVersion),
                              digest.caseInsensitiveCompare(record.md5) == .orderedSame else {
                            throw ChannelFailure("目标路径已被外部修改，未自动删除")
                        }
                        rollbackResult = "目标原先不存在；本次恢复文件保留，未自动删除"
                    } else {
                        guard try channel.inspectItem(at: target) == nil else {
                            throw ChannelFailure("目标原先不存在，但当前路径出现文件，未自动删除")
                        }
                        rollbackResult = "目标原先不存在，当前仍不存在"
                        rollbackContentRestored = true
                    }
                } catch {
                    rollbackResult = "目标原先不存在；未执行自动删除：\(error.localizedDescription)"
                }
            }

            if wasImmutable {
                if rollbackIdentityMatches {
                    do {
                        try channel.setImmutable(target, true)
                        guard channel.isImmutable(target) else { throw ChannelFailure("冻结状态校验失败") }
                        rollbackResult += "；原冻结状态已恢复"
                        rollbackLockRestored = true
                    } catch {
                        rollbackResult += "；警告：原冻结状态恢复失败：\(error.localizedDescription)"
                    }
                } else {
                    rollbackResult += "；目标身份已变化，未对当前路径修改冻结状态"
                }
            }

            if rollbackContentRestored && rollbackLockRestored {
                try? FileManager.default.removeItem(at: rollbackDirectory)
            } else if rollbackFile != nil {
                rollbackResult += "；回滚快照已保留供手动恢复：\(rollbackDirectory.path)"
            } else {
                rollbackResult += "；未删除当前路径文件，避免误删"
            }
            throw ChannelFailure("恢复失败：\(error.localizedDescription)；\(rollbackResult)")
        }
    }

    /// The first backup of a path is the original material (later ones may
    /// hold a re-downloaded ad), so restores use the oldest record.
    func originalBackup(bundleID: String, relativePath: String, groupID: String? = nil) -> BackupRecord? {
        store.file.backups
            .filter { $0.bundleID == bundleID && $0.relativePath == relativePath && $0.groupID == groupID }
            .sorted { $0.createdAt < $1.createdAt }
            .first
    }

    func originalBackups() -> [BackupRecord] {
        var seen = Set<String>()
        var result: [BackupRecord] = []
        for record in store.file.backups.sorted(by: { $0.createdAt < $1.createdAt }) {
            let key = record.bundleID + "\n" + (record.groupID ?? "") + "\n" + record.relativePath
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(record)
        }
        return result
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 512, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value == 0 }) else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isSafeAbsoluteContainerPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count <= 4096, !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value == 0 }) else { return false }
        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
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

        // Reject symlinked ancestors as well as a symlink at the leaf. A
        // lexical path-prefix check alone does not prevent traversal through
        // a replaced intermediate directory.
        var ancestor = directoryURL.deletingLastPathComponent()
        while ancestor.path != rootURL.path && ancestor.path != "/" {
            let values = try ancestor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  ancestor.path.hasPrefix(rootPrefix) else {
                throw ChannelFailure("备份目录的上级路径不安全")
            }
            ancestor.deleteLastPathComponent()
        }
        guard ancestor.path == rootURL.path else {
            throw ChannelFailure("备份目录不在受信任的备份根目录内")
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
