//
//  WQRoute.m
//  LaunchShield
//
//  GPL-3.0-or-later. Version split follows QuinnTang74/3106's support policy:
//  bad_query was verified on 26.0-26.6.1; Apple validated the part-domain
//  traversal after that, so 26.7+ and 27.x use worse_query. The 26.0-26.6.1
//  range is an overlap segment: an install that can open a usable App Group
//  takes worse_query (the route its signer already provisioned), and only an
//  install without a group falls back to bad_query.
//

#import "WQRoute.h"
#import "WQAccess.h"
#import "bad_query.h"

static BOOL gResolved;
static BOOL gBadQuery;

static void wq_route_resolve(void)
{
    if (gResolved) return;
    gResolved = YES;
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    BOOL overlap = v.majorVersion == 26 &&
        (v.minorVersion < 6 || (v.minorVersion == 6 && v.patchVersion <= 1));
    if (overlap) {
        gBadQuery = wq_app_group() == nil;
    } else {
        gBadQuery = NO;
    }
}

BOOL wq_route_is_bad_query(void)
{
    wq_route_resolve();
    return gBadQuery;
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
    return wq_route_is_bad_query() ? @"bad_query" : @"worse_query";
}

NSString *wq_route_detail(void)
{
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    NSString *version = [NSString stringWithFormat:@"%ld.%ld.%ld",
                         (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion];
    if (wq_route_is_bad_query()) {
        return [NSString stringWithFormat:@"bad_query（iOS %@，不需要共享组）", version];
    }
    return [NSString stringWithFormat:@"worse_query（iOS %@，需要共享组）", version];
}
