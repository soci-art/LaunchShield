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

/// YES on supported OS/device combinations: iOS 17.0-17.7.x (except A10)
/// and iOS 18.0-18.7.1. Unknown combinations fail closed.
BOOL wq_kernel_supported(void);
BOOL wq_kernel_unsupported_a10_ios17(void);

/// YES once the chain has run in this process and the sandbox is gone.
/// Cheap: it only reads the cached result.
BOOL wq_kernel_active(void);

/// YES while wq_kernel_start() is running on another thread.
BOOL wq_kernel_running(void);

/// YES when the last start attempt failed. A relaunch is needed to retry.
BOOL wq_kernel_failed(void);

/// Seconds since boot, or -1 when it cannot be read.
double wq_kernel_uptime(void);
/// YES when the device booted less than WQ_KERNEL_MIN_UPTIME ago: a start now
/// would run on top of the previous run's unreclaimed pages and sockets, and
/// is refused without consuming the one-shot attempt.
BOOL wq_kernel_boot_too_soon(void);
/// Seconds still to wait before a start is allowed; 0 when it is allowed now.
int wq_kernel_boot_wait_seconds(void);

/// Runs kexploit_opa334() and sandbox_escape() for this process. Blocks for
/// 1-3 minutes; call it off the main thread. A failed attempt can restart
/// the app, so the UI only calls this after the user taps.
BOOL wq_kernel_start(void);

/// Logs the newest kernel panic reports (usually the previous attempt's
/// crash), or a line saying there are none. Best effort, needs no kernel
/// access; call it off the main thread at launch and before an attempt.
void wq_kernel_log_recent_panics(void);

/// 第 92 条：把控制 socket 的 icmp6filt 指针恢复成合法缓冲区 / 重新指回 rw 的
/// PCB。进程退出时内核会把这个字段当 32 字节对象释放，指针还指着 PCB 就会
/// panic（panic 报告："not in the expected zone data.kalloc.32"）。所以进后台
/// （用户随时可能划掉应用）就恢复，回前台再武装。quiesced=YES 表示"不放内核
/// 状态了"，NO 表示"继续用内核读写"。返回 0 表示状态已是目标值。
int wq_kernel_set_quiesced(BOOL quiesced);
/// 内核链路是否处于"已恢复、可安全退出"的状态。
BOOL wq_kernel_quiesced(void);

NS_ASSUME_NONNULL_END
