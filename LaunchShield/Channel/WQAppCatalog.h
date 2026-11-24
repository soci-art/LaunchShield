//
//  WQAppCatalog.h
//  LaunchShield
//
//  App display names from LaunchServices. Best effort: the app list falls
//  back to bundle ids when the private workspace class is unavailable.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSDictionary<NSString *, NSString *> *wq_app_display_names(void);

/// Bundle ids of installed apps (not app extensions/plug-ins). Empty when
/// LaunchServices is unavailable; callers must treat empty as "unknown".
NSSet<NSString *> *wq_main_app_bundle_ids(void);

/// App Store category per bundle id (e.g. "public.app-category.games"),
/// best effort like the display names. Missing entries mean "unknown".
NSDictionary<NSString *, NSString *> *wq_app_categories(void);

NS_ASSUME_NONNULL_END
