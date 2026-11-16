# LaunchShield

LaunchShield 是一个 iOS 启动素材管理工具：定位其他应用缓存的开屏广告素材，备份后原地截断为 0 字节，并持续守护这些文件。首个验收目标是百度网盘（`com.baidu.netdisk`）。

版本 0.1.0（测试版），最低系统 iOS 26.0，SwiftUI。

## 功能

- **跨应用文件通道**：移植 kolbicz/WQFiles 的 WQAccess 容器访问层（worse_query 技术），不使用 dylib 注入。
- **容器浏览**：按应用列出数据容器，查看路径、大小、修改时间；图片和视频显示缩略图。
- **找广告（前后对比）**：对目标容器拍快照 → 让开屏广告播一次 → 再拍一次 → 列出「刚新增 / 变大了」的候选，勾选确认后才处理。
- **0 字节替换**：原地截断（保留 inode、属主和属性），改前先备份（记录原路径、大小、MD5），可一键还原并核对 MD5。
- **配方**：确认过的目标存为「Bundle ID ＋ 容器内相对路径」；「已守护应用」显示 0 字节＝正常、变大＝已复发、冻结、文件夹占位等状态，每次打开本应用自动复查。
- **百度网盘配方**：读取 `Library/Preferences/com.baidu.netdisk.plist` 中 `kBDNCSplashLastAdsFormat_*` 的广告 JSON，取 `activity_message` 里的素材网址原文算 MD5，定位 `Library/Caches/com.hackemist.SDImageCache/default/<md5>.png`；不写死文件名。全清零清单还包含优量汇、穿山甲、BeiZi 的缓存目录。
- **上锁**：冻结/解冻（`chflags UF_IMMUTABLE`）、同名文件夹占位与取消、文件权限调整。
- **守护模式**：用画中画（公开的 AVKit 视频通话 PiP 接口）让应用在后台存活；每 3 秒检查配方文件大小并立即重新截断，每 30 秒比对一次配方所在目录（新文件只提示，不自动处理）。守护被系统终止后，下次打开会明确显示中断时间。
- **日志**：记录每个文件的结果与失败原因，可复制，也可导出（导出内容带系统版本、应用版本、设备和共享组）。

## 签名要求（重要）

通道能力依赖 **App Group**，且没有写死任何组名：

1. 先用带 App Group 的证书和描述文件签名；
2. 应用启动时读自身 `embedded.mobileprovision` 的 `application-groups` 列表，再读签名 entitlements，按顺序逐个尝试打开，用第一个真正能用的；
3. 一个都打不开时，界面会明确提示「这个签名没有给可用的共享组，这个功能用不了」，不会静默失败，也不会回落到其他存储路径。

免费 Apple ID 的签名没有 App Group，本功能用不了；需要显式 App ID ＋ App Groups 能力 ＋ 对应描述文件。

## 构建

- 云端：每次推送 `main` 会自动构建未签名 IPA 并发布预发行版（标签 `v0.1.0-test.N`），见 `.github/workflows/build.yml`。
- 本地：用 Xcode 打开 `LaunchShield.xcodeproj`，选择 `LaunchShield` scheme，Release，真机或 generic iOS 设备。
- 应用图标在 `LaunchShield/Assets.xcassets/AppIcon.appiconset`，浅色与深色两版均由 `IconDesigns/` 的成品接入。

## 目录

```
LaunchShield/
  App/       SwiftUI 入口与首页
  UI/        各功能页面与通用组件
  Core/      状态、通道封装、备份、配方、百度配方、快照对比、守护
  Channel/   移植的 WQAccess 通道层与两个适配层（Objective-C）
```

## 许可

本项目按 **GPL-3.0-or-later** 分发，完整文本见 `LICENSE`；第三方署名与相对 WQFiles 上游的修改见 `NOTICE.md`。
