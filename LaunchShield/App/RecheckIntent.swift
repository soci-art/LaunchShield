import AppIntents

/// 第 103 条：给快捷指令用的动作——在后台跑一遍打开 App 时
/// 自动做的复查（目录补扫自动去除＋配方复查），不用打开 App。
/// 用户在快捷指令 App 里建一个每日定时自动化调它，就能每天
/// 自动复查一次。跑完返回一句话结果，快捷指令会显示出来；
/// 全程写进 App 的日志，事后打开 App 能查到跑没跑完。
struct RecheckAdsIntent: AppIntent {
    static var title: LocalizedStringResource = "复查并去除复发的广告"
    static var description = IntentDescription("把已知广告目录和守护文件夹里新冒出来的广告文件备份、去除并冻结，跟打开 LaunchShield 时自动做的那一轮一样，不用打开应用。")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let summary = await ShortcutRecheckRunner.run()
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

/// 跑复查期间留住那个 AppState 实例，跑完才放。
/// 第 103 条修法：快捷指令等一个动作的耐心只有约 30 秒，文件多
/// 的一轮跑不完它就报「未知错误」——所以最多等 25 秒，超时先
/// 回一句说明，让快捷指令正常收尾；复查本身接着跑（进程还
/// 活着就跑完，被系统收走也会在下次打开应用时由启动补扫接上），
/// 最终清了几个照样写进日志。
private enum ShortcutRecheckRunner {
    private static var runningState: AppState?

    static func run() async -> String {
        await withCheckedContinuation { continuation in
            let state = AppState()
            runningState = state
            let lock = NSLock()
            var resumed = false
            let finish: (String) -> Void = { summary in
                lock.lock()
                if resumed { lock.unlock(); return }
                resumed = true
                lock.unlock()
                if runningState === state { runningState = nil }
                continuation.resume(returning: summary)
            }
            state.runShortcutRecheck(completion: finish)
            DispatchQueue.global().asyncAfter(deadline: .now() + 25) {
                finish("文件多，这轮没清完；打开 LaunchShield 时会接着清，结果看日志")
            }
        }
    }
}

struct LaunchShieldShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RecheckAdsIntent(),
                    phrases: ["用 \(.applicationName) 复查广告"],
                    shortTitle: "复查并去除复发",
                    systemImageName: "shield.checkered")
    }
}
