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

    /// Persist an already-downloaded kept snap. Idempotent per snapId. For a
    /// video, the clip is stored as `{snapId}.mp4` and a poster frame is saved as
    /// `{snapId}.img` so the gallery grid has a thumbnail; photos store their
    /// bytes directly as `{snapId}.img`.
    func save(snapId: String, data: Data, mediaType: SnapMediaType,
              caption: String, keptAt: Date) {
        let imgURL = directory.appendingPathComponent("\(snapId).img")
        guard !FileManager.default.fileExists(atPath: imgURL.path) else { return }

        switch mediaType {
        case .image:
            try? data.write(to: imgURL, options: .atomic)
            excludeFromBackup(imgURL)
        case .video:
            let videoURL = directory.appendingPathComponent("\(snapId).mp4")
            try? data.write(to: videoURL, options: .atomic)
            excludeFromBackup(videoURL)
            if let poster = VideoProcessing.posterFrame(from: videoURL),
               let posterData = poster.jpegData(compressionQuality: 0.8) {
                try? posterData.write(to: imgURL, options: .atomic)
                excludeFromBackup(imgURL)
            }
        }

        let metaURL = directory.appendingPathComponent("\(snapId).json")
        let meta = KeptMeta(snapId: snapId, caption: caption, keptAt: keptAt,
                            mediaType: mediaType.rawValue)
        if let encoded = try? JSONEncoder().encode(meta) {
            try? encoded.write(to: metaURL, options: .atomic)
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
            let isVideo = meta.mediaType == SnapMediaType.video.rawValue
            let videoURL: URL? = isVideo
                ? directory.appendingPathComponent("\(meta.snapId).mp4") : nil
            loaded.append(KeptItem(id: meta.snapId, image: image,
                                   caption: meta.caption, keptAt: meta.keptAt,
                                   isVideo: isVideo, videoURL: videoURL))
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
    /// Thumbnail: the photo itself, or a poster frame for a video.
    let image: UIImage
    let caption: String
    let keptAt: Date
    var isVideo = false
    /// Local file for playback when `isVideo`; nil for photos.
    var videoURL: URL?
}

private struct KeptMeta: Codable {
    let snapId: String
    let caption: String
    let keptAt: Date
    /// Absent on metas written before videos existed → treat as a photo.
    var mediaType: String?
}
