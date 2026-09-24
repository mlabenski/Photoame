import SwiftUI
import UIKit

/// The paired home screen: a live camera with a single shutter, or the review
/// pane after capture (caption + view-timer + send). Every interaction is one tap.
struct CameraView: View {
    @Bindable var model: CameraViewModel

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
                    shutterButton
                        .padding(.bottom, 40)
                }
            }
        }
    }

    private func previewLayer(in size: CGSize) -> some View {
        let preview = CameraPreview(session: model.camera.captureSession)
        return preview
            .ignoresSafeArea()
            .gesture(
                MagnificationGesture()
                    .onChanged { value in model.camera.zoom(factor: value) }
            )
            .onTapGesture(count: 2) { model.flip() }
            .onTapGesture { location in
                // Single tap = focus. (Double-tap flip takes priority above.)
                let normalized = CGPoint(x: location.x / size.width,
                                         y: location.y / size.height)
                model.camera.focus(atPoint: normalized)
            }
            .accessibilityElement()
            .accessibilityLabel("Camera preview")
            .accessibilityHint("Double tap to flip the camera")
    }

    private var shutterButton: some View {
        Button(action: model.capture) {
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
            ZStack(alignment: .bottom) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                if !model.caption.isEmpty {
                    Text(model.caption)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(.black.opacity(0.35))
                }
            }

            VStack(spacing: 16) {
                TextField("Add a caption", text: Binding(
                    get: { model.caption },
                    set: { model.caption = String($0.prefix(80)) }))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Caption, up to 80 characters")

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
