import Foundation
import FirebaseFirestore

/// A Photoame user profile (`users/{uid}`). Only `displayName` and
/// `ageConfirmedAt` are ever written by the client.
struct UserProfile: Codable, Identifiable {
    @DocumentID var id: String?
    var displayName: String
    var activePairId: String?
    var ageConfirmedAt: Date?
    var createdAt: Date?
}

/// A pairing between exactly two users (`pairs/{pairId}`). Server-owned.
struct Pair: Codable, Identifiable {
    @DocumentID var id: String?
    var members: [String]
    var status: PairStatus
    var createdAt: Date?
    var endedAt: Date?
    var endedBy: String?

    func partner(of uid: String) -> String? {
        members.first { $0 != uid }
    }
}

enum PairStatus: String, Codable, Sendable {
    case active
    case ended
}

/// The server-tracked lifecycle of a snap. "Sending" is a client-only optimistic
/// label and is intentionally absent here (see DECISIONS.md).
enum SnapState: String, Codable, Sendable {
    case sent
    case delivered
    case opened
    case replayed
    case kept
}

/// A snap (`pairs/{pairId}/snaps/{snapId}`). The client only ever creates one
/// (with `state == .sent`); every transition afterwards is server-side.
struct Snap: Codable, Identifiable {
    @DocumentID var id: String?
    var senderUid: String
    var storagePath: String
    var caption: String
    var timerSeconds: Int
    var state: SnapState
    var createdAt: Date?
    var openedAt: Date?
    var replayedAt: Date?
    var keptBy: [String]?
    var screenshotAt: Date?
    var expiresAt: Date?

    var wasScreenshotted: Bool { screenshotAt != nil }
    func keptByMe(_ uid: String) -> Bool { keptBy?.contains(uid) ?? false }

    /// Whether a replay is still available to the recipient.
    var replayAvailable: Bool {
        guard state == .opened, let openedAt else { return false }
        return openedAt.addingTimeInterval(5 * 60) > Date()
    }
}

/// The label shown to the *sender* for a snap they sent.
enum SentDisplayState: String {
    case sending = "Sending"
    case delivered = "Delivered"
    case opened = "Opened"
    case replayed = "Replayed"
    case kept = "Kept"
    case screenshotted = "Screenshotted"

    static func forSnap(_ snap: Snap) -> SentDisplayState {
        if snap.wasScreenshotted { return .screenshotted }
        switch snap.state {
        case .sent: return .sending
        case .delivered: return .delivered
        case .opened: return .opened
        case .replayed: return .replayed
        case .kept: return .kept
        }
    }
}
