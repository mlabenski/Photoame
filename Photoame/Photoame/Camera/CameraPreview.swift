import SwiftUI
import AVFoundation

/// Lets the owning SwiftUI view convert a tap point into the normalized
/// capture-device coordinates the preview layer actually maps to. Held by the
/// caller; populated with a weak reference to the live `PreviewView` on layout.
final class CameraPreviewHandle {
    fileprivate weak var view: CameraPreview.PreviewView?

    /// Normalized (0...1) device point for a tap in the preview's coordinate
    /// space, accounting for `.resizeAspectFill` cropping. `nil` before layout.
    func devicePoint(for point: CGPoint) -> CGPoint? {
        view?.devicePoint(for: point)
    }

    /// The visible preview's aspect ratio (width / height). Callers crop a capture
    /// to this so the sent photo matches the `.resizeAspectFill` preview framing.
    /// `nil` before layout. Read on the main actor (it touches `UIView.bounds`).
    @MainActor
    var aspectRatio: CGFloat? {
        guard let bounds = view?.bounds, bounds.width > 0, bounds.height > 0 else {
            return nil
        }
        return bounds.width / bounds.height
    }
}

/// Hosts an `AVCaptureVideoPreviewLayer` for the shared capture session.
/// Also converts a tap location into normalized device coordinates for focus.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var handle: CameraPreviewHandle?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        handle?.view = view
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        /// Convert a point in this view to a normalized (0...1) capture-device point.
        func devicePoint(for point: CGPoint) -> CGPoint {
            videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: point)
        }
    }
}
