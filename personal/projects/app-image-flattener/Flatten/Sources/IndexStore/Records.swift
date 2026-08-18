import Foundation
import GRDB

public struct SourceRecord: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "sources"

    public var id: Int64?
    public var kind: String
    public var bookmark: Data?
    public var path: String?
    public var displayName: String?
    public var lastScannedAt: Int64?
    public var catalogSchemaVersion: String?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case bookmark
        case path
        case displayName = "display_name"
        case lastScannedAt = "last_scanned_at"
        case catalogSchemaVersion = "catalog_schema_version"
    }

    public init(
        id: Int64? = nil,
        kind: String,
        bookmark: Data? = nil,
        path: String? = nil,
        displayName: String? = nil,
        lastScannedAt: Int64? = nil,
        catalogSchemaVersion: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.bookmark = bookmark
        self.path = path
        self.displayName = displayName
        self.lastScannedAt = lastScannedAt
        self.catalogSchemaVersion = catalogSchemaVersion
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct ImageRecord: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "images"

    public var id: Int64?
    public var volumeUUID: String
    public var relPath: String
    public var filename: String
    public var ext: String
    public var fileSize: Int64
    public var mtime: Int64
    public var captureTime: Int64?
    public var cameraModel: String?
    public var cameraSerial: String?
    public var lens: String?
    public var contentKey: String?
    public var jpegSiblingPath: String?
    public var xmpSidecarPath: String?
    public var state: String

    enum CodingKeys: String, CodingKey {
        case id
        case volumeUUID = "volume_uuid"
        case relPath = "rel_path"
        case filename
        case ext
        case fileSize = "file_size"
        case mtime
        case captureTime = "capture_time"
        case cameraModel = "camera_model"
        case cameraSerial = "camera_serial"
        case lens
        case contentKey = "content_key"
        case jpegSiblingPath = "jpeg_sibling_path"
        case xmpSidecarPath = "xmp_sidecar_path"
        case state
    }

    public init(
        id: Int64? = nil,
        volumeUUID: String,
        relPath: String,
        filename: String,
        ext: String,
        fileSize: Int64,
        mtime: Int64,
        captureTime: Int64? = nil,
        cameraModel: String? = nil,
        cameraSerial: String? = nil,
        lens: String? = nil,
        contentKey: String? = nil,
        jpegSiblingPath: String? = nil,
        xmpSidecarPath: String? = nil,
        state: String = "present"
    ) {
        self.id = id
        self.volumeUUID = volumeUUID
        self.relPath = relPath
        self.filename = filename
        self.ext = ext
        self.fileSize = fileSize
        self.mtime = mtime
        self.captureTime = captureTime
        self.cameraModel = cameraModel
        self.cameraSerial = cameraSerial
        self.lens = lens
        self.contentKey = contentKey
        self.jpegSiblingPath = jpegSiblingPath
        self.xmpSidecarPath = xmpSidecarPath
        self.state = state
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
