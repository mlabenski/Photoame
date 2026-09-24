import Foundation
import FirebaseFirestore

/// Shared state for an active pair: the live snap list and the partner's name.
/// Owned by PairedHomeView and shared with the inbox and sender-state displays.
@MainActor
@Observable
final class PairSessionViewModel {
    private(set) var snaps: [Snap] = []
    private(set) var partnerName = "Partner"

    let pairId: String
    let uid: String
    private let repository: any SnapRepositoryProtocol
    private var streamTask: Task<Void, Never>?
    private var partnerListener: ListenerRegistration?

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

    /// Kept snaps (both members kept) — feed for the "Us" gallery download.
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
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        partnerListener?.remove()
        partnerListener = nil
    }

    private func resolvePartnerName() {
        Task { [weak self] in
            guard let self else { return }
            let db = Firestore.firestore()
            guard
                let pairDoc = try? await db.document("pairs/\(self.pairId)").getDocument(),
                let members = pairDoc.get("members") as? [String],
                let partnerUid = members.first(where: { $0 != self.uid })
            else { return }
            self.partnerListener = db.document("users/\(partnerUid)")
                .addSnapshotListener { [weak self] doc, _ in
                    let name = doc?.get("displayName") as? String
                    Task { @MainActor in
                        if let name, !name.isEmpty { self?.partnerName = name }
                    }
                }
        }
    }
}
