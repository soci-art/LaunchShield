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

NSDictionary<NSString *, NSString *> *wq_app_display_names(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary<NSString *, NSString *> *names = [NSMutableDictionary dictionary];
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
    });
    return gNames;
}
