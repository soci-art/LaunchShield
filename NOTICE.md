# 第三方代码与署名

LaunchShield 的跨应用文件通道移植自开源项目 **WQFiles**，并沿用其上游技术来源的署名：

- **WQFiles** — 作者 kolbicz，<https://github.com/kolbicz/WQFiles>，GPL-3.0-or-later。
  本工程移植了 `WQAccess.h` / `WQAccess.m` 及其直接依赖
  `WQAccessSafety.h`、`WQScanJournal.h`、`WQCore.h` / `WQCore.m`、
  `WQLocalization.h` / `WQLocalization.m`。
- **worse_query** — 作者 Taj C（forcequit），<https://github.com/forcequitOS/worse_query>，
  GPL-3.0-or-later。WQAccess 的沙箱扩展通道技术来自该项目；内核专用版
  （iOS 17/18）已移除这套扩展申请实现，沙箱由内核链路整体解除，此处保留署名
  与来源说明。
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

- **内核链路上游项目** — 作者 YangJiii，GPL-3.0。
  `LaunchShield/Channel/kexploit/` 下的 `kexploit_opa334`、`krw`、`kutils`、`offsets`、
  `vnode`、`xpaci`、`machine_info` 与 `sandbox_escape` 取自该项目，作为基线；本工程对内核层的修改见本节末尾。
- **FilzaSlop** — 作者 0xjohnnydev、CrazyMind90。内核链路的 `sandbox_escape.m` 基于该项目。
- **Dopamine** — 作者 opa334。内核链路的漏洞研究基础来自该项目。
- **分流口径参考项目** — 作者 QuinnTang74，GPL-3.0。
  按系统版本选择内核链路的分流口径参考该项目。
- **探针口径参考项目** — 作者 QuinnTang74，GPL-3.0。
  `sandbox_escape.m` 的“两个容器根任一根可写即视为逃逸成功”探针口径参考该项目；
  LaunchShield 保留了自己的 socket 凭证兜底（`ucred_self`），`proc_self()==0` 时仍会尝试逃逸。

本工程新增的部分：

1. `WQKernel` 适配层：按顺序跑 `kexploit_opa334()` → `sandbox_escape()`，缓存结果、写日志。
2. `WQRoute` 在 iOS 17.0–18.7.1 上先判为 kernel 路线（与签名方式、App Group 无关）；
   内核链路未启动时通道不开。
3. 内核链路激活后，`wq_grant` 直接放行（沙箱已整体放开），不再申请容器 token。
4. 内核专用版移除了整套沙箱扩展申请实现（`bad_query`、`worse_query` 的 token
   查询/换入换出与缓存修复、`wq_reset_access_cache`）；在本版里没有沙箱需要
   逐路径申请，这些代码在内核链路下永远不会执行。

本工程对内核层的修改：

1. `kexploit_opa334.m` / A18 `pe_v2`：wired window 上限 512 MB（并按进程可用内存
   再折半封顶，有 128 MB 下限），物理 OOB 读取与 icmp6filter 回写改为有界重试，
   socket 预算耗尽后短暂退避而不是 `sleep(20)`，起跑前检查可用内存与 `RLIMIT_NOFILE`。
2. `kexploit_opa334.m` / A15 `pe_v1`：每轮 256 MB × 4 轮（原来每轮 1 GB 且无轮数上限），
   轮末同时释放 search mapping 的 IOSurface，避免每轮泄漏 1 GB；失败分支正常清理。
3. `sandbox_escape.m`：探针改为“两个容器根任一根可写即成功”，并新增
   `sandbox_probe_report` 把每个根的结果写进内核日志；`proc_self()==0` 的
   socket 凭证兜底保留。
4. `WQAccess.m`：底层内核日志的导出改为只读快照，不再在每次复制/导出时截断落盘文件；
   文件仍按 1 MiB 上限裁旧行。
5. `kexploit_opa334.m`：`pe_v2` 改为每轮正向单遍扫描 + 末尾复扫已释放页（原来每释放
   一页就归零重扫，代价随页数平方增长）；扫描在映射末尾提前 `pcSize` 停下，避免物理
   窗口越界 panic；单次 OOB 读的内部竞争回合与每页重试次数都可按参数表调节，并加入
   "连续多次慢读就提前结束本轮换参数"的健康度截断。
6. `kexploit_opa334.m`：新增 icmp6 过滤指针的恢复/重新武装
   （`kexploit_filter_set`、`wq_kernel_set_quiesced`），离开前台时把控制 socket 的
   `inp6_icmp6filt` 指回合法缓冲区，避免进程退出时内核把它当作 32 字节对象释放而 panic。
