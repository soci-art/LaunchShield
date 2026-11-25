import Foundation

/// 广告识别规则：各家广告 SDK 的专属目录名单＋「疑似广告」关键词。
/// 内置一份保底规则；用户在首页点「更新规则」后，从服务器下载新规则存到
/// 本地，扫描、冻结、守护补扫、找广告都改用新规则，不用更新 App。
/// 规则只是一份名单数据，不含任何程序逻辑；下发通道是收集箱同一个域名。
enum RulesStore {

    struct Group: Codable {
        let name: String
        let directories: [String]
        /// 路径模板（第 95 条）：段可以是 *，代表任意一层目录名。
        /// 治名字带随机哈希的目录——写死路径永远追不上。可缺省，老规则文件没有这项。
        let templates: [String]?
        /// 结构指纹（第 97 条）：不认名字、认目录的「长相」（文件数、总大小、
        /// 图片视频占比、扩展名占比）。可缺省，老规则文件没有这项。
        let fingerprints: [Fingerprint]?
    }

    /// 一条结构指纹（第 97 条）：under 用模板语法圈定候选目录的位置范围，
    /// 其余是数值条件，全部可选、缺省不设限；至少要有一项数值条件才有效
    /// （校验里把关）。区间和占比由收集箱台账的真实分布反推，不拍脑袋写。
    struct Fingerprint: Codable {
        let under: String
        let minFiles: Int?
        let maxFiles: Int?
        let minTotalSize: Int64?
        let maxTotalSize: Int64?
        let mediaShare: Double?
        let extensions: [String: Double]?

        var hasNumericCondition: Bool {
            minFiles != nil || maxFiles != nil || minTotalSize != nil || maxTotalSize != nil
                || mediaShare != nil || !(extensions?.isEmpty ?? true)
        }
    }

    struct RulesFile: Codable {
        let version: Int
        /// 显示版号（第 94 条）：给用户看的字符串，如 "9.1"；比大小仍用整数
        /// version。可缺省，老规则文件没有这项，缺了就显示整数。
        let displayVersion: String?
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
    static let builtinGroups: [(group: String, directories: [String], templates: [String], fingerprints: [Fingerprint])] = []

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

        if let display = rules.displayVersion {
            guard !display.isEmpty, display.count <= 20,
                  !display.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                return false
            }
        }

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

            if let templates = group.templates {
                guard templates.count <= 500 else { return false }
                totalDirectories += templates.count
                if totalDirectories > 5000 { return false }
                var seenTemplates = Set<String>()
                for template in templates {
                    guard isSafeTemplate(template), seenTemplates.insert(template).inserted else {
                        return false
                    }
                }
            }

            if let fingerprints = group.fingerprints {
                guard fingerprints.count <= 100 else { return false }
                totalDirectories += fingerprints.count
                if totalDirectories > 5000 { return false }
                for fingerprint in fingerprints {
                    guard isValidFingerprint(fingerprint) else { return false }
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

    /// 模板的安全口径（第 95 条）：星号只能整段出现、最多两段；至少两段
    /// 写死的名字打底，防的是 `Library/*` 这类一网打尽的写法。
    private static func isSafeTemplate(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 512, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value == 0 }) else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        let stars = parts.filter { $0 == "*" }.count
        guard stars >= 1, stars <= 2, parts.count - stars >= 2 else { return false }
        return parts.allSatisfy { $0 == "*" || !$0.contains("*") }
    }

    /// 指纹的安全与自洽口径（第 97 条，与模板同档）：under 必须过模板那关
    /// （至少两段写死、星号至多两段且只能整段），数值区间不能反着写，
    /// 占比都得落在 0–1，扩展名占比加起来不能超过全部。
    private static func isValidFingerprint(_ fingerprint: Fingerprint) -> Bool {
        guard isSafeTemplate(fingerprint.under), fingerprint.hasNumericCondition else { return false }
        if let minFiles = fingerprint.minFiles, !(0...100_000).contains(minFiles) { return false }
        if let maxFiles = fingerprint.maxFiles, !(0...100_000).contains(maxFiles) { return false }
        if let minFiles = fingerprint.minFiles, let maxFiles = fingerprint.maxFiles, minFiles > maxFiles { return false }
        if let minSize = fingerprint.minTotalSize, minSize < 0 { return false }
        if let maxSize = fingerprint.maxTotalSize, maxSize < 0 { return false }
        if let minSize = fingerprint.minTotalSize, let maxSize = fingerprint.maxTotalSize, minSize > maxSize { return false }
        if let share = fingerprint.mediaShare, !(0...1).contains(share) { return false }
        if let extensions = fingerprint.extensions {
            guard extensions.count <= 10 else { return false }
            var sum = 0.0
            for (ext, share) in extensions {
                guard !ext.isEmpty, ext.count <= 10, ext == ext.lowercased(),
                      !ext.contains("."), share > 0, share <= 1 else { return false }
                sum += share
            }
            guard sum <= 1.0 + 0.000_001 else { return false }
        }
        return true
    }

    /// 模板与实际目录路径逐段比对：段数相同，写死的段一字不差，* 段任意。
    static func templateMatches(_ template: String, directory: String) -> Bool {
        let t = template.split(separator: "/", omittingEmptySubsequences: false)
        let d = directory.split(separator: "/", omittingEmptySubsequences: false)
        guard t.count == d.count else { return false }
        return zip(t, d).allSatisfy { $0 == "*" || $0 == $1 }
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
    static var groups: [(group: String, directories: [String], templates: [String], fingerprints: [Fingerprint])] {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        guard let downloaded else { return builtinGroups }
        return downloaded.groups.map {
            (group: $0.name, directories: $0.directories, templates: $0.templates ?? [],
             fingerprints: $0.fingerprints ?? [])
        }
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

    /// 给用户看的版号（第 94 条）：规则文件带了显示版号就用它（如 9.1），
    /// 没带就显示整数版号。比大小、判新旧永远只看整数 currentVersion。
    static var currentDisplayVersion: String {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        guard let downloaded else { return "0" }
        if let display = downloaded.displayVersion, !display.isEmpty { return display }
        return "\(downloaded.version)"
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
                    && !DatabaseFile.matches(relativePath: $0.relativePath)
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
              !DatabaseFile.matches(relativePath: relativePath) else { return false }
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
            let parsedDisplay = parsed.displayVersion ?? "\(parsed.version)"
            guard parsed.version > current else {
                done(true, "规则已是最新（\(current == 0 ? "内置规则" : "第 \(parsedDisplay) 版")）")
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
            let templateCount = parsed.groups.reduce(0) { $0 + ($1.templates?.count ?? 0) }
            let templateText = templateCount > 0 ? "、\(templateCount) 条模板" : ""
            let fingerprintCount = parsed.groups.reduce(0) { $0 + ($1.fingerprints?.count ?? 0) }
            let fingerprintText = fingerprintCount > 0 ? "、\(fingerprintCount) 条指纹" : ""
            done(true, "规则已更新到第 \(parsedDisplay) 版：\(groupCount) 家广告商、\(dirCount) 个目录\(templateText)\(fingerprintText)，扫描会按新规则走")
        }.resume()
    }

    /// 只查服务器上的规则版本号，不下载、不改本地规则。
    /// 回调带两个数：整数版号（判新旧用）和显示版号（给人看，如 9.3；
    /// 规则没带显示版号时用整数版号凑）。查不到（没网、服务器没放
    /// 规则、格式不对）一律回 nil，调用方安静收场。
    static func checkLatestVersion(completion: @escaping (Int?, String?) -> Void) {
        var request = URLRequest(url: CollectUploader.base.appendingPathComponent("rules"))
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { data, response, _ in
            func done(_ version: Int?, _ display: String?) {
                DispatchQueue.main.async { completion(version, display) }
            }
            guard let data, data.count <= 1_048_576,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let parsed = try? JSONDecoder().decode(RulesFile.self, from: data),
                  isValid(parsed) else {
                done(nil, nil)
                return
            }
            done(parsed.version, parsed.displayVersion ?? "\(parsed.version)")
        }.resume()
    }
}
