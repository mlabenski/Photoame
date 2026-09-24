import SwiftUI

struct PairingView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: PairingViewModel?
    @State private var mode: Mode = .choose

    enum Mode { case choose, create, enter }

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .navigationTitle("Connect")
            .task {
                if model == nil {
                    model = PairingViewModel(functions: env.functions)
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ model: PairingViewModel) -> some View {
        VStack(spacing: 28) {
            header
            switch mode {
            case .choose: chooser(model)
            case .create: createPane(model)
            case .enter: enterPane(model)
            }
            Spacer()
        }
        .padding(24)
        .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Sign out") { try? env.auth.signOut() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .accessibilityLabel("More")
                    }
                }
            }
            .alert("Couldn't connect",
                   isPresented: .init(get: { model.errorMessage != nil },
                                      set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.errorMessage ?? "") }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 44))
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text("Pair with one person")
                .font(.title2.bold())
            Text("Chatsnap connects you to exactly one partner.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func chooser(_ model: PairingViewModel) -> some View {
        VStack(spacing: 16) {
            Button {
                mode = .create
                model.createInvite()
            } label: {
                Label("Create invite", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow).foregroundStyle(.black)

            Button {
                mode = .enter
            } label: {
                Label("Enter code", systemImage: "keyboard")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.bordered)
        }
    }

    private func createPane(_ model: PairingViewModel) -> some View {
        VStack(spacing: 20) {
            if model.busy && model.inviteCode == nil {
                ProgressView()
            } else if let code = model.inviteCode {
                Text("Share this code")
                    .font(.headline)
                Text(code)
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .tracking(6)
                    .padding(.vertical, 8)
                    .accessibilityLabel("Invite code \(code.map { String($0) }.joined(separator: " "))")
                if let expires = model.inviteExpiresAt {
                    Text("Valid until \(expires.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ShareLink(item: "Pair with me on Chatsnap. My code is \(code).") {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .padding(.top, 4)
                Button("New code") { model.createInvite() }
                    .font(.footnote)
            }
            Button("Back") {
                model.revokeInvite()
                mode = .choose
            }
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
    }

    private func enterPane(_ model: PairingViewModel) -> some View {
        VStack(spacing: 20) {
            Text("Enter your partner's code")
                .font(.headline)
            TextField("ABC234", text: Binding(
                get: { model.enteredCode },
                set: { model.enteredCode = String($0.uppercased().prefix(6)) }))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Invite code")

            Button {
                model.acceptInvite()
            } label: {
                Text("Connect")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow).foregroundStyle(.black)
            .disabled(model.busy)

            Button("Back") { mode = .choose }
                .foregroundStyle(.secondary)
        }
    }
}
