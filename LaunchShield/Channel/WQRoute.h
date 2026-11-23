//
//  WQRoute.h
//  LaunchShield
//
//  Picks the sandbox-grant backend from the current process's capabilities.
//  Any usable App Group entitlement selects worse_query, regardless of whether
//  it came from a paid certificate or a Personal Team / SideStore signature.
//  On iOS 26.0-26.6.1 only, bad_query remains the fallback when no usable
//  App Group is available. Actual target-container access is verified later.
//  iOS 17.0-18.7.1 has its own route: the kernel chain, which takes
//  any signature, needs no App Group, and must be started from the home screen.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The route selected from the signature method and available entitlements.
typedef NS_ENUM(NSInteger, WQRouteState) {
    /// Signing mode could not be detected: the channel stays closed.
    WQRouteStateUnset = 0,
    /// worse_query: the process has any usable App Group entitlement.
    WQRouteStateWorse,
    /// bad_query: no usable App Group, on iOS 26.0-26.6.1.
    WQRouteStateBad,
    /// No usable App Group entitlement where bad_query is not supported.
    WQRouteStateMissingAppGroup,
    /// The system version is outside the available backend ranges.
    WQRouteStateUnsupported,
    /// kernel: iOS 17.0-18.7.1, the kernel chain. No App Group and
    /// no container query; it has to be started from the home screen once.
    WQRouteStateKernel,
};

/// Automatically detected signing mode: @"free" or @"cert".
NSString *wq_route_sign_method(void);

/// Current route. Resolved once, then cached until wq_route_reset().
WQRouteState wq_route_state(void);

/// Forgets the resolved route so the next query re-reads the signed profile.
void wq_route_reset(void);

/// YES only when the current state is bad.
BOOL wq_route_is_bad_query(void);

/// One bad_query grant for an absolute path (create=YES: no lstat first).
/// Returns a sandbox extension handle, or a negative error code.
int64_t wq_route_bad_grant(const char *path);

/// "bad_query" / "worse_query"; a short Chinese label when there is no route.
NSString *wq_route_name(void);

/// Chinese one-liner for the UI, with the detected system version.
NSString *wq_route_detail(void);

NS_ASSUME_NONNULL_END
