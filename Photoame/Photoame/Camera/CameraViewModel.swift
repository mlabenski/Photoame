import Foundation
import UIKit

/// Drives capture -> review -> send. Owns the CameraService.
@MainActor
@Observable
final class CameraViewModel {
    enum Phase: Equatable {
        case live
        case review(UIImage)
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
    }

    static let timerOptions = [3, 5, 10, 0] // 0 renders as "∞ / until dismissed"

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

    func retake() {
        resetCaption()
        phase = .live
    }

    private func resetCaption() {
        caption = ""
        captionPosition = CGPoint(x: 0.5, y: 0.85)
        captionScale = 1
    }

    func send() {
        guard case let .review(image) = phase else { return }
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
                resetCaption()
                phase = .live
            } catch {
                errorMessage = error.localizedDescription
            }
            sending = false
        }
    }

    func flip() { camera.flip() }
    func onAppear() { camera.onAppear() }
    func onDisappear() { camera.onDisappear() }
}
