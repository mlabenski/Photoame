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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.phase {
            case .live:
                liveCamera
            case .review(let image):
                reviewPane(image)
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
                }
                if model.camera.showScreenFlash {
                    Color.white.ignoresSafeArea()
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
                VStack {
                    Spacer()
                    ZStack {
                        shutterButton
                        HStack {
                            flashButton
                            Spacer()
                        }
                        .padding(.leading, 44)
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
                    .onChanged { value in model.camera.zoom(factor: value) }
            )
            .onTapGesture(count: 2) { model.flip() }
            .onTapGesture { location in
                // Single tap = focus. (Double-tap flip takes priority above.)
                // Convert through the preview layer so the focus point accounts
                // for `.resizeAspectFill` cropping; fall back to a plain
                // normalization if the layer isn't laid out yet.
                let point = previewHandle.devicePoint(for: location)
                    ?? CGPoint(x: location.x / size.width,
                               y: location.y / size.height)
                model.camera.focus(atPoint: point)
            }
            .accessibilityElement()
            .accessibilityLabel("Camera preview")
            .accessibilityHint("Double tap to flip the camera")
    }

    private var flashButton: some View {
        let on = model.camera.flashEnabled
        return Button {
            model.camera.flashEnabled.toggle()
        } label: {
            Image(systemName: on ? "bolt.fill" : "bolt.slash.fill")
                .font(.title3)
                .foregroundStyle(on ? .yellow : .white)
                .padding(12)
                .background(.black.opacity(0.4), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Flash")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private var shutterButton: some View {
        Button {
            model.capture(previewAspect: previewHandle.aspectRatio)
        } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 5).frame(width: 82, height: 82)
                Circle().fill(.white).frame(width: 68, height: 68)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Take photo")
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
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                    if !model.caption.isEmpty {
                        captionOverlay(imageSize: image.size, container: geo.size)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
            }

            VStack(spacing: 16) {
                TextField("Add a caption", text: Binding(
                    get: { model.caption },
                    set: { model.caption = String($0.prefix(80)) }))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Caption, up to 80 characters")

                if !model.caption.isEmpty {
                    Text("Drag the caption to move it · pinch to resize")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }

                timerPicker

                HStack(spacing: 16) {
                    Button(role: .cancel) { model.retake() } label: {
                        Label("Retake", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.bordered)

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
            }
            .padding()
            .background(.black)
        }
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
