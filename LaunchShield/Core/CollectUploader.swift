import Foundation

/// 收集箱：用户手动点上传才传。日志与识别数据都走这里，
/// 服务器只存几天就自动删。应用里不放任何钥匙。
enum CollectUploader {
    static let base = URL(string: "https://ls-collect.86419753.xyz")!

    static func upload(kind: String, contentType: String, body: Data,
                       timeout: TimeInterval = 30,
                       completion: @escaping (Bool, String) -> Void) {
        attempt(kind: kind, contentType: contentType, body: body,
                timeout: max(timeout, 60), attemptsLeft: 4, delay: 2,
                completion: completion)
    }

    /// One tap, several tries. The collector sits at the far end of an
    /// unstable link and a 1 MB+ log body often dies mid-flight (field
    /// logs show "network connection was lost" / "timed out" again and
    /// again, then a manual second tap lands). Retry transient failures
    /// with backoff instead of making the user tap again, and give each
    /// try at least a minute. A 4xx answer from the server will not
    /// change between tries, so fail at once.
    private static func attempt(kind: String, contentType: String, body: Data,
                                timeout: TimeInterval, attemptsLeft: Int,
                                delay: TimeInterval,
                                completion: @escaping (Bool, String) -> Void) {
        var request = URLRequest(url: base.appendingPathComponent("upload"))
        request.httpMethod = "POST"
        request.setValue(kind, forHTTPHeaderField: "X-Kind")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = timeout
        URLSession.shared.dataTask(with: request) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if error == nil, (200..<300).contains(code) {
                DispatchQueue.main.async { completion(true, "") }
                return
            }
            let retryable = error != nil || code == 408 || code == 429 || code >= 500
            if retryable, attemptsLeft > 1 {
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    attempt(kind: kind, contentType: contentType, body: body,
                            timeout: timeout, attemptsLeft: attemptsLeft - 1,
                            delay: min(delay * 2.5, 15), completion: completion)
                }
                return
            }
            DispatchQueue.main.async {
                if let error {
                    completion(false, error.localizedDescription)
                } else {
                    completion(false, code == 0 ? "没有连上服务器" : "服务器返回 \(code)")
                }
            }
        }.resume()
    }

}

/// 正式版更新改走 GitHub 发行版（清单第 14 条）：不再问收集箱要版本，
/// 直接查仓库的最新正式发行版。取数顺序照 Grace 定的三级：
/// 自家域名 gh.86419753.xyz → 国内加速 gh-proxy.com → 直连，
/// 跟 Drift 内置的顺序一致。查版本和下载安装包都按这个顺序试。
enum GitHubUpdate {
    struct VersionInfo {
        let version: String
        /// 发行说明里工作流写明的构建号；老发行版没写就是 nil。
        let build: Int?
        let notes: String
        let downloadURL: URL
        /// 发行版发布日期（yyyy-MM-dd），公告卡上显示用；取不到时为空。
        let publishedAt: String
        /// 这份发行版是不是预发行（Nightly）。
        let isPrerelease: Bool
    }

    private static let mirrors = ["https://gh.86419753.xyz/", "https://gh-proxy.com/", ""]
    private static let releasesAPI = "https://api.github.com/repos/soci-art/LaunchShield/releases/latest"
    private static let releasesListAPI = "https://api.github.com/repos/soci-art/LaunchShield/releases?per_page=10"

    /// 更新通道（清单第 31 条）：预发行构建由其工作流往 Info.plist 盖
    /// LSUpdateChannel=prerelease，只检测预发行更新；没有这个标记的一律
    /// 按正式版查——正式版工作流不盖标记，预发行代码同步到正式线也不会串线。
    static var isPrereleaseChannel: Bool {
        Bundle.main.infoDictionary?["LSUpdateChannel"] as? String == "prerelease"
    }

    /// 按本机通道查最新版：三条线路挨个试，第一条通了就用它。
    static func fetchLatest(completion: @escaping (VersionInfo?, String) -> Void) {
        fetchLatest(mirror: 0, prerelease: isPrereleaseChannel, completion: completion)
    }

    private static func fetchLatest(mirror: Int, prerelease: Bool, completion: @escaping (VersionInfo?, String) -> Void) {
        guard mirror < mirrors.count else {
            completion(nil, "三条线路都没连上 GitHub")
            return
        }
        guard let url = URL(string: mirrors[mirror] + (prerelease ? releasesListAPI : releasesAPI)) else {
            fetchLatest(mirror: mirror + 1, prerelease: prerelease, completion: completion)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let info = data.flatMap { prerelease ? parsePrereleaseList($0) : parseLatest($0) }
            DispatchQueue.main.async {
                if info != nil, (response as? HTTPURLResponse)?.statusCode == 200 {
                    completion(info, "")
                } else {
                    fetchLatest(mirror: mirror + 1, prerelease: prerelease, completion: completion)
                }
            }
        }.resume()
    }

    private static func parseLatest(_ data: Data) -> VersionInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parseRelease(object)
    }

    /// 预发行没有 /latest 接口：拉最近 10 个发行版，取第一个预发行且非草稿的。
    private static func parsePrereleaseList(_ data: Data) -> VersionInfo? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        for object in list {
            if (object["prerelease"] as? Bool) == true, (object["draft"] as? Bool) != true {
                return parseRelease(object)
            }
        }
        return nil
    }

    private static func parseRelease(_ object: [String: Any]) -> VersionInfo? {
        guard let tag = object["tag_name"] as? String else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = object["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: {
                  ($0["name"] as? String)?.hasPrefix("LaunchShield-") == true
                      && ($0["name"] as? String)?.hasSuffix("-unsigned.ipa") == true
              }),
              let download = asset["browser_download_url"] as? String,
              let url = URL(string: download) else { return nil }
        let body = object["body"] as? String ?? ""
        var published = ""
        if let raw = object["published_at"] as? String,
           let date = ISO8601DateFormatter().date(from: raw) {
            let day = DateFormatter()
            day.dateFormat = "yyyy-MM-dd"
            published = day.string(from: date)
        }
        return VersionInfo(version: version,
                           build: parseBuild(from: body),
                           notes: body,
                           downloadURL: url,
                           publishedAt: published,
                           isPrerelease: (object["prerelease"] as? Bool) ?? false)
    }

    /// 发行说明里工作流写死的一行「构建号：N」：同版本换包靠它认新旧。
    /// 老发行版没这行就返回 nil，检测退回只比版本号，不会误报。
    private static func parseBuild(from body: String) -> Int? {
        guard let range = body.range(of: #"构建号[:：]\s*[0-9]+"#, options: .regularExpression) else { return nil }
        return Int(body[range].filter { $0.isNumber })
    }

    private static var activeDownloader: IPADownloader?

    /// 下载正式版 IPA 到本应用的文稿目录：按三级顺序试，
    /// 哪条先下完用哪条，过程带进度回调。
    static func downloadIPA(from directURL: URL,
                            progress: @escaping (Double) -> Void,
                            completion: @escaping (URL?, String) -> Void) {
        downloadIPA(from: directURL, mirror: 0, progress: progress, completion: completion)
    }

    private static func downloadIPA(from directURL: URL, mirror: Int,
                                    progress: @escaping (Double) -> Void,
                                    completion: @escaping (URL?, String) -> Void) {
        guard mirror < mirrors.count else {
            completion(nil, "三条线路都没下下来")
            return
        }
        let base = mirrors[mirror]
        guard let url = base.isEmpty ? directURL : URL(string: base + directURL.absoluteString) else {
            downloadIPA(from: directURL, mirror: mirror + 1, progress: progress, completion: completion)
            return
        }
        let downloader = IPADownloader(progress: progress) { file, message in
            if let file {
                activeDownloader = nil
                completion(file, "")
            } else if mirror + 1 < mirrors.count {
                downloadIPA(from: directURL, mirror: mirror + 1, progress: progress, completion: completion)
            } else {
                activeDownloader = nil
                completion(nil, message)
            }
        }
        activeDownloader = downloader
        downloader.start(url: url)
    }
}

/// 更新公告（清单第 20 条）：跟着本机通道的发行版走（第 88 条），写在
/// 该通道最新发行版的发行说明里【公告】…【/公告】一段中，第一行是标题、
/// 其余是正文。App 检测更新时顺带取回，有新公告弹一次，主页入口常驻、未读带红点。
struct Announcement: Equatable {
    let title: String
    let body: String
    let version: String
    let date: String

    /// 同一条公告的身份标记：版本+标题+正文的稳定哈希（FNV-1a，
    /// 不用 String.hashValue——它每次启动都不一样，存不住）。
    var stamp: String { "\(version)#\(Self.stableHash(title + "\n" + body))" }

    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    static func parse(notes: String, version: String, date: String) -> Announcement? {
        // 发行说明经 GitHub 网页编辑保存后行尾是 CRLF：先把行尾归一，
        // 不然切行后每行尾巴上拖着回车符，「【公告】」等值比较对不上，
        // 公告永远解析不出来（2026-11-20 实证，0.1.7 的公告就没显示过）。
        let normalized = notes.replacingOccurrences(of: "\r\n", with: "\n")
                              .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "【公告】" }) else {
            return nil
        }
        var collected: [String] = []
        for line in lines[(start + 1)...] {
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "【/公告】" { break }
            collected.append(line)
        }
        let content = collected
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let title = content.first else { return nil }
        return Announcement(title: title,
                            body: content.dropFirst().joined(separator: "\n"),
                            version: version,
                            date: date)
    }
}

final class IPADownloader: NSObject, URLSessionDownloadDelegate {
    private var session: URLSession?
    private let progress: (Double) -> Void
    private let completion: (URL?, String) -> Void
    private var finished = false

    init(progress: @escaping (Double) -> Void,
         completion: @escaping (URL?, String) -> Void) {
        self.progress = progress
        self.completion = completion
    }

    func start(url: URL) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        session.downloadTask(with: request).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.progress(value) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard !finished else { return }
        finished = true
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dest = docs.appendingPathComponent("LaunchShield-新版.ipa")
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            DispatchQueue.main.async { self.completion(dest, "") }
        } catch {
            DispatchQueue.main.async { self.completion(nil, error.localizedDescription) }
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard !finished else { return }
        finished = true
        let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let message: String
        if let error {
            message = error.localizedDescription
        } else if code == 404 {
            message = "没找到这个安装包"
        } else {
            message = "服务器返回 \(code)"
        }
        DispatchQueue.main.async { self.completion(nil, message) }
        session.finishTasksAndInvalidate()
    }
}
