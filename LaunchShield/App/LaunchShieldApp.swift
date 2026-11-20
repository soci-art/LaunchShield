import SwiftUI
import UIKit

@main
struct LaunchShieldApp: App {
    @StateObject private var state = AppState()

    init() {
        // 界面重影对策：系统启动时会先贴一张上回的界面截图，
        // 这张截图在 iOS 27.2 beta 2 上会和真实界面错开叠在一起、迟迟不撤。
        // 让系统下次启动不要再用这张截图，改为直接显示启动画面。
        UIApplication.shared.ignoreSnapshotOnNextApplicationLaunch()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .onAppear {
                    state.bootstrap()
                }
        }
    }
}
