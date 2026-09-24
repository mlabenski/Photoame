import Foundation
import AVFoundation
import UIKit
import os

/// Owns the `AVCaptureSession` and confines every access to a private serial
/// queue. Declared `@unchecked Sendable` because that confinement is enforced by
/// convention here rather than by the type system; nothing outside this class
/// touches the session or its inputs/outputs off `queue` (the sole exception is
/// the `session` reference handed to the preview layer, which only retains it).
final class CaptureSessionController: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "com.photoame.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var configured = false
    private var captureContinuation: CheckedContinuation<UIImage, Error>?
    private let log = Logger(subsystem: "com.photoame.app", category: "camera")
    /// Called on the main queue whenever the running state changes (initial
    /// start, interruption, or interruption-ended restart).
    private var runningStateChanged: (@Sendable (Bool) -> Void)?

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sessionRuntimeError(_:)),
                           name: .AVCaptureSessionRuntimeError, object: session)
        center.addObserver(self, selector: #selector(sessionWasInterrupted(_:)),
                           name: .AVCaptureSessionWasInterrupted, object: session)
        center.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)),
                           name: .AVCaptureSessionInterruptionEnded, object: session)
    }

    /// Start the session (configuring it on first run). Reports the running state
    /// both immediately and on later interruption/restart via `onState`.
    func start(_ onState: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            self.runningStateChanged = onState
            if !self.configured { self.configureSession() }
            if !self.session.isRunning { self.session.startRunning() }
            let running = self.session.isRunning
            self.log.info("camera start: running=\(running, privacy: .public) inputs=\(self.session.inputs.count, privacy: .public)")
            onState(running)
        }
    }

    func stop(_ onState: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            self.runningStateChanged = nil
            if self.session.isRunning { self.session.stopRunning() }
            onState(false)
        }
    }

    // MARK: Interruption / error recovery
    //
    // The session can start (or be forced) into an interrupted state when it
    // begins while a system alert is up, another app holds the camera, or the
    // app isn't foreground-active yet — the classic "permission granted but the
    // preview is black" case. These observers log the cause and restart when the
    // interruption clears, so the preview self-heals instead of staying black.

    @objc private func sessionRuntimeError(_ note: Notification) {
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
        log.error("camera runtime error: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        queue.async {
            if !self.session.isRunning { self.session.startRunning() }
            self.reportRunningState()
        }
    }

    @objc private func sessionWasInterrupted(_ note: Notification) {
        let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int).map(String.init) ?? "unknown"
        log.notice("camera interrupted (reason=\(reason, privacy: .public))")
        reportRunningState()
    }

    @objc private func sessionInterruptionEnded(_ note: Notification) {
        log.notice("camera interruption ended; restarting")
        queue.async {
            if !self.session.isRunning { self.session.startRunning() }
            self.reportRunningState()
        }
    }

    /// Read the running state on `queue` (the session's confinement queue) and
    /// deliver it on the main queue to whoever registered via `start`.
    private func reportRunningState() {
        queue.async {
            let running = self.session.isRunning
            guard let handler = self.runningStateChanged else { return }
            DispatchQueue.main.async { handler(running) }
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
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: position) else {
            log.error("no wide-angle camera for position \(front ? "front" : "back", privacy: .public)")
            return
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            log.error("could not create camera input: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard session.canAddInput(input) else {
            log.error("session refused camera input (position=\(front ? "front" : "back", privacy: .public))")
            return
        }
        session.addInput(input)
        videoInput = input
    }
}

extension CaptureSessionController: AVCapturePhotoCaptureDelegate {
    // AVFoundation delivers this callback on its own internal queue, NOT on
    // `queue` where `captureContinuation` is set. Hop onto `queue` before
    // touching it so the set (in `capturePhoto`) and this read/clear are
    // serialized — otherwise the two race. Extract the photo result first,
    // since `AVCapturePhoto` must be read on the delivery thread.
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        let result: Result<UIImage, Error>
        if let error {
            result = .failure(error)
        } else if let data = photo.fileDataRepresentation(),
                  let image = UIImage(data: data) {
            result = .success(image)
        } else {
            result = .failure(CameraError.captureFailed)
        }
        queue.async {
            let continuation = self.captureContinuation
            self.captureContinuation = nil
            continuation?.resume(with: result)
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
