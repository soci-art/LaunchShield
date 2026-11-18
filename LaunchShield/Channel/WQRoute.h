//
//  WQRoute.h
//  LaunchShield
//
//  Picks the sandbox-grant backend for the running iOS build. The builds
//  bad_query (Taj C / forcequit, GPL-3.0-or-later) was verified for
//  (26.0-26.6.1) form an overlap segment: installs with a usable App Group
//  use worse_query through WQAccess, installs without one use bad_query.
//  Everything newer always uses worse_query.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// YES when this build should grant through bad_query.
BOOL wq_route_is_bad_query(void);

/// One bad_query grant for an absolute path (create=YES: no lstat first).
/// Returns a sandbox extension handle, or a negative error code.
int64_t wq_route_bad_grant(const char *path);

/// "bad_query" or "worse_query".
NSString *wq_route_name(void);

/// Chinese one-liner for the UI, with the detected system version.
NSString *wq_route_detail(void);

NS_ASSUME_NONNULL_END
