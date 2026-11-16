import Foundation
import CryptoKit

/// The Baidu Netdisk recipe from the work order. The self-sold splash image
/// path changes with every campaign, so it is derived at runtime:
///
///   Library/Preferences/com.baidu.netdisk.plist
///     key "kBDNCSplashLastAdsFormat_<account>" -> JSON with activity_message
///     MD5 of the percent-encoded URL text       -> <md5>.png
///   Library/Caches/com.hackemist.SDImageCache/default/<md5>.png
///
/// Nothing here hard-codes a file name, and a missing record is reported
/// instead of guessed silently.
enum BaiduNetdisk {
    static let bundleID = "com.baidu.netdisk"
    static let displayName = "百度网盘"

    static let preferencesPath = "Library/Preferences/com.baidu.netdisk.plist"
    static let splashCacheRoot = "Library/Caches/com.hackemist.SDImageCache/default"
    static let splashKeyPrefix = "kBDNCSplashLastAdsFormat_"

    static let thirdPartyCacheGroups: [(group: String, directories: [String])] = [
        ("优量汇", ["Library/Caches/default/tencent_gdtimg", "Library/Caches/default/tencent_gdtres"]),
        ("穿山甲", ["Library/Caches/com.hackemist.CSJDImageCache/default"]),
        ("BeiZi", ["Library/Caches/BeiZiMaterial"])
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
        var unresolved: SplashResolution?
        for key in keys {
            guard let value = plist[key], let json = decodeJSON(value) else { continue }
            guard let message = activityMessage(in: json), let url = firstURL(in: message) else { continue }
            let digest = md5Hex(url)
            if let path = cachedFile(root: cacheRoot, md5: digest, cached: cachedFiles, channel: channel) {
                return SplashResolution(key: key,
                                        url: url,
                                        md5: digest,
                                        path: path,
                                        exists: true,
                                        inferred: false,
                                        cachedFileCount: cachedFiles.count)
            }
            if unresolved == nil {
                unresolved = SplashResolution(key: key,
                                              url: url,
                                              md5: digest,
                                              path: cacheRoot + "/" + digest + ".png",
                                              exists: false,
                                              inferred: false,
                                              cachedFileCount: cachedFiles.count)
            }
        }
        if let unresolved { return unresolved }

        // No usable record (for example the ad never played on this account):
        // fall back to the newest cached image, flagged so the user confirms it.
        let newest = cachedFiles
            .filter { FileKind.of($0.name) == .image }
            .sorted { $0.modified > $1.modified }
            .first
        guard let newest else { return nil }
        let stem = (newest.name as NSString).deletingPathExtension
        return SplashResolution(key: "",
                                url: "",
                                md5: stem,
                                path: newest.path,
                                exists: true,
                                inferred: true,
                                cachedFileCount: cachedFiles.count)
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
                   note: splash.inferred ? "按最新素材推断，请你确认" : "按广告记录动态推导")
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

    private static func activityMessage(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary where key.lowercased().contains("activity_message") {
                if let text = value as? String, !text.isEmpty { return text }
                if let nested = firstString(in: value) { return nested }
            }
            for value in dictionary.values {
                if let found = activityMessage(in: value) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = activityMessage(in: value) { return found }
            }
        }
        return nil
    }

    private static func firstString(in object: Any) -> String? {
        if let text = object as? String { return text.isEmpty ? nil : text }
        if let dictionary = object as? [String: Any] {
            for value in dictionary.values {
                if let found = firstString(in: value) { return found }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let found = firstString(in: value) { return found }
            }
        }
        return nil
    }

    static func firstURL(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s\"'<>\\\\]+") else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let found = Range(match.range, in: text) else { return nil }
        return String(text[found])
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
