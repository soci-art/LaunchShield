//
//  WQAppCatalog.m
//  LaunchShield
//
//  GPL-3.0-or-later. Display names only; container discovery lives in
//  WQChannel and goes through the container manager.
//

#import "WQAppCatalog.h"
#import "WQAccess.h"

static NSDictionary<NSString *, NSString *> *gNames;
static NSDictionary<NSString *, NSString *> *gCategories;

NSDictionary<NSString *, NSString *> *wq_app_categories(void)
{
    // Populated as a side effect of the display-name pass below.
    (void)wq_app_display_names();
    return gCategories ?: @{};
}

NSDictionary<NSString *, NSString *> *wq_app_display_names(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary<NSString *, NSString *> *names = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSString *> *categories = [NSMutableDictionary dictionary];
        @try {
            Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
            if (workspaceClass) {
                id workspace = nil;
                if ([workspaceClass respondsToSelector:@selector(defaultWorkspace)]) {
                    workspace = [workspaceClass performSelector:@selector(defaultWorkspace)];
                }
                NSArray *apps = nil;
                if ([workspace respondsToSelector:@selector(allApplications)]) {
                    apps = [workspace performSelector:@selector(allApplications)];
                }
                if (!apps.count && [workspace respondsToSelector:@selector(allInstalledApplications)]) {
                    apps = [workspace performSelector:@selector(allInstalledApplications)];
                }
                for (id app in apps) {
                    NSString *bundleID = nil;
                    NSString *name = nil;
                    @try {
                        bundleID = [app valueForKey:@"bundleIdentifier"];
                        name = [app valueForKey:@"localizedName"];
                        if (![name isKindOfClass:NSString.class] || !name.length) name = [app valueForKey:@"itemName"];
                        id category = nil;
                        @try { category = [app valueForKey:@"applicationCategory"]; } @catch (NSException *e) { }
                        if (![category isKindOfClass:NSString.class] || ![category length]) {
                            @try { category = [app valueForKey:@"category"]; } @catch (NSException *e) { }
                        }
                        if ([bundleID isKindOfClass:NSString.class] && bundleID.length &&
                            [category isKindOfClass:NSString.class] && [category length]) {
                            categories[bundleID] = category;
                        }
                    } @catch (NSException *exception) {
                        continue;
                    }
                    if ([bundleID isKindOfClass:NSString.class] && bundleID.length &&
                        [name isKindOfClass:NSString.class] && name.length) {
                        names[bundleID] = name;
                    }
                }
            }
        } @catch (NSException *exception) {
            wq_log(@"app names: LaunchServices unavailable (%@)", exception.reason);
        }
        gNames = [names copy];
        gCategories = [categories copy];
    });
    return gNames;
}
