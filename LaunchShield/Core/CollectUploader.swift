import Foundation

/// 收集箱：用户手动点上传才传。日志与识别数据都走这里，
/// 服务器只存几天就自动删。应用里不放任何钥匙。
enum CollectUploader {
    static let base = URL(string: "https://ls-collect.86419753.xyz")!

    struct VersionInfo {
        let version: String
        let notes: String
    }

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

    // MARK: - 正式版下载

    private static var activeDownloader: IPADownloader?

    /// 下载正式版 IPA 到本应用的文稿目录，过程带进度回调。
    static func downloadIPA(progress: @escaping (Double) -> Void,
                            completion: @escaping (URL?, String) -> Void) {
        let downloader = IPADownloader(progress: progress) { url, message in
            activeDownloader = nil
            completion(url, message)
        }
        activeDownloader = downloader
        downloader.start(url: base.appendingPathComponent("download"))
    }

    /// 正式版版本信息（测试版不进这里）。
    static func fetchVersion(completion: @escaping (VersionInfo?, String) -> Void) {
        var request = URLRequest(url: base.appendingPathComponent("version"))
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(nil, error.localizedDescription)
                    return
                }
                guard let data,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let version = object["version"] as? String else {
                    completion(nil, "服务器没有返回版本信息")
                    return
                }
                completion(VersionInfo(version: version,
                                       notes: object["notes"] as? String ?? ""), "")
            }
        }.resume()
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
            message = "服务器上还没有放正式版安装包"
        } else {
            message = "服务器返回 \(code)"
        }
        DispatchQueue.main.async { self.completion(nil, message) }
        session.finishTasksAndInvalidate()
    }
}
