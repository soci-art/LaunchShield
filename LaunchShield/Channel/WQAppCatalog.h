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

NS_ASSUME_NONNULL_END
