import Foundation
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import FirebaseFunctions

/// Central Firebase setup. In Debug builds everything is wired to the local
/// Emulator Suite; Release builds talk to production (using the committed-out
/// GoogleService-Info.plist that ships only in the Release bundle).
enum FirebaseConfig {
    /// Host used to reach the emulators. `localhost` works on the Simulator; on a
    /// physical device set CHATSNAP_EMULATOR_HOST to your Mac's LAN IP.
    static var emulatorHost: String {
        ProcessInfo.processInfo.environment["CHATSNAP_EMULATOR_HOST"] ?? "localhost"
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
        Auth.auth().useEmulator(withHost: host, port: 9099)

        let settings = Firestore.firestore().settings
        settings.host = "\(host):8080"
        settings.isSSLEnabled = false
        settings.cacheSettings = MemoryCacheSettings()
        Firestore.firestore().settings = settings

        Storage.storage().useEmulator(withHost: host, port: 9199)
        Functions.functions().useEmulator(withHost: host, port: 5001)
    }
    #endif
}
