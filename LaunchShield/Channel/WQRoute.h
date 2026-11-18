//
//  WQRoute.h
//  LaunchShield
//
//  Picks the sandbox-grant backend from the signing mode detected in the
//  app's embedded provisioning profile. bad_query (Taj C / forcequit,
//  GPL-3.0-or-later) covers a free-ID signature without a borrowed App Group on
//  iOS 26.0-26.6.1; everything else goes through worse_query in WQAccess.
//  A free ID only counts a group borrowed from the installing host, never the
//  one the app's own provisioning profile names.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The route selected from the signature method and available entitlements.
typedef NS_ENUM(NSInteger, WQRouteState) {
    /// Signing mode could not be detected: the channel stays closed.
    WQRouteStateUnset = 0,
    /// worse_query: a certificate, or a free ID installed by a host whose
    /// group it borrowed.
    WQRouteStateWorse,
    /// bad_query: free ID without a borrowed group, on iOS 26.0-26.6.1.
    WQRouteStateBad,
    /// Certificate signing without a usable App Group entitlement.
    WQRouteStateMissingAppGroup,
    /// Free ID without a borrowed group on a version bad_query does not cover.
    WQRouteStateUnsupported,
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
