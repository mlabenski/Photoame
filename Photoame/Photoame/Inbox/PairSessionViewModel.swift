import Foundation
import FirebaseFirestore
import os

/// Shared state for an active pair: the live snap list and the partner's name.
/// Owned by PairedHomeView and shared with the inbox and sender-state displays.
@MainActor
@Observable
final class PairSessionViewModel {
    private(set) var snaps: [Snap] = []
    private(set) var partnerName = "Partner"
    private(set) var partnerPhotoURL: String?

    /// The latest snap that should surface an in-app banner. Set when a new,
    /// unopened received snap arrives while the session is live; the view
    /// consumes it (to open the viewer) and clears it after presenting.
    var incomingAlert: IncomingSnapAlert?

    let pairId: String
    let uid: String
    private let repository: any SnapRepositoryProtocol
    private var streamTask: Task<Void, Never>?
    private var partnerListener: ListenerRegistration?
    private let log = Logger(subsystem: "com.photoame.app", category: "pair")

    /// Snap ids seen so far, so a stream update can tell genuinely new arrivals
    /// from re-emissions of the existing list. Seeded on the first update so the
    /// initial backlog never triggers a banner.
    private var knownSnapIds: Set<String> = []
    private var didSeedKnownIds = false

    init(pairId: String, uid: String, repository: any SnapRepositoryProtocol) {
        self.pairId = pairId
        self.uid = uid
        self.repository = repository
    }

    /// Received snaps not yet opened — the actionable inbox.
    var unopenedReceived: [Snap] {
        snaps.filter { $0.senderUid != uid && ($0.state == .sent || $0.state == .delivered) }
    }

    /// Snaps this user sent, newest first — shown with their delivery state.
    var recentSent: [Snap] {
        snaps.filter { $0.senderUid == uid }
    }

    /// Kept snaps (both members kept) — feed for the Kept gallery download.
    var keptSnaps: [Snap] {
        snaps.filter { $0.state == .kept }
    }

    func snap(withId id: String) -> Snap? {
        snaps.first { $0.id == id }
    }

    func start() {
        guard streamTask == nil else { return }
        resolvePartnerName()
        let stream = repository.streamSnaps(pairId: pairId)
        streamTask = Task { [weak self] in
            for await snaps in stream {
                guard let self else { return }
                self.snaps = snaps
                self.detectIncomingSnap(in: snaps)
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        partnerListener?.remove()
        partnerListener = nil
    }

    /// Raise an in-app alert for the newest unopened received snap that wasn't in
    /// the previously known set. Seeds silently on the first update so an existing
    /// backlog of unread snaps doesn't fire a banner on launch.
    private func detectIncomingSnap(in snaps: [Snap]) {
        let previous = knownSnapIds
        knownSnapIds = Set(snaps.compactMap(\.id))
        guard didSeedKnownIds else { didSeedKnownIds = true; return }

        let arrival = snaps.first { snap in
            guard let id = snap.id, !previous.contains(id) else { return false }
            return snap.senderUid != uid && (snap.state == .sent || snap.state == .delivered)
        }
        guard let arrival, let id = arrival.id else { return }
        incomingAlert = IncomingSnapAlert(snapId: id, senderName: partnerName,
                                          senderPhotoURL: partnerPhotoURL)
    }

    private func resolvePartnerName() {
        Task { [weak self] in
            guard let self else { return }
            let db = Firestore.firestore()
            let pairDoc: DocumentSnapshot
            do {
                pairDoc = try await db.document("pairs/\(self.pairId)").getDocument()
            } catch {
                self.log.error("could not load pair \(self.pairId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
            guard
                let members = pairDoc.get("members") as? [String],
                let partnerUid = members.first(where: { $0 != self.uid })
            else {
                self.log.notice("pair \(self.pairId, privacy: .public) has no partner member yet")
                return
            }
            self.partnerListener = db.document("users/\(partnerUid)")
                .addSnapshotListener { [weak self] doc, error in
                    if let error {
                        self?.log.error("partner listener error: \(error.localizedDescription, privacy: .public)")
                    }
                    let name = doc?.get("displayName") as? String
                    let photoURL = doc?.get("photoURL") as? String
                    Task { @MainActor in
                        if let name, !name.isEmpty { self?.partnerName = name }
                        self?.partnerPhotoURL = photoURL
                    }
                }
        }
    }
}
