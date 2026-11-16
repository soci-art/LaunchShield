import Foundation

struct LibraryFile: Codable {
    var recipes: [Recipe] = []
    var backups: [BackupRecord] = []
}

/// Recipes and the backup index live in Application Support; the original
/// bytes live in a Documents folder so they survive an app update and can be
/// copied out by the user.
final class LibraryStore {
    var file = LibraryFile()

    let root: URL
    let backupRoot: URL

    private var jsonURL: URL { root.appendingPathComponent("library.json") }

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
        guard let data = try? Data(contentsOf: jsonURL),
              let decoded = try? JSONDecoder().decode(LibraryFile.self, from: data) else { return }
        file = decoded
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: jsonURL, options: .atomic)
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
