import Foundation
import IndexStore

public struct ScanSummary: Sendable {
    public var filesSeen = 0
    public var logicalImages = 0
    public var rawJpegPairs = 0
    public var sidecars = 0
    public var thumbnailsCached = 0
    public var totalRawBytes: Int64 = 0
    public var skippedNonImage = 0
    public var errors: [String] = []

    public init() {}
}

/// Recursive folder discovery: finds RAW files, collapses RAW+JPEG pairs,
/// detects XMP sidecars, reads the EXIF fast path, and upserts into IndexStore.
public struct ImageScanner: Sendable {
    let store: IndexStore
    let exif: any ExifFastPathReading
    let thumbnails: ThumbnailCache?

    public init(store: IndexStore, exif: any ExifFastPathReading, thumbnails: ThumbnailCache?) {
        self.store = store
        self.exif = exif
        self.thumbnails = thumbnails
    }

    public func scan(root: URL, sourceID: Int64) async throws -> ScanSummary {
        var summary = ScanSummary()

        // Pass 1: enumerate and classify.
        var rawFiles: [URL] = []
        // Keyed by "<dir>/<lowercased basename>" for sibling lookup.
        var jpegsByStem: [String: URL] = [:]
        var xmpsByStem: [String: URL] = [:]

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            summary.filesSeen += 1

            let ext = url.pathExtension.lowercased()
            if RawFormats.extensions.contains(ext) {
                rawFiles.append(url)
            } else if RawFormats.jpegExtensions.contains(ext) {
                jpegsByStem[Self.stemKey(url)] = url
            } else if ext == RawFormats.sidecarExtension {
                xmpsByStem[Self.stemKey(url)] = url
            } else {
                summary.skippedNonImage += 1
            }
        }

        // Pass 2: build records for each RAW (RAW+JPEG collapses onto the RAW row).
        let (volumeUUID, volumeRoot) = Self.volumeIdentity(for: root)

        for url in rawFiles {
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                let fileSize = Int64(values.fileSize ?? 0)
                let mtime = Int64(values.contentModificationDate?.timeIntervalSince1970 ?? 0)

                let stem = Self.stemKey(url)
                let jpegSibling = jpegsByStem[stem]
                let sidecar = xmpsByStem[stem]

                let meta = exif.read(url: url)

                var contentKey: String?
                if let thumbData = meta.thumbnailJPEG {
                    let key = ContentKey.make(
                        thumbnailJPEG: thumbData, captureTime: meta.captureTime)
                    contentKey = key
                    if let thumbnails {
                        try thumbnails.store(thumbData, forKey: key)
                        summary.thumbnailsCached += 1
                    }
                }

                let record = ImageRecord(
                    volumeUUID: volumeUUID,
                    relPath: Self.relativePath(of: url, toVolumeRoot: volumeRoot),
                    filename: url.lastPathComponent,
                    ext: url.pathExtension.lowercased(),
                    fileSize: fileSize,
                    mtime: mtime,
                    captureTime: meta.captureTime.map { Int64($0.timeIntervalSince1970) },
                    cameraModel: meta.cameraModel,
                    cameraSerial: meta.cameraSerial,
                    lens: meta.lens,
                    contentKey: contentKey,
                    jpegSiblingPath: jpegSibling?.path,
                    xmpSidecarPath: sidecar?.path
                )
                try await store.upsertImage(record)

                summary.logicalImages += 1
                summary.totalRawBytes += fileSize
                if jpegSibling != nil { summary.rawJpegPairs += 1 }
                if sidecar != nil { summary.sidecars += 1 }
            } catch {
                summary.errors.append("\(url.path): \(error)")
            }
        }

        try await store.markSourceScanned(
            sourceID: sourceID, at: Int64(Date().timeIntervalSince1970))
        return summary
    }

    // MARK: Identity helpers

    static func stemKey(_ url: URL) -> String {
        let dir = url.deletingLastPathComponent().path
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        return dir + "/" + stem
    }

    /// Volume UUID plus the volume's root URL, with a stable fallback for
    /// platforms/filesystems that expose neither.
    static func volumeIdentity(for url: URL) -> (uuid: String, root: URL?) {
        #if os(macOS)
        if let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey]),
            let uuid = values.volumeUUIDString
        {
            return (uuid, values.volume)
        }
        #endif
        return ("unknown-volume", nil)
    }

    static func relativePath(of url: URL, toVolumeRoot root: URL?) -> String {
        let full = url.standardizedFileURL.path
        guard let rootPath = root?.standardizedFileURL.path else { return full }
        if rootPath == "/" { return full }
        if full.hasPrefix(rootPath + "/") {
            return String(full.dropFirst(rootPath.count))
        }
        return full
    }
}
