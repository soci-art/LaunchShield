//
//  WQRoute.h
//  LaunchShield
//
//  Route selection for the kernel edition: the only backend is the
//  kernel chain on iOS 17.0-18.7.1, which takes any signature, needs
//  no App Group, and must be started from the home screen. Every other
//  system reports Unsupported here (iOS 26/27 belongs to the formal
//  edition).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The route selected for this edition.
typedef NS_ENUM(NSInteger, WQRouteState) {
    /// Route not resolved yet: the channel stays closed.
    WQRouteStateUnset = 0,
    /// The system version is outside this edition's range.
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

/// "kernel"; a short Chinese label when there is no route.
NSString *wq_route_name(void);

/// Chinese one-liner for the UI, with the detected system version.
NSString *wq_route_detail(void);

NS_ASSUME_NONNULL_END
