import Foundation
import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import os

/// Owns Sign in with Apple and the signed-in user's profile document.
/// The single source of truth for "who am I" and "am I paired".
@MainActor
@Observable
final class AuthService: NSObject {
    private(set) var uid: String?
    private(set) var profile: UserProfile?

    /// The launch gate. True until we know both whether someone is signed in
    /// (`authResolved`) and, if so, whether their profile has loaded
    /// (`profileResolved`). Computed so it can never get "stuck" out of sync
    /// with the two facts that actually determine it.
    var isLoading: Bool { !authResolved || (uid != nil && !profileResolved) }

    private var authResolved = false
    private var profileResolved = false

    private var authHandle: AuthStateDidChangeListenerHandle?
    private var profileListener: ListenerRegistration?
    private var currentNonce: String?
    private var bootstrapTimeout: Task<Void, Never>?
    private let log = Logger(subsystem: "com.photoame.app", category: "auth")
    private var db: Firestore { Firestore.firestore() }

    /// True once a signed-in user has both confirmed 18+ and set a display name.
    var isOnboarded: Bool {
        guard let profile else { return false }
        return profile.ageConfirmedAt != nil && !profile.displayName.isEmpty
    }

    var activePairId: String? { profile?.activePairId }

    func start() {
        reconcileAuthBackend()
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self else { return }
            Task { @MainActor in self.handleAuthChange(user) }
        }
        // Safety net: if no listener ever delivers (emulator wiped, offline
        // cache disabled, transient network), force the launch gate open after a
        // grace period so the app can never hang on the spinner forever.
        bootstrapTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled, self.isLoading else { return }
            self.log.warning("auth bootstrap timed out; unblocking UI")
            self.authResolved = true
            self.profileResolved = true
        }
    }

    private static let backendTagKey = "photoame.authBackendTag"

    /// Clear any persisted Auth session that belongs to a *different* backend than
    /// this launch is wired to. Firebase restores the last signed-in user from the
    /// keychain regardless of which backend (emulator, or a given project) minted
    /// its token; used against another backend that token is rejected on every
    /// read/write — the profile never loads, so onboarding (age gate, display
    /// name) repeats endlessly and self-writes fail with "insufficient
    /// permissions". We treat *no stored tag* (first launch after this shipped) as
    /// a mismatch too, so an already-stale session gets cleared once. Runs before
    /// the auth state listener so it observes the cleared state.
    private func reconcileAuthBackend() {
        let current = FirebaseConfig.backendTag
        let previous = UserDefaults.standard.string(forKey: Self.backendTagKey)
        if previous != current {
            if Auth.auth().currentUser != nil {
                log.notice("auth backend changed (\(previous ?? "none", privacy: .public) -> \(current, privacy: .public)); clearing stale session")
                try? Auth.auth().signOut()
            }
            // Also drop Firestore's on-disk cache. Production uses the default
            // *persistent* cache (only the emulator path opts into an in-memory
            // one), so pair/profile documents minted against the previous backend
            // can be served to this fresh session — rendering phantom "paired"
            // UI while live writes (e.g. sending a snap, which the Storage rules
            // authorize by reading pair membership) fail with permission-denied.
            // Safe to call here: this runs before the auth listener is attached,
            // so no Firestore read has started the client yet. Best-effort — worst
            // case we keep the stale cache for this launch. See
            // [[auth-backend-session-bleed]].
            let log = self.log
            Firestore.firestore().clearPersistence { error in
                if let error {
                    log.notice("clearPersistence failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        UserDefaults.standard.set(current, forKey: Self.backendTagKey)
    }

    private func handleAuthChange(_ user: FirebaseAuth.User?) {
        authResolved = true
        profileListener?.remove()
        profileListener = nil
        guard let user else {
            uid = nil
            profile = nil
            profileResolved = true
            return
        }
        uid = user.uid
        profileResolved = false
        listenToProfile(uid: user.uid)
    }

    private func listenToProfile(uid: String) {
        profileListener = db.document("users/\(uid)").addSnapshotListener { [weak self] snap, error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    self.log.error("profile listener error: \(error.localizedDescription, privacy: .public)")
                    self.recoverIfCredentialInvalid(error)
                } else {
                    self.profile = try? snap?.data(as: UserProfile.self)
                }
                // Resolve on error too — otherwise a failed first snapshot (no
                // offline cache to fall back on) would strand the launch gate.
                self.profileResolved = true
            }
        }
    }

    /// A permission-denied / unauthenticated read usually means our cached
    /// credential is no longer valid — e.g. the account was deleted or the
    /// emulator was reset out from under us. Sign out so the UI recovers to the
    /// sign-in screen instead of looping against a dead session.
    private func recoverIfCredentialInvalid(_ error: Error) {
        let code = (error as NSError).code
        guard code == FirestoreErrorCode.permissionDenied.rawValue
            || code == FirestoreErrorCode.unauthenticated.rawValue else { return }
        log.notice("cached credential invalid; signing out to recover")
        try? Auth.auth().signOut()
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

    /// Upload a profile picture and mirror its download URL onto the user doc.
    /// The blob is written to `avatars/{uid}.jpg` (overwriting any prior one);
    /// each upload mints a fresh download token, so we always re-read the URL.
    func updateAvatar(imageData: Data) async throws {
        guard let uid else { return }
        let ref = Storage.storage().reference(withPath: "avatars/\(uid).jpg")
        let meta = StorageMetadata()
        meta.contentType = "image/jpeg"
        _ = try await ref.putDataAsync(imageData, metadata: meta)
        let url = try await ref.downloadURL()
        try await db.document("users/\(uid)").setData(["photoURL": url.absoluteString], merge: true)
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
