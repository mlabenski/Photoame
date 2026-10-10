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
    /// Local temp file URL for a video snap (nil for photos). Playable while the
    /// snap is on screen; removed on `discard`.
    private(set) var videoURL: URL?
    private(set) var isVideo = false
    private(set) var caption = ""
    private(set) var countdown: Int?         // nil == "until dismissed"
    private(set) var iKept = false
    private(set) var bothKept = false

    /// Non-nil when a report/block call failed; surfaced as an alert.
    var moderationError: String?

    let pairId: String
    let snapId: String
    private let uid: String
    private let repository: any SnapRepositoryProtocol
    private let functions: FunctionsClient
    private let kept: KeptStore

    private var snap: Snap?
    /// The downloaded blob, kept in memory so Keep can persist it without a
    /// second download (image bytes for photos, the full file for videos).
    private var mediaData: Data?
    private var timerSeconds = 0
    private var hasReplayed = false
    private var countdownTask: Task<Void, Never>?

    init(pairId: String, snapId: String, uid: String,
         repository: any SnapRepositoryProtocol, functions: FunctionsClient,
         kept: KeptStore) {
        self.pairId = pairId
        self.snapId = snapId
        self.uid = uid
        self.repository = repository
        self.functions = functions
        self.kept = kept
    }

    var isSender: Bool { snap?.senderUid == uid }

    /// The recipient can report/block the sender of the snap they're viewing.
    /// Senders can't report their own snap.
    var canModerate: Bool { snap != nil && !isSender }
    private var reportedUid: String? { snap?.senderUid }

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

            self.isVideo = snap.isVideo
            if snap.isVideo {
                let data = try await repository.downloadData(
                    path: snap.storagePath, maxBytes: 80 * 1024 * 1024)
                self.mediaData = data
                self.videoURL = try Self.writeTempVideo(data)
            } else {
                let data = try await repository.downloadImage(path: snap.storagePath)
                self.mediaData = data
                self.image = UIImage(data: data)
            }
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
            // Stop showing the media until replay (keep bytes for the rewatch).
            image = nil
            removeTempVideo()
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
                if let data = mediaData {
                    if isVideo { videoURL = try Self.writeTempVideo(data) }
                    else { image = UIImage(data: data) }
                }
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
                if both, let data = mediaData {
                    kept.save(snapId: snapId, data: data,
                              mediaType: isVideo ? .video : .image,
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

    /// Freeze the disappearing timer so the snap doesn't vanish out from under a
    /// report/block flow the user is in the middle of.
    func pauseCountdown() { countdownTask?.cancel() }

    /// File a report against the snap's sender. Returns whether it succeeded.
    func submitReport(reason: String, detail: String) async -> Bool {
        guard let reportedUid else { return false }
        do {
            try await functions.submitReport(
                reportedUid: reportedUid, pairId: pairId, snapId: snapId,
                reason: reason, detail: detail)
            return true
        } catch {
            moderationError = error.localizedDescription
            return false
        }
    }

    /// Block the snap's sender (server tears down the pair). Returns success.
    func blockSender() async -> Bool {
        guard let reportedUid else { return false }
        do {
            try await functions.blockUser(otherUid: reportedUid)
            return true
        } catch {
            moderationError = error.localizedDescription
            return false
        }
    }

    /// Drop the decoded media and its bytes from memory (and the temp video file).
    func discard() {
        countdownTask?.cancel()
        image = nil
        mediaData = nil
        removeTempVideo()
    }

    /// Write downloaded video bytes to a temp `.mp4` for playback.
    private static func writeTempVideo(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("view-\(UUID().uuidString).mp4")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func removeTempVideo() {
        if let url = videoURL { try? FileManager.default.removeItem(at: url) }
        videoURL = nil
    }
}
