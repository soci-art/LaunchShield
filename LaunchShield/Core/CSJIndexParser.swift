import Foundation

/// 第 98 条：穿山甲开屏索引（CSJsplash_CN.plist）的解析器。
///
/// 这个文件是穿山甲 SDK 存的一份开屏广告记录：哪条广告、素材链接、
/// 素材的文件名哈希、整条广告什么时候过期，都在里面。拿它逐个对号，
/// 就能知道缓存目录里哪个文件是当前这条开屏的素材，比靠目录名和
/// 尺寸猜准得多。
///
/// 文件是 NSKeyedArchiver 归档（类是 CSJMaterialMeta、CSJImage 这些
/// App 里没有的类，不能用 NSKeyedUnarchiver 安全解档），所以走现行
/// 代码读 plist 的老路子：PropertyListSerialization 先把 $objects 图
/// 读出来，再递归解引用还原成普通字典。字段抽取只取素材相关的几样
/// （链接、image_key、file_hash、宽高、过期时刻），归档里的竞价、
/// 设备类字段一概不碰、不落盘、不进日志。
///
/// 任何一步失败都返回空结果，调用方当没这回事——文件没有、是空壳、
/// 被冻成 0 字节、格式对不上，都不许让扫描出错。
enum CSJIndexParser {
    struct Material {
        enum Kind { case image, video }
        let kind: Kind
        /// 对号候选名（文件名去后缀、小写）：图片是 image_key、视频是
        /// file_hash，再加上素材链接的 MD5（原文与解百分号编码两种，
        /// 复用 LocalADBlockRule.digests）。图片的 image_key 个别时候
        /// 与归档里那条链接的 MD5 对不上（链接存档前可能被重签名），
        /// 所以两个候选都要试。
        let candidateStems: [String]
        let width: Int
        let height: Int
        /// 这条广告的过期时刻（expire_seconds 是绝对时刻，不是时长）。
        let expire: Date?
    }

    struct ParsedIndex {
        let materials: [Material]
        /// 读到几条带素材的广告，只用来记日志。
        let adCount: Int
    }

    static func parse(data: Data) -> ParsedIndex? {
        guard let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }
        var root: Any = raw
        if let archive = raw as? [String: Any],
           let objects = archive["$objects"] as? [Any],
           let top = archive["$top"] as? [String: Any],
           let rootRef = top["root"] {
            var active = Set<Int>()
            root = resolve(rootRef, objects: objects, depth: 0, active: &active)
        }
        guard let rootDict = root as? [String: Any] else { return nil }
        var materials: [Material] = []
        var adCount = 0
        for meta in collectMetas(from: rootDict) {
            let found = Self.materials(from: meta)
            if !found.isEmpty {
                adCount += 1
                materials.append(contentsOf: found)
            }
        }
        // 跨广告去重：同一支素材（首候选名相同）只留一份——同一支品牌
        // 视频会有多条投放记录，图也可能被多条广告共用。
        var seen = Set<String>()
        materials = materials.filter { material in
            guard let primary = material.candidateStems.first else { return false }
            return seen.insert(primary).inserted
        }
        return ParsedIndex(materials: materials, adCount: adCount)
    }

    // MARK: - NSKeyedArchiver 图解包

    /// 归档图里引用别的对象的写法：只有一个 CF$UID 键的小字典。
    private static func uidIndex(_ value: Any) -> Int? {
        guard let dict = value as? [String: Any], dict.count == 1,
              let raw = dict["CF$UID"] else { return nil }
        if let number = raw as? NSNumber { return number.intValue }
        if let int = raw as? Int { return int }
        return nil
    }

    /// 把 UID 图还原成普通字典/数组。$class（类信息）直接丢掉——
    /// App 里没有那些类，留着也没用。深度封顶、正在解的引用不重复进，
    /// 防畸形归档把递归带进死循环。
    private static func resolve(_ value: Any, objects: [Any], depth: Int, active: inout Set<Int>) -> Any {
        if let index = uidIndex(value) {
            guard objects.indices.contains(index), depth < 64, !active.contains(index) else { return NSNull() }
            active.insert(index)
            let resolved = resolve(objects[index], objects: objects, depth: depth + 1, active: &active)
            active.remove(index)
            return resolved
        }
        if let dict = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, element) in dict where key != "$class" {
                result[key] = resolve(element, objects: objects, depth: depth, active: &active)
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { resolve($0, objects: objects, depth: depth, active: &active) }
        }
        return value
    }

    // MARK: - 字段抽取（宽容：大小写变体都认，抽不到就当没有）

    private static func looksLikeMeta(_ dict: [String: Any]) -> Bool {
        dict["images"] != nil || dict["precache_brand_video"] != nil
            || dict["materialDictionary"] != nil || dict["cover_image"] != nil
            || dict["expire_seconds"] != nil || dict["expire_Seconds"] != nil
    }

    /// 归档根是「广告位编号 → 一条广告记录」的字典。逐层找长得像
    /// 广告记录的字典；一条记录自己里面的镜像字典不再往下翻，
    /// 防同一条广告数两遍。
    private static func collectMetas(from root: [String: Any]) -> [[String: Any]] {
        var metas: [[String: Any]] = []
        func visit(_ dict: [String: Any], depth: Int) {
            if looksLikeMeta(dict) {
                metas.append(dict)
                return
            }
            guard depth < 3 else { return }
            for value in dict.values {
                if let child = value as? [String: Any] {
                    visit(child, depth: depth + 1)
                } else if let array = value as? [Any] {
                    for element in array {
                        if let child = element as? [String: Any] { visit(child, depth: depth + 1) }
                    }
                }
            }
        }
        visit(root, depth: 0)
        return metas
    }

    private static func numberField(_ dict: [String: Any], _ keys: [String]) -> Double? {
        for key in keys {
            if let number = dict[key] as? NSNumber { return number.doubleValue }
            if let int = dict[key] as? Int { return Double(int) }
            if let text = dict[key] as? String, let value = Double(text) { return value }
        }
        return nil
    }

    private static func stringField(_ dict: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let text = dict[key] as? String, !text.isEmpty, text != "$null" { return text }
            if let number = dict[key] as? NSNumber { return number.stringValue }
        }
        return nil
    }

    private static func dictField(_ dict: [String: Any], _ keys: [String]) -> [String: Any]? {
        for key in keys {
            if let found = dict[key] as? [String: Any] { return found }
        }
        return nil
    }

    private static func arrayField(_ dict: [String: Any], _ keys: [String]) -> [[String: Any]] {
        for key in keys {
            if let array = dict[key] as? [Any] {
                return array.compactMap { $0 as? [String: Any] }
            }
        }
        return []
    }

    private static func candidateStems(key: String?, url: String?) -> [String] {
        var stems: [String] = []
        if let key {
            let lowered = key.lowercased()
            if !lowered.isEmpty, !stems.contains(lowered) { stems.append(lowered) }
        }
        if let url {
            for digest in LocalADBlockRule.digests(for: url) where !stems.contains(digest) {
                stems.append(digest)
            }
        }
        return stems
    }

    /// 一条广告的素材清单就两样：1 张开屏图（images 第一张；
    /// cover_image 是同一张，不重复收）＋ precache_brand_video 里的
    /// 视频（按 file_hash 去重）。icon 是被推广应用的图标（200×200），
    /// 不是开屏素材，绝不能收——这里干脆不读 icon 这个键。
    /// 顶层抽不到就去 materialDictionary 镜像里兜底，两边不叠加。
    private static func materials(from meta: [String: Any]) -> [Material] {
        var result: [Material] = []
        let mirror = dictField(meta, ["materialDictionary"])
        var expire = numberField(meta, ["expire_seconds", "expire_Seconds"])
            .map { Date(timeIntervalSince1970: $0) }
        if expire == nil, let mirror {
            expire = numberField(mirror, ["expire_seconds", "expire_Seconds", "expiration_time"])
                .map { Date(timeIntervalSince1970: $0) }
        }

        var imageDict = arrayField(meta, ["images"]).first
        if imageDict == nil, let mirror {
            imageDict = dictField(mirror, ["image", "cover_image"])
        }
        if let image = imageDict {
            let stems = candidateStems(key: stringField(image, ["image_key", "imageKey"]),
                                       url: stringField(image, ["url"]))
            if !stems.isEmpty {
                result.append(Material(kind: .image,
                                       candidateStems: stems,
                                       width: Int(numberField(image, ["width"]) ?? 0),
                                       height: Int(numberField(image, ["height"]) ?? 0),
                                       expire: expire))
            }
        }

        var videoDicts = arrayField(meta, ["precache_brand_video"])
        if videoDicts.isEmpty, let mirror {
            videoDicts = arrayField(mirror, ["precache_brand_video"])
        }
        var seenVideo = Set<String>()
        for video in videoDicts {
            let stems = candidateStems(key: stringField(video, ["file_hash", "fileHash"]),
                                       url: stringField(video, ["url"]))
            guard let primary = stems.first, !seenVideo.contains(primary) else { continue }
            seenVideo.insert(primary)
            result.append(Material(kind: .video,
                                   candidateStems: stems,
                                   width: Int(numberField(video, ["width"]) ?? 0),
                                   height: Int(numberField(video, ["height"]) ?? 0),
                                   expire: expire))
        }
        return result
    }
}
