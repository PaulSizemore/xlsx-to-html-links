import Foundation
import GRDB

/// Single-writer actor over the workspace SQLite database.
/// UI/CLI reads go through the same actor in Phase 0; snapshot reads for the
/// grid arrive with the app shell (Phase 4).
public actor IndexStore {
    private let pool: DatabasePool

    public init(path: String) throws {
        pool = try DatabasePool(path: path)
        try Migrations.migrator.migrate(pool)
    }

    // MARK: Sources

    public func addSource(kind: String, path: String, displayName: String?) throws -> Int64 {
        try pool.write { db in
            if let existing = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM sources WHERE kind = ? AND path = ?",
                arguments: [kind, path]
            ) {
                return existing
            }
            var record = SourceRecord(kind: kind, path: path, displayName: displayName)
            try record.insert(db)
            guard let id = record.id else {
                throw DatabaseError(message: "source insert returned no rowid")
            }
            return id
        }
    }

    public func markSourceScanned(sourceID: Int64, at timestamp: Int64) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE sources SET last_scanned_at = ? WHERE id = ?",
                arguments: [timestamp, sourceID]
            )
        }
    }

    // MARK: Images

    /// Insert-or-update keyed on the (volume_uuid, rel_path) identity.
    /// Returns the image's row id.
    @discardableResult
    public func upsertImage(_ record: ImageRecord) throws -> Int64 {
        try pool.write { db in
            var record = record
            if let existing = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM images WHERE volume_uuid = ? AND rel_path = ?",
                arguments: [record.volumeUUID, record.relPath]
            ) {
                record.id = existing
                try record.update(db)
                return existing
            }
            try record.insert(db)
            guard let id = record.id else {
                throw DatabaseError(message: "image insert returned no rowid")
            }
            return id
        }
    }

    public func imageCount() throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM images") ?? 0
        }
    }

    public func totalImageBytes() throws -> Int64 {
        try pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(file_size), 0) FROM images") ?? 0
        }
    }

    public func fetchImages(limit: Int = 100) throws -> [ImageRecord] {
        try pool.read { db in
            try ImageRecord.fetchAll(
                db,
                sql: "SELECT * FROM images ORDER BY id LIMIT ?",
                arguments: [limit]
            )
        }
    }

    public func fetchImage(volumeUUID: String, relPath: String) throws -> ImageRecord? {
        try pool.read { db in
            try ImageRecord.fetchOne(
                db,
                sql: "SELECT * FROM images WHERE volume_uuid = ? AND rel_path = ?",
                arguments: [volumeUUID, relPath]
            )
        }
    }

    public func fetchImagesWithSidecars() throws -> [ImageRecord] {
        try pool.read { db in
            try ImageRecord.fetchAll(
                db,
                sql: "SELECT * FROM images WHERE xmp_sidecar_path IS NOT NULL ORDER BY id"
            )
        }
    }

    // MARK: Reconciliation lookups (CatalogKit's Reconciler)

    /// Tier 1: exact absolute-path match, case-insensitive (APFS default).
    public func findImageIDs(absPath: String) throws -> [Int64] {
        try pool.read { db in
            try Int64.fetchAll(
                db,
                sql: "SELECT id FROM images WHERE abs_path = ? COLLATE NOCASE",
                arguments: [absPath]
            )
        }
    }

    /// Tier 2: relink candidates by filename + capture time.
    public func findImageIDs(filename: String, captureTime: Int64) throws -> [Int64] {
        try pool.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT id FROM images
                    WHERE filename = ? COLLATE NOCASE AND capture_time = ?
                    """,
                arguments: [filename, captureTime]
            )
        }
    }

    // MARK: Rating records

    /// Insert-or-update keyed on the (image_id, source_id, origin) identity.
    @discardableResult
    public func upsertRatingRecord(_ record: RatingRecordRow) throws -> Int64 {
        try pool.write { db in
            var record = record
            if let existing = try Int64.fetchOne(
                db,
                sql: """
                    SELECT id FROM rating_records
                    WHERE image_id = ? AND source_id = ? AND origin = ?
                    """,
                arguments: [record.imageID, record.sourceID, record.origin]
            ) {
                record.id = existing
                try record.update(db)
                return existing
            }
            try record.insert(db)
            guard let id = record.id else {
                throw DatabaseError(message: "rating record insert returned no rowid")
            }
            return id
        }
    }

    public func fetchRatingRecords(imageID: Int64) throws -> [RatingRecordRow] {
        try pool.read { db in
            try RatingRecordRow.fetchAll(
                db,
                sql: "SELECT * FROM rating_records WHERE image_id = ? ORDER BY id",
                arguments: [imageID]
            )
        }
    }

    public func ratingRecordCount() throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rating_records") ?? 0
        }
    }

    /// Images no catalog has an opinion about — themselves prime flatten
    /// candidates ("on disk but unknown to any catalog").
    public func unknownToCatalogsCount() throws -> Int {
        try pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM images i
                    WHERE NOT EXISTS (
                      SELECT 1 FROM rating_records r WHERE r.image_id = i.id
                    )
                    """
            ) ?? 0
        }
    }
}
