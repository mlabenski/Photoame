import Foundation

@MainActor
@Observable
final class PairingViewModel {
    var inviteCode: String?
    var inviteExpiresAt: Date?
    var enteredCode = ""
    var busy = false
    var errorMessage: String?

    private let functions: FunctionsClient

    init(functions: FunctionsClient) {
        self.functions = functions
    }

    func createInvite() {
        busy = true
        Task {
            do {
                let result = try await functions.createInvite()
                inviteCode = result.code
                inviteExpiresAt = result.expiresAt
            } catch {
                errorMessage = friendly(error)
            }
            busy = false
        }
    }

    func revokeInvite() {
        Task {
            try? await functions.revokeInvite()
            inviteCode = nil
            inviteExpiresAt = nil
        }
    }

    func acceptInvite() {
        let code = enteredCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard code.count == 6 else {
            errorMessage = "Enter the 6-character code."
            return
        }
        busy = true
        Task {
            do {
                try await functions.acceptInvite(code: code)
                // On success, AuthService's profile listener flips to paired and
                // RootView routes to the camera automatically.
            } catch {
                errorMessage = friendly(error)
            }
            busy = false
        }
    }

    private func friendly(_ error: Error) -> String {
        // Callable errors surface their server message in NSLocalizedDescription.
        error.localizedDescription
    }
}
