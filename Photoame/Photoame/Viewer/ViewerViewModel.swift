import Foundation
import UIKit
import FirebaseFirestore

@MainActor
@Observable
final class ViewerViewModel {
    enum Phase: Equatable {
        case loading
        case viewing
        case replayAvailable
        case finished   // consumed, nothing more to show
        case keptConfirmed
        case error(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var image: UIImage?
    private(set) var caption = ""
    private(set) var countdown: Int?         // nil == "until dismissed"
    private(set) var iKept = false
    private(set) var bothKept = false

    let pairId: String
    let snapId: String
    private let uid: String
    private let repository: any SnapRepositoryProtocol
    private let kept: KeptStore

    private var snap: Snap?
    private var imageData: Data?
    private var timerSeconds = 0
    private var hasReplayed = false
    private var countdownTask: Task<Void, Never>?

    init(pairId: String, snapId: String, uid: String,
         repository: any SnapRepositoryProtocol, kept: KeptStore) {
        self.pairId = pairId
        self.snapId = snapId
        self.uid = uid
        self.repository = repository
        self.kept = kept
    }

    var isSender: Bool { snap?.senderUid == uid }

    func begin() async {
        do {
            let snap = try await fetchSnap()
            self.snap = snap
            self.caption = snap.caption
            self.timerSeconds = snap.timerSeconds
            self.iKept = snap.keptByMe(uid)

            // Sender re-viewing their own kept snap: just show it, no lifecycle.
            if isSender && snap.state != .kept {
                // Senders don't "open"; show the still-available image if any.
            } else if !isSender {
                _ = try await repository.markOpened(pairId: pairId, snapId: snapId)
            }

            let data = try await repository.downloadImage(path: snap.storagePath)
            self.imageData = data
            self.image = UIImage(data: data)
            phase = .viewing
            startCountdown()
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func fetchSnap() async throws -> Snap {
        let doc = try await Firestore.firestore()
            .document("pairs/\(pairId)/snaps/\(snapId)").getDocument()
        return try doc.data(as: Snap.self)
    }

    private func startCountdown() {
        guard timerSeconds > 0 else { countdown = nil; return }
        countdown = timerSeconds
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            while let remaining = self?.countdown, remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.tick() }
            }
        }
    }

    private func tick() {
        guard let remaining = countdown else { return }
        if remaining <= 1 {
            countdown = 0
            finishViewing()
        } else {
            countdown = remaining - 1
        }
    }

    /// Called when the timer elapses or the user dismisses an untimed snap.
    func finishViewing() {
        countdownTask?.cancel()
        // A recipient gets exactly one replay inside the 5-minute window.
        if !isSender, !hasReplayed, (snap?.replayAvailable ?? false) {
            image = nil // discard current frame from memory until replay
            phase = .replayAvailable
        } else {
            discard()
            phase = .finished
        }
    }

    func replay() {
        guard !hasReplayed else { return }
        hasReplayed = true
        Task {
            do {
                try await repository.markReplayed(pairId: pairId, snapId: snapId)
                if let data = imageData { image = UIImage(data: data) }
                phase = .viewing
                startCountdown()
            } catch {
                phase = .error(error.localizedDescription)
            }
        }
    }

    func keep() {
        Task {
            do {
                iKept = true
                let both = try await repository.keepSnap(pairId: pairId, snapId: snapId)
                bothKept = both
                if both, let data = imageData {
                    kept.save(snapId: snapId, imageData: data,
                              caption: caption, keptAt: Date())
                    phase = .keptConfirmed
                }
            } catch {
                iKept = false
                phase = .error(error.localizedDescription)
            }
        }
    }

    func reportScreenshot() {
        Task { try? await repository.reportScreenshot(pairId: pairId, snapId: snapId) }
    }

    /// Drop the decoded image and its bytes from memory.
    func discard() {
        countdownTask?.cancel()
        image = nil
        imageData = nil
    }
}
