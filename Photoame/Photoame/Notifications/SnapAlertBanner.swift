import SwiftUI

/// Copy for a "new snap" alert. Kept in one place so the in-app banner shows the
/// exact same wording the server puts in the push notification. Mirror of
/// `functions/src/snaps.ts` (`sendPushToUser(recipient, "New snap",
/// "New snap from <name>", …)`); update both together.
enum SnapNotificationCopy {
    static let title = "New snap"

    static func body(from senderName: String) -> String {
        "New snap from \(senderName)"
    }
}

/// A transient in-app alert for a freshly received snap. Identifiable so a new
/// arrival replaces the currently shown banner (and restarts its dismiss timer).
struct IncomingSnapAlert: Identifiable, Equatable {
    let id = UUID()
    let snapId: String
    let title: String
    let body: String
    /// The sender's avatar so the in-app banner matches the push notification.
    let senderName: String
    let senderPhotoURL: String?

    init(snapId: String, senderName: String, senderPhotoURL: String? = nil) {
        self.snapId = snapId
        self.title = SnapNotificationCopy.title
        self.body = SnapNotificationCopy.body(from: senderName)
        self.senderName = senderName
        self.senderPhotoURL = senderPhotoURL
    }
}

/// A notification-style banner that drops in from the top when a snap arrives
/// while the app is foreground — the in-app twin of the system push. Tapping it
/// opens the snap; it also auto-dismisses and can be swiped up to dismiss.
struct SnapAlertBanner: View {
    let alert: IncomingSnapAlert
    let onTap: () -> Void
    let onDismiss: () -> Void

    /// Seconds the banner stays on screen before auto-dismissing.
    private let lifetime: TimeInterval = 4

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                AvatarView(url: alert.senderPhotoURL, name: alert.senderName, size: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.title)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Text(alert.body)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 15).onEnded { value in
                if value.translation.height < -20 { onDismiss() }
            }
        )
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(alert.title). \(alert.body)")
        .accessibilityHint("Opens the snap")
        .accessibilityAddTraits(.isButton)
        // Auto-dismiss after `lifetime`; keyed to the alert id so a new arrival
        // (new id) restarts the countdown instead of inheriting the old one.
        .task(id: alert.id) {
            try? await Task.sleep(nanoseconds: UInt64(lifetime * 1_000_000_000))
            if !Task.isCancelled { onDismiss() }
        }
    }
}
