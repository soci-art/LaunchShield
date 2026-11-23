//
//  WQKernel.m
//  LaunchShield
//
//  GPL-3.0-or-later. The kernel chain itself is 3105's
//  (YangJiii, https://github.com/YangJiiii/3105, GPL-3.0):
//  kexploit_opa334 establishes kernel read/write, then sandbox_escape patches
//  this process's sandbox extension set so plain file calls work everywhere.
//  This file only sequences the two stages and caches the result.
//

#import "WQKernel.h"
#import "WQAccess.h"
#import "kexploit/kexploit_opa334.h"
#import "kexploit/kutils.h"
#import "kexploit/sandbox_escape.h"

static NSLock *gKernelLock;
static BOOL gKernelActive;
static BOOL gKernelRunning;
static BOOL gKernelFailed;

static NSLock *wq_kernel_lock(void)
{
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });
    return lock;
}

BOOL wq_kernel_supported(void)
{
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    if (v.majorVersion == 17) return v.minorVersion <= 7;
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
    if (!wq_kernel_supported()) {
        wq_log(@"kernel: this iOS version is outside the verified 17.0-18.7.1 range; not starting");
        return NO;
    }

    NSLock *lock = wq_kernel_lock();
    [lock lock];
    if (gKernelActive) {
        [lock unlock];
        return YES;
    }
    if (gKernelRunning) {
        [lock unlock];
        return NO;
    }
    gKernelRunning = YES;
    gKernelFailed = NO;
    [lock unlock];

    // Stage 1: kernel read/write. FAILURE() inside the exploit phase returns
    // an error code instead of terminating the process.
    wq_log(@"kernel: stage 1/2, kernel read/write (kexploit_opa334); this takes 10-30 s");
    int exploit = kexploit_opa334();
    if (exploit != 0) {
        [lock lock];
        gKernelRunning = NO;
        gKernelFailed = YES;
        [lock unlock];
        wq_log(@"kernel: kexploit_opa334 returned %d (unsupported build, offset mismatch, or a lost race). Relaunch and try again.", exploit);
        return NO;
    }
    wq_log(@"kernel: kernel read/write is up");

    // Stage 2: patch this process's sandbox so ordinary file calls reach
    // every container. Without it LaunchShield cannot read other apps' data.
    wq_log(@"kernel: stage 2/2, sandbox escape (sandbox_escape)");
    uint64_t selfProc = proc_self();
    // sandbox_escape() already writes, reads back and deletes probe files; it
    // returns 0 only when that probe passed, so trust it here.
    int escape = selfProc ? sandbox_escape(selfProc) : -1;
    BOOL active = escape == 0;

    [lock lock];
    gKernelRunning = NO;
    gKernelActive = active;
    gKernelFailed = !active;
    [lock unlock];

    if (active) {
        wq_log(@"kernel: sandbox escaped; full filesystem read/write is available");
    } else if (selfProc == 0) {
        wq_log(@"kernel: proc_self() returned 0; the chain is not active");
    } else {
        wq_log(@"kernel: sandbox_escape returned %d; the chain is not active", escape);
    }
    return active;
}
