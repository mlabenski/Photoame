import Foundation
import AVFoundation
import UIKit
import os

/// Pure video helpers: transcode a freshly recorded clip down to a small,
/// broadly compatible MP4 for sending, and pull a poster frame for thumbnails.
/// Everything stays in the app sandbox — nothing here ever touches the Photos
/// library.
enum VideoProcessing {
    private static let log = Logger(subsystem: "com.photoame.app", category: "snaps")

    /// Longest clip we record or send, in seconds.
    static let maxDuration: Double = 10

    /// Transcode `sourceURL` to a compressed `.mp4` in the temp directory,
    /// returning the output URL. Favors a small file (medium quality, ~540p) so
    /// a 10-second clip lands well under the Storage cap and uploads quickly on a
    /// phone connection. Returns `nil` if no exporter can be built; on an export
    /// failure the caller can fall back to the original file.
    static func transcodeForSend(_ sourceURL: URL) async -> URL? {
        let asset = AVURLAsset(url: sourceURL)
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
            log.error("could not create export session for video")
            return nil
        }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snap-\(UUID().uuidString).mp4")
        session.outputURL = outURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        await session.export()
        guard session.status == .completed else {
            log.error("video export failed: \(session.error?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }
        return outURL
    }

    /// Extract a poster frame (the first frame) from a video for use as a
    /// thumbnail in the Kept gallery. Returns `nil` if the frame can't be read.
    static func posterFrame(from url: URL) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let cg = try? generator.copyCGImage(
            at: CMTime(seconds: 0, preferredTimescale: 600), actualTime: nil) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }
}
