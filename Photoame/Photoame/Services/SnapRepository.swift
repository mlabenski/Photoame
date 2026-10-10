import Foundation
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import FirebaseFunctions
import os

private let repoLog = Logger(subsystem: "com.photoame.app", category: "snaps")

/// Abstraction over snap persistence so view models can be tested with a mock.
protocol SnapRepositoryProtocol: Sendable {
    /// Live stream of all snaps in a pair, newest first.
    func streamSnaps(pairId: String) -> AsyncStream<[Snap]>
    func sendSnap(pairId: String, senderUid: String, imageData: Data,
                  isHEIC: Bool, caption: String, timerSeconds: Int) async throws
    /// Send a video snap. `fileURL` points at an already-transcoded `.mp4` in the
    /// app sandbox; its bytes are uploaded and the file is the caller's to clean up.
    func sendVideoSnap(pairId: String, senderUid: String, fileURL: URL,
                       caption: String, timerSeconds: Int) async throws
    func downloadImage(path: String) async throws -> Data
    /// Download an arbitrary snap blob (used for video, which exceeds the image cap).
    func downloadData(path: String, maxBytes: Int) async throws -> Data
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
                .addSnapshotListener { snapshot, error in
                    if let error {
                        repoLog.error("snap stream error (pair \(pairId, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                    }
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
        try await createSnap(
            pairId: pairId, senderUid: senderUid, data: imageData,
            contentType: isHEIC ? "image/heic" : "image/jpeg",
            fileExtension: isHEIC ? "heic" : "jpg", mediaType: .image,
            caption: caption, timerSeconds: timerSeconds)
    }

    func sendVideoSnap(pairId: String, senderUid: String, fileURL: URL,
                       caption: String, timerSeconds: Int) async throws {
        let data = try Data(contentsOf: fileURL)
        try await createSnap(
            pairId: pairId, senderUid: senderUid, data: data,
            contentType: "video/mp4", fileExtension: "mp4", mediaType: .video,
            caption: caption, timerSeconds: timerSeconds)
    }

    /// Upload the blob, then create the snap doc (state "sent"); the Firestore
    /// trigger takes it from there. The blob is written first because the Storage
    /// create rule needs it to exist, and the doc reserves the id so the storage
    /// path and doc id line up.
    private func createSnap(pairId: String, senderUid: String, data: Data,
                            contentType: String, fileExtension: String,
                            mediaType: SnapMediaType, caption: String,
                            timerSeconds: Int) async throws {
        let snapRef = db.collection("pairs/\(pairId)/snaps").document()
        let path = "snaps/\(pairId)/\(snapRef.documentID).\(fileExtension)"
        try await uploadWithAuthRetry(data, to: path, contentType: contentType)
        try await snapRef.setData([
            "senderUid": senderUid,
            "storagePath": path,
            "caption": String(caption.prefix(80)),
            "timerSeconds": timerSeconds,
            "mediaType": mediaType.rawValue,
            "state": SnapState.sent.rawValue,
            "createdAt": FieldValue.serverTimestamp(),
        ])
    }

    /// Upload a blob, retrying once on an authorization denial.
    ///
    /// The Storage create rule authorizes the sender by reading the pair's
    /// members out of Firestore (a cross-service rule). Two transient conditions
    /// surface that read as an "unauthorized" storage error even though the user
    /// is a legitimate member: a stale ID token cached from a previous
    /// backend/session (see [[auth-backend-session-bleed]]), and the brief window
    /// right after pairing before the pair doc is visible to the Storage rules
    /// evaluator. Forcing a fresh token and retrying once clears both without
    /// bothering the user with a "Something went wrong" alert.
    private func uploadWithAuthRetry(_ data: Data, to path: String,
                                     contentType: String) async throws {
        // Build fresh (non-Sendable) reference + metadata per attempt so nothing
        // crosses a suspension point.
        func put() async throws {
            let meta = StorageMetadata()
            meta.contentType = contentType
            _ = try await storage.reference(withPath: path).putDataAsync(data, metadata: meta)
        }
        do {
            try await put()
        } catch let error as NSError where error.domain == StorageErrorDomain
            && error.code == StorageErrorCode.unauthorized.rawValue {
            repoLog.notice("snap upload unauthorized; refreshing ID token and retrying once")
            _ = try? await Auth.auth().currentUser?.getIDTokenResult(forcingRefresh: true)
            try await put()
        }
    }

    func downloadImage(path: String) async throws -> Data {
        try await downloadData(path: path, maxBytes: 5 * 1024 * 1024)
    }

    func downloadData(path: String, maxBytes: Int) async throws -> Data {
        try await storage.reference(withPath: path).data(maxSize: Int64(maxBytes))
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
