import Foundation
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

/// The scan-time metadata read: cheap fields only, no full RAW decode.
public struct ExifFastPathResult: Sendable {
    public var captureTime: Date?
    public var cameraModel: String?
    public var cameraSerial: String?
    public var lens: String?
    /// Embedded preview re-encoded as JPEG, capped at 512 px long edge.
    public var thumbnailJPEG: Data?

    public init(
        captureTime: Date? = nil,
        cameraModel: String? = nil,
        cameraSerial: String? = nil,
        lens: String? = nil,
        thumbnailJPEG: Data? = nil
    ) {
        self.captureTime = captureTime
        self.cameraModel = cameraModel
        self.cameraSerial = cameraSerial
        self.lens = lens
        self.thumbnailJPEG = thumbnailJPEG
    }

    public static let empty = ExifFastPathResult()
}

public protocol ExifFastPathReading: Sendable {
    func read(url: URL) -> ExifFastPathResult
}

/// Returns nothing; used on platforms without ImageIO and in deterministic tests.
public struct NullExifReader: ExifFastPathReading {
    public init() {}
    public func read(url: URL) -> ExifFastPathResult { .empty }
}

#if canImport(ImageIO)
public struct ImageIOExifReader: ExifFastPathReading {
    public init() {}

    public func read(url: URL) -> ExifFastPathResult {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return .empty
        }

        var result = ExifFastPathResult()
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions)
            as? [CFString: Any]
        {
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let exifAux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any]
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

            if let dateString = exif?[kCGImagePropertyExifDateTimeOriginal] as? String {
                result.captureTime = Self.exifDateFormatter.date(from: dateString)
            }
            result.cameraModel = tiff?[kCGImagePropertyTIFFModel] as? String
            result.cameraSerial =
                (exif?[kCGImagePropertyExifBodySerialNumber] as? String)
                ?? (exifAux?[kCGImagePropertyExifAuxSerialNumber] as? String)
            result.lens =
                (exif?[kCGImagePropertyExifLensModel] as? String)
                ?? (exifAux?[kCGImagePropertyExifAuxLensModel] as? String)
        }

        result.thumbnailJPEG = Self.thumbnailJPEG(source: source)
        return result
    }

    private static func thumbnailJPEG(source: CGImageSource) -> Data? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ] as [CFString: Any] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data as CFMutableData, "public.jpeg" as CFString, 1, nil)
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()
}
#endif
