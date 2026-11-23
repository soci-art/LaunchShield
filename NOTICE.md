# 第三方代码与署名

LaunchShield 的跨应用文件通道移植自开源项目 **WQFiles**，并沿用其上游技术来源的署名：

- **WQFiles** — 作者 kolbicz，<https://github.com/kolbicz/WQFiles>，GPL-3.0-or-later。
  本工程移植了 `WQAccess.h` / `WQAccess.m` 及其直接依赖
  `WQAccessSafety.h`、`WQScanJournal.h`、`WQCore.h` / `WQCore.m`、
  `WQLocalization.h` / `WQLocalization.m`。
- **worse_query** — 作者 Taj C（forcequit），<https://github.com/forcequitOS/worse_query>，
  GPL-3.0-or-later。WQAccess 的沙箱扩展通道技术来自该项目。
- **KAMUI（fsgetpath）** — 作者 murk-sus。WQAccess 中用 fsgetpath 按 inode 解析路径的扫描思路来自该项目。

本工程整体按 **GPL-3.0-or-later** 分发，完整许可文本见仓库根目录的 `LICENSE`。

## 相对 WQFiles 上游的移植修改

仅移植容器访问层，没有引入上游的界面、归档、SQLite、网页服务、主题、分享等模块。

1. **App Group 运行时发现（重要）**：不写死任何组名。先读自身
   `embedded.mobileprovision` 里的 `application-groups` 列表（按描述文件顺序），
   再读签名里的同一项，逐个尝试打开（确认 `Library` 能创建并打开），
   用第一个真正能用的。一个都打不开时返回中文原因，交由界面明确提示，
   不静默失败、不回落到别的存储路径。
2. **新增接口**：`wq_chmod`、`wq_set_immutable`、`wq_is_immutable`、
   `wq_list_containers`（按容器类别列出 identifier 与路径）。
3. **新增适配层**：`WQChannel`（Swift 友好类型化封装，含流式 MD5）、
   `WQAppCatalog`（应用显示名，来自 LaunchServices）。
4. 去掉 `WQAccess.h` 对 `WQLaunchServices.h` 的包含（该头只被上游界面层使用）。

WQAccess 的原有安全流程（原地写回保 inode/属主/属性、备份优先、失败回滚、
`_if_unchanged` 版本校验）没有改动。

## 内核链路（iOS 17.0–18.7.1）

- **3105** — 作者 YangJiii，<https://github.com/YangJiiii/3105>，GPL-3.0。
  `LaunchShield/Channel/kexploit/` 下的 `kexploit_opa334`、`krw`、`kutils`、`offsets`、
  `vnode`、`xpaci`、`machine_info` 与 `sandbox_escape` 取自该项目，逻辑未改动。
- **FilzaSlop** — 作者 0xjohnnydev、CrazyMind90。3105 的 `sandbox_escape.m` 基于该项目。
- **Dopamine** — 作者 opa334。3105 的内核漏洞研究基础来自该项目。
- **3106** — 作者 QuinnTang74，<https://github.com/QuinnTang74/3106>，GPL-3.0。
  按系统版本选择内核链路／bad_query／worse_query 的分流口径参考该项目。

本工程新增的部分：

1. `WQKernel` 适配层：按顺序跑 `kexploit_opa334()` → `sandbox_escape()`，缓存结果、写日志；
   内核层源码未改动。
2. `WQRoute` 在 iOS 17.0–18.7.1 上先判为 kernel 路线（与签名方式、App Group 无关）；
   内核链路未启动时通道不开。
3. 内核链路激活后，`wq_grant` 直接放行（沙箱已整体放开），不再申请容器 token。

## bad_query 路线（iOS 26.0–26.6.1）

- **bad_query** — 作者 Taj C（forcequit），<https://github.com/forcequitOS/bad_query>，
  GPL-3.0-or-later。`bad_query.c` / `bad_query.h` 取自该项目（经 3106 收录的版本），
  去掉了其中的 fsgetpath 暴力扫描，只保留 `bad_query` / `bad_query_release`。
- **3106** — 作者 QuinnTang74，<https://github.com/QuinnTang74/3106>，GPL-3.0。
  按系统版本分流的范围参考该项目：26.0–26.6.1 用 bad_query，26.7+/27.x 用 worse_query。

本工程的改动：

1. 新增 `WQRoute` 分流层，按系统版本自动选路线；界面、日志和导出都会显示当前路线。
2. bad_query 路线使用 class 13（SystemGroup）下发授权，不需要 App Group，因此普通签名即可；
   worse_query 路线仍按共享组申请。
3. bad_query 路线跳过“先 lstat 再授权”的前置检查（深路径在授权前无法 stat）。
4. 目录列表改为一次授权 + 一次 `readdir` + `fstatat`（`wq_list_detailed`），不再逐文件申请授权；
   bad_query 路线下应用容器根目录也直接列，不再等待全盘扫描。
