import Foundation

/// 收集箱：用户手动点上传才传。日志与识别数据都走这里，
/// 服务器只存几天就自动删。应用里不放任何钥匙。
enum CollectUploader {
    static let base = URL(string: "https://ls-collect.86419753.xyz")!

    static func upload(kind: String, contentType: String, body: Data,
                       completion: @escaping (Bool, String) -> Void) {
        var request = URLRequest(url: base.appendingPathComponent("upload"))
        request.httpMethod = "POST"
        request.setValue(kind, forHTTPHeaderField: "X-Kind")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30
        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(false, error.localizedDescription)
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                completion((200..<300).contains(code), code == 0 ? "没有连上服务器" : "服务器返回 \(code)")
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
    }

    private static let mirrors = ["https://gh.86419753.xyz/", "https://gh-proxy.com/", ""]
    private static let releasesAPI = "https://api.github.com/repos/soci-art/LaunchShield/releases/latest"

    /// 查最新正式版：三条线路挨个试，第一条通了就用它。
    static func fetchLatest(completion: @escaping (VersionInfo?, String) -> Void) {
        fetchLatest(mirror: 0, completion: completion)
    }

    private static func fetchLatest(mirror: Int, completion: @escaping (VersionInfo?, String) -> Void) {
        guard mirror < mirrors.count else {
            completion(nil, "三条线路都没连上 GitHub")
            return
        }
        guard let url = URL(string: mirrors[mirror] + releasesAPI) else {
            fetchLatest(mirror: mirror + 1, completion: completion)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let info = data.flatMap { parseLatest($0) }
            DispatchQueue.main.async {
                if info != nil, (response as? HTTPURLResponse)?.statusCode == 200 {
                    completion(info, "")
                } else {
                    fetchLatest(mirror: mirror + 1, completion: completion)
                }
            }
        }.resume()
    }

    private static func parseLatest(_ data: Data) -> VersionInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = object["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: {
                  ($0["name"] as? String)?.hasPrefix("LaunchShield-") == true
                      && ($0["name"] as? String)?.hasSuffix("-unsigned.ipa") == true
              }),
              let download = asset["browser_download_url"] as? String,
              let url = URL(string: download) else { return nil }
        let body = object["body"] as? String ?? ""
        return VersionInfo(version: version,
                           build: parseBuild(from: body),
                           notes: body,
                           downloadURL: url)
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
