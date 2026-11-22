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
/// - 按 Bundle ID 打包向商店目录查询（一次最多 30 个，连应用
///   名字都不用发）；结果自带 Bundle ID、逐个精确对号才采用
///   它的图标，绝不模糊对号、绝不拿别的应用的图标顶替。
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

/// 并发下载时收集结果的小盒子（锁保护，和 IconRequestResult 一个路子）。
private final class IconBatchResult: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: UIImage] = [:]

    func set(_ image: UIImage, for bundleID: String) {
        lock.lock()
        images[bundleID] = image
        lock.unlock()
    }

    func all() -> [String: UIImage] {
        lock.lock()
        defer { lock.unlock() }
        return images
    }
}

final class AppIconProvider {
    /// 商店图标有效期（天）。本地取图时代的缓存靠安装包时间失效，
    /// 商店图标没有本地信号可依，就按查到的时间算有效期。
    private static let freshnessDays: TimeInterval = 30

    /// 本轮通过 App Store 查询新取到（含刷新换新）的图标数。
    private(set) var appStoreIconsFetched = 0
    private var lastLookupAt = Date.distantPast

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

    // MARK: - 现取（商店目录，批量）

    /// 一次打包查询最多带多少个 Bundle ID（2026-11-22 实测：
    /// 30 个一请求、约 1 秒返回，带官方图地址）。
    private static let lookupBatchSize = 30
    /// 图标图片同时下载的路数。
    private static let downloadConcurrency = 8

    /// 批量取图：打包向商店目录查官方图地址，再多路并发下载。
    /// 返回 Bundle ID -> 图标；查不到、下不到的不会出现在结果里。
    /// 被查过的每个 ID 都记下查询时间（有效期从此算，查过没
    /// 结果的也不重复打扰）。
    func fetchIcons(bundleIDs: [String]) -> [String: UIImage] {
        loadStoreChecksIfNeeded()
        guard !bundleIDs.isEmpty else { return [:] }
        var artwork: [String: String] = [:]
        for start in stride(from: 0, to: bundleIDs.count, by: Self.lookupBatchSize) {
            let chunk = Array(bundleIDs[start..<min(start + Self.lookupBatchSize, bundleIDs.count)])
            for (bid, url) in lookupArtworkURLs(bundleIDs: chunk) where artwork[bid] == nil {
                artwork[bid] = url
            }
        }
        let box = IconBatchResult()
        if !artwork.isEmpty {
            let group = DispatchGroup()
            let slots = DispatchSemaphore(value: Self.downloadConcurrency)
            let queue = DispatchQueue(label: "com.sociart.launchshield.appicons.download",
                                      attributes: .concurrent)
            for (bid, urlString) in artwork {
                guard let url = URL(string: urlString) else { continue }
                group.enter()
                queue.async { [self] in
                    defer { group.leave() }
                    slots.wait()
                    defer { slots.signal() }
                    guard let data = synchronousRequest(url: url),
                          let image = UIImage(data: data) else { return }
                    let small = Self.downscale(image)
                    if let png = small.pngData() {
                        try? png.write(to: iconFileURL(bid), options: .atomic)
                    }
                    box.set(small, for: bid)
                }
            }
            group.wait()
        }
        let result = box.all()
        for bid in bundleIDs { recordStoreCheck(bid) }
        appStoreIconsFetched += result.count
        return result
    }

    /// 打包查询：一请求带一批 Bundle ID，逐个地区问，没查全的换
    /// 下一个地区补查。返回 Bundle ID -> 官方图地址；结果条目自带
    /// bundleId，只收被问到的 ID，不会串到别的 App 上。
    private func lookupArtworkURLs(bundleIDs: [String]) -> [String: String] {
        let preferred = Locale.current.region?.identifier.lowercased() ?? "us"
        var regions = [preferred, "cn", "us", "kr"]
        var seen = Set<String>()
        regions = regions.filter { seen.insert($0).inserted }
        var found: [String: String] = [:]
        var remaining = bundleIDs
        for region in regions where !remaining.isEmpty {
            // 查询请求之间留半秒，避开商店接口的频率限制。
            let interval = Date().timeIntervalSince(lastLookupAt)
            if interval < 0.5 { Thread.sleep(forTimeInterval: 0.5 - interval) }
            lastLookupAt = Date()
            var components = URLComponents(string: "https://itunes.apple.com/lookup")
            components?.queryItems = [
                URLQueryItem(name: "bundleId", value: remaining.joined(separator: ",")),
                URLQueryItem(name: "country", value: region),
                URLQueryItem(name: "entity", value: "software")
            ]
            guard let url = components?.url,
                  let data = synchronousRequest(url: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = root["results"] as? [[String: Any]] else { continue }
            for entry in results {
                guard let bid = entry["bundleId"] as? String,
                      remaining.contains(bid), found[bid] == nil,
                      let art = (entry["artworkUrl512"] as? String)
                        ?? (entry["artworkUrl100"] as? String)
                        ?? (entry["artworkUrl60"] as? String) else { continue }
                found[bid] = art
            }
            remaining = remaining.filter { found[$0] == nil }
        }
        return found
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
