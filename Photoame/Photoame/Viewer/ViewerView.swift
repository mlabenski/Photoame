import SwiftUI

/// Full-screen snap viewer. Shows a countdown when a timer is set, blurs while
/// the screen is being recorded/mirrored, reports screenshots, and offers Keep.
struct ViewerView: View {
    let pairId: String
    let snapId: String
    @Bindable var session: PairSessionViewModel
    /// Called when the user taps the photo to skip it — advances to the next
    /// unopened snap if there is one, otherwise returns to the camera.
    var onSkip: () -> Void = {}

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var model: ViewerViewModel?
    @State private var capture = ScreenCaptureObserver()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let model {
                content(model)
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }
        }
        .statusBarHidden()
        .task {
            if model == nil, let uid = env.auth.uid {
                let vm = ViewerViewModel(pairId: pairId, snapId: snapId, uid: uid,
                                         repository: env.repository, kept: env.kept)
                model = vm
                capture.onScreenshot = { vm.reportScreenshot() }
                capture.start()
                await vm.begin()
            }
        }
        .onDisappear {
            capture.stop()
            model?.discard()
        }
    }

    @ViewBuilder
    private func content(_ model: ViewerViewModel) -> some View {
        switch model.phase {
        case .loading:
            ProgressView().controlSize(.large).tint(.white)

        case .viewing:
            imageStage(model)

        case .replayAvailable:
            replayPrompt(model)

        case .finished:
            finishedState(dismissAfter: true)

        case .keptConfirmed:
            keptState()

        case .error(let message):
            errorState(message)
        }
    }

    private func imageStage(_ model: ViewerViewModel) -> some View {
        ZStack {
            if let image = model.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .blur(radius: capture.isCaptured ? 40 : 0)
                    .overlay {
                        if capture.isCaptured { capturedOverlay }
                    }
                    .accessibilityLabel(model.caption.isEmpty ? "Snap photo" : model.caption)
            }

            VStack {
                HStack {
                    if let countdown = model.countdown {
                        Text("\(countdown)")
                            .font(.title2.bold().monospacedDigit())
                            .padding(10)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    Spacer()
                    Button { model.finishViewing() } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .padding(10)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    .accessibilityLabel("Close snap")
                }
                .foregroundStyle(.white)
                .padding()

                Spacer()

                if !model.caption.isEmpty {
                    Text(model.caption)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.black.opacity(0.35))
                }

                keepBar(model)
            }
        }
        // Tap anywhere to skip this snap and move on (to the next unopened snap,
        // or back to the camera). Works whether or not a timer is counting down.
        .contentShape(Rectangle())
        .onTapGesture {
            model.discard()
            onSkip()
        }
    }

    private func keepBar(_ model: ViewerViewModel) -> some View {
        HStack {
            Button { model.keep() } label: {
                Label(model.iKept ? "Kept — waiting for partner" : "Keep",
                      systemImage: model.iKept ? "heart.fill" : "heart")
                    .font(.headline)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.black.opacity(0.5), in: Capsule())
            }
            .foregroundStyle(model.iKept ? .pink : .white)
            .disabled(model.iKept)
            .accessibilityHint("Both of you must Keep for it to be saved to the Us gallery")
        }
        .padding(.bottom, 24)
    }

    private var capturedOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.slash.fill").font(.largeTitle)
            Text("Hidden while your screen is being recorded")
                .font(.subheadline)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding()
    }

    private func replayPrompt(_ model: ViewerViewModel) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 56)).foregroundStyle(.yellow)
            Text("One replay available")
                .font(.title3.bold()).foregroundStyle(.white)
            Text("You can watch this once more within 5 minutes.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button { model.replay() } label: {
                Text("Replay").font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent).tint(.yellow).foregroundStyle(.black)
            Button("Done") { dismiss() }
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(32)
    }

    private func finishedState(dismissAfter: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle").font(.system(size: 44))
            Text("Gone.").font(.headline)
        }
        .foregroundStyle(.white)
        .task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            dismiss()
        }
    }

    private func keptState() -> some View {
        VStack(spacing: 12) {
            Image(systemName: "heart.fill").font(.system(size: 48)).foregroundStyle(.pink)
            Text("Saved to your Us gallery").font(.headline).foregroundStyle(.white)
            Button("Done") { dismiss() }
                .buttonStyle(.bordered).tint(.white).padding(.top, 8)
        }
        .padding(32)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 40))
            Text(message).multilineTextAlignment(.center)
            Button("Close") { dismiss() }.buttonStyle(.bordered).tint(.white)
        }
        .foregroundStyle(.white)
        .padding(32)
    }
}
