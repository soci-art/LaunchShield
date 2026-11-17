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
