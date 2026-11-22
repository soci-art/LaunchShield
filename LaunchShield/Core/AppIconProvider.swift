import Foundation
import UIKit
import Compression

/// 第 86 条：给应用列表取每个应用自己的图标。
///
/// 准确性口径（Grace 问过，照此实现）：
/// - 图标只从应用自己的安装包（.app）里取，不上网、不靠名字猜。
/// - 认 Bundle ID 对号：取图前先读安装包里的 Info.plist，里面写的
///   CFBundleIdentifier 必须和要找的 Bundle ID 完全一致才用它的图标。
/// - 取图顺序：先按 Info.plist 写的图标文件名拿包里的原图；没有再拆
///   Assets.car（图标打包文件）里那张扁平的 AppIcon 大图。
/// - 实在拿不到返回 nil，界面用通用图样占位，绝不拿别的图标顶替。
final class AppIconProvider {
    private static let bundleRoot = "/private/var/containers/Bundle/Application"
    private static let maxCarBytes: UInt64 = 64_000_000

    /// bundleID -> (安装包路径, Info.plist 修改时间戳)。落盘跨启动复用。
    private var pathCache: [String: (path: String, stamp: TimeInterval)] = [:]
    private var pathCacheLoaded = false
    private var bundleMapScanned = false

    // MARK: - 落盘缓存

    private var cacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("LaunchShield/AppIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func loadPathCacheIfNeeded() {
        guard !pathCacheLoaded else { return }
        pathCacheLoaded = true
        let url = cacheDir.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: [String: Any]] else { return }
        for (bid, entry) in dict {
            if let path = entry["path"] as? String, let stamp = entry["stamp"] as? Double {
                pathCache[bid] = (path, stamp)
            }
        }
    }

    private func persistPathCache() {
        var dict: [String: [String: Any]] = [:]
        for (bid, entry) in pathCache {
            dict[bid] = ["path": entry.path, "stamp": entry.stamp]
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: cacheDir.appendingPathComponent("meta.json"), options: .atomic)
        }
    }

    private func iconFileURL(_ bundleID: String) -> URL {
        cacheDir.appendingPathComponent(bundleID + ".png")
    }

    /// 缓存命中：安装包路径已知、Info.plist 没变过、图标文件还在。
    func iconFromCache(bundleID: String, channel: Channel) -> UIImage? {
        loadPathCacheIfNeeded()
        guard let entry = pathCache[bundleID] else { return nil }
        let plistPath = entry.path + "/Info.plist"
        guard let item = channel.item(at: plistPath),
              abs(item.modified.timeIntervalSince1970 - entry.stamp) < 1.0 else { return nil }
        let url = iconFileURL(bundleID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    // MARK: - 现取

    func fetchIcon(bundleID: String, channel: Channel) -> UIImage? {
        loadPathCacheIfNeeded()

        // 先用 LaunchServices 的 Bundle ID -> .app 路径映射，避免必须列举
        // 整个 Bundle/Application 根目录。路径仍须通过 WQChannel 授权读取，
        // 并且 Info.plist 中的 Bundle ID 必须精确匹配。
        var resolved: (path: String, plist: (id: String, dict: [String: Any], stamp: TimeInterval))?
        if let entry = pathCache[bundleID],
           let plist = readPlist(appPath: entry.path, channel: channel),
           plist.id == bundleID {
            resolved = (entry.path, plist)
        }

        if resolved == nil,
           let appPath = channel.installedAppBundlePath(for: bundleID),
           appPath.hasSuffix(".app"),
           let plist = readPlist(appPath: appPath, channel: channel),
           plist.id == bundleID {
            resolved = (appPath, plist)
            pathCache[bundleID] = (appPath, plist.stamp)
            persistPathCache()
        }

        // LaunchServices 没有给出可用路径时，才回退到原来的目录枚举。
        if resolved == nil {
            ensureBundleMap(channel: channel)
            if let entry = pathCache[bundleID],
               let plist = readPlist(appPath: entry.path, channel: channel),
               plist.id == bundleID {
                resolved = (entry.path, plist)
            }
        }

        guard let app = resolved else { return nil }
        let image = looseIcon(appPath: app.path, plist: app.plist.dict, channel: channel)
            ?? carIcon(appPath: app.path, plist: app.plist.dict, channel: channel)
        guard let found = image else { return nil }
        let small = Self.downscale(found)
        if let png = small.pngData() {
            try? png.write(to: iconFileURL(bundleID), options: .atomic)
        }
        return small
    }

    /// LaunchServices 直达路径不可用时的兼容回退。
    /// 只有成功列出根目录后才标记扫描完成；授权失败允许后续重试。
    private func ensureBundleMap(channel: Channel) {
        guard !bundleMapScanned else { return }
        guard let roots = try? channel.children(of: Self.bundleRoot) else { return }
        var changed = false
        var everyDirectoryListed = true
        for dir in roots where dir.isDirectory {
            guard let subs = try? channel.children(of: dir.path) else {
                everyDirectoryListed = false
                continue
            }
            for sub in subs where sub.isDirectory && sub.name.hasSuffix(".app") {
                guard let got = readPlist(appPath: sub.path, channel: channel) else { continue }
                if pathCache[got.id]?.path != sub.path {
                    pathCache[got.id] = (sub.path, got.stamp)
                    changed = true
                }
            }
        }
        // 任一 UUID 目录未能列举时保留重试机会；全部列举成功才缓存扫描完成。
        bundleMapScanned = everyDirectoryListed
        if changed { persistPathCache() }
    }

    private func readPlist(appPath: String, channel: Channel)
        -> (id: String, dict: [String: Any], stamp: TimeInterval)? {
        let plistPath = appPath + "/Info.plist"
        guard let data = try? channel.read(plistPath),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any],
              let bid = dict["CFBundleIdentifier"] as? String else { return nil }
        let stamp = channel.item(at: plistPath)?.modified.timeIntervalSince1970 ?? 0
        return (bid, dict, stamp)
    }

    // MARK: 取图第一路：安装包里的散图

    private func looseIcon(appPath: String, plist: [String: Any], channel: Channel) -> UIImage? {
        var bases: [String] = []
        if let icons = plist["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String], !files.isEmpty {
            bases = files
        }
        if bases.isEmpty { bases = ["AppIcon60x60"] }
        var names: [String] = []
        for base in bases {
            for suffix in ["@3x.png", "@2x.png", ".png"] { names.append(base + suffix) }
        }
        names.append(contentsOf: ["AppIcon60x60@3x.png", "AppIcon60x60@2x.png",
                                  "AppIcon60x60.png", "AppIcon@3x.png", "AppIcon@2x.png"])
        var seen = Set<String>()
        for name in names where seen.insert(name).inserted {
            let path = appPath + "/" + name
            if let data = try? channel.read(path, maxBytes: 4_000_000),
               let image = UIImage(data: data) {
                return image
            }
        }
        return nil
    }

    // MARK: 取图第二路：拆 Assets.car

    private func carIcon(appPath: String, plist: [String: Any], channel: Channel) -> UIImage? {
        let carPath = appPath + "/Assets.car"
        guard let item = channel.item(at: carPath), item.size > 0,
              item.size <= Self.maxCarBytes,
              let data = try? channel.read(carPath, maxBytes: Int(Self.maxCarBytes)),
              data.count == Int(item.size) else { return nil }
        var base = "AppIcon"
        if let icons = plist["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let name = primary["CFBundleIconName"] as? String, !name.isEmpty {
            base = name
        }
        return CarIconExtractor.extract(data: data, baseName: base)
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

/// Assets.car 里图标 renditions 的提取（已在本机用 LaunchShield 自家和
/// GoldenNugget 两种打包格式的真实文件验证过，拆出的图和包里的原图
/// 逐像素对得上）。格式要点：
/// - 每张图有一份 CSI 头（小端 'CTSI'，文件里字节是 "ISTC"），带名字、
///   宽高、像素格式（BGRA / ARGB）。
/// - 像素按横条切片存，每片是一个 'KCBC' 块：块头后跟一段 LZFSE
///   压缩的原始像素，用系统 Compression 框架解开。
/// - 每行像素按 8 像素对齐补齐，拼图时按解开的实际字节数推每行长度。
enum CarIconExtractor {
    private struct Rendition {
        var offset: Int
        var width: Int
        var height: Int
        var pixelFormat: String
        var name: String
    }

    static func extract(data: Data, baseName: String) -> UIImage? {
        let bytes = [UInt8](data)
        var candidates: [Rendition] = []
        var seen = Set<String>()
        var i = 0
        while i + 168 <= bytes.count {
            if bytes[i] == 0x49, bytes[i + 1] == 0x53, bytes[i + 2] == 0x54, bytes[i + 3] == 0x43,
               le32(bytes, i + 4) == 1 {
                let w = le32(bytes, i + 12), h = le32(bytes, i + 16)
                let pf = String(bytes: Array(bytes[(i + 24)..<(i + 28)]), encoding: .ascii) ?? ""
                if w >= 20, w <= 4096, h >= 20, h <= 4096, pf == "BGRA" || pf == "ARGB" {
                    var nameBytes: [UInt8] = []
                    for j in (i + 40)..<(i + 168) {
                        if bytes[j] == 0 { break }
                        nameBytes.append(bytes[j])
                    }
                    let name = String(bytes: nameBytes, encoding: .utf8) ?? ""
                    if isIconRendition(name: name, base: baseName) {
                        let key = "\(name)|\(w)x\(h)"
                        if seen.insert(key).inserted {
                            candidates.append(Rendition(offset: i, width: w, height: h,
                                                        pixelFormat: pf, name: name))
                        }
                    }
                }
                i += 4
            } else {
                i += 1
            }
        }
        // 选图口径：默认外观（不带 Dark / Tintable）优先；尺寸挑够用的
        // 最小张（>=180），都没有就挑最大张。
        let sorted = candidates.sorted { a, b in
            let pa = appearancePenalty(a.name), pb = appearancePenalty(b.name)
            if pa != pb { return pa < pb }
            return sizeRank(a.width) < sizeRank(b.width)
        }
        for rendition in sorted {
            if let image = decode(bytes: bytes, rendition: rendition) { return image }
        }
        return nil
    }

    private static func isIconRendition(name: String, base: String) -> Bool {
        guard !name.contains("/") else { return false }
        let trimmed = name.hasSuffix(".png") ? String(name.dropLast(4)) : name
        if trimmed == base { return true }
        guard trimmed.hasPrefix(base) else { return false }
        let next = trimmed[trimmed.index(trimmed.startIndex, offsetBy: base.count)]
        // "AppIcon" 后面跟 -、_、. 或数字（AppIcon-light / AppIcon1024…）
        // 才算同一个图标的变体；跟小写字母的是别的名字（如 AppIcons）。
        return next == "-" || next == "_" || next == "." || next.isNumber
    }

    private static func appearancePenalty(_ name: String) -> Int {
        if name.contains("Tintable") { return 4 }
        if name.contains("Dark") { return 2 }
        return 0
    }

    private static func sizeRank(_ width: Int) -> Int {
        // >=180 里越小越优先；<180 的排后面、越大越优先。
        width >= 180 ? width : 100_000 - width
    }

    private static func decode(bytes: [UInt8], rendition r: Rendition) -> UIImage? {
        guard var pos = findChunk(bytes: bytes, from: r.offset + 168,
                                  limit: min(bytes.count, r.offset + 4096)) else { return nil }
        var rowsDone = 0
        var stride = 0
        var pixels = Data()
        while rowsDone < r.height {
            guard pos + 20 <= bytes.count, isKCBC(bytes, pos) else { return nil }
            let rows = le32(bytes, pos + 12)
            let length = le32(bytes, pos + 16)
            let dataOff = pos + 20
            guard rows >= 1, rows <= r.height - rowsDone,
                  length >= 5, dataOff + length <= bytes.count,
                  bytes[dataOff] == 0x62, bytes[dataOff + 1] == 0x76,
                  bytes[dataOff + 2] == 0x78 else { return nil }
            let capacity = rows * (r.width + 64) * 4
            guard let decoded = lzfseDecode(Array(bytes[dataOff..<(dataOff + length)]),
                                            capacity: capacity),
                  decoded.count % rows == 0 else { return nil }
            let rowBytes = decoded.count / rows
            guard rowBytes >= r.width * 4, rowBytes <= (r.width + 64) * 4 else { return nil }
            if stride == 0 { stride = rowBytes } else if stride != rowBytes { return nil }
            pixels.append(decoded)
            rowsDone += rows
            pos = dataOff + length
            if rowsDone < r.height, !isKCBC(bytes, pos) {
                guard let next = findChunk(bytes: bytes, from: pos,
                                           limit: min(bytes.count, pos + 512)) else { return nil }
                pos = next
            }
        }
        guard rowsDone == r.height, stride > 0,
              let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue
            | (r.pixelFormat == "BGRA"
                ? CGBitmapInfo.byteOrder32Little.rawValue
                : CGBitmapInfo.byteOrder32Big.rawValue))
        guard let cg = CGImage(width: r.width, height: r.height,
                               bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: stride,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: bitmapInfo, provider: provider,
                               decode: nil, shouldInterpolate: true,
                               intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// 找下一个结构校验过关的 KCBC 块（行数、长度、数据头和结尾标记都对）。
    private static func findChunk(bytes: [UInt8], from: Int, limit: Int) -> Int? {
        var pos = from
        while pos + 20 <= limit {
            if isKCBC(bytes, pos) {
                let rows = le32(bytes, pos + 12)
                let length = le32(bytes, pos + 16)
                let dataOff = pos + 20
                if rows >= 1, rows <= 4096, length >= 5, dataOff + length <= bytes.count,
                   bytes[dataOff] == 0x62, bytes[dataOff + 1] == 0x76, bytes[dataOff + 2] == 0x78,
                   bytes[dataOff + length - 4] == 0x62, bytes[dataOff + length - 3] == 0x76,
                   bytes[dataOff + length - 2] == 0x78, bytes[dataOff + length - 1] == 0x24 {
                    return pos
                }
            }
            pos += 1
        }
        return nil
    }

    private static func isKCBC(_ bytes: [UInt8], _ pos: Int) -> Bool {
        pos + 4 <= bytes.count
            && bytes[pos] == 0x4B && bytes[pos + 1] == 0x43
            && bytes[pos + 2] == 0x42 && bytes[pos + 3] == 0x43
    }

    private static func le32(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
    }

    private static func lzfseDecode(_ source: [UInt8], capacity: Int) -> Data? {
        var dst = [UInt8](repeating: 0, count: capacity)
        let written = dst.withUnsafeMutableBufferPointer { dstPtr in
            source.withUnsafeBufferPointer { srcPtr in
                compression_decode_buffer(dstPtr.baseAddress!, capacity,
                                          srcPtr.baseAddress!, source.count,
                                          nil, COMPRESSION_LZFSE)
            }
        }
        guard written > 0 else { return nil }
        return Data(dst.prefix(written))
    }
}
