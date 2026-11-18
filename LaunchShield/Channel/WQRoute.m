//
//  WQRoute.m
//  LaunchShield
//
//  GPL-3.0-or-later. The route follows the signature method the user picked,
//  not the system version alone:
//    cert                     -> worse_query (a group must exist)
//    free + a borrowed group  -> worse_query, any version
//    free, no borrowed group, 26.0-26.6.1 -> bad_query
//    free, no borrowed group, anything else -> unsupported
//    nothing picked           -> no route
//
// The free branch ignores the group the app's own profile names: a
// certificate install that picked "free ID" must not look like a ready
// channel. Only a group borrowed from the installing host counts.
//

#import "WQRoute.h"
#import "WQAccess.h"
#import "bad_query.h"

// Written by the home screen; values are "free" or "cert".
static NSString *const WQSignMethodKey = @"ls.signMethod";
static NSString *const WQSignMethodFree = @"free";
static NSString *const WQSignMethodCert = @"cert";

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

// bad_query was verified on 26.0-26.6.1; Apple validated the part-domain
// traversal after that.
static BOOL wq_route_version_supports_bad_query(void)
{
    NSOperatingSystemVersion v = wq_route_version();
    if (v.majorVersion != 26) return NO;
    return v.minorVersion < 6 || (v.minorVersion == 6 && v.patchVersion <= 1);
}

static NSString *wq_route_sign_method(void)
{
    NSString *method = [[NSUserDefaults standardUserDefaults] stringForKey:WQSignMethodKey];
    if (![method isKindOfClass:NSString.class] || method.length == 0) return nil;
    if ([method isEqualToString:WQSignMethodFree]) return WQSignMethodFree;
    if ([method isEqualToString:WQSignMethodCert]) return WQSignMethodCert;
    return nil;
}

static WQRouteState wq_route_compute(void)
{
    NSString *method = wq_route_sign_method();
    if (!method) return WQRouteStateUnset;
    // A certificate always runs worse_query; the version and the group are
    // not looked at.
    if ([method isEqualToString:WQSignMethodCert]) return WQRouteStateWorse;
    // Free ID: only a group borrowed from the installing host (a SideStore /
    // LiveContainer group) counts. The app's own profile group belongs to a
    // certificate install and must leave this branch alone.
    if (wq_borrowed_group() != nil) return WQRouteStateWorse;
    return wq_route_version_supports_bad_query() ? WQRouteStateBad : WQRouteStateUnsupported;
}

static NSString *wq_route_state_label(WQRouteState state)
{
    switch (state) {
        case WQRouteStateWorse: return @"worse_query";
        case WQRouteStateBad: return @"bad_query";
        case WQRouteStateUnsupported: return @"系统不支持";
        case WQRouteStateUnset: return @"未选择";
    }
    return @"未选择";
}

WQRouteState wq_route_state(void)
{
    if (gResolved) return gState;
    gState = wq_route_compute();
    gResolved = YES;
    wq_log(@"route: borrowedGroup=%@", wq_borrowed_group() ?: @"none");
    wq_log(@"route: signMethod=%@ state=%@", wq_route_sign_method() ?: @"none",
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
    switch (wq_route_state()) {
        case WQRouteStateBad:
            return [NSString stringWithFormat:@"bad_query（iOS %@，不需要共享组）", version];
        case WQRouteStateWorse:
            return [NSString stringWithFormat:@"worse_query（iOS %@，需要共享组）", version];
        case WQRouteStateUnsupported:
            return [NSString stringWithFormat:@"系统不支持（iOS %@，免费 ID 签名只支持 iOS 26.0–26.6.1）", version];
        case WQRouteStateUnset:
            return @"还没选签名方式";
    }
    return @"还没选签名方式";
}
