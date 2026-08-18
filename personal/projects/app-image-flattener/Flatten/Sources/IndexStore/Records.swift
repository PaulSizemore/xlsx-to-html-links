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
    public var absPath: String?
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
        case absPath = "abs_path"
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
        absPath: String? = nil,
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
        self.absPath = absPath
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

/// One catalog's opinion of one image — a row of rating_records.
public struct RatingRecordRow: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "rating_records"

    public var id: Int64?
    public var imageID: Int64
    public var sourceID: Int64
    public var origin: String
    public var rating: Int?
    public var flag: String?
    public var colorLabel: String?
    /// JSON array of strings.
    public var keywords: String?
    /// JSON array of strings.
    public var collections: String?
    public var hasDevelopEdits: Bool?
    public var recordedAt: Int64?
    public var matchConfidence: String

    enum CodingKeys: String, CodingKey {
        case id
        case imageID = "image_id"
        case sourceID = "source_id"
        case origin
        case rating
        case flag
        case colorLabel = "color_label"
        case keywords
        case collections
        case hasDevelopEdits = "has_develop_edits"
        case recordedAt = "recorded_at"
        case matchConfidence = "match_confidence"
    }

    public init(
        id: Int64? = nil,
        imageID: Int64,
        sourceID: Int64,
        origin: String,
        rating: Int? = nil,
        flag: String? = nil,
        colorLabel: String? = nil,
        keywords: String? = nil,
        collections: String? = nil,
        hasDevelopEdits: Bool? = nil,
        recordedAt: Int64? = nil,
        matchConfidence: String
    ) {
        self.id = id
        self.imageID = imageID
        self.sourceID = sourceID
        self.origin = origin
        self.rating = rating
        self.flag = flag
        self.colorLabel = colorLabel
        self.keywords = keywords
        self.collections = collections
        self.hasDevelopEdits = hasDevelopEdits
        self.recordedAt = recordedAt
        self.matchConfidence = matchConfidence
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
