import Foundation
import UIKit
import UserNotifications
import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging

/// A deep link parsed from a tapped notification.
struct SnapDeepLink: Equatable, Sendable {
    let pairId: String
    let snapId: String
}

/// Owns APNs/FCM registration and turns a tapped "New snap" notification into a
/// deep link the UI observes to open the viewer directly.
@MainActor
@Observable
final class PushService: NSObject {
    /// Set when a snap notification is tapped; the root view consumes and clears it.
    var pendingDeepLink: SnapDeepLink?

    private var lastToken: String?

    func configure() {
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
    }

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Persist the FCM token under the signed-in user's private push doc.
    func syncToken(_ token: String?) {
        guard let token, let uid = Auth.auth().currentUser?.uid, token != lastToken else { return }
        lastToken = token
        Firestore.firestore().document("users/\(uid)/private/push")
            .setData(["fcmToken": token], merge: true)
    }

    fileprivate func apply(_ link: SnapDeepLink) {
        pendingDeepLink = link
    }

    /// Parse a notification payload into a Sendable deep link (nonisolated so it
    /// can run before hopping to the main actor).
    fileprivate nonisolated static func parseDeepLink(_ userInfo: [AnyHashable: Any]) -> SnapDeepLink? {
        guard
            userInfo["type"] as? String == "snap",
            let pairId = userInfo["pairId"] as? String,
            let snapId = userInfo["snapId"] as? String
        else { return nil }
        return SnapDeepLink(pairId: pairId, snapId: snapId)
    }
}

extension PushService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let link = PushService.parseDeepLink(userInfo) else { return }
        await MainActor.run { self.apply(link) }
    }
}

extension PushService: MessagingDelegate {
    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        Task { @MainActor in self.syncToken(fcmToken) }
    }
}
