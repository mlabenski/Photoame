import Foundation
import UIKit

/// Drives capture -> review -> send for both photos and videos. Owns the
/// CameraService. A quick tap on the shutter takes a photo; a press-and-hold
/// records a video (up to 10 seconds).
@MainActor
@Observable
final class CameraViewModel {
    enum Phase: Equatable {
        case live
        case review(UIImage)
        case reviewVideo(URL)
    }

    let camera = CameraService()
    private(set) var phase: Phase = .live
    var caption = ""
    /// Caption center, normalized (0...1) within the displayed photo. Defaults to
    /// the lower-middle; the user can drag it anywhere on the image.
    var captionPosition = CGPoint(x: 0.5, y: 0.85)
    /// Caption size multiplier, driven by pinch-to-zoom in the review pane.
    var captionScale: CGFloat = 1
    var timerSeconds = 5 // default 5s; 0 == "until dismissed"
    private(set) var sending = false
    var errorMessage: String?

    private let pairId: String
    private let senderUid: String
    private let repository: any SnapRepositoryProtocol

    init(pairId: String, senderUid: String, repository: any SnapRepositoryProtocol) {
        self.pairId = pairId
        self.senderUid = senderUid
        self.repository = repository
        camera.onRecordingFinished = { [weak self] result in
            self?.handleRecording(result)
        }
    }

    static let timerOptions = [3, 5, 10, 0] // 0 renders as "∞ / until dismissed"

    /// True on the live camera; false while reviewing a captured photo or video.
    var isLive: Bool { if case .live = phase { return true }; return false }
    /// True while reviewing a captured photo or video (either kind).
    var isReviewing: Bool { !isLive }

    /// - Parameter previewAspect: the live preview's aspect ratio (width / height),
    ///   so the capture can be center-cropped to match what was framed on screen.
    ///   `nil` leaves the full sensor frame uncropped.
    func capture(previewAspect: CGFloat?) {
        Task {
            do {
                var image = try await camera.capturePhoto()
                if let previewAspect {
                    image = ImageProcessing.cropCentered(image, toAspect: previewAspect)
                }
                phase = .review(image)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Recording

    func startRecording() { Task { await camera.startRecording() } }
    func stopRecording() { camera.stopRecording() }

    private func handleRecording(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            phase = .reviewVideo(url)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func retake() {
        if case let .reviewVideo(url) = phase { try? FileManager.default.removeItem(at: url) }
        resetCaption()
        phase = .live
    }

    private func resetCaption() {
        caption = ""
        captionPosition = CGPoint(x: 0.5, y: 0.85)
        captionScale = 1
    }

    func send() {
        switch phase {
        case .review(let image): sendImage(image)
        case .reviewVideo(let url): sendVideo(url)
        case .live: break
        }
    }

    private func sendImage(_ image: UIImage) {
        guard let prepared = ImageProcessing.prepareForSend(
            image, caption: caption,
            captionPosition: captionPosition, captionScale: captionScale) else {
            errorMessage = "Could not encode the photo."
            return
        }
        sending = true
        let caption = self.caption
        let timer = timerSeconds
        Task {
            do {
                try await repository.sendSnap(
                    pairId: pairId, senderUid: senderUid,
                    imageData: prepared.data, isHEIC: prepared.isHEIC,
                    caption: caption, timerSeconds: timer)
                finishSending()
            } catch {
                errorMessage = error.localizedDescription
            }
            sending = false
        }
    }

    private func sendVideo(_ sourceURL: URL) {
        sending = true
        let caption = self.caption
        let timer = timerSeconds
        Task {
            // Transcode to a small MP4 before upload; fall back to the raw clip if
            // the export fails for any reason.
            let upload = await VideoProcessing.transcodeForSend(sourceURL) ?? sourceURL
            do {
                try await repository.sendVideoSnap(
                    pairId: pairId, senderUid: senderUid, fileURL: upload,
                    caption: caption, timerSeconds: timer)
                if upload != sourceURL { try? FileManager.default.removeItem(at: upload) }
                try? FileManager.default.removeItem(at: sourceURL)
                finishSending()
            } catch {
                if upload != sourceURL { try? FileManager.default.removeItem(at: upload) }
                errorMessage = error.localizedDescription
            }
            sending = false
        }
    }

    private func finishSending() {
        resetCaption()
        phase = .live
    }

    func flip() { camera.flip() }
    func onAppear() { camera.onAppear() }
    func onDisappear() { camera.onDisappear() }
}
