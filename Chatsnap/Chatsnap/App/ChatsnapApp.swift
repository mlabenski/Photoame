import SwiftUI

@main
struct ChatsnapApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .preferredColorScheme(.dark)
                .task {
                    appDelegate.pushService = env.push
                    env.auth.start()
                    env.push.configure()
                }
        }
    }
}
