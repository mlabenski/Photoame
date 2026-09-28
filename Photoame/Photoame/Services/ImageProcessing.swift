import UIKit
import AVFoundation

/// Pure image helpers: burn a caption onto a capture, downscale to ~1600px on
/// the long edge, and encode to HEIC (fallback JPEG) targeting 200–400 KB.
/// Everything happens in memory — nothing here ever touches the Photos library.
enum ImageProcessing {
    static let longEdge: CGFloat = 1600
    static let minBytes = 200 * 1024
    static let maxBytes = 400 * 1024

    /// Downscale, render the caption, and return encoded image data plus whether
    /// HEIC was used (so the caller can pick the storage extension/content type).
    /// - Parameters:
    ///   - captionPosition: caption center, normalized (0...1) within the image.
    ///   - captionScale: font size multiplier from the review pane's pinch gesture.
    static func prepareForSend(_ image: UIImage, caption: String,
                               captionPosition: CGPoint = CGPoint(x: 0.5, y: 0.85),
                               captionScale: CGFloat = 1) -> (data: Data, isHEIC: Bool)? {
        let scaled = downscale(image, longEdge: longEdge)
        let captioned = caption.isEmpty ? scaled
            : renderCaption(caption, on: scaled,
                            position: captionPosition, scale: captionScale)
        return encode(captioned)
    }

    /// Center-crop `image` so its aspect ratio matches `aspect` (width / height in
    /// the image's displayed orientation). Used to make a capture match what the
    /// `.resizeAspectFill` preview showed: the preview covers the tall screen by
    /// cropping the sensor frame's edges, so we reproduce that same center crop on
    /// the full-frame photo before review/send. A no-op if `aspect` is invalid or
    /// already matches (within rounding).
    static func cropCentered(_ image: UIImage, toAspect aspect: CGFloat) -> UIImage {
        guard aspect > 0 else { return image }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let currentAspect = size.width / size.height
        guard abs(currentAspect - aspect) > 0.001 else { return image }

        var cropSize = size
        if currentAspect > aspect {
            cropSize.width = size.height * aspect   // too wide: trim the sides
        } else {
            cropSize.height = size.width / aspect   // too tall: trim top/bottom
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: cropSize, format: format).image { _ in
            // Draw the full (orientation-corrected) image offset so its center
            // lands in the crop rect; the renderer clips to `cropSize`.
            let origin = CGPoint(x: (cropSize.width - size.width) / 2,
                                 y: (cropSize.height - size.height) / 2)
            image.draw(in: CGRect(origin: origin, size: size))
        }
    }

    static func downscale(_ image: UIImage, longEdge: CGFloat) -> UIImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        guard maxSide > longEdge else { return image }
        let scale = longEdge / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Draw the caption centered on a rounded scrim, positioned at `position`
    /// (normalized 0...1) and sized by `scale`. Wraps across up to a few lines and
    /// is clipped to 80 characters. The scrim is clamped to stay on the image.
    static func renderCaption(_ caption: String, on image: UIImage,
                              position: CGPoint, scale: CGFloat) -> UIImage {
        let text = String(caption.prefix(80))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { ctx in
            image.draw(at: .zero)

            // Match the on-screen review overlay: base size is a fraction of the
            // image width, multiplied by the user's pinch scale.
            let fontSize = max(image.size.width * 0.045 * scale, 12)
            let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
            ]

            let inset = image.size.width * 0.06
            let maxWidth = image.size.width - inset * 2
            let bounding = (text as NSString).boundingRect(
                with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                attributes: attrs, context: nil)
            let textWidth = min(ceil(bounding.width), maxWidth)
            let textHeight = ceil(bounding.height)
            let pad = fontSize * 0.4

            // Desired scrim center in pixels, clamped so the scrim stays on-image.
            let scrimWidth = textWidth + pad * 2
            let scrimHeight = textHeight + pad * 2
            let halfW = scrimWidth / 2, halfH = scrimHeight / 2
            let cx = min(max(position.x * image.size.width, halfW),
                         image.size.width - halfW)
            let cy = min(max(position.y * image.size.height, halfH),
                         image.size.height - halfH)

            let scrimRect = CGRect(x: cx - halfW, y: cy - halfH,
                                   width: scrimWidth, height: scrimHeight)
            let scrimPath = UIBezierPath(roundedRect: scrimRect, cornerRadius: pad)
            UIColor.black.withAlphaComponent(0.35).setFill()
            scrimPath.fill()

            let textRect = CGRect(x: cx - textWidth / 2, y: cy - textHeight / 2,
                                  width: textWidth, height: textHeight)
            (text as NSString).draw(with: textRect,
                                    options: [.usesLineFragmentOrigin],
                                    attributes: attrs, context: nil)
        }
    }

    /// Try HEIC first; iterate quality to land in the target byte range.
    static func encode(_ image: UIImage) -> (data: Data, isHEIC: Bool)? {
        if let heic = encodeHEIC(image) { return (heic, true) }
        if let jpeg = encodeJPEG(image) { return (jpeg, false) }
        return nil
    }

    private static func encodeHEIC(_ image: UIImage) -> Data? {
        for quality in stride(from: 0.7, through: 0.35, by: -0.05) {
            guard let data = heicData(image, quality: quality) else { return nil }
            if data.count <= maxBytes { return data }
        }
        return heicData(image, quality: 0.3)
    }

    private static func heicData(_ image: UIImage, quality: Double) -> Data? {
        guard let cg = image.cgImage else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, AVFileType.heic as CFString, 1, nil) else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(dest, cg, options)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func encodeJPEG(_ image: UIImage) -> Data? {
        for quality in stride(from: 0.7, through: 0.35, by: -0.05) {
            if let data = image.jpegData(compressionQuality: quality), data.count <= maxBytes {
                return data
            }
        }
        return image.jpegData(compressionQuality: 0.3)
    }
}
