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
private enum ShortcutRecheckRunner {
    private static var runningState: AppState?

    static func run() async -> String {
        await withCheckedContinuation { continuation in
            let state = AppState()
            runningState = state
            state.runShortcutRecheck { summary in
                runningState = nil
                continuation.resume(returning: summary)
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
