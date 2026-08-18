import Foundation

// Phase 3 module. Protocol seams only in Phase 0.

public enum OutputFormat: String, Codable, Sendable, CaseIterable {
    case heic
    case jpeg
    case jpegXL = "jxl"
    case avif
    case lossyDNG = "dng"
}

public struct EncodeSettings: Codable, Sendable, Equatable {
    public var format: OutputFormat
    /// 0.0–1.0 fixed quality; ignored when perceptualTarget is set (Phase 6).
    public var quality: Double
    public var maxLongEdge: Int?

    public init(format: OutputFormat = .heic, quality: Double = 0.8, maxLongEdge: Int? = nil) {
        self.format = format
        self.quality = quality
        self.maxLongEdge = maxLongEdge
    }
}

public protocol RawDecoding: Sendable {
    // func decode(url: URL) throws -> DecodedImage   // Phase 3
}

public protocol ImageEncoding: Sendable {
    // func encode(_ image: DecodedImage, settings: EncodeSettings, to url: URL) throws  // Phase 3
}
