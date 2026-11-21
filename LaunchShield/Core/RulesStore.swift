import Foundation

/// 广告识别规则：各家广告 SDK 的专属目录名单＋「疑似广告」关键词。
/// 内置一份保底规则；用户在首页点「更新规则」后，从服务器下载新规则存到
/// 本地，扫描、冻结、守护补扫、找广告都改用新规则，不用更新 App。
/// 规则只是一份名单数据，不含任何程序逻辑；下发通道是收集箱同一个域名。
enum RulesStore {

    struct Group: Codable {
        let name: String
        let directories: [String]
    }

    struct RulesFile: Codable {
        let version: Int
        let groups: [Group]
        let keywords: [String]
    }

    struct LocalCandidateRule: Codable, Identifiable, Equatable {
        let bundleID: String
        let appName: String
        let relativePath: String
        let createdAt: Date
        var id: String { bundleID.lowercased() + "|" + relativePath }
    }

    // MARK: - 内置保底规则（与服务器 v1 种子一致）

    // Built-in local rule data is embedded in LocalADBlockRule and scanned locally.
    // No Baidu-only default rule list is maintained here.
    static let builtinGroups: [(group: String, directories: [String])] = []

    static let builtinKeywords = [
        "csj", "pangle", "buadsdk", "gdt", "beizi", "baidumobad", "bd_ad_cache",
        "splash", "launch", "adcache", "adsdk", "tanx", "jadyun", "sigmob",
        "mintegral", "tradplus", "applovin", "chartboost", "googlemobileads",
        "unityads", "vungle", "ironsource", "qumeng", "ubixad", "ksadsdk"
    ]

    // MARK: - 当前生效规则

    private static let lock = NSLock()
    private static var downloaded: RulesFile?
    private static var didLoad = false

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ad-rules.json")
    }

    /// 验证服务器和磁盘上的规则；规则只能包含容器内相对目录，不能携带路径跳转。
    private static func isValid(_ rules: RulesFile) -> Bool {
        guard rules.version > 0,
              !rules.groups.isEmpty,
              rules.groups.count <= 100,
              rules.keywords.count <= 500 else { return false }

        var totalDirectories = 0
        for group in rules.groups {
            let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 80,
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !group.directories.isEmpty,
                  group.directories.count <= 500 else { return false }
            totalDirectories += group.directories.count
            if totalDirectories > 5000 { return false }

            var seen = Set<String>()
            for directory in group.directories {
                guard isSafeRelativeDirectory(directory), seen.insert(directory).inserted else {
                    return false
                }
            }
        }

        for keyword in rules.keywords {
            guard !keyword.isEmpty, keyword.count <= 80,
                  !keyword.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                return false
            }
        }
        return true
    }

    private static func isSafeRelativeDirectory(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 512, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value == 0 }) else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func loadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL),
              data.count <= 1_048_576,
              let parsed = try? JSONDecoder().decode(RulesFile.self, from: data),
              isValid(parsed) else { return }
        downloaded = parsed
    }

    /// 清除缓存时把下好的规则从内存里也撤掉，之后回到内置规则。
    static func resetDownloaded() {
        lock.lock()
        defer { lock.unlock() }
        downloaded = nil
        didLoad = false
    }

    /// 当前生效的分组名单：下过新规则用新规则，没下过用内置的。
    static var groups: [(group: String, directories: [String])] {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        guard let downloaded else { return builtinGroups }
        return downloaded.groups.map { (group: $0.name, directories: $0.directories) }
    }

    static var keywords: [String] {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        guard let downloaded, !downloaded.keywords.isEmpty else { return builtinKeywords }
        return downloaded.keywords
    }

    /// 0 表示还在用内置规则；下载过的规则带服务器版本号。
    static var currentVersion: Int {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return downloaded?.version ?? 0
    }

    // MARK: - 用户确认的 LaunchHack 本地规则

    private static var localRulesURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("launchhack-local-rules.json")
    }
    private static var localRulesCache: [LocalCandidateRule]?
    private static var localRulesDidLoad = false
    private static var localRulesLoadFailure: String?

    private static func loadLocalRulesIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !localRulesDidLoad else { return }
        localRulesDidLoad = true
        guard FileManager.default.fileExists(atPath: localRulesURL.path) else {
            localRulesCache = []
            return
        }
        do {
            let data = try Data(contentsOf: localRulesURL)
            guard data.count <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
            let parsed = try JSONDecoder().decode([LocalCandidateRule].self, from: data)
            localRulesCache = parsed.filter {
                !$0.bundleID.isEmpty && isSafeRelativeDirectory($0.relativePath)
                    && (FileKind.of($0.relativePath) == .image || FileKind.of($0.relativePath) == .video)
            }
            localRulesLoadFailure = nil
        } catch {
            localRulesCache = []
            localRulesLoadFailure = error.localizedDescription
        }
    }

    static var localCandidateRules: [LocalCandidateRule] {
        loadLocalRulesIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return localRulesCache ?? []
    }

    static func localCandidates(for bundleID: String) -> [LocalCandidateRule] {
        localCandidateRules.filter { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    static func containsLocalCandidate(bundleID: String, relativePath: String) -> Bool {
        localCandidates(for: bundleID).contains { $0.relativePath == relativePath }
    }

    @discardableResult
    static func addLocalCandidate(bundleID: String, appName: String, relativePath: String) -> Bool {
        let owner = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard owner.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil,
              isSafeRelativeDirectory(relativePath),
              FileKind.of(relativePath) == .image || FileKind.of(relativePath) == .video else { return false }
        loadLocalRulesIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        guard localRulesLoadFailure == nil else { return false }
        var records = localRulesCache ?? []
        let record = LocalCandidateRule(bundleID: owner, appName: appName,
                                        relativePath: relativePath, createdAt: Date())
        guard !records.contains(where: { $0.id == record.id }) else { return true }
        records.append(record)
        guard let data = try? JSONEncoder().encode(records) else { return false }
        do {
            try data.write(to: localRulesURL, options: [.atomic])
            localRulesCache = records
            return true
        } catch {
            return false
        }
    }

    // MARK: - 更新

    static func update(completion: @escaping (Bool, String) -> Void) {
        var request = URLRequest(url: CollectUploader.base.appendingPathComponent("rules"))
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { data, response, error in
            func done(_ ok: Bool, _ message: String) {
                DispatchQueue.main.async { completion(ok, message) }
            }
            if let error {
                done(false, "更新规则失败：\(error.localizedDescription)")
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data else {
                done(false, code == 404 ? "服务器上还没有放规则" : "更新规则失败：服务器返回 \(code)")
                return
            }
            guard data.count <= 1_048_576,
                  let parsed = try? JSONDecoder().decode(RulesFile.self, from: data),
                  isValid(parsed) else {
                done(false, "更新规则失败：规则格式不正确或包含不安全路径")
                return
            }
            let current = currentVersion
            guard parsed.version > current else {
                done(true, "规则已是最新（\(current == 0 ? "内置规则" : "第 \(current) 版")）")
                return
            }
            do {
                try data.write(to: fileURL, options: [.atomic])
            } catch {
                done(false, "更新规则失败：存不下来（\(error.localizedDescription)）")
                return
            }
            lock.lock()
            downloaded = parsed
            didLoad = true
            lock.unlock()
            let groupCount = parsed.groups.count
            let dirCount = parsed.groups.reduce(0) { $0 + $1.directories.count }
            done(true, "规则已更新到第 \(parsed.version) 版：\(groupCount) 家广告商、\(dirCount) 个目录，扫描会按新规则走")
        }.resume()
    }

    /// 只查服务器上的规则版本号，不下载、不改本地规则。
    /// 查不到（没网、服务器没放规则、格式不对）一律回 nil，调用方安静收场。
    static func checkLatestVersion(completion: @escaping (Int?) -> Void) {
        var request = URLRequest(url: CollectUploader.base.appendingPathComponent("rules"))
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { data, response, _ in
            func done(_ version: Int?) {
                DispatchQueue.main.async { completion(version) }
            }
            guard let data, data.count <= 1_048_576,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let parsed = try? JSONDecoder().decode(RulesFile.self, from: data),
                  isValid(parsed) else {
                done(nil)
                return
            }
            done(parsed.version)
        }.resume()
    }
}
