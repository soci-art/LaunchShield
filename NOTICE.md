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
