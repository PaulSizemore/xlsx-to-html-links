import Foundation
import GRDB

enum Migrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // v1 mirrors ARCHITECTURE.md §3, with two deviations:
        // - sources.bookmark is nullable and sources.path exists, because the CLI
        //   harness has no security-scoped bookmarks; the app fills bookmark in.
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE sources (
                  id INTEGER PRIMARY KEY,
                  kind TEXT NOT NULL,
                  bookmark BLOB,
                  path TEXT,
                  display_name TEXT,
                  last_scanned_at INTEGER,
                  catalog_schema_version TEXT
                )
                """)

            try db.execute(sql: """
                CREATE TABLE images (
                  id INTEGER PRIMARY KEY,
                  volume_uuid TEXT NOT NULL,
                  rel_path TEXT NOT NULL,
                  filename TEXT NOT NULL,
                  ext TEXT NOT NULL,
                  file_size INTEGER NOT NULL,
                  mtime INTEGER NOT NULL,
                  capture_time INTEGER,
                  camera_model TEXT,
                  camera_serial TEXT,
                  lens TEXT,
                  content_key TEXT,
                  jpeg_sibling_path TEXT,
                  xmp_sidecar_path TEXT,
                  state TEXT NOT NULL DEFAULT 'present',
                  UNIQUE(volume_uuid, rel_path)
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_images_state ON images(state)")
            try db.execute(sql: "CREATE INDEX idx_images_content_key ON images(content_key)")

            try db.execute(sql: """
                CREATE TABLE rating_records (
                  id INTEGER PRIMARY KEY,
                  image_id INTEGER NOT NULL REFERENCES images(id),
                  source_id INTEGER NOT NULL REFERENCES sources(id),
                  origin TEXT NOT NULL,
                  rating INTEGER,
                  flag TEXT,
                  color_label TEXT,
                  keywords TEXT,
                  collections TEXT,
                  has_develop_edits INTEGER,
                  recorded_at INTEGER,
                  match_confidence TEXT NOT NULL,
                  UNIQUE(image_id, source_id, origin)
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_rating_records_image ON rating_records(image_id)")

            try db.execute(sql: """
                CREATE TABLE overrides (
                  image_id INTEGER PRIMARY KEY REFERENCES images(id),
                  action TEXT NOT NULL
                )
                """)
        }

        // v2: absolute path column for tier-1 (exact) catalog reconciliation.
        // rel_path + volume_uuid remains the durable identity; abs_path is the
        // as-scanned location used for joining against catalog path claims.
        migrator.registerMigration("v2") { db in
            try db.execute(sql: "ALTER TABLE images ADD COLUMN abs_path TEXT")
            try db.execute(
                sql: "CREATE INDEX idx_images_abs_path ON images(abs_path COLLATE NOCASE)")
        }

        // v3: the operation journal (every original-file mutation is recorded
        // before/after it happens, §4.5–4.6) and the flattened-output pointer.
        migrator.registerMigration("v3") { db in
            try db.execute(sql: """
                CREATE TABLE journal (
                  id INTEGER PRIMARY KEY,
                  batch_id TEXT NOT NULL,
                  image_id INTEGER,
                  kind TEXT NOT NULL,
                  src_path TEXT,
                  dst_path TEXT,
                  detail TEXT,
                  created_at INTEGER NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_journal_batch ON journal(batch_id)")
            try db.execute(sql: "ALTER TABLE images ADD COLUMN flattened_path TEXT")
        }

        return migrator
    }
}
