//
//  WQKernel.h
//  LaunchShield
//
//  Adapter for the iOS 17/18 kernel chain ported from YangJiii's
//  upstream project (GPL-3.0). kexploit_opa334 establishes kernel read/write and
//  sandbox_escape patches this process's sandbox so ordinary POSIX calls
//  reach every container, so no App Group and no container query is needed.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// YES on the builds the chain was verified on: iOS 17.0-17.7.x and
/// 18.0-18.7.1. Everywhere else the chain is not offered at all.
BOOL wq_kernel_supported(void);

/// YES once the chain has run in this process and the sandbox is gone.
/// Cheap: it only reads the cached result.
BOOL wq_kernel_active(void);

/// YES while wq_kernel_start() is running on another thread.
BOOL wq_kernel_running(void);

/// YES when the last start attempt failed. A relaunch is needed to retry.
BOOL wq_kernel_failed(void);

/// Runs kexploit_opa334() and sandbox_escape() for this process. Blocks for
/// 10-30 seconds; call it off the main thread. A failed attempt can restart
/// the app, so the UI only calls this after the user taps.
BOOL wq_kernel_start(void);

NS_ASSUME_NONNULL_END
