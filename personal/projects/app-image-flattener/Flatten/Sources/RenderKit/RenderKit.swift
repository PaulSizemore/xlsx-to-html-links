import Foundation

public enum OutputFormat: String, Codable, Sendable, CaseIterable {
    case heic
    case jpeg
    case jpegXL = "jxl"
    case avif
    case lossyDNG = "dng"

    public var fileExtension: String {
        switch self {
        case .heic: return "heic"
        case .jpeg: return "jpg"
        case .jpegXL: return "jxl"
        case .avif: return "avif"
        case .lossyDNG: return "dng"
        }
    }
}

public struct EncodeSettings: Codable, Sendable, Equatable {
    public var format: OutputFormat
    /// 0.0–1.0 fixed quality; perceptual-target mode lands in Phase 6.
    public var quality: Double
    public var maxLongEdge: Int?

    public init(format: OutputFormat = .heic, quality: Double = 0.8, maxLongEdge: Int? = nil) {
        self.format = format
        self.quality = quality
        self.maxLongEdge = maxLongEdge
    }
}

public struct TranscodeResult: Sendable, Equatable {
    public var outputBytes: Int64
    public var width: Int
    public var height: Int

    public init(outputBytes: Int64, width: Int, height: Int) {
        self.outputBytes = outputBytes
        self.width = width
        self.height = height
    }
}

public struct TranscodeError: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// Decode + encode as one operation so no image buffer ever crosses an actor
/// boundary. Implementations must write to `destination` completely or throw —
/// a partial file on throw is the caller's to sweep.
public protocol Transcoding: Sendable {
    func transcode(source: URL, destination: URL, settings: EncodeSettings) throws
        -> TranscodeResult
}

/// Post-encode gate: an output failing verification keeps its original,
/// regardless of ladder rung (SPEC §4.6).
public protocol OutputVerifying: Sendable {
    func verify(output: URL, expected: TranscodeResult) throws
}

/// Platform fallback that refuses to transcode; keeps non-Apple builds honest.
public struct UnavailableTranscoder: Transcoding {
    public init() {}
    public func transcode(source: URL, destination: URL, settings: EncodeSettings) throws
        -> TranscodeResult
    {
        throw TranscodeError("no transcoder available on this platform")
    }
}
