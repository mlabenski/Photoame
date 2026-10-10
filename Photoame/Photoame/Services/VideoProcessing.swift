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
        // Bake an upright-portrait orientation into the output frames. See
        // `portraitComposition` — this is what keeps the sent MP4 from landing
        // sideways when the capture connection failed to rotate the clip.
        if let composition = await portraitComposition(for: asset) {
            session.videoComposition = composition
        }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snap-\(UUID().uuidString).mp4")
        session.shouldOptimizeForNetworkUse = true

        do {
            try await session.export(to: outURL, as: .mp4)
        } catch {
            log.error("video export failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return outURL
    }

    /// Build a video composition that renders the clip **upright in portrait**.
    ///
    /// The app only ever shoots portrait, yet some devices don't honor the movie
    /// output connection's rotation, leaving the recorded file in the sensor's
    /// native landscape. This composition starts from the source's own preferred
    /// transform; if the resulting frame is still landscape it adds a 90°
    /// clockwise rotation so the output is portrait. A clip that's already
    /// portrait is left untouched, so this never double-rotates a correct clip —
    /// which makes it safe to apply to both review playback and the sent copy.
    ///
    /// Returns `nil` if the track or its attributes can't be read (callers then
    /// fall back to playing/exporting the file as-is).
    static func portraitComposition(for asset: AVAsset) async -> AVMutableVideoComposition? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let preferred = try? await track.load(.preferredTransform),
              let duration = try? await asset.load(.duration) else {
            return nil
        }
        // Frame extents after the source's own transform.
        let displayed = naturalSize.applying(preferred)
        let dW = abs(displayed.width), dH = abs(displayed.height)

        var transform = preferred
        var renderSize = CGSize(width: dW, height: dH)
        if dW > dH {
            // Landscape → rotate an extra 90° clockwise into a portrait frame.
            let cw90 = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: dH, ty: 0)
            transform = preferred.concatenating(cw90)
            renderSize = CGSize(width: dH, height: dW)
        }

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
    static func posterFrame(from url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let result = try? await generator.image(
            at: CMTime(seconds: 0, preferredTimescale: 600)) else {
            return nil
        }
        return UIImage(cgImage: result.image)
    }
}
