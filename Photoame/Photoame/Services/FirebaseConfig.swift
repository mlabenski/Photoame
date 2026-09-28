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

    private static let useProdDefaultsKey = "photoame.useProductionBackend"

    /// Whether a Debug build should talk to the real Firebase backend instead of
    /// the local emulators. Needed to test push notifications, which the Functions
    /// emulator cannot deliver (no FCM/APNs backend). See [[device-emulator-setup]].
    ///
    /// Source of truth is a **persisted UserDefaults flag**, not the Run-scheme env
    /// var: an env var is injected only when Xcode launches the app, so it silently
    /// evaporates on any icon/OS relaunch (exactly what happens when you background
    /// the app to watch for a push) and the build falls back to the emulator. The
    /// persisted flag survives every launch. `PHOTOAME_USE_PROD` still works as the
    /// first-run seed; after that the in-app toggle (`setUseProduction`) is
    /// authoritative. Release builds always use production.
    static var useProduction: Bool {
        #if DEBUG
        let defaults = UserDefaults.standard
        if defaults.object(forKey: useProdDefaultsKey) != nil {
            return defaults.bool(forKey: useProdDefaultsKey)
        }
        let seed = ProcessInfo.processInfo.environment["PHOTOAME_USE_PROD"] == "1"
        defaults.set(seed, forKey: useProdDefaultsKey)
        return seed
        #else
        return true
        #endif
    }

    /// Persist a new backend choice. Takes effect on the next launch (Firebase is
    /// configured once at process start and can't be re-pointed live). Debug only.
    static func setUseProduction(_ useProd: Bool) {
        UserDefaults.standard.set(useProd, forKey: useProdDefaultsKey)
    }

    /// The backend this running process actually wired up at launch — captured in
    /// `configure()`. May differ from `useProduction` if the user just toggled the
    /// pending choice but hasn't restarted yet.
    // Written once in `configure()` at launch (main thread, before any
    // concurrency), read thereafter — safe to treat as immutable at runtime.
    nonisolated(unsafe) private(set) static var activeIsProduction = true

    /// Human-readable description of the backend this session is talking to.
    static var activeBackendDescription: String {
        let project = FirebaseApp.app()?.options.projectID ?? "unknown"
        #if DEBUG
        return activeIsProduction ? "Production (\(project))" : "Emulator (\(emulatorHost))"
        #else
        return "Production (\(project))"
        #endif
    }

    /// A stable identifier for the backend this launch is wired to: the Firebase
    /// project id plus emulator-vs-prod (and the emulator host). `AuthService`
    /// persists this across launches to detect a target switch — toggling
    /// `PHOTOAME_USE_PROD`, changing emulator host, or a project change. A Firebase
    /// Auth session cached in the keychain belongs to whichever backend minted it;
    /// restored against a *different* backend its ID token is rejected, surfacing
    /// as endless "Missing or insufficient permissions" and a profile that never
    /// loads. Must be read after `configure()` so `FirebaseApp` is available.
    static var backendTag: String {
        let project = FirebaseApp.app()?.options.projectID ?? "unknown"
        #if DEBUG
        if activeIsProduction { return "prod:\(project)" }
        return "emu:\(emulatorHost):\(project)"
        #else
        return "prod:\(project)"
        #endif
    }

    static func configure() {
        FirebaseApp.configure()
        #if DEBUG
        activeIsProduction = useProduction
        if !activeIsProduction {
            useEmulators()
        }
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
