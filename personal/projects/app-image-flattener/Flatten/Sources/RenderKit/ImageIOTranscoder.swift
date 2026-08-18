#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO

/// The macOS decode→encode path: ImageIO RAW decode, HEIC/JPEG encode with
/// source metadata carried over and the effective rating overlaid.
/// JXL/AVIF/lossy-DNG land in Phase 6 behind the same protocol.
public struct ImageIOTranscoder: Transcoding {
    /// Star rating to stamp into the output's metadata (from EffectiveRating),
    /// so the flattened file carries the catalog's verdict forward.
    public var ratingOverlay: Int?

    public init(ratingOverlay: Int? = nil) {
        self.ratingOverlay = ratingOverlay
    }

    public func transcode(source: URL, destination: URL, settings: EncodeSettings) throws
        -> TranscodeResult
    {
        let typeIdentifier: String
        switch settings.format {
        case .heic: typeIdentifier = "public.heic"
        case .jpeg: typeIdentifier = "public.jpeg"
        case .jpegXL, .avif, .lossyDNG:
            throw TranscodeError("\(settings.format.rawValue) encoding lands in Phase 6")
        }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, sourceOptions) else {
            throw TranscodeError("cannot open \(source.path)")
        }

        var decodeOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        var image: CGImage?
        if let maxEdge = settings.maxLongEdge {
            decodeOptions[kCGImageSourceCreateThumbnailFromImageAlways] = true
            decodeOptions[kCGImageSourceThumbnailMaxPixelSize] = maxEdge
            decodeOptions[kCGImageSourceCreateThumbnailWithTransform] = true
            image = CGImageSourceCreateThumbnailAtIndex(
                imageSource, 0, decodeOptions as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(
                imageSource, 0, decodeOptions as CFDictionary)
        }
        guard let image else {
            throw TranscodeError("decode failed for \(source.path)")
        }

        var properties =
            (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, sourceOptions)
                as? [CFString: Any]) ?? [:]
        properties[kCGImageDestinationLossyCompressionQuality] = settings.quality
        if let rating = ratingOverlay {
            var iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
            iptc[kCGImagePropertyIPTCStarRating] = rating
            properties[kCGImagePropertyIPTCDictionary] = iptc
        }

        guard
            let imageDestination = CGImageDestinationCreateWithURL(
                destination as CFURL, typeIdentifier as CFString, 1, nil)
        else {
            throw TranscodeError("cannot create \(settings.format.rawValue) destination")
        }
        CGImageDestinationAddImage(imageDestination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(imageDestination) else {
            throw TranscodeError("encode failed for \(source.path)")
        }

        // Durability before the finalize ordering relies on this file existing.
        if let handle = try? FileHandle(forWritingTo: destination) {
            try? handle.synchronize()
            try? handle.close()
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return TranscodeResult(outputBytes: size, width: image.width, height: image.height)
    }
}

/// Decode-back verification: the output must open, decode, and match the
/// dimensions the encoder reported.
public struct ImageIOVerifier: OutputVerifying {
    public init() {}

    public func verify(output: URL, expected: TranscodeResult) throws {
        guard
            let imageSource = CGImageSourceCreateWithURL(
                output as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw TranscodeError("verification: cannot decode \(output.path)")
        }
        guard width == expected.width, height == expected.height else {
            throw TranscodeError(
                "verification: dimensions \(width)x\(height) != expected "
                    + "\(expected.width)x\(expected.height)")
        }
    }
}
#endif
