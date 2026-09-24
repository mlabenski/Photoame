import Foundation
import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseFirestore

/// Owns Sign in with Apple and the signed-in user's profile document.
/// The single source of truth for "who am I" and "am I paired".
@MainActor
@Observable
final class AuthService: NSObject {
    private(set) var uid: String?
    private(set) var profile: UserProfile?
    private(set) var isLoading = true

    private var authHandle: AuthStateDidChangeListenerHandle?
    private var profileListener: ListenerRegistration?
    private var currentNonce: String?
    private var db: Firestore { Firestore.firestore() }

    /// True once a signed-in user has both confirmed 18+ and set a display name.
    var isOnboarded: Bool {
        guard let profile else { return false }
        return profile.ageConfirmedAt != nil && !profile.displayName.isEmpty
    }

    var activePairId: String? { profile?.activePairId }

    func start() {
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self else { return }
            Task { @MainActor in self.handleAuthChange(user) }
        }
    }

    private func handleAuthChange(_ user: FirebaseAuth.User?) {
        profileListener?.remove()
        guard let user else {
            uid = nil
            profile = nil
            isLoading = false
            return
        }
        uid = user.uid
        listenToProfile(uid: user.uid)
    }

    private func listenToProfile(uid: String) {
        profileListener = db.document("users/\(uid)").addSnapshotListener { [weak self] snap, _ in
            guard let self else { return }
            Task { @MainActor in
                self.profile = try? snap?.data(as: UserProfile.self)
                self.isLoading = false
            }
        }
    }

    // MARK: - Sign in with Apple

    /// Configure a SwiftUI SignInWithAppleButton request with a fresh nonce.
    func configure(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonce()
        currentNonce = nonce
        request.requestedScopes = [.fullName]
        request.nonce = Self.sha256(nonce)
    }

    func handleCompletion(_ result: Result<ASAuthorization, Error>) async throws {
        switch result {
        case .failure(let error):
            throw error
        case .success(let auth):
            guard
                let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                let nonce = currentNonce,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8)
            else {
                throw AuthError.invalidCredential
            }
            let firebaseCredential = OAuthProvider.appleCredential(
                withIDToken: idToken,
                rawNonce: nonce,
                fullName: credential.fullName
            )
            let authResult = try await Auth.auth().signIn(with: firebaseCredential)
            try await ensureProfile(for: authResult.user, fullName: credential.fullName)
        }
    }

    /// Create the user doc on first sign-in. Only writes fields the client owns.
    private func ensureProfile(for user: FirebaseAuth.User, fullName: PersonNameComponents?) async throws {
        let ref = db.document("users/\(user.uid)")
        let existing = try await ref.getDocument()
        if existing.exists { return }
        let suggested = fullName?.givenName ?? ""
        try await ref.setData([
            "displayName": suggested,
            "activePairId": NSNull(),
            "cooldowns": [:],
            "createdAt": FieldValue.serverTimestamp(),
        ])
    }

    // MARK: - Onboarding writes (client-owned fields only)

    func confirmAge() async throws {
        guard let uid else { return }
        try await db.document("users/\(uid)").setData(
            ["ageConfirmedAt": FieldValue.serverTimestamp()], merge: true)
    }

    func setDisplayName(_ name: String) async throws {
        guard let uid else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try await db.document("users/\(uid)").setData(["displayName": trimmed], merge: true)
    }

    func signOut() throws {
        try Auth.auth().signOut()
    }

    // MARK: - Nonce helpers

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            if status != errSecSuccess { continue }
            if random < charset.count {
                result.append(charset[Int(random)])
                remaining -= 1
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        let hashed = SHA256.hash(data: Data(input.utf8))
        return hashed.map { String(format: "%02x", $0) }.joined()
    }
}

enum AuthError: LocalizedError {
    case invalidCredential
    var errorDescription: String? {
        switch self {
        case .invalidCredential: return "Could not read your Apple credential."
        }
    }
}
