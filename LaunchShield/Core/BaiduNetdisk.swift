import Foundation
import CryptoKit

/// The Baidu Netdisk recipe from the work order. The self-sold splash image
/// path changes with every campaign, so it is derived at runtime:
///
///   Library/Preferences/com.baidu.netdisk.plist
///     key "kBDNCSplashLastAdsFormat_<account>" -> record with activity_message
///     the splash image URL lives in activity_message's content_url_list
///     MD5 of the percent-encoded URL text       -> <md5>.png
///   Library/Caches/com.hackemist.SDImageCache/default/<md5>.png
///
/// Nothing here hard-codes a file name. The derivation is deterministic:
/// candidate URLs are collected in a fixed order (content_url_list first,
/// then every other URL in the message), each is matched against the cache,
/// and the largest matching image wins. There is no "newest file" guessing:
/// when no candidate matches a cached file, the miss is reported instead.
enum BaiduNetdisk {
    static let bundleID = "com.baidu.netdisk"
    static let displayName = "百度网盘"

    static let preferencesPath = "Library/Preferences/com.baidu.netdisk.plist"
    static let splashCacheRoot = "Library/Caches/com.hackemist.SDImageCache/default"
    static let splashKeyPrefix = "kBDNCSplashLastAdsFormat_"

    static let thirdPartyCacheGroups: [(group: String, directories: [String])] = [
        ("优量汇", ["Library/Caches/default/tencent_gdtimg", "Library/Caches/default/tencent_gdtres",
                    "tmp/gdtMedia",
                    "Library/tencent_gdtmob", "Library/Caches/GDT"]),
        ("穿山甲", ["Library/Caches/com.hackemist.CSJSDImageCache/default",
                    "Library/Caches/cn_buadsdk_file_cache/bu_splash_cache"]),
        ("BeiZi", ["Library/Caches/BeiZiMaterial"]),
        ("美数", ["Library/Caches/MSAdSDK"])
    ]

    // MARK: - Splash derivation

    static func resolveSplash(container: String, channel: Channel) -> SplashResolution? {
        let prefsPath = container + "/" + preferencesPath
        guard channel.exists(prefsPath) else { return nil }
        guard let data = try? channel.read(prefsPath, maxBytes: 16 * 1024 * 1024) else { return nil }
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
            return nil
        }
        let cacheRoot = container + "/" + splashCacheRoot
        let cachedFiles = (try? channel.children(of: cacheRoot))?.filter { !$0.isDirectory } ?? []

        let keys = plist.keys.filter { $0.hasPrefix(splashKeyPrefix) }.sorted()
        var bestPrimary: (resolution: SplashResolution, size: UInt64)?
        var bestSecondary: (resolution: SplashResolution, size: UInt64)?
        var unresolved: SplashResolution?
        for key in keys {
            guard let value = plist[key], let json = decodeJSON(value) else { continue }
            for message in activityMessages(in: json) {
                let (primary, secondary) = candidateURLs(in: message)
                for (urls, isPrimary) in [(primary, true), (secondary, false)] {
                    for url in urls {
                        for digest in digests(for: url) {
                            if let path = cachedFile(root: cacheRoot, md5: digest, cached: cachedFiles, channel: channel) {
                                let size = channel.item(at: path)?.size ?? 0
                                let found = SplashResolution(key: key,
                                                             url: url,
                                                             md5: digest,
                                                             path: path,
                                                             exists: true,
                                                             inferred: false,
                                                             cachedFileCount: cachedFiles.count)
                                if isPrimary {
                                    if bestPrimary == nil || size > bestPrimary!.size { bestPrimary = (found, size) }
                                } else if bestSecondary == nil || size > bestSecondary!.size {
                                    bestSecondary = (found, size)
                                }
                            } else if unresolved == nil {
                                unresolved = SplashResolution(key: key,
                                                              url: url,
                                                              md5: digest,
                                                              path: cacheRoot + "/" + digest + ".png",
                                                              exists: false,
                                                              inferred: false,
                                                              cachedFileCount: cachedFiles.count)
                            }
                        }
                    }
                }
            }
        }
        if let bestPrimary { return bestPrimary.resolution }
        if let bestSecondary { return bestSecondary.resolution }
        return unresolved
    }

    static func relativePath(container: String, path: String) -> String {
        let prefix = container.hasSuffix("/") ? container : container + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    // MARK: - Clear list

    static func targets(container: String, channel: Channel, splash: SplashResolution?) -> [TargetFile] {
        var result: [TargetFile] = []
        var seen = Set<String>()

        func append(_ item: FileItem, group: String, note: String) {
            guard !seen.contains(item.path) else { return }
            seen.insert(item.path)
            result.append(TargetFile(path: item.path,
                                     relativePath: relativePath(container: container, path: item.path),
                                     group: group,
                                     note: note,
                                     size: item.size,
                                     isSmallConfig: group == "BeiZi" && item.size < 4096))
        }

        if let splash, splash.exists, let item = channel.item(at: splash.path), !item.isDirectory {
            append(item,
                   group: "百度自营",
                   note: "按广告记录动态推导")
        }

        for group in thirdPartyCacheGroups {
            for directory in group.directories {
                let root = container + "/" + directory
                for item in files(below: root, channel: channel, depth: 0, limit: 4000) {
                    append(item, group: group.group, note: item.size < 4096 ? "清单小文件" : "")
                }
            }
        }
        return result
    }

    private static func files(below directory: String, channel: Channel, depth: Int, limit: Int) -> [FileItem] {
        guard depth < 6 else { return [] }
        guard let items = try? channel.children(of: directory) else { return [] }
        var result: [FileItem] = []
        for item in items {
            if item.isSymlink { continue }
            if item.isDirectory {
                result.append(contentsOf: files(below: item.path, channel: channel, depth: depth + 1, limit: limit))
            } else {
                result.append(item)
            }
            if result.count >= limit { break }
        }
        return result
    }

    // MARK: - JSON helpers

    private static func decodeJSON(_ value: Any) -> Any? {
        if let data = value as? Data {
            return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
        }
        if let text = value as? String, let data = text.data(using: .utf8) {
            return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
        }
        if value is [String: Any] || value is [Any] {
            return value
        }
        return nil
    }

    /// Every activity_message value in the record, collected in a fixed
    /// walk order (dictionary keys sorted, arrays in order) so repeated
    /// scans of the same record always see the same list.
    static func activityMessages(in object: Any) -> [Any] {
        var result: [Any] = []
        func walk(_ o: Any) {
            if let dictionary = o as? [String: Any] {
                for key in dictionary.keys.sorted() {
                    let value = dictionary[key]!
                    if key.lowercased().contains("activity_message") { result.append(value) }
                    walk(value)
                }
            } else if let array = o as? [Any] {
                for value in array { walk(value) }
            } else if let text = o as? String, let parsed = decodeJSON(text), !(parsed is String) {
                walk(parsed)
            }
        }
        walk(object)
        return result
    }

    /// Candidate URLs of one activity_message: URLs listed under
    /// content_url_list first (the splash image lives there), then every
    /// other URL in the message. Both lists keep a fixed order.
    static func candidateURLs(in message: Any) -> (primary: [String], secondary: [String]) {
        var primary: [String] = []
        var secondary: [String] = []
        func walk(_ o: Any, underContentList: Bool) {
            if let dictionary = o as? [String: Any] {
                for key in dictionary.keys.sorted() {
                    walk(dictionary[key]!, underContentList: underContentList || key.lowercased() == "content_url_list")
                }
            } else if let array = o as? [Any] {
                for value in array { walk(value, underContentList: underContentList) }
            } else if let text = o as? String {
                if let parsed = decodeJSON(text), !(parsed is String) {
                    walk(parsed, underContentList: underContentList)
                } else {
                    for url in allURLs(in: text) {
                        if underContentList {
                            if !primary.contains(url) { primary.append(url) }
                        } else if !secondary.contains(url) {
                            secondary.append(url)
                        }
                    }
                }
            }
        }
        walk(message, underContentList: false)
        secondary.removeAll { primary.contains($0) }
        return (primary, secondary)
    }

    static func allURLs(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s\"'<>\\\\]+") else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    /// The cache file name is the MD5 of the URL exactly as stored in the
    /// record (percent-encoded spelling). The decoded spelling is tried
    /// too, in this fixed order.
    static func digests(for url: String) -> [String] {
        var result = [md5Hex(url)]
        if let decoded = url.removingPercentEncoding, decoded != url {
            result.append(md5Hex(decoded))
        }
        return result
    }

    static func md5Hex(_ text: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func cachedFile(root: String, md5: String, cached: [FileItem], channel: Channel) -> String? {
        for extensionName in ["png", "jpg", "jpeg", "webp", "gif", "mp4", ""] {
            let path = extensionName.isEmpty ? root + "/" + md5 : root + "/" + md5 + "." + extensionName
            if channel.exists(path) { return path }
        }
        for item in cached where !item.isDirectory {
            let stem = (item.name as NSString).deletingPathExtension.lowercased()
            if stem == md5 { return item.path }
        }
        return nil
    }
}
