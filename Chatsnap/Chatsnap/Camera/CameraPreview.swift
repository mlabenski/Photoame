import SwiftUI
import AVFoundation

/// Hosts an `AVCaptureVideoPreviewLayer` for the shared capture session.
/// Also converts a tap location into normalized device coordinates for focus.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
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
