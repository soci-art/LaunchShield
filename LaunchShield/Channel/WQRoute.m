//
//  WQRoute.m
//  LaunchShield
//
//  GPL-3.0-or-later. Route selection is capability-based:
//    supported OS/build + a usable process App Group -> worse_query
//    supported OS/build + no usable group + iOS 26.0-26.6.1 -> bad_query
//    otherwise -> unavailable
//
//  The signing-method label is diagnostic only. The effective process
//  application-groups entitlement (with a signed-Mach-O fallback) decides
//  whether worse_query can be attempted; paid/free signing labels do not.
//

#import "WQRoute.h"
#import "WQAccess.h"
#import "bad_query.h"
#import <sys/sysctl.h>
#import <stdlib.h>

static WQRouteState gState = WQRouteStateUnset;
static BOOL gResolved;

static NSOperatingSystemVersion wq_route_version(void)
{
    return NSProcessInfo.processInfo.operatingSystemVersion;
}

static NSString *wq_route_version_text(void)
{
    NSOperatingSystemVersion v = wq_route_version();
    return [NSString stringWithFormat:@"%ld.%ld.%ld",
            (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion];
}

static NSString *wq_route_build_text(void)
{
    size_t size = 0;
    if (sysctlbyname("kern.osversion", NULL, &size, NULL, 0) != 0 || size == 0)
        return @"";
    char *buffer = calloc(size, sizeof(char));
    if (!buffer) return @"";
    NSString *build = @"";
    if (sysctlbyname("kern.osversion", buffer, &size, NULL, 0) == 0)
        build = [NSString stringWithUTF8String:buffer] ?: @"";
    free(buffer);
    return [build stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// Upstream WQFiles support window: iOS 26.0-26.7.2 and iOS 27.0 through
// 27.3 beta 1. Apple fixed worse_query in 27.3 beta 2 (24C5049d).
// Unknown/newer builds fail closed instead of assuming compatibility.
static BOOL wq_route_version_supports_worse_query(void)
{
    NSOperatingSystemVersion v = wq_route_version();
    if (v.majorVersion == 26) {
        return v.minorVersion < 7 || (v.minorVersion == 7 && v.patchVersion <= 2);
    }
    if (v.majorVersion == 27) {
        if (v.minorVersion < 3) return YES;
        if (v.minorVersion == 3 && v.patchVersion == 0)
            return [wq_route_build_text() isEqualToString:@"24C5037i"];
    }
    return NO;
}

// bad_query was verified on iOS 26.0-26.6.1; Apple validated the
// part-domain traversal after that range.
static BOOL wq_route_version_supports_bad_query(void)
{
    NSOperatingSystemVersion v = wq_route_version();
    if (v.majorVersion != 26) return NO;
    return v.minorVersion < 6 || (v.minorVersion == 6 && v.patchVersion <= 1);
}

NSString *wq_route_sign_method(void)
{
    return wq_detect_sign_method();
}

static WQRouteState wq_route_compute(void)
{
    if (!wq_route_version_supports_worse_query())
        return WQRouteStateUnsupported;

    // The actual process entitlement is decisive. Personal Team / free Apple
    // ID signing is not rejected by name: if SecTask exposes a usable group,
    // worse_query can use it just like any other signing method.
    if (wq_app_group() != nil)
        return WQRouteStateWorse;

    // Only the older verified segment has the no-App-Group fallback.
    return wq_route_version_supports_bad_query()
        ? WQRouteStateBad : WQRouteStateMissingAppGroup;
}

static NSString *wq_route_state_label(WQRouteState state)
{
    switch (state) {
        case WQRouteStateWorse: return @"worse_query";
        case WQRouteStateBad: return @"bad_query";
        case WQRouteStateMissingAppGroup: return @"缺少 App Group";
        case WQRouteStateUnsupported: return @"系统不支持";
        case WQRouteStateUnset: return @"无法识别";
    }
    return @"未选择";
}

WQRouteState wq_route_state(void)
{
    if (gResolved) return gState;
    gState = wq_route_compute();
    gResolved = YES;
    // Avoid touching the App Group cache on a system already known to be
    // outside the supported worse_query window.
    NSString *effectiveGroup = gState == WQRouteStateWorse ? wq_app_group() : nil;
    wq_log(@"route: effectiveAppGroup=%@",
           effectiveGroup ?: @"none");
    wq_log(@"route: signMethod=%@ iOS=%@ build=%@ state=%@",
           wq_route_sign_method() ?: @"none",
           wq_route_version_text(), wq_route_build_text(),
           wq_route_state_label(gState));
    return gState;
}

void wq_route_reset(void)
{
    gResolved = NO;
    gState = WQRouteStateUnset;
}

BOOL wq_route_is_bad_query(void)
{
    return wq_route_state() == WQRouteStateBad;
}

int64_t wq_route_bad_grant(const char *path)
{
    if (!path || path[0] != '/') return -255;
    // Class 13 (SystemGroup) with the part-domain traversal. The App Group is
    // not involved, so a plain signature can use this route.
    return bad_query((char *)path, true, NULL, false);
}

NSString *wq_route_name(void)
{
    return wq_route_state_label(wq_route_state());
}

NSString *wq_route_detail(void)
{
    NSString *version = wq_route_version_text();
    NSString *build = wq_route_build_text();
    switch (wq_route_state()) {
        case WQRouteStateBad:
            return [NSString stringWithFormat:@"bad_query（iOS %@，不需要共享组）", version];
        case WQRouteStateWorse:
            return [NSString stringWithFormat:@"worse_query（iOS %@，已检测到进程可用的共享组）", version];
        case WQRouteStateMissingAppGroup:
            return wq_app_group_error() ?: @"当前进程没有可用的 App Group；请检查实际签名 entitlements。";
        case WQRouteStateUnsupported:
            return [NSString stringWithFormat:@"系统版本或构建号不在已验证范围内（iOS %@%@）。当前仅支持 iOS 26.0–26.7.2、iOS 27.0–27.3 beta 1（24C5037i）；Apple 已在 27.3 beta 2 修复 worse_query。", version,
                    build.length ? [NSString stringWithFormat:@"，构建 %@", build] : @""];
        case WQRouteStateUnset:
            return @"无法自动识别当前访问通道";
    }
    return @"还没选访问通道";
}
