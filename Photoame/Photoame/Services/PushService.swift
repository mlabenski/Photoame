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

    /// Most recent FCM token, cached so it can be written once a user is signed
    /// in even if it arrived earlier (the MessagingDelegate callback commonly
    /// fires before authentication completes).
    private var latestToken: String?
    /// "uid|token" of the last successful write, to avoid redundant setData.
    private var syncedKey: String?

    func configure() {
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
    }

    /// Call once the user is authenticated: request notification permission,
    /// register for APNs, and flush any FCM token that arrived before sign-in.
    /// This is the entry point that actually gets a token stored — without it the
    /// app never registers and the recipient has no `fcmToken`, so pushes are
    /// dropped server-side with "No fcmToken for <uid>; skipping push."
    func onSignedIn() async {
        await requestAuthorization()
        if latestToken == nil {
            latestToken = try? await Messaging.messaging().token()
        }
        syncToken(latestToken)
    }

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Persist the FCM token under the signed-in user's private push doc. Caches
    /// the token so a later sign-in can still write it; no-ops (rather than
    /// dropping the token) when no user is signed in yet.
    func syncToken(_ token: String?) {
        if let token { latestToken = token }
        guard let token = latestToken, let uid = Auth.auth().currentUser?.uid else { return }
        let key = "\(uid)|\(token)"
        guard key != syncedKey else { return }
        syncedKey = key
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
