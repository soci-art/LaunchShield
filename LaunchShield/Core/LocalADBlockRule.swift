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
enum LocalADBlockRule {
    static let dynamicSplashBundleID = "com.baidu.netdisk"
    static let dynamicSplashDisplayName = "百度网盘"

    static let preferencesPath = "Library/Preferences/com.baidu.netdisk.plist"
    static let splashCacheRoot = "Library/Caches/com.hackemist.SDImageCache/default"
    static let splashKeyPrefix = "kBDNCSplashLastAdsFormat_"

    /// 分组名单改由 RulesStore 提供：内置保底一份，用户点「更新规则」
    /// 下载到新名单后，这里自动跟着换。
    static var thirdPartyCacheGroups: [(group: String, directories: [String])] {
        RulesStore.groups
    }

    /// 广告商的专属文件夹本身（包括空文件夹和所有子文件夹），相对路径，深的在前。
    /// 清零后把这些文件夹也冻上，广告商就没法在里面新建文件备货。
    /// 只含上面各家的专属目录，绝不含公共目录（图片缓存、default、tmp 本身都不在内）。
    static func freezeDirectories(container: String, channel: Channel, ownerBundleID: String = dynamicSplashBundleID) -> [String] {
        var result: [String] = []
        for group in thirdPartyCacheGroups {
            for directory in group.directories {
                let root = container + "/" + directory
                guard let item = channel.item(at: root), item.isDirectory, !item.isSymlink else { continue }
                result.append(directory)
                collectSubdirectories(container: container, relative: directory, channel: channel, into: &result)
            }
        }
        for relative in erosionMatchedDirectoryPaths(container: container, channel: channel, ownerBundleID: ownerBundleID) {
            guard let item = channel.item(at: container + "/" + relative), item.isDirectory, !item.isSymlink else { continue }
            result.append(relative)
            collectSubdirectories(container: container, relative: relative, channel: channel, into: &result)
        }
        let unique = Array(Set(result))
        // 深的先冻：先冻子文件夹，再冻外层文件夹。
        return unique.sorted { $0.components(separatedBy: "/").count > $1.components(separatedBy: "/").count }
    }

    private static func collectSubdirectories(container: String, relative: String, channel: Channel, into: inout [String]) {
        guard let items = try? channel.children(of: container + "/" + relative) else { return }
        for item in items where item.isDirectory && !item.isSymlink && !neverTouchOrDescend.contains(item.name.lowercased()) {
            let child = relative + "/" + item.name
            into.append(child)
            collectSubdirectories(container: container, relative: child, channel: channel, into: &into)
        }
    }

    // MARK: - Splash derivation

    static func resolveSelfSoldSplash(container: String, channel: Channel) -> SplashResolution? {
        let prefsPath = container + "/" + preferencesPath
        guard let prefsItem = channel.item(at: prefsPath),
              !prefsItem.isDirectory, !prefsItem.isSymlink else { return nil }
        guard let data = try? channel.read(prefsPath, maxBytes: 16 * 1024 * 1024) else { return nil }
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
            return nil
        }
        let cacheRoot = container + "/" + splashCacheRoot
        guard let cacheItem = channel.item(at: cacheRoot),
              cacheItem.isDirectory, !cacheItem.isSymlink else { return nil }
        let cachedFiles = (try? channel.children(of: cacheRoot))?.filter { !$0.isDirectory && !$0.isSymlink } ?? []

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


    // Container safety exclusions.
    private static let protectedBundleIDs: Set<String> = [
        "com.jbdotparty.Erosion", "com.apple.PosterBoard", "com.apple.springboard",
        "com.apple.Preferences", "com.apple.mobilephone"
    ]
    private static let ignoredAppGroupPrefixes: [String] = [
        "group.com.apple.", "systemgroup.", "group.com.jbdotparty.",
        "group.com.nssurge.", "group.com.liguangming.", "group.com.luo.",
        "group.com.loon", "group.ws.stash."
    ]

    static func shouldIgnoreAppGroup(_ bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        return ignoredAppGroupPrefixes.contains { lower.hasPrefix($0) }
    }

    // MARK: - Built-in local rule data
    // Curated per-app splash & ad cache candidate subpaths (only reported when verified present on disk)
    private static let appSpecificAdPaths: [String: [(relPath: String, zh: String, en: String)]] = [
        "com.sina.weibo": [
            ("Documents/wb_ad_cache", "微博开屏广告缓存", "Weibo Splash Ad Cache"),
            ("Library/Caches/wb_ad_cache", "微博开屏广告缓存", "Weibo Splash Ad Cache"),
            ("Documents/WBAdCache", "微博广告素材缓存", "Weibo Ad Asset Cache"),
            ("Library/Caches/WBAdCache", "微博广告素材缓存", "Weibo Ad Asset Cache"),
            ("Library/Caches/wbad_splash", "微博开屏素材", "Weibo Splash Assets")
        ],
        "com.sina.weibolite": [
            ("Documents/wb_ad_cache", "微博轻享版广告缓存", "Weibo Lite Ad Cache"),
            ("Library/Caches/wb_ad_cache", "微博轻享版广告缓存", "Weibo Lite Ad Cache"),
            ("Library/Caches/WBAdCache", "微博广告缓存", "Weibo Ad Cache")
        ],
        "com.zhihu.ios": [
            ("Library/Caches/ZHAdCache", "知乎开屏广告缓存", "Zhihu Splash Ad Cache"),
            ("Library/Caches/ZHSplashAd", "知乎开屏广告", "Zhihu Splash Ad"),
            ("Documents/ZHAdCache", "知乎广告缓存", "Zhihu Ad Cache"),
            ("Library/Caches/LaunchAdCache", "知乎启动广告缓存", "Zhihu Launch Ad Cache")
        ],
        "com.netease.cloudmusic": [
            ("Library/Caches/NEAdCache", "网易云开屏广告缓存", "NetEase Music Ad Cache"),
            ("Library/Caches/AdCache", "网易云广告缓存", "NetEase Ad Cache"),
            ("Documents/AdCache", "网易云广告缓存", "NetEase Ad Cache")
        ],
        "com.tencent.QQMusic": [
            ("Library/Caches/QMAdCache", "QQ音乐开屏广告缓存", "QQ Music Ad Cache"),
            ("Documents/QMAdCache", "QQ音乐广告缓存", "QQ Music Ad Cache"),
            ("Library/Caches/TADCache", "腾讯广告缓存 (TAD)", "Tencent Ad Cache (TAD)")
        ],
        "tv.danmaku.bilianime": [
            ("Library/Caches/SplashAd", "B站开屏广告缓存", "Bilibili Splash Ad"),
            ("Library/Caches/BiliSplashAd", "B站开屏广告", "Bilibili Splash Ad"),
            ("Documents/SplashAd", "B站开屏广告", "Bilibili Splash Ad")
        ],
        "com.bilibili.app.in": [
            ("Library/Caches/SplashAd", "B站国际版开屏广告", "Bilibili Intl Splash Ad")
        ],
        "com.xingin.discover": [
            ("Library/Caches/XYAdCache", "小红书广告缓存", "Rednote Ad Cache"),
            ("Library/Caches/XHSSplashAd", "小红书开屏广告", "Rednote Splash Ad")
        ],
        "com.taobao.taobao4iphone": [
            ("Documents/TBDocuments/bootImagebiz", "淘宝开屏启动配置 (bootImagebiz)", "Taobao Boot Splash Config (bootImagebiz)"),
            ("Documents/TBDocuments/bootImageDoc", "淘宝开屏启动缓存 (bootImageDoc)", "Taobao Boot Splash Assets (bootImageDoc)"),
            ("Library/Caches/TanxAd", "阿里妈妈 Tanx 广告", "Alimama Tanx Ad"),
            ("Library/Caches/TanxSDK", "阿里妈妈 Tanx SDK", "Alimama Tanx SDK"),
            ("Documents/SplashAd", "淘宝开屏广告", "Taobao Splash Ad")
        ],
        "com.taobao.fleamarket": [
            ("Library/Caches/TanxAd", "闲鱼 Tanx 广告缓存", "Idlefish Tanx Ad"),
            ("Library/Caches/SplashAd", "闲鱼开屏广告", "Idlefish Splash Ad")
        ],
        "com.jingdong.app.mall": [
            ("Library/Caches/JADYun", "京东直投广告 SDK", "JD JADYun Ad SDK"),
            ("Library/Caches/JDAdSDK", "京东广告 SDK", "JD Ad SDK")
        ],
        "com.meituan.imeituan": [
            ("Library/Caches/MTSplashAd", "美团开屏广告", "Meituan Splash Ad"),
            ("Library/Caches/SplashAd", "美团开屏广告缓存", "Meituan Splash Cache")
        ],
        "com.dianping.dpscope": [
            ("Library/Caches/DPSplashAd", "大众点评开屏广告", "Dianping Splash Ad"),
            ("Library/Caches/SplashAd", "大众点评广告缓存", "Dianping Splash Cache")
        ],
        "com.autonavi.amap": [
            ("Library/Caches/AmapSplashAd", "高德开屏广告", "Amap Splash Ad"),
            ("Library/Caches/SplashAd", "高德广告缓存", "Amap Splash Cache")
        ],
        "com.baidu.BaiduMobile": [
            ("Library/Caches/BaiduMobAd", "百度百青藤广告", "Baidu MobAd"),
            ("Library/Caches/BDAdCache", "百度开屏广告缓存", "Baidu Ad Cache")
        ],
        "com.baidu.tieba": [
            ("Library/Caches/BaiduMobAd", "贴吧百青藤广告", "Tieba BaiduMobAd"),
            ("Library/Caches/TBAdCache", "贴吧广告缓存", "Tieba Ad Cache")
        ],
        "com.baidu.netdisk": [
            ("Library/Caches/BaiduMobAd", "网盘百青藤广告", "Netdisk BaiduMobAd"),
            ("Library/Caches/BDSplashAd", "网盘开屏广告", "Netdisk Splash Ad")
        ],
        "com.gemd.iting": [
            ("Library/Caches/XMLYAdCache", "喜马拉雅广告缓存", "Ximalaya Ad Cache"),
            ("Documents/XMLYAdCache", "喜马拉雅广告缓存", "Ximalaya Ad Cache")
        ],
        "com.hupu.games": [
            ("Library/Caches/HupuAdCache", "虎扑开屏广告", "Hupu Ad Cache")
        ],
        "com.douban.frodo": [
            ("Library/Caches/DoubanAdCache", "豆瓣开屏广告", "Douban Ad Cache")
        ]
    ]

    // Critical guard: never touch or descend into iOS launch snapshots, WebKit, cookies, or user downloads
    private static let neverTouchOrDescend: Set<String> = [
        "splashboard",
        "webkit",
        "fscacheddata",
        "com.apple.nsurlsessiond",
        "cookies",
        "httpstorages",
        "preferences",
        "saved application state",
        "cloudkit",
        "snapshots",
        "flutter_assets",
        "downloads",
        "download",
        "uploads",
        "upload",
        "preload",
        "shaders",
        "shadercache",
        "metadata",
        "payload",
        "avatars",
        "database",
        "databases"
    ]

    // Curated lowercased folder names of mainstream iOS Splash & Ad SDKs
    private static let exactAdSDKMap: [String: (zh: String, en: String)] = [
        "ksadsdk": ("快手广告 SDK (KSAdSDK)", "Kwai Ad SDK (KSAdSDK)"),
        "ksadcache": ("快手广告缓存", "Kwai Ad Cache"),
        "ksad_cache": ("快手广告缓存", "Kwai Ad Cache"),
        "com.kwad.sdk": ("快手联盟 (Kwad)", "Kwai Ad SDK"),
        "kwadsdk": ("快手联盟 SDK", "Kwad SDK"),
        "buadsdk": ("穿山甲广告 (BUAdSDK)", "Pangle / CSJ (BUAdSDK)"),
        "csjadsdk": ("穿山甲广告 SDK", "CSJ Ad SDK"),
        "csjadcache": ("穿山甲广告缓存", "CSJ Ad Cache"),
        "pangle_sdk": ("穿山甲 Pangle SDK", "Pangle Ad SDK"),
        "panglesdk": ("穿山甲 Pangle SDK", "Pangle Ad SDK"),
        "bytedancead": ("字节广告缓存", "ByteDance Ad Cache"),
        "ttadsdk": ("字节穿山甲 (TTAdSDK)", "ByteDance TTAdSDK"),
        "pangolinad": ("穿山甲广告 (Pangolin)", "Pangolin Ad Cache"),
        "gromoread": ("GroMore 聚合广告", "GroMore Ad SDK"),
        "gdtmobsdk": ("腾讯优量汇 (GDTMobSDK)", "Tencent YLH (GDTMobSDK)"),
        "gdt_splash": ("优量汇开屏缓存", "GDT Splash Cache"),
        "gdtsplash": ("优量汇开屏缓存", "GDT Splash Cache"),
        "gdtadcache": ("优量汇广告缓存", "GDT Ad Cache"),
        "gdtnetcache": ("优量汇网络缓存", "GDT Net Cache"),
        "tadcache": ("腾讯广告缓存 (TADCache)", "Tencent Ad Cache (TAD)"),
        "tencentad": ("腾讯广告缓存", "Tencent Ad Cache"),
        "qq_ad_cache": ("腾讯广告缓存", "QQ Ad Cache"),
        "ylhadsdk": ("优量汇广告 SDK", "YLH Ad SDK"),
        "baidumobad": ("百度百青藤广告", "Baidu MobAd SDK"),
        "bd_ad_cache": ("百度广告缓存", "Baidu Ad Cache"),
        "baidusplashad": ("百度开屏广告", "Baidu Splash Ad"),
        "bdsplashad": ("开屏广告缓存 (BDSplashAd)", "Splash Ad Cache (BDSplashAd)"),
        "beizisdk": ("倍孜开屏广告 (BeiZi)", "BeiZi Ad SDK"),
        "beiziad": ("倍孜广告缓存 (BeiZi)", "BeiZi Ad Cache"),
        "octopusad": ("章鱼广告 (OctopusAd)", "Octopus Ad SDK"),
        "jadyun": ("京东直投广告 (JADYun)", "JD JADYun Ad SDK"),
        "jdadsdk": ("京东广告 SDK", "JD Ad SDK"),
        "sigmob": ("Sigmob 广告 SDK", "Sigmob Ad SDK"),
        "windadsdk": ("Sigmob / WindAd", "WindAd SDK"),
        "windad": ("WindAd 广告缓存", "WindAd Cache"),
        "anythinksdk": ("TopOn 聚合广告 (AnyThink)", "TopOn / AnyThink SDK"),
        "toponsdk": ("TopOn 聚合广告 SDK", "TopOn Ad SDK"),
        "tradplus": ("TradPlus 聚合广告", "TradPlus Ad SDK"),
        "mintegral": ("Mintegral 广告 SDK", "Mintegral Ad SDK"),
        "mtgadcache": ("Mintegral 广告缓存", "Mintegral Ad Cache"),
        "tanxad": ("阿里妈妈 Tanx 广告", "Alimama Tanx Ad"),
        "tanxsdk": ("阿里妈妈 Tanx SDK", "Alimama Tanx SDK"),
        "sakuraad": ("樱花广告 SDK", "SakuraAd SDK"),
        "ubixad": ("优比客思广告 (UbixAd)", "UbixAd SDK"),
        "qumengad": ("趣盟广告 (QuMeng)", "QuMeng Ad SDK"),
        "googlemobileads": ("Google Mobile Ads", "Google Mobile Ads"),
        "gadcache": ("Google AdMob 缓存", "Google AdMob Cache"),
        "unityads": ("Unity Ads 缓存", "Unity Ads Cache"),
        "unityadscache": ("Unity Ads 缓存", "Unity Ads Cache"),
        "vunglecache": ("Vungle 广告缓存", "Vungle Ad Cache"),
        "vungle_cache": ("Vungle 广告缓存", "Vungle Ad Cache"),
        "applovin": ("AppLovin 广告缓存", "AppLovin Ad Cache"),
        "chartboost": ("Chartboost 广告缓存", "Chartboost Ad Cache"),
        "inmobicache": ("InMobi 广告缓存", "InMobi Ad Cache"),
        "ironsource": ("ironSource 广告缓存", "ironSource Ad Cache"),
        "splashad": ("开屏广告缓存", "Splash Ad Cache"),
        "splashads": ("开屏广告缓存", "Splash Ads Cache"),
        "splashadcache": ("开屏广告缓存", "Splash Ad Cache"),
        "splash_ad": ("开屏广告缓存", "Splash Ad Cache"),
        "splash_ads": ("开屏广告缓存", "Splash Ads Cache"),
        "splashscreenad": ("开屏广告缓存", "Splash Screen Ad"),
        "launchad": ("启动开屏广告", "Launch Ad Cache"),
        "launchads": ("启动开屏广告", "Launch Ads Cache"),
        "launchadcache": ("启动广告缓存", "Launch Ad Cache"),
        "launch_ad": ("启动广告缓存", "Launch Ad Cache"),
        "xhlaunchadcache": ("XHLaunchAd 开屏广告", "XHLaunchAd Cache"),
        "xhlaunchad": ("XHLaunchAd 开屏广告", "XHLaunchAd Cache"),
        "jwlaunchad": ("JWLaunchAd 开屏广告", "JWLaunchAd Cache"),
        "openscreenad": ("开屏广告目录", "Open Screen Ad"),
        "open_screen_ad": ("开屏广告目录", "Open Screen Ad"),
        "adsplash": ("开屏广告目录", "Ad Splash Cache"),
        "adcache": ("应用内广告缓存", "App Ad Cache"),
        "adscache": ("应用内广告缓存", "App Ads Cache"),
        "ad_cache": ("应用内广告缓存", "App Ad Cache"),
        "ads_cache": ("应用内广告缓存", "App Ads Cache"),
        "advertisingcache": ("广告缓存目录", "Advertising Cache"),
        "startupad": ("启动广告缓存", "Startup Ad Cache"),
        "startupads": ("启动广告缓存", "Startup Ads Cache"),
        "bootad": ("开机广告缓存", "Boot Ad Cache"),
        "wb_ad_cache": ("微博开屏广告缓存", "Weibo Ad Cache"),
        "wbadcache": ("微博广告缓存", "Weibo Ad Cache"),
        "zhadcache": ("知乎广告缓存", "Zhihu Ad Cache"),
        "xyadcache": ("小红书广告缓存", "Rednote Ad Cache"),
        "qmadcache": ("QQ音乐广告缓存", "QQ Music Ad Cache"),
        "xmlyadcache": ("喜马拉雅广告缓存", "Ximalaya Ad Cache")
    ]


    // Curated lowercased single splash/ad config filenames
    private static let exactAdConfigFiles: [String: (zh: String, en: String)] = [
        "splash_ad.json": ("开屏广告配置 (JSON)", "Splash Ad Config (JSON)"),
        "splashad.json": ("开屏广告配置 (JSON)", "Splash Ad Config (JSON)"),
        "splash_ads.json": ("开屏广告配置 (JSON)", "Splash Ads Config (JSON)"),
        "splash_cache.json": ("开屏广告索引 (JSON)", "Splash Cache Index (JSON)"),
        "launch_ad.json": ("启动广告配置 (JSON)", "Launch Ad Config (JSON)"),
        "launchad.json": ("启动广告配置 (JSON)", "Launch Ad Config (JSON)"),
        "open_screen_ad.json": ("开屏广告配置 (JSON)", "Open Screen Ad Config (JSON)"),
        "ad_splash.json": ("开屏广告配置 (JSON)", "Ad Splash Config (JSON)"),
        "wb_splash_ad.json": ("微博开屏配置 (JSON)", "Weibo Splash Config (JSON)"),
        "splash_ad.plist": ("开屏广告配置 (Plist)", "Splash Ad Config (Plist)"),
        "splashad.plist": ("开屏广告配置 (Plist)", "Splash Ad Config (Plist)"),
        "launch_ad.plist": ("启动广告配置 (Plist)", "Launch Ad Config (Plist)"),
        "xhlaunchad.plist": ("XHLaunchAd 配置 (Plist)", "XHLaunchAd Config (Plist)"),
        "ad_splash.plist": ("开屏广告配置 (Plist)", "Ad Splash Config (Plist)"),
        "wb_ad_cache.plist": ("微博广告配置 (Plist)", "Weibo Ad Config (Plist)")
    ]

    private static func classifyAdFolder(name: String) -> (zh: String, en: String)? {
        let lower = name.lowercased()
        if neverTouchOrDescend.contains(lower) { return nil }
        if let exact = exactAdSDKMap[lower] { return exact }
        let tokens = splitBoundaryTokens(name)
        guard tokens.contains("ad") || tokens.contains("ads") else { return nil }
        let modifiers: Set<String> = ["sdk", "splash", "launch", "cache", "banner", "interstitial", "mob"]
        guard tokens.contains(where: { modifiers.contains($0) }) else { return nil }
        return ("广告缓存目录 (\(name))", "Ad Cache (\(name))")
    }

    private static func splitBoundaryTokens(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        let scalars = Array(raw.unicodeScalars)
        for i in scalars.indices {
            let scalar = scalars[i]
            if scalar == "_" || scalar == "-" || scalar == "." || scalar == " " {
                if !current.isEmpty { tokens.append(current.lowercased()); current.removeAll(keepingCapacity: true) }
                continue
            }
            let upper = scalar.value >= 65 && scalar.value <= 90
            if upper && !current.isEmpty {
                let previous = scalars[i - 1]
                let previousLower = previous.value >= 97 && previous.value <= 122
                let nextLower = i + 1 < scalars.count && scalars[i + 1].value >= 97 && scalars[i + 1].value <= 122
                if previousLower || nextLower {
                    tokens.append(current.lowercased())
                    current.removeAll(keepingCapacity: true)
                }
            }
            current.unicodeScalars.append(scalar)
        }
        if !current.isEmpty { tokens.append(current.lowercased()) }
        return tokens
    }

    private static func erosionMatchedDirectoryPaths(container: String, channel: Channel, ownerBundleID: String) -> [String] {
        var paths: [String] = []
        for spec in appSpecificAdPaths[ownerBundleID] ?? [] {
            if let item = try? channel.inspectItem(at: container + "/" + spec.relPath), let item, item.isDirectory, !item.isSymlink {
                paths.append(spec.relPath)
            }
        }
        func walk(_ directory: String, relative: String, depth: Int) {
            guard depth <= 2,
                  let rootItem = channel.item(at: directory),
                  rootItem.isDirectory, !rootItem.isSymlink,
                  let items = try? channel.children(of: directory) else { return }
            for item in items where item.isDirectory && !item.isSymlink {
                let lower = item.name.lowercased()
                if lower.hasPrefix(".") || neverTouchOrDescend.contains(lower) { continue }
                let childRelative = relative + "/" + item.name
                if classifyAdFolder(name: item.name) != nil {
                    paths.append(childRelative)
                } else if depth < 2 {
                    walk(item.path, relative: childRelative, depth: depth + 1)
                }
            }
        }
        for root in ["Documents", "Library/Caches", "Library/Application Support", "tmp"] {
            walk(container + "/" + root, relative: root, depth: 0)
        }
        return Array(Set(paths))
    }

    private static func erosionCandidates(container: String, channel: Channel, ownerBundleID: String) -> [(FileItem, String, String)] {
        var result: [(FileItem, String, String)] = []
        var seen = Set<String>()

        // Per-app rules: only evaluate paths against their matching bundle ID.
        for spec in appSpecificAdPaths[ownerBundleID] ?? [] {
            let path = container + "/" + spec.relPath
            if channel.isDirectory(path) {
                for file in files(below: path, channel: channel, depth: 0, limit: 4000) where seen.insert(file.path).inserted {
                    result.append((file, "本地广告规则", spec.zh))
                }
            } else if let item = channel.item(at: path), !item.isDirectory, !item.isSymlink, seen.insert(item.path).inserted {
                result.append((item, "本地广告规则", spec.zh))
            }
        }

        // SDK/config rules: shallow scan only the standard app data roots.
        func walk(_ directory: String, depth: Int) {
            guard depth <= 2, let items = try? channel.children(of: directory) else { return }
            for item in items {
                if item.isSymlink { continue }
                let lower = item.name.lowercased()
                if neverTouchOrDescend.contains(lower) { continue }
                if item.isDirectory {
                    if let match = classifyAdFolder(name: item.name) {
                        for file in files(below: item.path, channel: channel, depth: 0, limit: 4000) where seen.insert(file.path).inserted {
                            result.append((file, "本地广告规则", match.zh))
                        }
                    } else if depth < 2 {
                        walk(item.path, depth: depth + 1)
                    }
                } else if let match = exactAdConfigFiles[lower], seen.insert(item.path).inserted {
                    result.append((item, "本地广告规则", match.zh))
                }
            }
        }
        for relative in ["Documents", "Library/Caches", "Library/Application Support", "tmp"] {
            walk(container + "/" + relative, depth: 0)
        }
        return result
    }

    // MARK: - Clear list

    /// 扫一个应用的容器：软件自营只对百度网盘推导（传 splash），
    /// 第三方 SDK 分组对任何应用都一样适用（传该应用的归属信息即可）。
    static func targets(container: String, channel: Channel, splash: SplashResolution?,
                        ownerBundleID: String = dynamicSplashBundleID, ownerName: String = dynamicSplashDisplayName,
                        onVisit: (() -> Void)? = nil) -> [TargetFile] {
        guard !protectedBundleIDs.contains(ownerBundleID) else { return [] }
        var result: [TargetFile] = []
        var seen = Set<String>()

        func append(_ item: FileItem, group: String, note: String) {
            guard !item.isSymlink, !item.isDirectory, !seen.contains(item.path) else { return }
            seen.insert(item.path)
            result.append(TargetFile(path: item.path,
                                     relativePath: relativePath(container: container, path: item.path),
                                     group: group,
                                     note: note,
                                     size: item.size,
                                     isSmallConfig: group == "BeiZi" && item.size < 4096,
                                     bundleID: ownerBundleID,
                                     appName: ownerName))
        }

        if let splash, splash.exists, let item = channel.item(at: splash.path), !item.isDirectory, !item.isSymlink {
            append(item,
                   group: "软件自营",
                   note: "按广告记录动态推导")
        }

        for group in thirdPartyCacheGroups {
            for directory in group.directories {
                let root = container + "/" + directory
                for item in files(below: root, channel: channel, depth: 0, limit: 4000, onVisit: onVisit) {
                    append(item, group: group.group, note: item.size < 4096 ? "清单小文件" : "")
                }
            }
        }

        for (item, group, note) in erosionCandidates(container: container, channel: channel, ownerBundleID: ownerBundleID) {
            append(item, group: group, note: note)
        }

        // LaunchHack 用户确认的单文件规则，按宿主 App 与精确相对路径匹配。
        for rule in RulesStore.localCandidates(for: ownerBundleID) {
            let fullPath = container + "/" + rule.relativePath
            guard let item = channel.item(at: fullPath), !item.isDirectory, !item.isSymlink else { continue }
            append(item, group: "LaunchHack 本地规则", note: "用户确认的本地识别规则")
        }
        return result
    }

    private static func files(below directory: String, channel: Channel, depth: Int, limit: Int,
                              onVisit: (() -> Void)? = nil) -> [FileItem] {
        guard depth < 6,
              let rootItem = channel.item(at: directory),
              rootItem.isDirectory, !rootItem.isSymlink else { return [] }
        guard let items = try? channel.children(of: directory) else { return [] }
        var result: [FileItem] = []
        for item in items {
            onVisit?()
            if item.isSymlink { continue }
            if item.isDirectory {
                if neverTouchOrDescend.contains(item.name.lowercased()) { continue }
                result.append(contentsOf: files(below: item.path, channel: channel, depth: depth + 1, limit: limit, onVisit: onVisit))
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
            if let item = channel.item(at: path), !item.isDirectory, !item.isSymlink { return path }
        }
        for item in cached where !item.isDirectory && !item.isSymlink {
            let stem = (item.name as NSString).deletingPathExtension.lowercased()
            if stem == md5 { return item.path }
        }
        return nil
    }
}
