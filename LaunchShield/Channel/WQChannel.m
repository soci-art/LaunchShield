//
//  WQChannel.m
//  LaunchShield
//
//  GPL-3.0-or-later. Channel implementation over the ported
//  kolbicz/WQFiles access layer (WQAccess).
//

#import "WQChannel.h"
#import "WQAppCatalog.h"
#import "WQLaunchServices.h"
#import "WQAccess.h"
#import "WQRoute.h"
#import "WQKernel.h"
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>
#import <errno.h>
#import <sys/sysctl.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <stdlib.h>
#import <unistd.h>
#import <xpc/xpc.h>

@interface WQChannel ()
- (BOOL)isCanonicalBundleIdentifier:(NSString *)bundleID;
- (NSString *)canonicalApplicationDataPath:(NSString *)rawPath;
- (NSString *)rawContainerMetadataIdentifierForPath:(NSString *)path;
- (WQAppContainer *)resolvedContainerForBundleID:(NSString *)bundleID;
@end
@interface MCMRetainedLease : NSObject {
    void *_query;
    void *_activation;
}
@property(nonatomic, copy) NSString *rootPath;
@property(nonatomic) BOOL activated;
+ (nullable instancetype)leaseForClass:(uint64_t)cls
                             identifier:(NSString *)identifier
                                  group:(BOOL)group
                                  error:(NSString **)error;
- (BOOL)activate:(NSString **)error;
@end


@implementation WQOp

+ (instancetype)ok:(id)value
{
    WQOp *op = [WQOp new];
    op->_ok = YES;
    op->_value = value;
    return op;
}

+ (instancetype)fail:(NSString *)error
{
    WQOp *op = [WQOp new];
    op->_ok = NO;
    op->_error = [error copy] ?: @"操作失败";
    return op;
}

@end

@implementation WQFileItem
@end

@implementation WQAppContainer
@end

// Full-scan confirmation bridge. On systems where the quick container
// queries answer nothing (iOS 26), the scan machinery needs the user's
// OK before a long full scan. The C hooks forward to the app UI via
// notifications; the wait happens on the caller's background thread.
static NSCondition *gFullScanCondition;
static BOOL gFullScanAnswer;
static BOOL gFullScanWaiting;

static BOOL LSFullScanConfirm(NSString *what, int64_t ids, double seconds)
{
    if ([NSThread isMainThread]) return NO;
    if (!gFullScanCondition) gFullScanCondition = [NSCondition new];
    [gFullScanCondition lock];
    gFullScanWaiting = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:@"LSFullScanConfirmRequested" object:nil
            userInfo:@{ @"ids": @(ids), @"seconds": @(seconds) }];
    });
    while (gFullScanWaiting) [gFullScanCondition wait];
    BOOL answer = gFullScanAnswer;
    [gFullScanCondition unlock];
    return answer;
}

static void LSFullScanProgress(int64_t done, int64_t total, BOOL finished)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:@"LSFullScanProgress" object:nil
            userInfo:@{ @"done": @(done), @"total": @(total), @"finished": @(finished) }];
    });
}

@implementation WQChannel {
    NSArray<WQAppContainer *> *_containers;
    NSTimeInterval _containersAt;
    BOOL _containersLoaded;
    NSArray<WQAppContainer *> *_groupContainers;
    NSTimeInterval _groupContainersAt;
    BOOL _groupContainersLoaded;
}

+ (instancetype)shared
{
    static WQChannel *channel;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Same wiring as WQ Files: the LaunchServices database backs the
        // container label resolver and the container list provider.
        wq_set_container_label_resolver(wq_bundle_id_for_container);
        wq_set_container_list_provider(wq_ls_container_paths);
        wq_set_full_scan_ui(LSFullScanConfirm, LSFullScanProgress);
        channel = [WQChannel new];
    });
    return channel;
}

- (void)answerFullScan:(BOOL)yes
{
    if (!gFullScanCondition) return;
    [gFullScanCondition lock];
    gFullScanAnswer = yes;
    gFullScanWaiting = NO;
    [gFullScanCondition signal];
    [gFullScanCondition unlock];
}

- (void)stopFullScan
{
    wq_full_scan_stop();
}

- (BOOL)available
{
    WQRouteState state = wq_route_state();
    switch (state) {
        case WQRouteStateKernel: {
            BOOL ok = wq_kernel_active();
            wq_log(@"channel availability: route=kernel result=%@",
                   ok ? @"available" : @"not started");
            return ok;
        }
        case WQRouteStateUnset:
            wq_log(@"channel availability: route=unset");
            return NO;
        case WQRouteStateUnsupported:
            wq_log(@"channel availability: route=unsupported");
            return NO;
    }
    return NO;
}

- (void)resetRoute
{
    wq_route_reset();
    _containers = nil;
    _containersAt = 0;
    _containersLoaded = NO;
    _groupContainers = nil;
    _groupContainersAt = 0;
    _groupContainersLoaded = NO;
}

- (BOOL)kernelSupported { return wq_kernel_supported(); }
- (BOOL)kernelActive { return wq_kernel_active(); }
- (BOOL)kernelRunning { return wq_kernel_running(); }
- (BOOL)startKernel { return wq_kernel_start(); }

- (NSString *)groupID
{
    return wq_app_group();
}

- (NSString *)groupText
{
    switch (wq_route_state()) {
        case WQRouteStateKernel:
            return @"不需要（内核链路不用共享组）";
        case WQRouteStateUnset:
            return @"尚未识别访问通道";
        case WQRouteStateUnsupported:
            if (wq_kernel_unsupported_a10_ios17()) return @"A10 + iOS 17 组合未纳入已验证范围，已阻止启动内核链路";
            return @"当前 iOS 版本、构建号或机型组合不在已验证范围内";
    }
    return @"没有拿到";
}

- (NSString *)signMethod
{
    return wq_route_sign_method();
}

- (NSString *)routeName
{
    return wq_route_name();
}

- (NSString *)routeDetail
{
    return wq_route_detail();
}

- (NSString *)unavailableReason
{
    switch (wq_route_state()) {
        case WQRouteStateUnset:
            return @"无法自动识别当前访问通道，请重新打开应用后再试。";
        case WQRouteStateKernel:
            if (wq_kernel_running()) return @"内核链路正在启动：等它跑完，应用可能会重启一次。";
            if (wq_kernel_failed()) return @"内核链路没启动成功：重启应用后再点一次「启动内核链路」。";
            return @"内核链路还没启动：点主页的「启动内核链路」。启动通常要 1–3 分钟，期间请保持应用在前台；失败时应用可能会重启一次。";
        case WQRouteStateUnsupported: {
            if (wq_kernel_unsupported_a10_ios17())
                return @"当前设备为 A10 且运行 iOS 17；该组合未纳入已验证范围，已阻止启动内核链路。";
            NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
            if (v.majorVersion >= 26) {
                return @"此版本为 iOS 17/18 系统内核专用版本，请使用正式版。";
            }
            return @"系统不支持：内核专用版只支持 iOS 17.0–18.7.1，你现在的系统用不了。";
        }
    }
    return @"文件通道不可用。";
}

- (NSString *)messageFor:(NSString *)error fallback:(NSString *)fallback
{
    if (error.length == 0) return fallback;
    // WQAccess reports POSIX reasons in English; keep the detail but lead with
    // plain Chinese so the screen stays readable.
    return [NSString stringWithFormat:@"%@（%@）", fallback, error];
}

// MCM bridge adapted from QuinnTang74's collection (mcm_bridge.m).
typedef void *(*MCMQueryCreate)(void);
typedef void (*MCMQuerySetU64)(void *, uint64_t);
typedef void (*MCMQuerySetXPC)(void *, xpc_object_t);
typedef void *(*MCMQueryGetPointer)(void *);
typedef bool (*MCMQueryIterate)(void *, bool (^)(void *));
typedef char *(*MCMCopyToken)(void *);
typedef const char *(*MCMGetPath)(void *);
typedef const char *(*MCMGetIdentifier)(void *);
typedef void *(*MCMObjectCopy)(void *);
typedef bool (*MCMObjectActivate)(void *, bool);
typedef void (*MCMObjectFree)(void *);
typedef int (*MCMErrorGetInt)(void *);
typedef const char *(*MCMErrorGetString)(void *);
typedef void (*MCMQueryFree)(void *);

typedef struct {
    void *handle;
    MCMQueryCreate queryCreate;
    MCMQuerySetU64 querySetClass;
    MCMQuerySetXPC querySetIdentifiers;
    MCMQuerySetXPC querySetGroupIdentifiers;
    MCMQuerySetU64 querySetFlags;
    MCMQuerySetU64 querySetPart;
    MCMQueryGetPointer queryGetSingle;
    MCMQueryGetPointer queryGetLastError;
    MCMQueryIterate queryIterate;
    MCMQueryFree queryFree;
    MCMGetPath objectGetPath;
    MCMGetIdentifier objectGetIdentifier;
    MCMObjectCopy objectCopy;
    MCMCopyToken objectCopyToken;
    MCMObjectActivate objectActivate;
    MCMObjectFree objectFree;
    MCMErrorGetInt errorGetPOSIX;
    MCMErrorGetString errorGetMessage;
} MCMAPI;

static MCMAPI *MCMSharedAPI(void) {
    static MCMAPI api;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        api.handle = dlopen(
            "/usr/lib/system/libsystem_containermanager.dylib",
            RTLD_NOW | RTLD_LOCAL
        );
        void *handle = api.handle ?: RTLD_DEFAULT;
#define LOAD(field, symbol) api.field = (__typeof(api.field))dlsym(handle, symbol)
        LOAD(queryCreate, "container_query_create");
        LOAD(querySetClass, "container_query_set_class");
        LOAD(querySetIdentifiers, "container_query_set_identifiers");
        LOAD(querySetGroupIdentifiers, "container_query_set_group_identifiers");
        LOAD(querySetFlags, "container_query_operation_set_flags");
        LOAD(querySetPart, "container_query_operation_set_part");
        LOAD(queryGetSingle, "container_query_get_single_result");
        LOAD(queryGetLastError, "container_query_get_last_error");
        LOAD(queryIterate, "container_query_iterate_results_sync");
        LOAD(queryFree, "container_query_free");
        LOAD(objectGetPath, "container_object_get_path");
        LOAD(objectGetIdentifier, "container_object_get_identifier");
        LOAD(objectCopy, "container_object_copy");
        LOAD(objectCopyToken, "container_copy_sandbox_token");
        LOAD(objectActivate, "container_object_sandbox_extension_activate");
        LOAD(objectFree, "container_object_free");
        LOAD(errorGetPOSIX, "container_error_get_posix_errno");
        LOAD(errorGetMessage, "container_error_get_message");
#undef LOAD
    });
    return &api;
}

BOOL MCMBridgeAvailable(void) {
    MCMAPI *api = MCMSharedAPI();
    return api->queryCreate && api->querySetClass &&
        api->querySetIdentifiers && api->querySetGroupIdentifiers &&
        api->querySetFlags && api->queryGetSingle && api->queryFree &&
        api->objectGetPath && api->objectCopy && api->objectCopyToken &&
        api->objectActivate && api->objectFree;
}

NSArray<NSString *> *MCMEnumerateIdentifiersForClass(uint64_t cls, NSUInteger limit, NSString **error) {
    MCMAPI *api = MCMSharedAPI();
    if (!api->queryCreate || !api->querySetClass || !api->querySetFlags ||
        !api->queryIterate || !api->objectGetIdentifier || !api->queryFree ||
        limit == 0) {
        if (error) *error = @"missing symbols";
        return @[];
    }

    void *query = api->queryCreate();
    if (!query) { if (error) *error = @"query create failed"; return @[]; }

    api->querySetClass(query, cls);
    api->querySetFlags(query, 0x100000000ULL);
    if (api->querySetPart) api->querySetPart(query, 0);

    NSMutableOrderedSet<NSString *> *set = [NSMutableOrderedSet orderedSet];
    BOOL iterated = api->queryIterate(query, ^bool(void *object) {
        const char *raw = object ? api->objectGetIdentifier(object) : NULL;
        NSString *identifier = raw ? [NSString stringWithUTF8String:raw] : nil;
        if (identifier.length) [set addObject:identifier];
        return set.count < limit;
    });
    if (!iterated && set.count < limit && error) {
        void *queryError = api->queryGetLastError ? api->queryGetLastError(query) : NULL;
        int posix = queryError && api->errorGetPOSIX ? api->errorGetPOSIX(queryError) : 0;
        const char *message = queryError && api->errorGetMessage
            ? api->errorGetMessage(queryError) : NULL;
        *error = [NSString stringWithFormat:@"enumeration denied posix=%d message=%s",
            posix, message ?: "unknown"];
    }

    api->queryFree(query);
    return set.array;
}

NSString *MCMContainerPathForIdentifier(uint64_t cls, NSString *identifier, BOOL group, NSString **error) {
    MCMAPI *api = MCMSharedAPI();
    MCMQuerySetXPC setIdentifiers = group
        ? api->querySetGroupIdentifiers
        : api->querySetIdentifiers;
    if (!api->queryCreate || identifier.length == 0) {
        if (error) *error = @"lib not loaded or identifier empty";
        return nil;
    }
    if (!api->querySetClass || !setIdentifiers || !api->querySetFlags ||
        !api->queryGetSingle || !api->objectGetPath || !api->queryFree) {
        if (error) *error = @"missing path lookup symbols";
        return nil;
    }

    void *query = api->queryCreate();
    if (!query) { if (error) *error = @"query create failed"; return nil; }

    api->querySetClass(query, cls);
    xpc_object_t value = xpc_string_create(identifier.UTF8String);
    setIdentifiers(query, value);
#if !OS_OBJECT_USE_OBJC
    xpc_release(value);
#endif
    api->querySetFlags(query, 0x100000000ULL);
    if (api->querySetPart) api->querySetPart(query, 0);

    void *result = api->queryGetSingle(query);
    if (!result) {
        if (error) {
            void *queryError = api->queryGetLastError ? api->queryGetLastError(query) : NULL;
            int posix = queryError && api->errorGetPOSIX ? api->errorGetPOSIX(queryError) : 0;
            const char *message = queryError && api->errorGetMessage
                ? api->errorGetMessage(queryError) : NULL;
            *error = [NSString stringWithFormat:@"lookup denied posix=%d message=%s",
                posix, message ?: "unknown"];
        }
        api->queryFree(query);
        return nil;
    }

    const char *rawPath = api->objectGetPath(result);
    NSString *path = rawPath ? [NSString stringWithUTF8String:rawPath] : nil;
    if ([path isEqualToString:@"/var"] || [path hasPrefix:@"/var/"])
        path = [@"/private" stringByAppendingString:path];
    api->queryFree(query);
    return path.length ? path : nil;
}

static BOOL MCMSafeIdentifier(NSString *identifier) {
    if (identifier.length == 0 || identifier.length > 255) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    return [identifier rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound &&
        ![identifier isEqualToString:@"."] && ![identifier isEqualToString:@".."];
}


static NSMutableDictionary<NSString *, MCMRetainedLease *> *MCMActiveLeases(void) {
    static NSMutableDictionary<NSString *, MCMRetainedLease *> *leases;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        leases = [NSMutableDictionary dictionary];
    });
    return leases;
}

BOOL MCMHostIsMobileHouseArrest(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.mobile.MobileHouseArrest"];
}

NSString *MCMActivateContainerPath(uint64_t cls, NSString *identifier, BOOL group, NSString **error) {
    // The upstream build is signed with its own bundle identifier, so the old MHA-only
    // guard rejected every lookup in this build. MCM itself does not require
    // the caller to be MobileHouseArrest; keep the check only as a capability
    // hint and always attempt the lookup. Callers fall back to the filesystem
    // and LaunchServices store when the daemon denies it.
    if (!MCMSafeIdentifier(identifier)) {
        if (error) *error = @"identifier contains unsupported characters";
        return nil;
    }

    NSMutableDictionary *leases = MCMActiveLeases();
    NSString *key = [NSString stringWithFormat:@"%llu:%d:%@", cls, group, identifier];
    @synchronized (leases) {
        MCMRetainedLease *existing = leases[key];
        if (existing.rootPath.length) return existing.rootPath;

        NSString *detail = nil;
        MCMRetainedLease *lease = [MCMRetainedLease leaseForClass:cls
            identifier:identifier group:group error:&detail];
        if (!lease) {
            // Some builds hand out a readable container path but refuse the
            // sandbox extension (for example when the caller is not signed as
            // MobileHouseArrest). The path is still useful: the filesystem
            // backend grants access separately.
            NSString *pathOnlyError = nil;
            NSString *pathOnly = MCMContainerPathForIdentifier(cls, identifier, group, &pathOnlyError);
            if (pathOnly.length) {
                int pathOnlyDescriptor = open(
                    pathOnly.fileSystemRepresentation,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                );
                if (pathOnlyDescriptor >= 0) {
                    close(pathOnlyDescriptor);
                    if (error) *error = nil;
                    return pathOnly;
                }
                if (error) {
                    *error = [NSString stringWithFormat:
                        @"container path open failed errno=%d (activation: %@)",
                        errno, detail ?: @"unavailable"];
                }
                return nil;
            }
            if (error) *error = detail ?: pathOnlyError ?: @"MCM lookup failed";
            return nil;
        }
        [lease activate:&detail];

        if (!lease.rootPath.length) {
            if (error) *error = detail ?: @"container path unavailable";
            return nil;
        }

        int descriptor = open(
            lease.rootPath.fileSystemRepresentation,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        );
        if (descriptor < 0) {
            if (error) {
                *error = detail ?: [NSString stringWithFormat:
                    @"container root open failed errno=%d", errno];
            }
            return nil;
        }
        close(descriptor);
        leases[key] = lease;
        return lease.rootPath;
    }
}

int64_t MCMActivateContainer(uint64_t cls, NSString *identifier, BOOL group, NSString **error) {
    return MCMActivateContainerPath(cls, identifier, group, error) ? 1 : -1;
}

#pragma mark - Containers

// Last-resort label: read the container's own metadata plist through the
// channel, without the permission pre-check the shared helper applies (on
// iOS 27.x that pre-check guesses "unreadable" for files the channel can in
// fact read).
- (NSString *)rawContainerMetadataIdentifierForPath:(NSString *)path
{
    NSString *meta = [path stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    NSData *data = wq_read(meta, 64 * 1024, NULL);
    if (!data.length) return nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
    if (![plist isKindOfClass:NSDictionary.class]) return nil;
    id identifier = plist[@"MCMMetadataIdentifier"];
    if (![identifier isKindOfClass:NSString.class] ||
        [identifier length] == 0 || [identifier length] > 255) return nil;
    return identifier;
}

- (NSString *)metadataLabelForPath:(NSString *)path
{
    NSString *identifier = [self rawContainerMetadataIdentifierForPath:path];
    if (![identifier containsString:@"."] || [identifier hasPrefix:@"com.apple."]) return nil;
    return identifier;
}

- (NSString *)labelForPath:(NSString *)path
{
    NSString *label = wq_container_label(path);
    if (label.length) return label;
    return [self metadataLabelForPath:path];
}

// Fallback for systems where the scan machinery returns nothing: walk the
// app-data container folder and resolve each folder's bundle id.
- (NSArray<NSDictionary<NSString *, NSString *> *> *)fallbackContainerRows
{
    wq_load_display_names();
    NSString *parent = @"/private/var/mobile/Containers/Data/Application";
    NSMutableSet<NSString *> *paths = [NSMutableSet set];
    for (NSString *path in wq_ls_container_paths(nil) ?: @[]) {
        if ([path hasPrefix:[parent stringByAppendingString:@"/"]]) [paths addObject:path];
    }
    NSString *error = nil;
    for (NSString *name in wq_list(parent, &error) ?: @[]) {
        if (name.length) [paths addObject:[parent stringByAppendingPathComponent:name]];
    }
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *rows = [NSMutableArray array];
    for (NSString *path in paths) {
        NSString *identifier = [self labelForPath:path];
        if (identifier.length) [rows addObject:@{ @"identifier": identifier, @"path": path }];
    }
    wq_log(@"containers: query empty, fallback resolved %lu of %lu folders",
           (unsigned long)rows.count, (unsigned long)paths.count);
    return rows;
}

- (NSArray<WQAppContainer *> *)appContainers
{
    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    if (_containersLoaded && now - _containersAt < 30) return _containers;

    // Primary: the original scan machinery over both container roots (asks
    // the container manager every class, then the LaunchServices database,
    // then a bounded id scan). The single-class query below returns nothing
    // on iOS 27.2, which is why this goes first.
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *rows = [NSMutableArray array];
    wq_load_display_names();
    NSArray<NSString *> *roots = @[@"/private/var/mobile/Containers/Data/Application",
                                   @"/private/var/mobile/Containers/Data/PluginKitPlugin"];
    if (wq_kernel_active()) {
        // The kernel chain has no sandbox left, so both roots can be
        // listed directly instead of waiting for a full inode scan.
        for (NSString *root in roots) {
            for (NSString *name in wq_list(root, NULL) ?: @[]) {
                if (!name.length || [name hasPrefix:@"."]) continue;
                NSString *path = [root stringByAppendingPathComponent:name];
                NSString *identifier = [self labelForPath:path];
                if (identifier.length) [rows addObject:@{ @"identifier": identifier, @"path": path }];
            }
        }
        wq_log(@"containers: direct listing found %lu", (unsigned long)rows.count);
    }
    for (NSString *root in roots) {
        if (rows.count) break;
        for (NSString *path in wq_enumerate(root, 0, nil, nil) ?: @[]) {
            NSString *identifier = [self labelForPath:path];
            if (identifier.length) [rows addObject:@{ @"identifier": identifier, @"path": path }];
        }
    }
    wq_log(@"containers: scan machinery resolved %lu", (unsigned long)rows.count);
    if (!rows.count) rows = [wq_list_containers(2) mutableCopy] ?: [NSMutableArray array];
    if (!rows.count) rows = [[self fallbackContainerRows] mutableCopy];
    // Merge exact MCM class-2 identifiers as a supplemental source.
    // Only resolve identifiers missing from the existing path list. Calls are
    // sequential because containermanagerd concurrency guarantees are undocumented.
    NSString *enumerationError = nil;
    NSArray<NSString *> *identifiers = MCMEnumerateIdentifiersForClass(2, 4096, &enumerationError);
    NSMutableSet<NSString *> *seenIdentifiers = [NSMutableSet set];
    NSMutableSet<NSString *> *seenPaths = [NSMutableSet set];
    for (NSDictionary<NSString *, NSString *> *row in rows) {
        NSString *existingIdentifier = row[@"identifier"];
        NSString *existingPath = row[@"path"];
        if (existingIdentifier.length) [seenIdentifiers addObject:existingIdentifier];
        if (existingPath.length) [seenPaths addObject:existingPath.stringByStandardizingPath];
    }
    NSUInteger mcmAdded = 0;
    for (NSString *identifier in identifiers) {
        if (![self isCanonicalBundleIdentifier:identifier] ||
            [seenIdentifiers containsObject:identifier]) continue;
        NSString *lookupError = nil;
        NSString *resolved = [self canonicalApplicationDataPath:
            MCMActivateContainerPath(2, identifier, NO, &lookupError)];
        if (!resolved.length) continue;
        NSString *metadataIdentifier = [self rawContainerMetadataIdentifierForPath:resolved];
        if (metadataIdentifier.length && ![metadataIdentifier isEqualToString:identifier]) {
            wq_log(@"containers: MCM path identity mismatch for %@; skipped", identifier);
            continue;
        }
        if ([seenPaths containsObject:resolved]) continue;
        [rows addObject:@{ @"identifier": identifier, @"path": resolved }];
        [seenIdentifiers addObject:identifier];
        [seenPaths addObject:resolved];
        mcmAdded++;
    }
    wq_log(@"containers: MCM supplement added %lu apps from %lu identifiers (error=%@)",
           (unsigned long)mcmAdded, (unsigned long)identifiers.count,
           enumerationError ?: @"none");
    NSDictionary<NSString *, NSString *> *names = wq_app_display_names();
    NSDictionary<NSString *, NSString *> *categories = wq_app_categories();
    NSMutableArray<WQAppContainer *> *result = [NSMutableArray array];
    for (NSDictionary<NSString *, NSString *> *row in rows) {
        NSString *identifier = row[@"identifier"];
        NSString *path = row[@"path"];
        if (!identifier.length || !path.length) continue;
        WQAppContainer *container = [WQAppContainer new];
        container.identifier = identifier;
        container.path = path;
        container.name = names[identifier] ?: wq_display_name(identifier) ?: identifier;
        container.category = categories[identifier] ?: @"";
        container.isSystem = [identifier hasPrefix:@"com.apple."];
        [result addObject:container];
    }
    [result sortUsingComparator:^NSComparisonResult(id first, id second) {
        WQAppContainer *a = (WQAppContainer *)first;
        WQAppContainer *b = (WQAppContainer *)second;
        if (a.isSystem != b.isSystem) return a.isSystem ? NSOrderedDescending : NSOrderedAscending;
        return [a.name localizedStandardCompare:b.name];
    }];
    _containers = [result copy];
    _containersAt = now;
    _containersLoaded = YES;
    return _containers;
}

- (NSArray<WQAppContainer *> *)groupContainers
{
    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    if (_groupContainersLoaded && now - _groupContainersAt < 30) return _groupContainers;

    // Shared App Group containers: the metadata plist's identifier IS the
    // group id (e.g. group.com.example.app), which is what we label by.
    // NOTE: wq_enumerate does not serve this root — its inode scan refuses
    // to start for AppGroup (millions of ids), so it returns nothing.
    // List the folder directly and merge in the LaunchServices database
    // paths instead (same trick as the app-container fallback).
    NSMutableArray<WQAppContainer *> *result = [NSMutableArray array];
    NSString *root = @"/private/var/mobile/Containers/Shared/AppGroup";
    NSMutableSet<NSString *> *paths = [NSMutableSet set];
    NSString *error = nil;
    for (NSString *name in wq_list(root, &error) ?: @[]) {
        if (name.length && ![name hasPrefix:@"."]) {
            [paths addObject:[root stringByAppendingPathComponent:name]];
        }
    }
    for (NSString *path in wq_ls_container_paths(nil) ?: @[]) {
        if ([path hasPrefix:[root stringByAppendingString:@"/"]]) [paths addObject:path];
    }
    wq_log(@"containers: shared group folder yielded %lu candidate paths", (unsigned long)paths.count);
    for (NSString *path in paths) {
        NSString *identifier = [self metadataLabelForPath:path];
        if (!identifier.length) identifier = [self labelForPath:path];
        if (!identifier.length) continue;
        WQAppContainer *container = [WQAppContainer new];
        container.identifier = identifier;
        container.path = path;
        container.name = identifier;
        container.category = @"";
        container.isSystem = NO;
        [result addObject:container];
    }
    [result sortUsingComparator:^NSComparisonResult(id first, id second) {
        WQAppContainer *a = (WQAppContainer *)first;
        WQAppContainer *b = (WQAppContainer *)second;
        return [a.identifier localizedStandardCompare:b.identifier];
    }];
    wq_log(@"containers: resolved %lu shared group containers", (unsigned long)result.count);
    _groupContainers = [result copy];
    _groupContainersAt = now;
    _groupContainersLoaded = YES;
    return _groupContainers;
}

- (BOOL)isCanonicalBundleIdentifier:(NSString *)bundleID
{
    if (![bundleID isKindOfClass:NSString.class] || bundleID.length == 0 || bundleID.length > 255) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    return [bundleID rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound &&
        ![bundleID hasPrefix:@"."] && ![bundleID hasSuffix:@"."] &&
        ![bundleID containsString:@".."];
}

- (NSString *)canonicalApplicationDataPath:(NSString *)rawPath
{
    if (![rawPath isKindOfClass:NSString.class] || !rawPath.length) return nil;
    NSString *path = rawPath.stringByStandardizingPath;
    if ([path hasPrefix:@"/var/"]) path = [@"/private" stringByAppendingString:path];
    NSString *root = @"/private/var/mobile/Containers/Data/Application";
    NSString *prefix = [root stringByAppendingString:@"/"];
    if (![path hasPrefix:prefix]) return nil;
    NSString *component = [path substringFromIndex:prefix.length];
    if (component.length != 36 || [component containsString:@"/"] ||
        ![[NSUUID alloc] initWithUUIDString:component]) return nil;
    struct stat st;
    if (!wq_stat(path, &st) || !S_ISDIR(st.st_mode)) return nil;
    return path;
}

- (WQAppContainer *)resolvedContainerForBundleID:(NSString *)bundleID
{
    if (![self isCanonicalBundleIdentifier:bundleID]) return nil;

    NSString *lookupError = nil;
    NSString *path = [self canonicalApplicationDataPath:
        MCMActivateContainerPath(2, bundleID, NO, &lookupError)];
    if (path.length) {
        NSString *metadataIdentifier = [self metadataLabelForPath:path];
        if (metadataIdentifier.length && ![metadataIdentifier isEqualToString:bundleID]) {
            wq_log(@"container lookup: MCM identity mismatch for %@; rejecting %@", bundleID, path.lastPathComponent);
            path = nil;
        }
    }

    // If MCM refuses this exact lookup, inspect only UUID children of the
    // known app-data root and compare their metadata identifier. No volume scan.
    if (!path.length) {
        NSString *root = @"/private/var/mobile/Containers/Data/Application";
        NSString *listError = nil;
        NSArray<NSString *> *names = wq_list(root, &listError);
        for (NSString *name in names ?: @[]) {
            if (name.length != 36 || [name containsString:@"/"] ||
                ![[NSUUID alloc] initWithUUIDString:name]) continue;
            NSString *candidate = [self canonicalApplicationDataPath:
                [root stringByAppendingPathComponent:name]];
            if (!candidate.length) continue;
            NSString *metadataIdentifier = [self rawContainerMetadataIdentifierForPath:candidate];
            if ([metadataIdentifier isEqualToString:bundleID]) {
                path = candidate;
                break;
            }
        }
        if (!path.length) {
            wq_log(@"container lookup: %@ unresolved (MCM=%@, metadata=%@)",
                   bundleID, lookupError ?: @"no path", listError ?: @"not found");
            return nil;
        }
        wq_log(@"container lookup: %@ resolved by metadata fallback", bundleID);
    } else {
        wq_log(@"container lookup: %@ resolved by MCM", bundleID);
    }

    WQAppContainer *container = [WQAppContainer new];
    container.identifier = bundleID;
    container.path = path;
    NSDictionary<NSString *, NSString *> *names = wq_app_display_names();
    NSDictionary<NSString *, NSString *> *categories = wq_app_categories();
    container.name = names[bundleID] ?: wq_display_name(bundleID) ?: bundleID;
    container.category = categories[bundleID] ?: @"";
    container.isSystem = [bundleID hasPrefix:@"com.apple."];
    return container;
}

- (WQAppContainer *)containerForBundleID:(NSString *)bundleID
{
    for (WQAppContainer *container in [self appContainers]) {
        if ([container.identifier isEqualToString:bundleID]) return container;
    }
    WQAppContainer *resolved = [self resolvedContainerForBundleID:bundleID];
    if (resolved) {
        NSMutableArray<WQAppContainer *> *updated = [_containers mutableCopy] ?: [NSMutableArray array];
        BOOL exists = NO;
        for (WQAppContainer *item in updated) {
            if ([item.identifier isEqualToString:bundleID]) { exists = YES; break; }
        }
        if (!exists) [updated addObject:resolved];
        _containers = [updated copy];
        _containersAt = NSDate.date.timeIntervalSinceReferenceDate;
        _containersLoaded = YES;
    }
    return resolved;
}

#pragma mark - Files

- (WQFileItem *)itemAtPath:(NSString *)path name:(NSString *)name
{
    struct stat st;
    if (!wq_stat(path, &st)) return nil;
    WQFileItem *item = [WQFileItem new];
    item.name = name ?: path.lastPathComponent;
    item.path = path;
    item.isDirectory = S_ISDIR(st.st_mode);
    item.isSymlink = S_ISLNK(st.st_mode);
    item.size = (unsigned long long)st.st_size;
    item.modified = (NSTimeInterval)st.st_mtimespec.tv_sec + (NSTimeInterval)st.st_mtimespec.tv_nsec / 1e9;
    item.isImmutable = (st.st_flags & UF_IMMUTABLE) != 0;
    item.posixMode = (unsigned int)(st.st_mode & 07777);
    return item;
}

- (WQOp *)listDirectory:(NSString *)path
{
    NSString *error = nil;
    NSArray<NSDictionary<NSString *, id> *> *rows = wq_list_detailed(path, &error);
    if (!rows) return [WQOp fail:[self messageFor:error fallback:@"打不开这个文件夹"]];
    if (rows.count == 0) {
        // Safety net: if the single-grant readdir saw entries but could not stat
        // them, fall back to the per-entry path so a folder never looks empty.
        NSArray<NSString *> *names = wq_list(path, &error);
        if (names.count) {
            NSMutableArray<WQFileItem *> *fallback = [NSMutableArray array];
            for (NSString *name in names) {
                if (!name.length || [name isEqualToString:@"."] || [name isEqualToString:@".."]) continue;
                WQFileItem *item = [self itemAtPath:[path stringByAppendingPathComponent:name] name:name];
                if (item) [fallback addObject:item];
            }
            return [WQOp ok:fallback];
        }
    }
    NSMutableArray<WQFileItem *> *items = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSDictionary<NSString *, id> *row in rows) {
        NSString *name = row[@"name"];
        if (!name.length) continue;
        WQFileItem *item = [WQFileItem new];
        item.name = name;
        item.path = [path stringByAppendingPathComponent:name];
        item.isDirectory = [row[@"directory"] boolValue];
        item.isSymlink = [row[@"symlink"] boolValue];
        item.size = [row[@"size"] unsignedLongLongValue];
        item.modified = [row[@"modified"] doubleValue];
        item.isImmutable = [row[@"immutable"] boolValue];
        item.posixMode = [row[@"mode"] unsignedIntValue];
        [items addObject:item];
    }
    [items sortUsingComparator:^NSComparisonResult(id first, id second) {
        WQFileItem *a = (WQFileItem *)first;
        WQFileItem *b = (WQFileItem *)second;
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
        return [a.name localizedStandardCompare:b.name];
    }];
    return [WQOp ok:[items copy]];
}

- (WQOp *)walkFiles:(NSString *)path
              limit:(NSInteger)limit
      skipDirNames:(NSSet<NSString *> *)skipDirNames
skipDirSubstrings:(NSArray<NSString *> *)skipDirSubstrings
   skipAccountDirs:(BOOL)skipAccountDirs
           progress:(void (^)(NSInteger))progress
{
    NSString *error = nil;
    NSArray<NSDictionary<NSString *, id> *> *rows =
        wq_walk_files(path, limit, skipDirNames, skipDirSubstrings,
                      skipAccountDirs, progress, &error);
    if (!rows) return [WQOp fail:[self messageFor:error fallback:@"打不开这个文件夹"]];
    NSMutableArray<WQFileItem *> *items = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSDictionary<NSString *, id> *row in rows) {
        NSString *filePath = row[@"path"];
        if (!filePath.length) continue;
        WQFileItem *item = [WQFileItem new];
        item.name = filePath.lastPathComponent;
        item.path = filePath;
        item.isDirectory = NO;
        item.isSymlink = NO;
        item.size = [row[@"size"] unsignedLongLongValue];
        item.modified = [row[@"modified"] doubleValue];
        item.isImmutable = NO;
        item.posixMode = 0;
        [items addObject:item];
    }
    return [WQOp ok:[items copy]];
}

- (WQOp *)statPath:(NSString *)path
{
    struct stat st;
    if (!wq_stat(path, &st)) {
        int errorCode = errno;
        if (errorCode == ENOENT || errorCode == ENOTDIR) {
            return [WQOp fail:@"目标不存在"];
        }
        return [WQOp fail:[NSString stringWithFormat:@"无法检查目标（errno=%d）", errorCode]];
    }
    WQFileItem *item = [self itemAtPath:path name:path.lastPathComponent];
    if (!item) return [WQOp fail:@"无法读取目标属性"];
    return [WQOp ok:item];
}

- (WQOp *)fileVersion:(NSString *)path
{
    NSDictionary<NSString *, NSNumber *> *version = wq_file_version(path);
    if (!version) return [WQOp fail:@"无法读取普通文件身份或版本信息"];
    return [WQOp ok:version];
}

- (WQOp *)readFile:(NSString *)path maxBytes:(NSUInteger)maxBytes
{
    NSString *error = nil;
    NSData *data = wq_read(path, maxBytes, &error);
    if (!data) return [WQOp fail:[self messageFor:error fallback:@"读不了这个文件"]];
    return [WQOp ok:data];
}

- (WQOp *)writeData:(NSString *)path data:(NSData *)data
{
    NSString *error = nil;
    if (!wq_write(path, data, &error)) {
        return [WQOp fail:[self messageFor:error fallback:@"写不进去"]];
    }
    return [WQOp ok:@(data.length)];
}

- (WQOp *)truncateFile:(NSString *)path
{
    NSString *error = nil;
    if (!wq_write(path, [NSData data], &error)) {
        return [WQOp fail:[self messageFor:error fallback:@"去除失败"]];
    }
    return [WQOp ok:@(0)];
}

- (WQOp *)truncateFile:(NSString *)path expectingVersion:(NSDictionary<NSString *,NSNumber *> *)version
{
    NSString *error = nil;
    if (!version || !wq_write_if_unchanged(path, [NSData data], version, &error))
        return [WQOp fail:[self messageFor:error fallback:@"目标文件身份或内容已变化，已取消去除"]];
    return [WQOp ok:@(0)];
}


- (WQOp *)writeFromLocalFile:(NSString *)path source:(NSString *)source
{
    NSString *error = nil;
    if (!wq_write_from_file(path, source, &error)) {
        return [WQOp fail:[self messageFor:error fallback:@"写回失败"]];
    }
    return [WQOp ok:nil];
}

- (WQOp *)writeFromLocalFile:(NSString *)path source:(NSString *)source expectingVersion:(NSDictionary<NSString *,NSNumber *> *)version
{
    NSString *error = nil;
    if (!version || !wq_write_from_file_if_unchanged(path, source, version, &error))
        return [WQOp fail:[self messageFor:error fallback:@"目标文件身份或内容已变化，已取消恢复"]];
    return [WQOp ok:nil];
}

- (WQOp *)createFromLocalFile:(NSString *)path source:(NSString *)source
{
    NSString *error = nil;
    if (!wq_create_file_from(path, source, &error)) {
        return [WQOp fail:[self messageFor:error fallback:@"写回失败"]];
    }
    return [WQOp ok:nil];
}

- (WQOp *)copyToLocalFile:(NSString *)path destination:(NSString *)destination
{
    NSString *error = nil;
    if (!wq_copy_to_local(path, destination, &error)) {
        return [WQOp fail:[self messageFor:error fallback:@"备份失败"]];
    }
    return [WQOp ok:destination];
}

- (WQOp *)deletePath:(NSString *)path
{
    NSString *error = nil;
    if (!wq_delete(path, &error)) {
        return [WQOp fail:[self messageFor:error fallback:@"删不掉"]];
    }
    return [WQOp ok:nil];
}

- (WQOp *)createDirectory:(NSString *)path
{
    NSString *error = nil;
    if (!wq_create_dir(path, &error)) {
        return [WQOp fail:[self messageFor:error fallback:@"建不了文件夹"]];
    }
    return [WQOp ok:nil];
}

- (WQOp *)renamePath:(NSString *)path newName:(NSString *)newName
{
    NSString *error = nil;
    if (!wq_rename(path, newName, &error)) {
        return [WQOp fail:[self messageFor:error fallback:@"改名失败"]];
    }
    return [WQOp ok:nil];
}

- (WQOp *)setImmutable:(BOOL)immutable forPath:(NSString *)path
{
    NSString *error = nil;
    if (!wq_set_immutable(path, immutable, &error)) {
        return [WQOp fail:error.length ? error : @"改不了冻结状态"];
    }
    return [WQOp ok:@(immutable)];
}

- (WQOp *)setMode:(unsigned int)mode forPath:(NSString *)path
{
    NSString *error = nil;
    if (!wq_chmod(path, (mode_t)mode, &error)) {
        return [WQOp fail:error.length ? error : @"改不了权限"];
    }
    return [WQOp ok:@(mode)];
}

- (BOOL)isImmutable:(NSString *)path
{
    return wq_is_immutable(path);
}

- (WQOp *)md5OfFile:(NSString *)path
{
    struct stat st;
    if (!wq_stat(path, &st)) return [WQOp fail:@"找不到这个文件"];
    if (!S_ISREG(st.st_mode)) return [WQOp fail:@"这个路径不是普通文件"];
    CC_MD5_CTX context;
    CC_MD5_Init(&context);
    unsigned long long offset = 0;
    unsigned long long total = (unsigned long long)st.st_size;
    const NSUInteger chunkSize = 1 << 20;
    while (offset < total) {
        @autoreleasepool {
            NSString *error = nil;
            NSData *chunk = wq_read_range(path, offset, chunkSize, &error);
            if (!chunk || chunk.length == 0) {
                return [WQOp fail:[self messageFor:error fallback:@"算校验值时读不了这个文件"]];
            }
            CC_MD5_Update(&context, chunk.bytes, (CC_LONG)chunk.length);
            offset += chunk.length;
        }
    }
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5_Final(digest, &context);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return [WQOp ok:[hex copy]];
}

- (BOOL)fileExists:(NSString *)path
{
    struct stat st;
    return path.length > 0 && wq_stat(path, &st);
}

- (BOOL)isDirectory:(NSString *)path
{
    struct stat st;
    return path.length > 0 && wq_stat(path, &st) && S_ISDIR(st.st_mode);
}

@end


@implementation MCMRetainedLease

+ (instancetype)leaseForClass:(uint64_t)cls
                    identifier:(NSString *)identifier
                         group:(BOOL)group
                         error:(NSString **)error {
    MCMAPI *api = MCMSharedAPI();
    if (!MCMBridgeAvailable() || !MCMSafeIdentifier(identifier)) {
        if (error) *error = @"MCM unavailable or identifier contains unsupported characters";
        return nil;
    }

    void *query = api->queryCreate();
    if (!query) {
        if (error) *error = @"query create failed";
        return nil;
    }

    api->querySetClass(query, cls);
    xpc_object_t value = xpc_string_create(identifier.UTF8String);
    if (group) api->querySetGroupIdentifiers(query, value);
    else api->querySetIdentifiers(query, value);
#if !OS_OBJECT_USE_OBJC
    xpc_release(value);
#endif
    api->querySetFlags(query, 0x900000000ULL);
    if (api->querySetPart) api->querySetPart(query, 0);

    void *result = api->queryGetSingle(query);
    if (!result) {
        void *queryError = api->queryGetLastError ? api->queryGetLastError(query) : NULL;
        int posix = queryError && api->errorGetPOSIX ? api->errorGetPOSIX(queryError) : 0;
        const char *message = queryError && api->errorGetMessage
            ? api->errorGetMessage(queryError) : NULL;
        if (error) *error = [NSString stringWithFormat:@"lookup denied posix=%d message=%s",
            posix, message ?: "unknown"];
        api->queryFree(query);
        return nil;
    }

    const char *rawPath = api->objectGetPath(result);
    NSString *rootPath = rawPath ? [NSString stringWithUTF8String:rawPath] : nil;
    if (rootPath.length == 0 || !rootPath.isAbsolutePath) {
        if (error) *error = @"MCM returned no absolute container path";
        api->queryFree(query);
        return nil;
    }
    if ([rootPath isEqualToString:@"/var"] || [rootPath hasPrefix:@"/var/"])
        rootPath = [@"/private" stringByAppendingString:rootPath];

    MCMRetainedLease *lease = [MCMRetainedLease new];
    lease->_query = query;
    lease.rootPath = rootPath;
    return lease;
}

- (BOOL)activate:(NSString **)error {
    if (self.activated) return YES;
    if (!_query) {
        if (error) *error = @"lease invalidated";
        return NO;
    }

    MCMAPI *api = MCMSharedAPI();
    void *result = api->queryGetSingle(_query);
    _activation = result ? api->objectCopy(result) : NULL;
    char *token = _activation ? api->objectCopyToken(_activation) : NULL;
    BOOL tokenPresent = token && token[0] != '\0';
    free(token);
    self.activated = tokenPresent && api->objectActivate(_activation, false);
    if (!self.activated && error) {
        *error = tokenPresent
            ? @"sandbox extension activation failed"
            : @"MCM object contained no sandbox token";
    }
    return self.activated;
}

- (void)dealloc {
    MCMAPI *api = MCMSharedAPI();
    if (_activation) api->objectFree(_activation);
    if (_query) api->queryFree(_query);
}

@end
