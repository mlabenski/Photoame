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
        // Bake the source's orientation into the output frames. A plain export is
        // notorious for dropping a portrait clip's preferred transform and landing
        // it sideways (landscape); an explicit, orientation-aware composition keeps
        // the sent MP4 upright exactly as it was recorded.
        if let composition = await orientedComposition(for: asset) {
            session.videoComposition = composition
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

    /// Build a video composition that applies the source track's preferred
    /// transform, with a render size matching the *oriented* frame — the canonical
    /// recipe for exporting an upright clip. Returns `nil` if the track or its
    /// attributes can't be read (the caller then exports without a composition).
    private static func orientedComposition(for asset: AVAsset) async -> AVMutableVideoComposition? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform),
              let duration = try? await asset.load(.duration) else {
            return nil
        }
        // Extents of the frame after the transform rotates/flips it.
        let oriented = naturalSize.applying(transform)
        let renderSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))

        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        return composition
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
