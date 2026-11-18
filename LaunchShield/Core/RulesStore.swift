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

    private static func loadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL),
              let parsed = try? JSONDecoder().decode(RulesFile.self, from: data),
              !parsed.groups.isEmpty else { return }
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
            guard let parsed = try? JSONDecoder().decode(RulesFile.self, from: data),
                  !parsed.groups.isEmpty,
                  parsed.groups.allSatisfy({ !$0.name.isEmpty && !$0.directories.isEmpty }) else {
                done(false, "更新规则失败：服务器上的规则格式不对")
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
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data,
                  let parsed = try? JSONDecoder().decode(RulesFile.self, from: data),
                  !parsed.groups.isEmpty else {
                done(nil)
                return
            }
            done(parsed.version)
        }.resume()
    }
}
