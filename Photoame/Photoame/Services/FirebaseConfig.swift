import Foundation
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import FirebaseFunctions
#if DEBUG
import Network
#endif

/// Central Firebase setup. In Debug builds everything is wired to the local
/// Emulator Suite; Release builds talk to production (using the committed-out
/// GoogleService-Info.plist that ships only in the Release bundle).
enum FirebaseConfig {
    /// Host used to reach the emulators.
    ///
    /// Resolution order:
    ///   1. `PHOTOAME_EMULATOR_HOST` env var, if set — manual override for any
    ///      network where mDNS is unavailable (e.g. a guest/VLAN that blocks it).
    ///   2. Simulator → `localhost` (shares the Mac's loopback).
    ///   3. Physical device → the Mac's `.local` mDNS hostname, which Bonjour
    ///      resolves to the current LAN IP automatically. Immune to DHCP drift,
    ///      so no IP editing when the lease rotates.
    static var emulatorHost: String {
        if let override = ProcessInfo.processInfo.environment["PHOTOAME_EMULATOR_HOST"],
           !override.isEmpty {
            return override
        }
        #if targetEnvironment(simulator)
        return "localhost"
        #else
        return "Reacts-MacBook-Pro.local"
        #endif
    }

    static func configure() {
        FirebaseApp.configure()
        #if DEBUG
        useEmulators()
        #endif
    }

    #if DEBUG
    private static func useEmulators() {
        let host = emulatorHost
        triggerLocalNetworkPrompt(host: host)
        Auth.auth().useEmulator(withHost: host, port: 9099)

        let settings = Firestore.firestore().settings
        settings.host = "\(host):8080"
        settings.isSSLEnabled = false
        settings.cacheSettings = MemoryCacheSettings()
        Firestore.firestore().settings = settings

        Storage.storage().useEmulator(withHost: host, port: 9199)
        Functions.functions().useEmulator(withHost: host, port: 5001)
    }

    /// A plain URLSession request to a raw LAN IP often fails to surface the iOS
    /// Local Network permission prompt, leaving every emulator call blocked with
    /// error -1009 ("Local network prohibited"). Opening an NWConnection to the
    /// emulator host reliably forces the system dialog. Loopback is exempt from
    /// the restriction, so we skip it on the Simulator.
    private static func triggerLocalNetworkPrompt(host: String) {
        guard host != "localhost", host != "127.0.0.1" else { return }
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: 9099)!,
            using: .tcp
        )
        // The handler closure captures `connection`, keeping it alive while the
        // probe runs. On any terminal state we cancel and clear the handler,
        // which breaks that retain cycle and lets it deallocate — so there is no
        // shared mutable state for the concurrency checker to complain about.
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                connection.cancel()
                connection.stateUpdateHandler = nil
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
    }
    #endif
}
