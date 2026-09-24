import SwiftUI

/// Collect the display name shown to the partner. Shown once after the age gate.
struct DisplayNameView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var name = ""
    @State private var busy = false
    @State private var errorMessage: String?

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("What should we call you?")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text("Your partner sees this name on your snaps.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("Display name", text: $name)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: name) { _, value in
                    if value.count > 30 { name = String(value.prefix(30)) }
                }
                .accessibilityLabel("Display name")

            Spacer()

            Button {
                save()
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow)
            .foregroundStyle(.black)
            .disabled(trimmed.isEmpty || busy)
        }
        .padding(24)
        .alert("Something went wrong",
               isPresented: .init(get: { errorMessage != nil },
                                  set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func save() {
        busy = true
        Task {
            do { try await env.auth.setDisplayName(trimmed) }
            catch { errorMessage = error.localizedDescription }
            busy = false
        }
    }
}
