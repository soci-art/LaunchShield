import Foundation

struct LibraryFile: Codable {
    var recipes: [Recipe] = []
    var backups: [BackupRecord] = []
    var directoryGuards: [DirectoryGuard] = []
}

/// Recipes and the backup index live in Application Support; the original
/// bytes live in a Documents folder so they survive an app update and can be
/// copied out by the user.
final class LibraryStore {
    var file = LibraryFile()

    let root: URL
    let backupRoot: URL

    private var jsonURL: URL { root.appendingPathComponent("library.json") }
    private(set) var loadFailure: String?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? docs
        root = support.appendingPathComponent("LaunchShield", isDirectory: true)
        backupRoot = docs.appendingPathComponent("LaunchShieldBackups", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        load()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: jsonURL.path) else { return }
        do {
            let data = try Data(contentsOf: jsonURL)
            file = try JSONDecoder().decode(LibraryFile.self, from: data)
            loadFailure = nil
        } catch {
            loadFailure = error.localizedDescription
        }
    }

    /// Persist the complete library atomically and verify the bytes on disk.
    /// The throwing form is used before destructive file operations so a
    /// failed index write prevents the target from being truncated.
    func saveOrThrow() throws {
        if let loadFailure {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "本机守护库无法读取，为避免覆盖损坏数据，已阻止写入：\(loadFailure)"
            ])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(file)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: jsonURL, options: .atomic)
        let written = try Data(contentsOf: jsonURL)
        guard written == data else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "备份索引写入后校验不一致"
            ])
        }
        loadFailure = nil
    }

    /// Register a backup record durably before its source file is modified.
    /// On failure the in-memory index is left unchanged and the caller must
    /// skip truncation/freezing for that file.
    func registerBackup(_ record: BackupRecord) throws {
        if file.backups.contains(where: { $0.id == record.id }) { return }
        let previous = file.backups
        file.backups.append(record)
        do {
            try saveOrThrow()
        } catch {
            file.backups = previous
            // If the failed write can be rolled back durably, remove the
            // unregistered backup bytes as well. If rollback also fails,
            // preserve the backup directory rather than risk deleting bytes
            // referenced by an index that may have reached disk.
            do {
                try saveOrThrow()
                try? FileManager.default.removeItem(at: backupDirectoryURL(for: record.id))
            } catch {
                // Keep the backup bytes for manual recovery.
            }
            throw error
        }
    }

    /// Best-effort save for non-destructive metadata updates. Critical
    /// backup registration uses registerBackup(_:) and propagates errors.
    @discardableResult
    func save() -> Bool {
        do {
            try saveOrThrow()
            return true
        } catch {
            return false
        }
    }

    func backupFileURL(for record: BackupRecord) -> URL {
        backupRoot
            .appendingPathComponent(record.id.uuidString, isDirectory: true)
            .appendingPathComponent(record.localFileName)
    }

    func backupDirectoryURL(for id: UUID) -> URL {
        backupRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }
}
