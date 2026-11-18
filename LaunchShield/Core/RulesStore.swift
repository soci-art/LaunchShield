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

    // MARK: - 内置保底规则（与服务器 v1 种子一致）

    static let builtinGroups: [(group: String, directories: [String])] = [
        ("优量汇", ["Library/Caches/default/tencent_gdtimg", "Library/Caches/default/tencent_gdtres",
                    "tmp/gdtMedia",
                    "Library/tencent_gdtmob", "Library/Caches/GDT", "Library/Caches/GDTMEC"]),
        ("穿山甲", ["Library/Caches/com.hackemist.CSJSDImageCache/default",
                    "Library/Caches/cn_buadsdk_file_cache/bu_splash_cache",
                    "Library/Caches/CSJLottieResources", "Library/Caches/buadsdk",
                    "Library/com.bytedance.buadsdk.root", "Library/po_csj_dt", "Library/csj_alog",
                    "Library/Caches/com.csj.plist.v4"]),
        ("BeiZi", ["Library/Caches/BeiZiMaterial", "Library/Caches/BeiZiDirectory",
                    "Library/Caches/beizi_cookie_sql"]),
        ("美数", ["Library/Caches/MSAdSDK"]),
        ("UBIX", ["Library/ubixad"]),
        ("趣盟", ["Library/Caches/com.qumeng.yykit"]),
        ("AdMob", ["Library/Caches/AdMob", "Library/Application Support/GoogleMobileAds"]),
        ("其他广告", ["Library/Advertises"])
    ]

    static let builtinKeywords = ["csj", "gdt", "beizi", "msadsdk", "ubix", "qumeng",
                                  "admob", "advertise", "splash", "buadsdk", "pangolin"]

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
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\\\"),
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
