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
    static func prepareForSend(_ image: UIImage, caption: String) -> (data: Data, isHEIC: Bool)? {
        let scaled = downscale(image, longEdge: longEdge)
        let captioned = caption.isEmpty ? scaled : renderCaption(caption, on: scaled)
        return encode(captioned)
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

    /// Draw the caption as a single centered line near the bottom, on a legible
    /// scrim, clipped to 80 characters.
    static func renderCaption(_ caption: String, on image: UIImage) -> UIImage {
        let text = String(caption.prefix(80))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { ctx in
            image.draw(at: .zero)

            let fontSize = max(image.size.width * 0.045, 22)
            let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
            ]
            let inset = image.size.width * 0.06
            let maxWidth = image.size.width - inset * 2
            let bounding = (text as NSString).boundingRect(
                with: CGSize(width: maxWidth, height: fontSize * 3),
                options: [.usesLineFragmentOrigin],
                attributes: attrs, context: nil)
            let textHeight = ceil(bounding.height)
            let pad = fontSize * 0.4
            let scrimRect = CGRect(
                x: 0,
                y: image.size.height - textHeight - pad * 2 - inset,
                width: image.size.width,
                height: textHeight + pad * 2)
            UIColor.black.withAlphaComponent(0.35).setFill()
            ctx.cgContext.fill(scrimRect)

            let textRect = CGRect(
                x: inset, y: scrimRect.minY + pad,
                width: maxWidth, height: textHeight)
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
