import Foundation
import UIKit

/// Local, on-device store for kept snaps. Images live in
/// Application Support/KeptSnaps and are excluded from iCloud backup. They are
/// NEVER written to the Photos library and never leave the sandbox.
@MainActor
@Observable
final class KeptStore {
    private(set) var items: [KeptItem] = []

    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("KeptSnaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeFromBackup(directory)
        reload()
    }

    /// Persist an already-downloaded kept image. Idempotent per snapId.
    func save(snapId: String, imageData: Data, caption: String, keptAt: Date) {
        let fileURL = directory.appendingPathComponent("\(snapId).img")
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? imageData.write(to: fileURL, options: .atomic)
        excludeFromBackup(fileURL)

        let metaURL = directory.appendingPathComponent("\(snapId).json")
        let meta = KeptMeta(snapId: snapId, caption: caption, keptAt: keptAt)
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metaURL, options: .atomic)
            excludeFromBackup(metaURL)
        }
        reload()
    }

    func contains(snapId: String) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("\(snapId).img").path)
    }

    /// Purge everything — used when the pair ends (all shared data must be gone).
    func purgeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeFromBackup(directory)
        items = []
    }

    private func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        let metas = files.filter { $0.pathExtension == "json" }
        var loaded: [KeptItem] = []
        for metaURL in metas {
            guard
                let data = try? Data(contentsOf: metaURL),
                let meta = try? JSONDecoder().decode(KeptMeta.self, from: data)
            else { continue }
            let imgURL = directory.appendingPathComponent("\(meta.snapId).img")
            guard let imgData = try? Data(contentsOf: imgURL),
                  let image = UIImage(data: imgData) else { continue }
            loaded.append(KeptItem(id: meta.snapId, image: image,
                                   caption: meta.caption, keptAt: meta.keptAt))
        }
        items = loaded.sorted { $0.keptAt > $1.keptAt }
    }

    private func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

struct KeptItem: Identifiable {
    let id: String
    let image: UIImage
    let caption: String
    let keptAt: Date
}

private struct KeptMeta: Codable {
    let snapId: String
    let caption: String
    let keptAt: Date
}
