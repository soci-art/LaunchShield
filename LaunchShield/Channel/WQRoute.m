//
//  WQRoute.m
//  LaunchShield
//
//  GPL-3.0-or-later. Route selection for the kernel edition:
//    iOS 17.0-18.7.1 -> the kernel chain (any signature, no group)
//    otherwise -> unavailable (iOS 26/27 belongs to the formal edition)
//

#import "WQRoute.h"
#import "WQAccess.h"
#import "WQKernel.h"
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

// Hardware identifier (for example, iPhone15,3), distinct from the marketing
// model name returned by UIDevice. This is diagnostic only; it never selects
// or enables a sandbox-access route.
static NSString *wq_route_hardware_model_text(void)
{
    char machine[128] = {0};
    size_t size = sizeof(machine);
    if (sysctlbyname("hw.machine", machine, &size, NULL, 0) != 0 || machine[0] == '\0')
        return @"unknown";
    return [NSString stringWithUTF8String:machine] ?: @"unknown";
}

NSString *wq_route_sign_method(void)
{
    return wq_detect_sign_method();
}

static WQRouteState wq_route_compute(void)
{
    // The kernel chain is this edition's only backend: signature-
    // independent, no App Group. Everything else is unsupported here.
    if (wq_kernel_supported()) return WQRouteStateKernel;
    return WQRouteStateUnsupported;
}

static NSString *wq_route_state_label(WQRouteState state)
{
    switch (state) {
        case WQRouteStateKernel: return @"kernel";
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
    wq_log(@"route: signMethod=%@ iOS=%@ build=%@ hw.machine=%@ state=%@",
           wq_route_sign_method() ?: @"none",
           wq_route_version_text(), wq_route_build_text(),
           wq_route_hardware_model_text(),
           wq_route_state_label(gState));
    return gState;
}

void wq_route_reset(void)
{
    gResolved = NO;
    gState = WQRouteStateUnset;
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
        case WQRouteStateKernel:
            return [NSString stringWithFormat:@"内核链路（iOS %@，不需要共享组，要手动启动）", version];
        case WQRouteStateUnsupported:
            if (wq_kernel_unsupported_a10_ios17())
                return @"系统不支持（A10 + iOS 17 组合未纳入已验证范围，已阻止启动内核链路）";
            if (wq_route_version().majorVersion >= 26) {
                return [NSString stringWithFormat:@"系统不支持（iOS %@%@，此版本为 iOS 17/18 内核专用版，请使用正式版）", version,
                        build.length ? [NSString stringWithFormat:@"，构建 %@", build] : @""];
            }
            return [NSString stringWithFormat:@"系统不支持（iOS %@%@，内核专用版只支持 iOS 17.0–18.7.1）", version,
                    build.length ? [NSString stringWithFormat:@"，构建 %@", build] : @""];
        case WQRouteStateUnset:
            return @"无法自动识别当前访问通道";
    }
    return @"还没选访问通道";
}
