import Foundation

struct LibraryFile: Codable {
    var recipes: [Recipe] = []
    var backups: [BackupRecord] = []
    var directoryGuards: [DirectoryGuard] = []
}

extension LibraryFile {
    private enum CodingKeys: String, CodingKey {
        case recipes, backups, directoryGuards
    }

    /// Decode every field as if-present. The synthesized decoder ignores
    /// the property defaults above and throws keyNotFound for any key a
    /// library.json written by an older build does not have yet (e.g.
    /// `directoryGuards`, added in build 23) — and that error's message
    /// ("couldn't be read because it is missing") latched the store's
    /// fail-closed lock for the whole session (checklist item 53).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recipes = try container.decodeIfPresent([Recipe].self, forKey: .recipes) ?? []
        backups = try container.decodeIfPresent([BackupRecord].self, forKey: .backups) ?? []
        directoryGuards = try container.decodeIfPresent([DirectoryGuard].self, forKey: .directoryGuards) ?? []
    }
}

/// Recipes and the backup index live in Application Support; the original
/// bytes live in a Documents folder so they survive an app update and can be
/// copied out by the user.
final class LibraryStore {
    var file = LibraryFile()

    let root: URL
    let backupRoot: URL

    private var jsonURL: URL { root.appendingPathComponent("library.json") }
    /// 备份登记用的追加日志：一条记录一行，写完即 fsync。
    /// 以前每登记一条备份就整份 library.json 重写＋读回校验，批量清零
    /// 两万个文件时写入量是 O(n²)，几十 GB 都花在重写索引上；这里
    /// 改成追加一行，收尾或下一次 save 时再合并回 library.json。
    private var journalURL: URL { root.appendingPathComponent("backups.journal") }
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
        if FileManager.default.fileExists(atPath: jsonURL.path) {
            do {
                let data = try Data(contentsOf: jsonURL)
                file = try JSONDecoder().decode(LibraryFile.self, from: data)
                loadFailure = nil
            } catch {
                loadFailure = error.localizedDescription
            }
        }
        replayJournal()
    }

    /// 把日志里还没合并进 library.json 的备份记录补回来。崩溃、被杀进程
    /// 之后，这些记录只存在于日志里；半行或坏行直接跳过，不让一行坏数据
    /// 挡住整库。
    private func replayJournal() {
        guard let data = try? Data(contentsOf: journalURL), !data.isEmpty else { return }
        let decoder = JSONDecoder()
        var known = Set(file.backups.map { $0.id })
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let record = try? decoder.decode(BackupRecord.self, from: Data(line)) else { continue }
            if known.insert(record.id).inserted { file.backups.append(record) }
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
        // 合并已完成，日志里的记录都进了 library.json；删失败也不怕，
        // 下次加载时按 id 去重会跳过重复。
        try? FileManager.default.removeItem(at: journalURL)
    }

    /// Register a backup record durably before its source file is modified.
    /// Appends one journal line and fsyncs it; the full-library rewrite is
    /// deferred to save(). On failure the in-memory index is left unchanged.
    func registerBackup(_ record: BackupRecord) throws {
        if file.backups.contains(where: { $0.id == record.id }) { return }
        do {
            try appendToJournal(record)
        } catch {
            // 记录没落盘，这份备份不作数：删掉刚拷出来的字节，原文件没动。
            try? FileManager.default.removeItem(at: backupDirectoryURL(for: record.id))
            throw error
        }
        file.backups.append(record)
    }

    /// 追加一行并 fsync。这是「先登记、再动原文件」的持久化点，代价恒定，
    /// 不随备份条数增长。
    private func appendToJournal(_ record: BackupRecord) throws {
        let data = try JSONEncoder().encode(record)
        guard !data.contains(UInt8(ascii: "\n")) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "备份记录含换行，无法写入日志"
            ])
        }
        if !FileManager.default.fileExists(atPath: journalURL.path) {
            FileManager.default.createFile(atPath: journalURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: journalURL)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            // 上次进程要是正好死在写一半的地方，文件末尾会留半行、
            // 没有换行；直接续写会把新记录跟半行粘成一行，回放时
            // 两条都解不出来。先给半行补上换行收尾，新记录另起
            // 一行（半行回放时会被当坏行跳过，不影响别人）。
            try handle.seek(toFileOffset: end - 1)
            let last = try handle.read(upToCount: 1) ?? Data()
            _ = try handle.seekToEnd()
            if last.first != UInt8(0x0A) {
                try handle.write(contentsOf: Data([UInt8(0x0A)]))
            }
        }
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([UInt8(0x0A)]))
        try handle.synchronize()
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
