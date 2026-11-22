import Foundation
import UIKit

/// 第 86 条：给应用列表取每个应用自己的图标。
///
/// 现行方案（2026-11-22 Grace 定，沿用此方案）：从 Apple App Store
/// 公开目录取官方图标。本地从安装包取图的旧方案已删除——真机两轮
/// 实证：iOS 27 的沙盒不给 Bundle 目录树任何读取许可（根目录列举
/// 被拒、逐个 .app 读 Info.plist 也是 Operation not permitted），
/// 只有系统区公开可读的自带应用能读到，第三方应用一个都读不到。
///
/// 准确性口径（照此实现，不许放宽）：
/// - 应用名字只用作商店搜索词；搜回来的结果必须带有一字不差的
///   Bundle ID 才采用它的图标，绝不按名字模糊对号、绝不拿别的
///   应用的图标顶替。
/// - 实在查不到返回 nil，界面用通用图样占位。
/// - 图标存本地缓存，有效期 30 天：过期后先照常显示旧图，后台
///   重新查一次，商店有新图就换上；查过没结果的也记下时间，
///   一个有效期内不重复打扰商店接口。
private final class IconRequestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    func set(_ data: Data?) {
        lock.lock()
        stored = data
        lock.unlock()
    }

    func get() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class AppIconProvider {
    /// 商店图标有效期（天）。本地取图时代的缓存靠安装包时间失效，
    /// 商店图标没有本地信号可依，就按查到的时间算有效期。
    private static let freshnessDays: TimeInterval = 30

    /// 本轮通过 App Store 查询新取到（含刷新换新）的图标数。
    private(set) var appStoreIconsFetched = 0
    private var lastAppStoreSearchAt = Date.distantPast

    /// bundleID -> 上次查询商店的时间戳。落盘跨启动复用。
    private var storeChecks: [String: TimeInterval] = [:]
    private var storeChecksLoaded = false

    // MARK: - 落盘缓存

    private var cacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("LaunchShield/AppIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func iconFileURL(_ bundleID: String) -> URL {
        cacheDir.appendingPathComponent(bundleID + ".appstore.png")
    }

    private func loadStoreChecksIfNeeded() {
        guard !storeChecksLoaded else { return }
        storeChecksLoaded = true
        // 旧方案（本地安装包取图）留下的缓存文件一并清掉，不再使用。
        let fm = FileManager.default
        try? fm.removeItem(at: cacheDir.appendingPathComponent("meta.json"))
        if let files = try? fm.contentsOfDirectory(atPath: cacheDir.path) {
            for name in files where name.hasSuffix(".png") && !name.hasSuffix(".appstore.png") {
                try? fm.removeItem(at: cacheDir.appendingPathComponent(name))
            }
        }
        let url = cacheDir.appendingPathComponent("store-checks.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Double] else { return }
        storeChecks = dict
    }

    private func recordStoreCheck(_ bundleID: String) {
        storeChecks[bundleID] = Date().timeIntervalSince1970
        if let data = try? JSONSerialization.data(withJSONObject: storeChecks) {
            try? data.write(to: cacheDir.appendingPathComponent("store-checks.json"),
                            options: .atomic)
        }
    }

    // MARK: - 缓存读取

    /// 缓存里有图就先给界面显示（新旧都给，过期只是排队刷新，
    /// 不让界面闪占位图）。
    func iconFromCache(bundleID: String) -> UIImage? {
        let url = iconFileURL(bundleID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// 要不要去商店查：没图、或上次查询已过有效期。
    func iconNeedsFetch(bundleID: String) -> Bool {
        loadStoreChecksIfNeeded()
        let hasIcon = FileManager.default.fileExists(atPath: iconFileURL(bundleID).path)
        guard hasIcon, let last = storeChecks[bundleID] else { return true }
        return Date().timeIntervalSince1970 - last >= Self.freshnessDays * 86_400
    }

    // MARK: - 现取（商店目录）

    func fetchIcon(bundleID: String, appName: String) -> UIImage? {
        loadStoreChecksIfNeeded()
        guard let storeImage = fetchAppStoreIcon(bundleID: bundleID, appName: appName) else {
            // 查过没结果也记时间，有效期内不再重复查。
            recordStoreCheck(bundleID)
            return nil
        }
        let small = Self.downscale(storeImage)
        if let png = small.pngData() {
            try? png.write(to: iconFileURL(bundleID), options: .atomic)
        }
        recordStoreCheck(bundleID)
        appStoreIconsFetched += 1
        return small
    }

    /// Apple 文档给出的 Search API 参考上限约为每分钟 20 次。
    /// 图标队列串行运行，因此用 3.1 秒间隔避免集中请求触发限流。
    private func waitForAppStoreSearchSlot() {
        let interval = Date().timeIntervalSince(lastAppStoreSearchAt)
        if interval < 3.1 {
            Thread.sleep(forTimeInterval: 3.1 - interval)
        }
        lastAppStoreSearchAt = Date()
    }

    /// Apple 官方 iTunes Search API。按应用名称搜索软件结果，再用
    /// 返回的 bundleId 精确匹配；不使用未在官方文档列明的 bundleId lookup 参数。
    /// 当前 App Store 地区优先，必要时回退 US / CN / KR。
    private func fetchAppStoreIcon(bundleID: String, appName: String) -> UIImage? {
        let preferred = Locale.current.region?.identifier.lowercased() ?? "us"
        var regions = [preferred, "us", "cn", "kr"]
        var seen = Set<String>()
        regions = regions.filter { seen.insert($0).inserted }

        for region in regions {
            waitForAppStoreSearchSlot()
            var components = URLComponents(string: "https://itunes.apple.com/search")
            components?.queryItems = [
                URLQueryItem(name: "term", value: appName),
                URLQueryItem(name: "country", value: region),
                URLQueryItem(name: "media", value: "software"),
                URLQueryItem(name: "entity", value: "software"),
                URLQueryItem(name: "limit", value: "50")
            ]
            guard let url = components?.url,
                  let data = synchronousRequest(url: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = root["results"] as? [[String: Any]] else { continue }

            guard let match = results.first(where: {
                ($0["bundleId"] as? String) == bundleID
            }) else { continue }

            guard let artwork = (match["artworkUrl512"] as? String)
                ?? (match["artworkUrl100"] as? String)
                ?? (match["artworkUrl60"] as? String),
                let artworkURL = URL(string: artwork),
                let imageData = synchronousRequest(url: artworkURL),
                let image = UIImage(data: imageData) else { continue }
            return image
        }
        return nil
    }

    /// 仅在专用后台图标队列调用；限制单次请求等待时间，避免网络故障卡住界面。
    private func synchronousRequest(url: URL) -> Data? {
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad,
                                 timeoutInterval: 10)
        let semaphore = DispatchSemaphore(value: 0)
        let result = IconRequestResult()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil,
                  let response = response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode) else { return }
            result.set(data)
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + 11) == .success else {
            task.cancel()
            return nil
        }
        return result.get()
    }

    // MARK: 缩图

    static func downscale(_ image: UIImage) -> UIImage {
        let pixelW = image.cgImage?.width ?? Int(image.size.width * image.scale)
        let pixelH = image.cgImage?.height ?? Int(image.size.height * image.scale)
        let longest = max(pixelW, pixelH)
        guard longest > 120, pixelW > 0, pixelH > 0 else { return image }
        let ratio = 120.0 / Double(longest)
        let newSize = CGSize(width: max(1, (Double(pixelW) * ratio).rounded()),
                             height: max(1, (Double(pixelH) * ratio).rounded()))
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
