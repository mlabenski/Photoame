import Foundation
import FirebaseFirestore

@MainActor
@Observable
final class SettingsViewModel {
    var displayName = ""
    private(set) var partnerName = "your partner"
    private(set) var partnerUid: String?
    private(set) var pairId: String?
    var busy = false
    var errorMessage: String?

    private let auth: AuthService
    private let functions: FunctionsClient

    init(auth: AuthService, functions: FunctionsClient) {
        self.auth = auth
        self.functions = functions
        self.displayName = auth.profile?.displayName ?? ""
        self.pairId = auth.activePairId
    }

    func load() {
        guard let uid = auth.uid, let pairId else { return }
        Task { [weak self] in
            let db = Firestore.firestore()
            guard
                let pairDoc = try? await db.document("pairs/\(pairId)").getDocument(),
                let members = pairDoc.get("members") as? [String],
                let partner = members.first(where: { $0 != uid })
            else { return }
            self?.partnerUid = partner
            let userDoc = try? await db.document("users/\(partner)").getDocument()
            if let name = userDoc?.get("displayName") as? String, !name.isEmpty {
                self?.partnerName = name
            }
        }
    }

    func saveDisplayName() {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { try? await auth.setDisplayName(trimmed) }
    }

    func endPair() { run { try await self.functions.endPair() } }

    func block() {
        guard let partnerUid else { return }
        run { try await self.functions.blockUser(otherUid: partnerUid) }
    }

    func report(reason: String, detail: String) {
        guard let partnerUid else { return }
        run { try await self.functions.submitReport(
            reportedUid: partnerUid, pairId: self.pairId,
            reason: reason, detail: detail) }
    }

    func deleteAccount() {
        run {
            try await self.functions.deleteAccount()
            try? self.auth.signOut()
        }
    }

    func signOut() { try? auth.signOut() }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            do { try await action() }
            catch { errorMessage = error.localizedDescription }
            busy = false
        }
    }
}
