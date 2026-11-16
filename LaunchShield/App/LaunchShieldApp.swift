import SwiftUI

@main
struct LaunchShieldApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
                .onAppear {
                    state.bootstrap()
                }
        }
    }
}
