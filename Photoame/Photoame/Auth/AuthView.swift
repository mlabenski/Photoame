import SwiftUI
import AuthenticationServices

/// Sign in with Apple — the only sign-in method.
struct AuthView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
                Text("Photoame")
                    .font(.largeTitle.bold())
                Text("Photos, just for the two of you.")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()

            SignInWithAppleButton(.signIn) { request in
                env.auth.configure(request)
            } onCompletion: { result in
                Task {
                    do {
                        try await env.auth.handleCompletion(result)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 52)
            .accessibilityLabel("Sign in with Apple")

            Text("Photoame uses Sign in with Apple only.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .padding(.bottom, 24)
        .alert("Sign-in failed",
               isPresented: .init(get: { errorMessage != nil },
                                  set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}
