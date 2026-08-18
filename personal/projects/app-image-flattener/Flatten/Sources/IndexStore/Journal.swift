import Foundation
import GRDB

public struct JournalEntry: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "journal"

    public var id: Int64?
    public var batchID: String
    public var imageID: Int64?
    public var kind: String
    public var srcPath: String?
    public var dstPath: String?
    public var detail: String?
    public var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case batchID = "batch_id"
        case imageID = "image_id"
        case kind
        case srcPath = "src_path"
        case dstPath = "dst_path"
        case detail
        case createdAt = "created_at"
    }

    public init(
        id: Int64? = nil,
        batchID: String,
        imageID: Int64? = nil,
        kind: String,
        srcPath: String? = nil,
        dstPath: String? = nil,
        detail: String? = nil,
        createdAt: Int64
    ) {
        self.id = id
        self.batchID = batchID
        self.imageID = imageID
        self.kind = kind
        self.srcPath = srcPath
        self.dstPath = dstPath
        self.detail = detail
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension IndexStore {
    public func appendJournal(_ entry: JournalEntry) throws {
        try pool.write { db in
            var entry = entry
            try entry.insert(db)
        }
    }

    public func fetchJournal(batchID: String) throws -> [JournalEntry] {
        try pool.read { db in
            try JournalEntry.fetchAll(
                db,
                sql: "SELECT * FROM journal WHERE batch_id = ? ORDER BY id",
                arguments: [batchID])
        }
    }

    public func journalBatchIDs() throws -> [String] {
        try pool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT batch_id FROM journal GROUP BY batch_id ORDER BY MIN(id)")
        }
    }

    public func markFlattened(imageID: Int64, outputPath: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE images SET state = 'flattened', flattened_path = ? WHERE id = ?",
                arguments: [outputPath, imageID])
        }
    }

    public func markPresent(imageID: Int64) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE images SET state = 'present', flattened_path = NULL WHERE id = ?",
                arguments: [imageID])
        }
    }

    public func imageState(imageID: Int64) throws -> String? {
        try pool.read { db in
            try String.fetchOne(
                db, sql: "SELECT state FROM images WHERE id = ?", arguments: [imageID])
        }
    }
}
