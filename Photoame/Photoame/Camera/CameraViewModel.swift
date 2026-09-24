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

    func capture() {
        Task {
            do {
                let image = try await camera.capturePhoto()
                phase = .review(image)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func retake() {
        caption = ""
        phase = .live
    }

    func send() {
        guard case let .review(image) = phase else { return }
        guard let prepared = ImageProcessing.prepareForSend(image, caption: caption) else {
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
                self.caption = ""
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
