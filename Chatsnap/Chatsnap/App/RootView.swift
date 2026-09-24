import SwiftUI

/// Top-level routing based on auth + onboarding + pairing state.
///   signed-out            -> AuthView (age gate lives inside once signed in)
///   signed-in, no name    -> DisplayNameView
///   onboarded, unpaired   -> PairingView
///   onboarded, paired     -> PairedHomeView (camera + inbox + viewer)
struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            if env.auth.isLoading {
                ProgressView().controlSize(.large)
            } else if env.auth.uid == nil {
                AuthView()
            } else if env.auth.profile?.ageConfirmedAt == nil {
                AgeGateView()
            } else if (env.auth.profile?.displayName ?? "").isEmpty {
                DisplayNameView()
            } else if let pairId = env.auth.activePairId {
                PairedHomeView(pairId: pairId)
            } else {
                PairingView()
            }
        }
        .animation(.default, value: env.auth.uid)
        .animation(.default, value: env.auth.activePairId)
        .onChange(of: env.auth.activePairId) { _, newValue in
            // When a pair ends, purge the local kept gallery (all shared data gone).
            if newValue == nil { env.kept.purgeAll() }
        }
    }
}
