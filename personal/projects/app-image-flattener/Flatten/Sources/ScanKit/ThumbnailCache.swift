import Foundation

/// Flat on-disk cache of preview JPEGs, keyed by content key.
public struct ThumbnailCache: Sendable {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    public func url(forKey key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("jpg")
    }

    @discardableResult
    public func store(_ data: Data, forKey key: String) throws -> URL {
        let target = url(forKey: key)
        if !FileManager.default.fileExists(atPath: target.path) {
            try data.write(to: target, options: .atomic)
        }
        return target
    }
}
