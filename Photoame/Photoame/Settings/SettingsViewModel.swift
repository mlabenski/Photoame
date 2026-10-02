import Foundation
import UIKit
import FirebaseFirestore

@MainActor
@Observable
final class SettingsViewModel {
    var displayName = ""
    private(set) var partnerName = "your partner"
    private(set) var partnerUid: String?
    private(set) var partnerPhotoURL: String?
    private(set) var pairId: String?
    var isPaired: Bool { pairId != nil }
    var busy = false
    var uploadingAvatar = false
    var errorMessage: String?

    /// Your own avatar URL, read live from the profile so it updates right after
    /// an upload (the profile listener rewrites `auth.profile`).
    var ownPhotoURL: String? { auth.profile?.photoURL }

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
            self?.partnerPhotoURL = userDoc?.get("photoURL") as? String
        }
    }

    func saveDisplayName() {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { try? await auth.setDisplayName(trimmed) }
    }

    /// Downscale and upload a newly picked profile picture. Raw image data comes
    /// from the view's PhotosPicker; processing to a square JPEG happens here.
    func updateAvatar(imageData: Data) {
        guard let image = UIImage(data: imageData),
              let prepared = ImageProcessing.prepareAvatar(image) else {
            errorMessage = "That image couldn't be used."
            return
        }
        uploadingAvatar = true
        Task {
            do { try await auth.updateAvatar(imageData: prepared) }
            catch { errorMessage = error.localizedDescription }
            uploadingAvatar = false
        }
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
