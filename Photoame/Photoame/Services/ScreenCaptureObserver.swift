import Foundation
import UIKit

/// Observes screenshots and screen-recording/mirroring while the viewer is open.
/// - `onScreenshot` fires so the caller can call `reportScreenshot`.
/// - `isCaptured` mirrors `UIScreen.isCaptured` so the viewer can blur the image
///   while the screen is being recorded or mirrored.
@MainActor
@Observable
final class ScreenCaptureObserver {
    private(set) var isCaptured = false
    var onScreenshot: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    func start() {
        isCaptured = UIScreen.main.isCaptured
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: UIApplication.userDidTakeScreenshotNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onScreenshot?() }
        })

        observers.append(center.addObserver(
            forName: UIScreen.capturedDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isCaptured = UIScreen.main.isCaptured }
        })
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        onScreenshot = nil
    }
}
