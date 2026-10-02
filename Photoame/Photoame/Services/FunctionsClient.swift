import Foundation
import FirebaseFunctions

/// Thin wrapper over the pairing / safety / account callables. Every product
/// rule these touch is enforced server-side; this just marshals arguments.
struct FunctionsClient: Sendable {
    private var functions: Functions { Functions.functions() }

    private func call(_ name: String, _ data: [String: Any] = [:]) async throws -> [String: Any] {
        let result = try await functions.httpsCallable(name).call(data)
        return (result.data as? [String: Any]) ?? [:]
    }

    // MARK: Pairing
    func createInvite() async throws -> (code: String, expiresAt: Date) {
        let r = try await call("createInvite")
        let code = r["code"] as? String ?? ""
        let ms = (r["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        return (code, Date(timeIntervalSince1970: ms / 1000))
    }

    func revokeInvite() async throws {
        _ = try await call("revokeInvite")
    }

    func acceptInvite(code: String) async throws {
        _ = try await call("acceptInvite", ["code": code])
    }

    // MARK: Safety
    func endPair() async throws {
        _ = try await call("endPair")
    }

    func blockUser(otherUid: String) async throws {
        _ = try await call("blockUser", ["otherUid": otherUid])
    }

    func submitReport(reportedUid: String, pairId: String?, snapId: String? = nil,
                      reason: String, detail: String) async throws {
        _ = try await call("submitReport", [
            "reportedUid": reportedUid,
            "pairId": pairId as Any,
            "snapId": snapId as Any,
            "reason": reason,
            "detail": detail,
        ])
    }

    // MARK: Account
    func deleteAccount() async throws {
        _ = try await call("deleteAccount")
    }
}
