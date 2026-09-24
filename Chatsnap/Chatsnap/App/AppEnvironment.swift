import Foundation
import SwiftUI

/// Dependency container. Constructed once and injected into the view tree so that
/// services (and the SnapRepository actor) can be swapped for mocks in previews
/// and tests.
@MainActor
@Observable
final class AppEnvironment {
    let auth: AuthService
    let push: PushService
    let repository: any SnapRepositoryProtocol
    let functions: FunctionsClient
    let kept: KeptStore

    init(
        auth: AuthService = AuthService(),
        push: PushService = PushService(),
        repository: any SnapRepositoryProtocol = SnapRepository(),
        functions: FunctionsClient = FunctionsClient(),
        kept: KeptStore = KeptStore()
    ) {
        self.auth = auth
        self.push = push
        self.repository = repository
        self.functions = functions
        self.kept = kept
    }
}
