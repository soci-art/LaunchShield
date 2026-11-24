//
//  WQAppCatalog.m
//  LaunchShield
//
//  GPL-3.0-or-later. Display names only; container discovery lives in
//  WQChannel and goes through the container manager.
//

#import "WQAppCatalog.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"

static NSDictionary<NSString *, NSString *> *gNames;
static NSDictionary<NSString *, NSString *> *gCategories;
static NSSet<NSString *> *gMainAppIDs;
static NSSet<NSString *> *gExtensionIDs;
static BOOL gCatalogLoaded;

static NSArray<NSString *> *wq_name_probe_ids(void) {
    return @[@"com.apple.mobilesafari", @"com.apple.Preferences",
             @"com.apple.camera", @"com.apple.mobilenotes", @"cn.12306.rails12306",
             @"com.alipay.iphoneclient", @"com.360buy.jdmobile", @"com.tencent.xin",
             @"com.autonavi.amap"];
}

// Read installed apps' names from the bundles themselves: every .app's
// Info.plist carries its bundle id and name, and the Simplified Chinese
// strings file carries the localized display name. The bundle roots only
// list once the sandbox is open (the kernel route on iOS 17/18, where the
// workspace walk below returns nothing); before that this finds nothing
// and the catalog simply stays empty until the post-escape reload.
static void wq_scan_bundle_plists(NSMutableDictionary<NSString *, NSString *> *names,
                                  NSMutableSet<NSString *> *mainIDs)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *appDirs = [NSMutableArray new];
    NSString *userRoot = @"/private/var/containers/Bundle/Application";
    for (NSString *uuid in [fm contentsOfDirectoryAtPath:userRoot error:nil]) {
        NSString *dir = [userRoot stringByAppendingPathComponent:uuid];
        for (NSString *entry in [fm contentsOfDirectoryAtPath:dir error:nil])
            if ([entry hasSuffix:@".app"]) [appDirs addObject:[dir stringByAppendingPathComponent:entry]];
    }
    for (NSString *root in @[@"/System/Applications", @"/Applications"])
        for (NSString *entry in [fm contentsOfDirectoryAtPath:root error:nil])
            if ([entry hasSuffix:@".app"]) [appDirs addObject:[root stringByAppendingPathComponent:entry]];
    NSUInteger named = 0;
    for (NSString *appDir in appDirs) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
            [appDir stringByAppendingPathComponent:@"Info.plist"]];
        NSString *bid = info[@"CFBundleIdentifier"];
        if (![bid isKindOfClass:NSString.class] || !bid.length) continue;
        [mainIDs addObject:bid];
        if (names[bid]) continue;
        NSString *name = nil;
        for (NSString *lproj in @[@"zh-Hans.lproj", @"zh-CN.lproj"]) {
            NSData *data = [NSData dataWithContentsOfFile:
                [[appDir stringByAppendingPathComponent:lproj]
                    stringByAppendingPathComponent:@"InfoPlist.strings"]];
            if (!data) continue;
            id parsed = [NSPropertyListSerialization propertyListWithData:data
                options:0 format:nil error:nil];
            if ([parsed isKindOfClass:NSDictionary.class]) {
                NSString *localized = parsed[@"CFBundleDisplayName"] ?: parsed[@"CFBundleName"];
                if ([localized isKindOfClass:NSString.class] && localized.length) {
                    name = localized;
                    break;
                }
            }
        }
        if (!name) {
            NSString *display = info[@"CFBundleDisplayName"];
            NSString *plain = info[@"CFBundleName"];
            name = ([display isKindOfClass:NSString.class] && display.length) ? display
                 : ([plain isKindOfClass:NSString.class] && plain.length) ? plain : nil;
        }
        if (name) {
            names[bid] = name;
            named++;
        }
    }
    wq_log(@"app catalog: bundle plists scanned %lu bundles, %lu names",
           (unsigned long)appDirs.count, (unsigned long)named);
}

static NSLock *wq_catalog_lock(void) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });
    return lock;
}

void wq_app_catalog_invalidate(void) {
    NSLock *lock = wq_catalog_lock();
    [lock lock];
    gCatalogLoaded = NO;
    gNames = nil;
    gCategories = nil;
    gMainAppIDs = nil;
    gExtensionIDs = nil;
    [lock unlock];
}

NSDictionary<NSString *, NSString *> *wq_app_categories(void)
{
    // Populated as a side effect of the display-name pass below.
    (void)wq_app_display_names();
    return gCategories ?: @{};
}

NSSet<NSString *> *wq_main_app_bundle_ids(void)
{
    (void)wq_app_display_names();
    NSSet<NSString *> *ids = gMainAppIDs ?: [NSSet set];
    if (!ids.count) {
        // The workspace walk can return nothing even with the sandbox open
        // (seen on iOS 18: 0 ids after the kernel escape, first run included).
        // The parsed LaunchServices store classifies its containers itself;
        // use its app set when the walk has none.
        NSSet<NSString *> *storeIDs = wq_ls_main_app_bundle_ids();
        if (storeIDs.count) {
            // Logged once per process: this getter runs once per container
            // per picker pass, and a line per call flooded the persisted
            // log and froze the UI on iOS 18 (build 14).
            static BOOL logged = NO;
            if (!logged) {
                logged = YES;
                wq_log(@"app catalog: the walk found no app ids; using the store app set (%lu ids)",
                       (unsigned long)storeIDs.count);
            }
            return storeIDs;
        }
    }
    return ids;
}

NSSet<NSString *> *wq_extension_bundle_ids(void)
{
    (void)wq_app_display_names();
    NSSet<NSString *> *ids = gExtensionIDs ?: [NSSet set];
    if (!ids.count) {
        // Same fallback as the app set: the store's plug-in containers.
        NSSet<NSString *> *storeIDs = wq_ls_extension_bundle_ids();
        if (storeIDs.count) {
            // Once per process, same reason as the app set above.
            static BOOL logged = NO;
            if (!logged) {
                logged = YES;
                wq_log(@"app catalog: the walk found no extension ids; using the store extension set (%lu ids)",
                       (unsigned long)storeIDs.count);
            }
            return storeIDs;
        }
    }
    return ids;
}

NSDictionary<NSString *, NSString *> *wq_app_display_names(void)
{
    NSLock *lock = wq_catalog_lock();
    [lock lock];
    if (!gCatalogLoaded) {
        NSMutableDictionary<NSString *, NSString *> *names = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSString *> *categories = [NSMutableDictionary dictionary];
        NSMutableSet<NSString *> *mainIDs = [NSMutableSet set];
        NSMutableSet<NSString *> *extensionIDs = [NSMutableSet set];
        @try {
            Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
            if (workspaceClass) {
                id workspace = nil;
                if ([workspaceClass respondsToSelector:@selector(defaultWorkspace)]) {
                    workspace = [workspaceClass performSelector:@selector(defaultWorkspace)];
                }
                NSArray *apps = nil;
                if ([workspace respondsToSelector:@selector(allApplications)]) {
                    apps = [workspace performSelector:@selector(allApplications)];
                }
                if (!apps.count && [workspace respondsToSelector:@selector(allInstalledApplications)]) {
                    apps = [workspace performSelector:@selector(allInstalledApplications)];
                }
                for (id app in apps) {
                    NSString *bundleID = nil;
                    NSString *name = nil;
                    @try {
                        bundleID = [app valueForKey:@"bundleIdentifier"];
                        name = [app valueForKey:@"localizedName"];
                        if (![name isKindOfClass:NSString.class] || !name.length) name = [app valueForKey:@"itemName"];
                        id category = nil;
                        @try { category = [app valueForKey:@"applicationCategory"]; } @catch (NSException *e) { }
                        if (![category isKindOfClass:NSString.class] || ![category length]) {
                            @try { category = [app valueForKey:@"category"]; } @catch (NSException *e) { }
                        }
                        if ([bundleID isKindOfClass:NSString.class] && bundleID.length) {
                            [mainIDs addObject:bundleID];
                        }
                        // allApplications can include plug-ins on iOS 18; the
                        // per-app plugInKitPlugins list is the authoritative
                        // extension set (and is what the LS full scan counts).
                        SEL pluginsSel = NSSelectorFromString(@"plugInKitPlugins");
                        if ([app respondsToSelector:pluginsSel]) {
                            @try {
                                NSArray *plugins = [app performSelector:pluginsSel];
                                for (id plugin in [plugins isKindOfClass:NSArray.class] ? plugins : @[]) {
                                    NSString *pid = [plugin valueForKey:@"bundleIdentifier"];
                                    if ([pid isKindOfClass:NSString.class] && pid.length) {
                                        [extensionIDs addObject:pid];
                                    }
                                }
                            } @catch (NSException *e) { }
                        }
                        if ([bundleID isKindOfClass:NSString.class] && bundleID.length &&
                            [category isKindOfClass:NSString.class] && [category length]) {
                            categories[bundleID] = category;
                        }
                    } @catch (NSException *exception) {
                        continue;
                    }
                    if ([bundleID isKindOfClass:NSString.class] && bundleID.length &&
                        [name isKindOfClass:NSString.class] && name.length) {
                        names[bundleID] = name;
                    }
                }
            }
        } @catch (NSException *exception) {
            wq_log(@"app names: LaunchServices unavailable (%@)", exception.reason);
        }
        if (!names.count) {
            // The workspace walk returned nothing (iOS 17/18 kernel route:
            // 0 ids even after the escape). Fall back to the bundles' own
            // Info.plists, which the open sandbox lets us read directly.
            wq_scan_bundle_plists(names, mainIDs);
        }
        gNames = [names copy];
        gCategories = [categories copy];
        gMainAppIDs = [mainIDs copy];
        gExtensionIDs = [extensionIDs copy];
        wq_log(@"app catalog: %lu app ids, %lu extension ids", (unsigned long)mainIDs.count, (unsigned long)extensionIDs.count);
        {
            NSMutableArray *parts = [NSMutableArray new];
            for (NSString *bid in wq_name_probe_ids())
                [parts addObject:[NSString stringWithFormat:@"%@=%@", bid, names[bid] ?: @"-"]];
            wq_log(@"app catalog: name probes: %@", [parts componentsJoinedByString:@", "]);
        }
        // Probe: the workspace enumeration returns empty on the kernel
        // route, but a per-id proxy lookup goes through a different path
        // and may still answer. Log what it gives for well-known ids.
        @try {
            Class proxyClass = NSClassFromString(@"LSApplicationProxy");
            if (proxyClass && [proxyClass respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
                NSMutableArray *parts = [NSMutableArray new];
                for (NSString *bid in wq_name_probe_ids()) {
                    NSString *nm = nil;
                    @try {
                        id proxy = [proxyClass performSelector:@selector(applicationProxyForIdentifier:) withObject:bid];
                        id value = [proxy valueForKey:@"localizedName"];
                        if ([value isKindOfClass:NSString.class] && [value length]) nm = value;
                    } @catch (NSException *e) { }
                    [parts addObject:[NSString stringWithFormat:@"%@=%@", bid, nm ?: @"-"]];
                }
                wq_log(@"app catalog: proxy probes: %@", [parts componentsJoinedByString:@", "]);
            }
        } @catch (NSException *e) { }
        gCatalogLoaded = YES;
    }
    NSDictionary<NSString *, NSString *> *result = gNames;
    [lock unlock];
    return result;
}
