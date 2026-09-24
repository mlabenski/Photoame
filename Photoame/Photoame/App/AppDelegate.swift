import UIKit
import FirebaseMessaging

/// Handles Firebase configuration and the APNs <-> FCM token handshake. The
/// PushService reference is set by PhotoameApp so callbacks can route deep links.
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor var pushService: PushService?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseConfig.configure()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // In the Simulator (no APNs) this is expected; the app still runs.
        print("Remote notification registration failed: \(error.localizedDescription)")
    }
}
