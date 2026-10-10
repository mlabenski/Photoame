import Foundation
import AVFoundation
import UIKit
import os

/// Capabilities reported from the session queue to the UI when the active device
/// changes, so the zoom controls can reflect what the current lens set supports.
/// `min`/`max`/`current`/`presets` are all expressed as *display* zoom (where the
/// main wide camera is 1.0×), not raw `videoZoomFactor`.
struct ZoomCapabilities: Sendable {
    var minZoom: CGFloat
    var maxZoom: CGFloat
    var current: CGFloat
    var presets: [CGFloat]
}

/// Owns the `AVCaptureSession` and confines every access to a private serial
/// queue. Declared `@unchecked Sendable` because that confinement is enforced by
/// convention here rather than by the type system; nothing outside this class
/// touches the session or its inputs/outputs off `queue` (the sole exception is
/// the `session` reference handed to the preview layer, which only retains it).
final class CaptureSessionController: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "com.photoame.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var configured = false
    private var captureContinuation: CheckedContinuation<UIImage, Error>?
    private var recordingURL: URL?
    private let log = Logger(subsystem: "com.photoame.app", category: "camera")

    /// Delivers the finished recording (success URL or failure) on the main queue.
    var onRecordingFinished: (@Sendable (Result<URL, Error>) -> Void)?

    // MARK: Zoom mapping
    //
    // Virtual multi-lens devices (triple / dual-wide) express zoom as a single
    // continuous `videoZoomFactor`, where 1.0 is the *widest* physical lens (the
    // ultra-wide, i.e. "0.5×" in the camera UI). The main wide lens — what users
    // think of as "1×" — kicks in at the first entry of
    // `virtualDeviceSwitchOverVideoZoomFactors`. We treat that factor as the 1.0×
    // reference and express everything the UI sees relative to it.
    private var referenceFactor: CGFloat = 1.0
    private var minDisplayZoom: CGFloat = 1.0
    private var maxDisplayZoom: CGFloat = 8.0

    /// Called on the main queue whenever the running state changes (initial
    /// start, interruption, or interruption-ended restart).
    private var runningStateChanged: (@Sendable (Bool) -> Void)?
    /// Reports the live display-zoom (main queue) as the user pinches or taps a preset.
    var onZoomChanged: (@Sendable (CGFloat) -> Void)?
    /// Reports the active lens set's zoom capabilities (main queue) after configure/flip.
    var onCapabilities: (@Sendable (ZoomCapabilities) -> Void)?

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

    /// Configure the session ahead of the first `start` so the first frame lands
    /// as soon as the preview is on screen. Safe to call before `start`; a no-op
    /// once configured. Only call when camera access is already authorized.
    func prepare() {
        queue.async {
            if !self.configured { self.configureSession() }
        }
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
            self.applyDeviceDefaultsAndCapabilities(front: front)
        }
    }

    // MARK: Zoom

    /// Set the zoom in *display* terms (main wide == 1.0×). `animated` ramps the
    /// lens (used for preset taps); pinch passes `false` for immediate tracking.
    func setZoom(display: CGFloat, animated: Bool) {
        queue.async {
            guard let device = self.videoInput?.device else { return }
            let clampedDisplay = min(max(display, self.minDisplayZoom), self.maxDisplayZoom)
            let factor = clampedDisplay * self.referenceFactor
            do {
                try device.lockForConfiguration()
                if animated {
                    device.ramp(toVideoZoomFactor: factor, withRate: 24)
                } else {
                    device.cancelVideoZoomRamp()
                    device.videoZoomFactor = factor
                }
                device.unlockForConfiguration()
            } catch {
                self.log.error("zoom lock failed: \(error.localizedDescription, privacy: .public)")
            }
            if let cb = self.onZoomChanged {
                DispatchQueue.main.async { cb(clampedDisplay) }
            }
        }
    }

    // MARK: Focus & exposure

    func focus(atPoint point: CGPoint) {
        queue.async {
            guard let device = self.videoInput?.device else { return }
            try? device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = point
                device.exposureMode = .autoExpose
            }
            // Reset any manual exposure compensation when the user re-aims.
            if device.isExposureModeSupported(.continuousAutoExposure) || device.isExposureModeSupported(.autoExpose) {
                device.setExposureTargetBias(0, completionHandler: nil)
            }
            device.unlockForConfiguration()
        }
    }

    /// Manual exposure compensation. `normalized` is -1...1; mapped onto the
    /// device's supported bias range (0 == the metered exposure).
    func setExposure(normalized: CGFloat) {
        queue.async {
            guard let device = self.videoInput?.device else { return }
            let n = Float(min(max(normalized, -1), 1))
            let bias = n >= 0 ? n * device.maxExposureTargetBias
                              : n * -device.minExposureTargetBias
            try? device.lockForConfiguration()
            device.setExposureTargetBias(bias, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    func capturePhoto(front: Bool, flashOn: Bool) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.captureContinuation = continuation
                let settings = AVCapturePhotoSettings()
                // Favor a snappy shutter over maximum quality — this is a quick-
                // snap app, and the capture is downscaled before sending anyway.
                settings.photoQualityPrioritization = .balanced
                // Back camera uses the hardware flash; front camera's "flash" is
                // the white screen overlay handled in `CameraService`.
                if !front {
                    let desired: AVCaptureDevice.FlashMode = flashOn ? .on : .off
                    if self.photoOutput.supportedFlashModes.contains(desired) {
                        settings.flashMode = desired
                    }
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

    // MARK: Video recording

    /// Begin recording to a temp `.mov`. Lazily adds the mic input on the first
    /// recording (so photo-only users never trigger a mic prompt). The movie
    /// output stops itself at `maxRecordedDuration`; either way completion is
    /// reported through `onRecordingFinished`.
    func startRecording(front: Bool) {
        queue.async {
            guard !self.movieOutput.isRecording else { return }
            if self.audioInput == nil {
                self.session.beginConfiguration()
                self.addAudioInputIfNeeded()
                self.session.commitConfiguration()
            }
            if let conn = self.movieOutput.connection(with: .video) {
                if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
                if conn.isVideoMirroringSupported {
                    conn.automaticallyAdjustsVideoMirroring = false
                    conn.isVideoMirrored = front
                }
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("rec-\(UUID().uuidString).mov")
            self.recordingURL = url
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
            self.log.info("video recording started")
        }
    }

    func stopRecording() {
        queue.async {
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
        }
    }

    // MARK: Queue-only configuration

    private func configureSession() {
        session.beginConfiguration()
        // `.high` (not `.photo`) so the same session can both take stills and
        // record movies; `AVCaptureMovieFileOutput` is incompatible with the
        // `.photo` preset. Stills still come through at 1080p, which is plenty
        // once they're downscaled for sending.
        session.sessionPreset = .high
        addVideoInput(front: true)
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .balanced
        }
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
            movieOutput.maxRecordedDuration = CMTime(
                seconds: VideoProcessing.maxDuration, preferredTimescale: 600)
        }
        session.commitConfiguration()
        configured = true
        applyDeviceDefaultsAndCapabilities(front: true)
    }

    /// Add the microphone input so recordings carry sound. Called on `queue`
    /// inside a configuration transaction; a no-op if already present or if the
    /// mic isn't available (the recording just stays silent).
    private func addAudioInputIfNeeded() {
        guard audioInput == nil,
              let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        audioInput = input
    }

    private func addVideoInput(front: Bool) {
        if let existing = videoInput { session.removeInput(existing) }
        guard let device = Self.bestDevice(front: front) else {
            log.error("no camera for position \(front ? "front" : "back", privacy: .public)")
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

    /// Prefer a virtual multi-lens device on the back so we get real optical zoom
    /// and ultra-wide (0.5×); fall back through progressively simpler devices.
    private static func bestDevice(front: Bool) -> AVCaptureDevice? {
        if front {
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }
        let order: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera,
        ]
        for type in order {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) {
                return device
            }
        }
        return nil
    }

    /// After the active device changes: set sensible AF/AE defaults, reset to 1×,
    /// compute the display-zoom range + presets, and report them to the UI. Runs
    /// on `queue` after `commitConfiguration` so the device lock is independent of
    /// the session-configuration transaction.
    private func applyDeviceDefaultsAndCapabilities(front: Bool) {
        guard let device = videoInput?.device else { return }

        // The app is portrait-locked, so pin the movie output to portrait (90°)
        // here — once the connection is fully formed after commit — as well as at
        // record time, so a recorded clip is never saved sideways.
        if let conn = movieOutput.connection(with: .video),
           conn.isVideoRotationAngleSupported(90) {
            conn.videoRotationAngle = 90
        }

        let switchovers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let hasUltraWide = !switchovers.isEmpty && device.minAvailableVideoZoomFactor < switchovers[0]
        referenceFactor = hasUltraWide ? switchovers[0] : 1.0
        minDisplayZoom = device.minAvailableVideoZoomFactor / referenceFactor
        // Cap digital zoom so the slider doesn't run out to absurd, mushy factors.
        maxDisplayZoom = min(device.maxAvailableVideoZoomFactor / referenceFactor, 10.0)

        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = true }
            device.setExposureTargetBias(0, completionHandler: nil)
            device.videoZoomFactor = referenceFactor   // display 1.0×
            device.unlockForConfiguration()
        } catch {
            log.error("device defaults lock failed: \(error.localizedDescription, privacy: .public)")
        }

        let caps = ZoomCapabilities(minZoom: minDisplayZoom,
                                    maxZoom: maxDisplayZoom,
                                    current: 1.0,
                                    presets: zoomPresets(switchovers: switchovers))
        if let cb = onCapabilities { DispatchQueue.main.async { cb(caps) } }
    }

    /// Build the row of tap-to-jump zoom presets: 0.5× if an ultra-wide exists,
    /// always 1×, the device's optical tele stops, and a 2× digital fallback.
    private func zoomPresets(switchovers: [CGFloat]) -> [CGFloat] {
        var presets: Set<CGFloat> = [1.0]
        if minDisplayZoom <= 0.5 + 0.001 { presets.insert(0.5) }
        // Optical switch-over points above the main wide become tele presets.
        for factor in switchovers {
            let display = factor / referenceFactor
            if display > 1.5 { presets.insert((display * 10).rounded() / 10) }
        }
        if !presets.contains(where: { $0 >= 2 }), maxDisplayZoom >= 2 { presets.insert(2.0) }
        return presets
            .filter { $0 >= minDisplayZoom - 0.001 && $0 <= maxDisplayZoom + 0.001 }
            .sorted()
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

extension CaptureSessionController: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        // Hitting `maxRecordedDuration` surfaces as an error whose userInfo flags
        // the recording as successfully finished — treat that as success.
        let succeeded: Bool
        if let error {
            succeeded = (error as NSError)
                .userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false
        } else {
            succeeded = true
        }
        let result: Result<URL, Error> = succeeded
            ? .success(outputFileURL)
            : .failure(error ?? CameraError.recordingFailed)
        queue.async {
            self.recordingURL = nil
            if let cb = self.onRecordingFinished {
                DispatchQueue.main.async { cb(result) }
            }
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
    /// User-controlled flash. Governs the back camera's hardware flash and the
    /// front camera's screen-flash overlay. Off by default.
    var flashEnabled = false

    /// True while a video is recording. Drives the shutter's recording UI.
    private(set) var isRecording = false
    /// Recording progress, 0...1 across the 10-second maximum. Drives the ring.
    private(set) var recordingProgress: CGFloat = 0
    /// Set by the view model; delivers the finished recording's file URL (or an
    /// error). Fires whether the user lifted off or the 10-second cap was hit.
    var onRecordingFinished: ((Result<URL, Error>) -> Void)?
    private var progressTask: Task<Void, Never>?

    // Zoom state, in display terms (main wide == 1.0×), kept in sync with the
    // active lens set via the controller's callbacks.
    private(set) var zoomFactor: CGFloat = 1.0
    private(set) var minZoom: CGFloat = 1.0
    private(set) var maxZoom: CGFloat = 8.0
    private(set) var zoomPresets: [CGFloat] = [1.0]

    private let controller = CaptureSessionController()

    /// The session, for the preview layer only.
    var captureSession: AVCaptureSession { controller.session }

    init() {
        controller.onZoomChanged = { [weak self] z in
            Task { @MainActor in self?.zoomFactor = z }
        }
        controller.onCapabilities = { [weak self] caps in
            Task { @MainActor in
                self?.minZoom = caps.minZoom
                self?.maxZoom = caps.maxZoom
                self?.zoomPresets = caps.presets
                self?.zoomFactor = caps.current
            }
        }
        controller.onRecordingFinished = { [weak self] result in
            Task { @MainActor in self?.finishRecording(result) }
        }
        // Warm the session up front for already-authorized users so the first
        // frame appears as soon as the view is on screen.
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            controller.prepare()
        }
    }

    func onAppear() { Task { await requestAccessAndStart() } }
    func onDisappear() {
        if isRecording { controller.stopRecording() }
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
        zoomFactor = 1.0
        controller.flip(front: isFrontCamera)
    }

    /// Set zoom in display terms. Pinch passes `animated: false` for 1:1 tracking;
    /// preset taps pass `true` to ramp smoothly.
    func setZoom(_ display: CGFloat, animated: Bool = false) {
        controller.setZoom(display: display, animated: animated)
    }
    func setExposure(normalized: CGFloat) { controller.setExposure(normalized: normalized) }
    func focus(atPoint point: CGPoint) { controller.focus(atPoint: point) }

    func capturePhoto() async throws -> UIImage {
        if isFrontCamera && flashEnabled {
            showScreenFlash = true
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        defer { showScreenFlash = false }
        return try await controller.capturePhoto(front: isFrontCamera, flashOn: flashEnabled)
    }

    // MARK: Recording

    /// Begin recording. Requests mic access on first use (recording proceeds
    /// silently if denied). The clip stops itself at the 10-second cap; either
    /// way the result is delivered via `onRecordingFinished`.
    func startRecording() async {
        guard !isRecording else { return }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        guard !isRecording else { return }
        isRecording = true
        recordingProgress = 0
        controller.startRecording(front: isFrontCamera)
        startProgressTimer()
    }

    func stopRecording() {
        guard isRecording else { return }
        controller.stopRecording()
    }

    private func finishRecording(_ result: Result<URL, Error>) {
        progressTask?.cancel()
        progressTask = nil
        isRecording = false
        recordingProgress = 0
        onRecordingFinished?(result)
    }

    private func startProgressTimer() {
        progressTask?.cancel()
        let start = Date()
        progressTask = Task { @MainActor [weak self] in
            while let self, self.isRecording {
                let elapsed = Date().timeIntervalSince(start)
                self.recordingProgress = min(CGFloat(elapsed / VideoProcessing.maxDuration), 1)
                if elapsed >= VideoProcessing.maxDuration { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }
}

enum CameraError: LocalizedError {
    case captureFailed
    case recordingFailed
    var errorDescription: String? {
        switch self {
        case .captureFailed: return "Could not capture the photo."
        case .recordingFailed: return "Could not record the video."
        }
    }
}
