import Foundation
import FirebaseFirestore
import FirebaseStorage
import FirebaseFunctions

/// Abstraction over snap persistence so view models can be tested with a mock.
protocol SnapRepositoryProtocol: Sendable {
    /// Live stream of all snaps in a pair, newest first.
    func streamSnaps(pairId: String) -> AsyncStream<[Snap]>
    func sendSnap(pairId: String, senderUid: String, imageData: Data,
                  isHEIC: Bool, caption: String, timerSeconds: Int) async throws
    func downloadImage(path: String) async throws -> Data
    func markOpened(pairId: String, snapId: String) async throws -> Date?
    func markReplayed(pairId: String, snapId: String) async throws
    /// Returns true once both members have kept the snap.
    func keepSnap(pairId: String, snapId: String) async throws -> Bool
    func reportScreenshot(pairId: String, snapId: String) async throws
}

/// Firestore + Storage backed implementation. An actor so the mutating callable
/// operations are serialized; the live-query stream is nonisolated because it
/// only bridges Firestore's own callback queue into an AsyncStream.
actor SnapRepository: SnapRepositoryProtocol {
    private nonisolated var db: Firestore { Firestore.firestore() }
    private nonisolated var storage: Storage { Storage.storage() }
    private nonisolated var functions: Functions { Functions.functions() }

    nonisolated func streamSnaps(pairId: String) -> AsyncStream<[Snap]> {
        AsyncStream { continuation in
            let box = ListenerBox()
            box.registration = db.collection("pairs/\(pairId)/snaps")
                .order(by: "createdAt", descending: true)
                .limit(to: 50)
                .addSnapshotListener { snapshot, _ in
                    let snaps = snapshot?.documents.compactMap {
                        try? $0.data(as: Snap.self)
                    } ?? []
                    continuation.yield(snaps)
                }
            continuation.onTermination = { _ in box.remove() }
        }
    }

    func sendSnap(pairId: String, senderUid: String, imageData: Data,
                  isHEIC: Bool, caption: String, timerSeconds: Int) async throws {
        // 1. Reserve a snap id so the storage path and doc id line up.
        let snapRef = db.collection("pairs/\(pairId)/snaps").document()
        let ext = isHEIC ? "heic" : "jpg"
        let path = "snaps/\(pairId)/\(snapRef.documentID).\(ext)"

        // 2. Upload the blob first — rules require it to exist before the doc read.
        let meta = StorageMetadata()
        meta.contentType = isHEIC ? "image/heic" : "image/jpeg"
        _ = try await storage.reference(withPath: path).putDataAsync(imageData, metadata: meta)

        // 3. Create the snap doc (state "sent"); the trigger takes it from here.
        try await snapRef.setData([
            "senderUid": senderUid,
            "storagePath": path,
            "caption": String(caption.prefix(80)),
            "timerSeconds": timerSeconds,
            "state": SnapState.sent.rawValue,
            "createdAt": FieldValue.serverTimestamp(),
        ])
    }

    func downloadImage(path: String) async throws -> Data {
        try await storage.reference(withPath: path).data(maxSize: 5 * 1024 * 1024)
    }

    func markOpened(pairId: String, snapId: String) async throws -> Date? {
        let result = try await call("markOpened", ["pairId": pairId, "snapId": snapId])
        if let ms = (result["expiresAt"] as? NSNumber)?.doubleValue {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        return nil
    }

    func markReplayed(pairId: String, snapId: String) async throws {
        _ = try await call("markReplayed", ["pairId": pairId, "snapId": snapId])
    }

    func keepSnap(pairId: String, snapId: String) async throws -> Bool {
        let result = try await call("keepSnap", ["pairId": pairId, "snapId": snapId])
        return (result["bothKept"] as? Bool) ?? false
    }

    func reportScreenshot(pairId: String, snapId: String) async throws {
        _ = try await call("reportScreenshot", ["pairId": pairId, "snapId": snapId])
    }

    private nonisolated func call(_ name: String, _ data: [String: Any]) async throws -> [String: Any] {
        let result = try await functions.httpsCallable(name).call(data)
        return (result.data as? [String: Any]) ?? [:]
    }
}

/// Carries a non-Sendable `ListenerRegistration` across the AsyncStream's
/// `@Sendable` termination boundary. Access is single-threaded in practice
/// (set once at creation, removed once on termination).
private final class ListenerBox: @unchecked Sendable {
    var registration: ListenerRegistration?
    func remove() {
        registration?.remove()
        registration = nil
    }
}
