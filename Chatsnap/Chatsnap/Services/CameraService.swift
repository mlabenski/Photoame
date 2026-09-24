import Foundation
import AVFoundation
import UIKit

/// Owns the `AVCaptureSession` and confines every access to a private serial
/// queue. Declared `@unchecked Sendable` because that confinement is enforced by
/// convention here rather than by the type system; nothing outside this class
/// touches the session or its inputs/outputs off `queue` (the sole exception is
/// the `session` reference handed to the preview layer, which only retains it).
final class CaptureSessionController: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "com.chatsnap.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var configured = false
    private var captureContinuation: CheckedContinuation<UIImage, Error>?

    /// Start the session (configuring it on first run). Reports the running state.
    func start(_ onState: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            if !self.configured { self.configureSession() }
            if !self.session.isRunning { self.session.startRunning() }
            onState(self.session.isRunning)
        }
    }

    func stop(_ onState: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            onState(false)
        }
    }

    func flip(front: Bool) {
        queue.async {
            self.session.beginConfiguration()
            self.addVideoInput(front: front)
            self.session.commitConfiguration()
        }
    }

    func zoom(factor: CGFloat) {
        queue.async {
            guard let device = self.videoInput?.device else { return }
            try? device.lockForConfiguration()
            let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 8.0)
            device.videoZoomFactor = min(max(factor, 1.0), maxZoom)
            device.unlockForConfiguration()
        }
    }

    func focus(atPoint point: CGPoint) {
        queue.async {
            guard let device = self.videoInput?.device else { return }
            try? device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                device.exposureMode = .autoExpose
            }
            device.unlockForConfiguration()
        }
    }

    func capturePhoto(front: Bool) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.captureContinuation = continuation
                let settings = AVCapturePhotoSettings()
                if !front, self.photoOutput.supportedFlashModes.contains(.auto) {
                    settings.flashMode = .auto
                }
                if let connection = self.photoOutput.connection(with: .video),
                   connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = front
                }
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    // MARK: Queue-only configuration

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        addVideoInput(front: true)
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .balanced
        }
        session.commitConfiguration()
        configured = true
    }

    private func addVideoInput(front: Bool) {
        if let existing = videoInput { session.removeInput(existing) }
        let position: AVCaptureDevice.Position = front ? .front : .back
        guard
            let device = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: position),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else { return }
        session.addInput(input)
        videoInput = input
    }
}

extension CaptureSessionController: AVCapturePhotoCaptureDelegate {
    // Resumes the pending continuation directly; only one capture is ever in
    // flight, and both the setter (on `queue`) and this callback touch
    // `captureContinuation` under the class's manual confinement.
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        let continuation = captureContinuation
        captureContinuation = nil
        if let error {
            continuation?.resume(throwing: error)
        } else if let data = photo.fileDataRepresentation(),
                  let image = UIImage(data: data) {
            continuation?.resume(returning: image)
        } else {
            continuation?.resume(throwing: CameraError.captureFailed)
        }
    }
}

/// Observable, main-actor camera facade for SwiftUI. Delegates all session work
/// to `CaptureSessionController` and pauses when off screen / backgrounded.
@MainActor
@Observable
final class CameraService {
    private(set) var isRunning = false
    private(set) var isFrontCamera = true
    private(set) var permissionDenied = false
    /// Drives the white screen-flash overlay used as a front-camera "flash".
    var showScreenFlash = false
    var frontFlashEnabled = true

    private let controller = CaptureSessionController()

    /// The session, for the preview layer only.
    var captureSession: AVCaptureSession { controller.session }

    func onAppear() { Task { await requestAccessAndStart() } }
    func onDisappear() {
        controller.stop { _ in }
        isRunning = false
    }

    private func requestAccessAndStart() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { permissionDenied = true; return }
        default:
            permissionDenied = true
            return
        }
        start()
    }

    func start() {
        controller.start { running in
            Task { @MainActor in self.isRunning = running }
        }
    }

    func flip() {
        isFrontCamera.toggle()
        controller.flip(front: isFrontCamera)
    }

    func zoom(factor: CGFloat) { controller.zoom(factor: factor) }
    func focus(atPoint point: CGPoint) { controller.focus(atPoint: point) }

    func capturePhoto() async throws -> UIImage {
        if isFrontCamera && frontFlashEnabled {
            showScreenFlash = true
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        defer { showScreenFlash = false }
        return try await controller.capturePhoto(front: isFrontCamera)
    }
}

enum CameraError: LocalizedError {
    case captureFailed
    var errorDescription: String? {
        switch self {
        case .captureFailed: return "Could not capture the photo."
        }
    }
}
