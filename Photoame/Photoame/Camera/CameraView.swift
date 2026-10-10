import SwiftUI
import UIKit

/// The paired home screen: a live camera with a single shutter, or the review
/// pane after capture (caption + view-timer + send). Every interaction is one tap.
struct CameraView: View {
    @Bindable var model: CameraViewModel
    /// Bridges preview-layer tap coordinates to capture-device coordinates.
    @State private var previewHandle = CameraPreviewHandle()
    /// Base values captured at the start of a caption drag / pinch so the gesture
    /// deltas apply relative to where the caption was, not from zero.
    @State private var captionDragBase: CGPoint?
    @State private var captionScaleBase: CGFloat?
    /// Display-zoom captured when a pinch begins, so the pinch scales relative to
    /// the current zoom instead of snapping back to 1× each gesture.
    @State private var zoomBase: CGFloat?
    /// Rule-of-thirds overlay toggle (purely a framing aid; does not affect capture).
    @State private var gridEnabled = false
    /// The active tap-to-focus reticle, if any. Auto-dismisses after a short delay.
    @State private var focusReticle: FocusReticle?
    /// Manual exposure, -1...1, driven by dragging the reticle's sun slider.
    @State private var exposureNorm: CGFloat = 0
    @State private var exposureBase: CGFloat = 0

    /// A tap-to-focus indicator placed at `location` (preview coordinates). `id`
    /// lets a fresh tap restart the auto-dismiss timer cleanly.
    private struct FocusReticle: Equatable {
        var location: CGPoint
        var id = UUID()
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.phase {
            case .live:
                liveCamera
            case .review(let image):
                reviewPane(image)
            case .reviewVideo(let url):
                videoReviewPane(url)
            }
        }
        .onAppear { model.onAppear() }
        .onDisappear { model.onDisappear() }
        .alert("Something went wrong",
               isPresented: .init(get: { model.errorMessage != nil },
                                  set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
    }

    // MARK: Live

    private var liveCamera: some View {
        GeometryReader { geo in
            ZStack {
                if model.camera.permissionDenied {
                    permissionDenied
                } else {
                    previewLayer(in: geo.size)
                        // Fade the preview in once frames are actually flowing so
                        // the hand-off from black never looks like a stutter.
                        .opacity(model.camera.isRunning ? 1 : 0)
                        .animation(.easeIn(duration: 0.25), value: model.camera.isRunning)
                    if gridEnabled { gridOverlay }
                    if let reticle = focusReticle {
                        focusReticleView(reticle)
                            .transition(.opacity)
                    }
                }
                if model.camera.showScreenFlash {
                    Color.white.ignoresSafeArea()
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
                VStack {
                    Spacer()
                    VStack(spacing: 18) {
                        // Hide the framing controls while recording so a stray tap
                        // can't flip the camera or toggle flash mid-clip.
                        if !model.camera.isRecording {
                            controlRow
                            if model.camera.zoomPresets.count > 1 { zoomControl }
                        }
                        shutterButton
                        shutterHint
                    }
                    .padding(.bottom, 40)
                }
            }
        }
    }

    private func previewLayer(in size: CGSize) -> some View {
        let preview = CameraPreview(session: model.camera.captureSession,
                                    handle: previewHandle)
        return preview
            .ignoresSafeArea()
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        let base = zoomBase ?? model.camera.zoomFactor
                        if zoomBase == nil { zoomBase = base }
                        model.camera.setZoom(base * value)
                    }
                    .onEnded { _ in zoomBase = nil }
            )
            .onTapGesture(count: 2) { flip() }
            .onTapGesture { location in
                // Single tap = focus. (Double-tap flip takes priority above.)
                // Convert through the preview layer so the focus point accounts
                // for `.resizeAspectFill` cropping; fall back to a plain
                // normalization if the layer isn't laid out yet.
                let point = previewHandle.devicePoint(for: location)
                    ?? CGPoint(x: location.x / size.width,
                               y: location.y / size.height)
                model.camera.focus(atPoint: point)
                showFocusReticle(at: location)
            }
            .accessibilityElement()
            .accessibilityLabel("Camera preview")
            .accessibilityHint("Double tap to flip the camera")
    }

    // MARK: Camera controls
    //
    // The top of the screen belongs to `PairedHomeView`'s bar (settings · partner
    // · gallery) and the bottom-right to its inbox handle, so the camera controls
    // live in the bottom cluster just above the zoom row and shutter.

    private var controlRow: some View {
        HStack(spacing: 24) {
            flashButton
            gridButton
            flipButton
        }
    }

    private var flashButton: some View {
        let on = model.camera.flashEnabled
        return Button {
            model.camera.flashEnabled.toggle()
            Haptics.light()
        } label: {
            controlIcon(on ? "bolt.fill" : "bolt.slash.fill", active: on)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Flash")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private var gridButton: some View {
        Button {
            gridEnabled.toggle()
            Haptics.light()
        } label: {
            controlIcon("grid", active: gridEnabled)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Grid")
        .accessibilityValue(gridEnabled ? "On" : "Off")
        .accessibilityAddTraits(gridEnabled ? [.isSelected] : [])
    }

    private var flipButton: some View {
        Button {
            flip()
        } label: {
            controlIcon("arrow.triangle.2.circlepath", active: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Flip camera")
    }

    private func controlIcon(_ name: String, active: Bool) -> some View {
        Image(systemName: name)
            .font(.title3)
            .foregroundStyle(active ? .yellow : .white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.4), in: Circle())
    }

    // MARK: Zoom control

    private var zoomControl: some View {
        HStack(spacing: 6) {
            ForEach(model.camera.zoomPresets, id: \.self) { preset in
                zoomChip(preset)
            }
        }
        .padding(6)
        .background(.black.opacity(0.4), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Zoom")
    }

    private func zoomChip(_ preset: CGFloat) -> some View {
        let selected = nearestPreset == preset
        // The selected chip shows the live zoom (e.g. "1.4×") so pinching reads out.
        let text = selected ? zoomLabel(model.camera.zoomFactor) : shortZoomLabel(preset)
        return Button {
            model.camera.setZoom(preset, animated: true)
            Haptics.light()
        } label: {
            Text(text)
                .font(.system(size: selected ? 14 : 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(selected ? .yellow : .white)
                .frame(width: selected ? 50 : 38, height: 38)
                .background(.black.opacity(selected ? 0.55 : 0.0), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(shortZoomLabel(preset)) zoom")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// The preset currently "active" — the one closest to the live zoom factor.
    private var nearestPreset: CGFloat? {
        model.camera.zoomPresets.min(by: {
            abs($0 - model.camera.zoomFactor) < abs($1 - model.camera.zoomFactor)
        })
    }

    private func zoomLabel(_ z: CGFloat) -> String {
        if abs(z - z.rounded()) < 0.05 { return "\(Int(z.rounded()))×" }
        return String(format: "%.1f×", z)
    }

    private func shortZoomLabel(_ z: CGFloat) -> String {
        if abs(z - z.rounded()) < 0.05 { return "\(Int(z.rounded()))" }
        return String(format: "%.1f", z)
    }

    // MARK: Grid & focus overlays

    private var gridOverlay: some View {
        GeometryReader { geo in
            Path { path in
                for i in 1...2 {
                    let x = geo.size.width * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geo.size.height))
                    let y = geo.size.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func focusReticleView(_ reticle: FocusReticle) -> some View {
        // A focus square with a draggable "sun" to its right for exposure.
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.yellow, lineWidth: 1.5)
                .frame(width: 74, height: 74)
            Image(systemName: "sun.max.fill")
                .font(.caption)
                .foregroundStyle(.yellow)
                .offset(y: -exposureNorm * 30)
        }
        .position(x: reticle.location.x + 10, y: reticle.location.y)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if exposureBase == 0, abs(value.translation.height) < 0.5 {
                        exposureBase = exposureNorm
                    }
                    let delta = -value.translation.height / 150
                    exposureNorm = min(max(exposureBase + delta, -1), 1)
                    model.camera.setExposure(normalized: exposureNorm)
                    // Keep the reticle alive while actively adjusting exposure.
                    keepReticleAlive(reticle.id)
                }
                .onEnded { _ in exposureBase = exposureNorm }
        )
        .allowsHitTesting(true)
        .accessibilityHidden(true)
    }

    // MARK: Actions

    private func flip() {
        model.flip()
        Haptics.light()
    }

    private func showFocusReticle(at location: CGPoint) {
        exposureNorm = 0
        exposureBase = 0
        let reticle = FocusReticle(location: location)
        withAnimation(.easeOut(duration: 0.15)) { focusReticle = reticle }
        keepReticleAlive(reticle.id)
    }

    /// Dismiss the reticle ~2.5s after the last interaction with this `id`.
    private func keepReticleAlive(_ id: UUID) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if focusReticle?.id == id {
                withAnimation(.easeOut(duration: 0.3)) { focusReticle = nil }
            }
        }
    }

    /// Tap to take a photo; press and hold to record a video (up to 10s). While
    /// recording, a red progress ring fills around the shutter and the inner knob
    /// becomes a red square.
    private var shutterButton: some View {
        let recording = model.camera.isRecording
        return ZStack {
            if recording {
                Circle().stroke(.white.opacity(0.3), lineWidth: 5)
                    .frame(width: 82, height: 82)
                Circle()
                    .trim(from: 0, to: model.camera.recordingProgress)
                    .stroke(.red, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 82, height: 82)
                RoundedRectangle(cornerRadius: 8).fill(.red)
                    .frame(width: 32, height: 32)
            } else {
                Circle().stroke(.white, lineWidth: 5).frame(width: 82, height: 82)
                Circle().fill(.white).frame(width: 68, height: 68)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: recording)
        .contentShape(Circle())
        .gesture(recordGesture)
        .simultaneousGesture(
            TapGesture().onEnded {
                guard model.isLive, !model.camera.isRecording else { return }
                Haptics.medium()
                model.capture(previewAspect: previewHandle.aspectRatio)
            }
        )
        .accessibilityLabel("Shutter")
        .accessibilityHint("Tap to take a photo. Press and hold to record a video.")
    }

    /// Long-press (held ≥0.3s) starts recording; lifting off stops it. A plain
    /// quick tap falls through to the simultaneous `TapGesture` (a photo).
    private var recordGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                if case .second(true, _) = value, !model.camera.isRecording {
                    Haptics.medium()
                    model.startRecording()
                }
            }
            .onEnded { _ in
                if model.camera.isRecording { model.stopRecording() }
            }
    }

    @ViewBuilder
    private var shutterHint: some View {
        if model.camera.isRecording {
            Text("Recording… release to stop")
                .font(.caption).foregroundStyle(.white.opacity(0.85))
        } else {
            Text("Tap for photo · hold for video")
                .font(.caption).foregroundStyle(.white.opacity(0.7))
        }
    }

    private var permissionDenied: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.metering.none")
                .font(.system(size: 48))
            Text("Camera access is off")
                .font(.headline)
            Text("Enable the camera in Settings to send snaps.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
        }
        .foregroundStyle(.white)
        .padding()
    }

    // MARK: Review

    private func reviewPane(_ image: UIImage) -> some View {
        // Show the captured photo full-bleed, exactly matching the `.resizeAspectFill`
        // live preview (the capture is already center-cropped to the preview aspect),
        // with the caption/timer/send controls overlaid at the bottom. Displaying it
        // in a split top pane made a full-screen-aspect photo shrink to fit and look
        // "zoomed out" with wide side gaps.
        ZStack(alignment: .bottom) {
            GeometryReader { geo in
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                    if !model.caption.isEmpty {
                        captionOverlay(imageSize: image.size, container: geo.size)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
            }
            .ignoresSafeArea()

            sendControls(showDragHint: true)
        }
    }

    // MARK: Video review

    /// Review a just-recorded clip: it loops full-bleed behind the same caption /
    /// timer / send controls used for photos. The caption isn't burned into the
    /// video (it's shown as an overlay to the recipient), so there's no drag hint.
    private func videoReviewPane(_ url: URL) -> some View {
        ZStack(alignment: .bottom) {
            LoopingPlayerView(url: url, fill: true)
                .ignoresSafeArea()

            if !model.caption.isEmpty {
                Text(model.caption)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .background(.black.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .allowsHitTesting(false)
            }

            sendControls(showDragHint: false)
        }
    }

    private func sendControls(showDragHint: Bool) -> some View {
        VStack(spacing: 16) {
            TextField("Add a caption", text: Binding(
                get: { model.caption },
                set: { model.caption = String($0.prefix(80)) }))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Caption, up to 80 characters")

            if showDragHint, !model.caption.isEmpty {
                Text("Drag the caption to move it · pinch to resize")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }

            timerPicker

            // Retake now lives in the top bar (the X); this row is just Send.
            Button(action: model.send) {
                Group {
                    if model.sending { ProgressView() }
                    else { Label("Send", systemImage: "paperplane.fill") }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow).foregroundStyle(.black)
            .disabled(model.sending)
        }
        .padding()
        .padding(.bottom, 8)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.85)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    /// The caption rendered over the photo, positioned by `model.captionPosition`
    /// and sized by `model.captionScale`. Drag moves it; pinch resizes it. Font
    /// size tracks the displayed image width so it previews what will be burned in.
    private func captionOverlay(imageSize: CGSize, container: CGSize) -> some View {
        let frame = displayedImageFrame(imageSize: imageSize, container: container)
        let fontSize = max(frame.width * 0.045 * model.captionScale, 10)
        return Text(model.caption)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(fontSize * 0.4)
            .background(.black.opacity(0.35),
                        in: RoundedRectangle(cornerRadius: fontSize * 0.4))
            .frame(maxWidth: frame.width * 0.88)
            .position(x: frame.minX + model.captionPosition.x * frame.width,
                      y: frame.minY + model.captionPosition.y * frame.height)
            .gesture(captionDrag(in: frame))
            .simultaneousGesture(captionMagnify)
            .accessibilityLabel("Caption: \(model.caption)")
            .accessibilityHint("Drag to reposition, pinch to resize")
    }

    private func captionDrag(in frame: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let base = captionDragBase ?? model.captionPosition
                if captionDragBase == nil { captionDragBase = base }
                let nx = base.x + value.translation.width / frame.width
                let ny = base.y + value.translation.height / frame.height
                model.captionPosition = CGPoint(
                    x: min(max(nx, 0.05), 0.95),
                    y: min(max(ny, 0.05), 0.95))
            }
            .onEnded { _ in captionDragBase = nil }
    }

    private var captionMagnify: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let base = captionScaleBase ?? model.captionScale
                if captionScaleBase == nil { captionScaleBase = base }
                model.captionScale = min(max(base * value, 0.5), 3.0)
            }
            .onEnded { _ in captionScaleBase = nil }
    }

    /// The rect the `.scaledToFit` image actually occupies inside `container`,
    /// so the caption can be placed in image-relative coordinates.
    private func displayedImageFrame(imageSize: CGSize, container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = container.width / container.height
        var w = container.width, h = container.height
        if imageAspect > containerAspect {
            h = container.width / imageAspect   // letterboxed top/bottom
        } else {
            w = container.height * imageAspect   // pillarboxed sides
        }
        return CGRect(x: (container.width - w) / 2,
                      y: (container.height - h) / 2,
                      width: w, height: h)
    }

    private var timerPicker: some View {
        HStack(spacing: 10) {
            ForEach(CameraViewModel.timerOptions, id: \.self) { value in
                timerChip(value)
            }
        }
    }

    private func timerChip(_ value: Int) -> some View {
        let selected = model.timerSeconds == value
        let label = value == 0 ? "∞" : "\(value)s"
        let fill: Color = selected ? .yellow : .gray.opacity(0.3)
        let fg: Color = selected ? .black : .white
        return Button {
            model.timerSeconds = value
        } label: {
            Text(label)
                .font(.subheadline.bold())
                .frame(width: 52, height: 40)
                .background(fill, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(fg)
        }
        .accessibilityLabel(value == 0 ? "Until dismissed" : "\(value) seconds")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Lightweight haptic feedback for camera interactions.
enum Haptics {
    @MainActor static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    @MainActor static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
