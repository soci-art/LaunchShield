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

/// Drop the cached LaunchServices catalog. Call after the kernel chain makes
/// LaunchServices readable again; before that the first lookup can cache an
/// empty result for the whole process.
void wq_app_catalog_invalidate(void);

/// Bundle ids of installed apps (not app extensions/plug-ins). Empty when
/// LaunchServices is unavailable; callers must treat empty as "unknown".
NSSet<NSString *> *wq_main_app_bundle_ids(void);

/// Bundle ids of app extensions/plug-ins reported by each installed app.
NSSet<NSString *> *wq_extension_bundle_ids(void);

/// App Store category per bundle id (e.g. "public.app-category.games"),
/// best effort like the display names. Missing entries mean "unknown".
NSDictionary<NSString *, NSString *> *wq_app_categories(void);

NS_ASSUME_NONNULL_END
