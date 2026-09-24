import SwiftUI

/// One-time 18+ confirmation shown right after first sign-in.
struct AgeGateView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "person.badge.shield.checkmark")
                .font(.system(size: 56))
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text("Are you 18 or older?")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text("Chatsnap is for adults only. You must be 18+ to continue.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()

            Button {
                confirm()
            } label: {
                Text("I am 18 or older")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow)
            .foregroundStyle(.black)
            .disabled(busy)

            Button("Sign out") { try? env.auth.signOut() }
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .alert("Something went wrong",
               isPresented: .init(get: { errorMessage != nil },
                                  set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func confirm() {
        busy = true
        Task {
            do { try await env.auth.confirmAge() }
            catch { errorMessage = error.localizedDescription }
            busy = false
        }
    }
}
