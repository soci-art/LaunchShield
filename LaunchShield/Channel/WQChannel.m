//
//  WQChannel.m
//  LaunchShield
//
//  GPL-3.0-or-later. Channel implementation: kolbicz/WQFiles (WQAccess),
//  worse_query by Taj C / forcequit.
//

#import "WQChannel.h"
#import "WQAppCatalog.h"
#import "WQLaunchServices.h"
#import "WQAccess.h"
#import "WQRoute.h"
#import "bad_query.h"
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>

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

- (BOOL)badQueryGrantWorks
{
    static NSInteger cached = -1;
    static NSTimeInterval checkedAt;
    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    if (cached >= 0 && now - checkedAt < 30) return cached == 1;
    int64_t handle = wq_route_bad_grant("/private/var/mobile/Containers/Data/Application");
    BOOL ok = handle >= 0;
    wq_log(@"route probe: bad_query grant handle=%lld result=%@",
           handle, ok ? @"ok" : @"failed");
    if (ok) bad_query_release(handle);
    cached = ok ? 1 : 0;
    checkedAt = now;
    return ok;
}

- (BOOL)available
{
    WQRouteState state = wq_route_state();
    switch (state) {
        case WQRouteStateBad: {
            BOOL ok = [self badQueryGrantWorks];
            wq_log(@"channel availability: route=bad_query result=%@",
                   ok ? @"available" : @"unavailable");
            return ok;
        }
        case WQRouteStateWorse: {
            BOOL ok = wq_app_group() != nil;
            wq_log(@"channel availability: route=worse app_group=%@",
                   ok ? @"available" : @"missing");
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

- (NSString *)groupID
{
    return wq_app_group();
}

- (NSString *)groupText
{
    switch (wq_route_state()) {
        case WQRouteStateBad:
            return @"不需要（bad_query 走系统组）";
        case WQRouteStateWorse:
            return wq_app_group() ?: @"没有拿到";
        case WQRouteStateUnset:
        case WQRouteStateUnsupported:
            return @"这个签名方式不用共享组";
    }
    return @"没有拿到";
}

- (NSString *)routeName
{
    return wq_route_name();
}

- (NSString *)routeDetail
{
    return wq_route_detail();
}

- (BOOL)usesBadQuery
{
    return wq_route_is_bad_query();
}

- (NSString *)unavailableReason
{
    switch (wq_route_state()) {
        case WQRouteStateUnset:
            return @"还没选签名方式：在主页上方选一下你装这个应用时用的签名方式，通道才能打开。";
        case WQRouteStateUnsupported:
            return @"系统不支持：免费 ID 签名只支持 iOS 26.0–26.6.1，你现在的系统用不了这条路线。";
        case WQRouteStateBad:
            return @"bad_query 在这台设备上没拿到访问权限。请确认系统版本（26.0–26.6.1）和签名方式后再试。";
        case WQRouteStateWorse: {
            NSString *reason = wq_app_group_error();
            return reason.length ? reason : @"文件通道不可用。";
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

#pragma mark - Containers

// Last-resort label: read the container's own metadata plist through the
// channel, without the permission pre-check the shared helper applies (on
// iOS 27.x that pre-check guesses "unreadable" for files the channel can in
// fact read).
- (NSString *)metadataLabelForPath:(NSString *)path
{
    NSString *meta = [path stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    NSString *error = nil;
    NSData *data = wq_read(meta, 64 * 1024, &error);
    if (!data.length) return nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
    if (![plist isKindOfClass:NSDictionary.class]) return nil;
    NSString *identifier = plist[@"MCMMetadataIdentifier"];
    if (![identifier isKindOfClass:NSString.class] || ![identifier containsString:@"."]) return nil;
    if ([identifier hasPrefix:@"com.apple."]) return nil;
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
    if (wq_route_is_bad_query()) {
        // bad_query grants a folder in one query, so both roots can be listed
        // directly instead of waiting for a full inode scan.
        for (NSString *root in roots) {
            for (NSString *name in wq_list(root, NULL) ?: @[]) {
                if (!name.length || [name hasPrefix:@"."]) continue;
                NSString *path = [root stringByAppendingPathComponent:name];
                NSString *identifier = [self labelForPath:path];
                if (identifier.length) [rows addObject:@{ @"identifier": identifier, @"path": path }];
            }
        }
        wq_log(@"containers: bad_query listed %lu directly", (unsigned long)rows.count);
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

- (WQAppContainer *)containerForBundleID:(NSString *)bundleID
{
    for (WQAppContainer *container in [self appContainers]) {
        if ([container.identifier isEqualToString:bundleID]) return container;
    }
    return nil;
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

- (WQOp *)statPath:(NSString *)path
{
    WQFileItem *item = [self itemAtPath:path name:path.lastPathComponent];
    if (!item) return [WQOp fail:@"找不到这个文件"];
    return [WQOp ok:item];
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
        return [WQOp fail:[self messageFor:error fallback:@"清零失败"]];
    }
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
