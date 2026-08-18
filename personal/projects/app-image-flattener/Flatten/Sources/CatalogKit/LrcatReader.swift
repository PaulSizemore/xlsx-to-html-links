import Foundation
import GRDB

/// What this catalog's schema actually supports. Unknown schemas degrade to
/// whatever subset still resolves (ARCHITECTURE.md §4.1) and the report says so.
public struct LrcatCapabilities: Sendable, Equatable {
    public var schemaVersion: String?
    public var hasImages = false
    public var hasPaths = false
    public var hasKeywords = false
    public var hasCollections = false
    public var hasDevelopHistory = false
}

/// One image as the catalog describes it.
public struct LrcatEntry: Sendable, Equatable {
    public var idLocal: Int64
    /// rootFolder.absolutePath + folder.pathFromRoot + filename.
    public var absolutePath: String
    public var filename: String
    /// Seconds since epoch; LR stores local-naive time, parsed as UTC —
    /// consistent with ScanKit's EXIF fast path so tier-2 joins line up.
    public var captureTime: Int64?
    public var rating: Int?
    public var flag: Flag?
    public var colorLabel: String?
    public var keywords: [String]
    public var collections: [String]
    public var hasDevelopEdits: Bool?
}

public struct LrcatCatalog: Sendable {
    public var capabilities: LrcatCapabilities
    public var entries: [LrcatEntry]
}

public struct LrcatReaderError: Error, CustomStringConvertible {
    public let description: String
}

/// Read-only parser for Lightroom Classic catalogs. Always operates on a
/// snapshot copy so an open/locked catalog is never touched (§6.6).
public struct LrcatReader: Sendable {
    public let catalogPath: String

    public init(catalogPath: String) {
        self.catalogPath = catalogPath
    }

    public func read() throws -> LrcatCatalog {
        let snapshotPath = try Self.makeSnapshot(of: catalogPath)
        defer {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: snapshotPath).deletingLastPathComponent())
        }

        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: snapshotPath, configuration: configuration)

        return try queue.read { db in
            var capabilities = LrcatCapabilities()

            if try db.tableExists("Adobe_variablesTable") {
                capabilities.schemaVersion = try String.fetchOne(
                    db,
                    sql: "SELECT value FROM Adobe_variablesTable WHERE name = 'Adobe_DBVersion'")
            }

            guard try db.tableExists("Adobe_images") else {
                throw LrcatReaderError(
                    description: "not a Lightroom catalog: Adobe_images table missing")
            }
            capabilities.hasImages = true
            capabilities.hasPaths =
                try db.tableExists("AgLibraryFile")
                && db.tableExists("AgLibraryFolder")
                && db.tableExists("AgLibraryRootFolder")
            guard capabilities.hasPaths else {
                throw LrcatReaderError(
                    description: "unsupported catalog schema: file/folder tables missing")
            }

            // Column presence drives the SELECT; missing columns become NULLs.
            let imageColumns = Set(try db.columns(in: "Adobe_images").map { $0.name.lowercased() })
            let fileColumns = Set(try db.columns(in: "AgLibraryFile").map { $0.name.lowercased() })

            let ratingExpr = imageColumns.contains("rating") ? "i.rating" : "NULL"
            let pickExpr = imageColumns.contains("pick") ? "i.pick" : "NULL"
            let labelExpr = imageColumns.contains("colorlabels") ? "i.colorLabels" : "NULL"
            let captureExpr = imageColumns.contains("capturetime") ? "i.captureTime" : "NULL"
            let filenameExpr =
                fileColumns.contains("idx_filename")
                ? "f.idx_filename"
                : "f.baseName || '.' || f.extension"

            let sql = """
                SELECT i.id_local AS id_local,
                       \(ratingExpr) AS rating,
                       \(pickExpr) AS pick,
                       \(labelExpr) AS color_label,
                       \(captureExpr) AS capture_time,
                       \(filenameExpr) AS filename,
                       fo.pathFromRoot AS path_from_root,
                       rf.absolutePath AS root_path
                FROM Adobe_images i
                JOIN AgLibraryFile f ON f.id_local = i.rootFile
                JOIN AgLibraryFolder fo ON fo.id_local = f.folder
                JOIN AgLibraryRootFolder rf ON rf.id_local = fo.rootFolder
                """

            // Side tables, keyed by Adobe_images.id_local.
            var keywordsByImage: [Int64: [String]] = [:]
            if try db.tableExists("AgLibraryKeywordImage") && db.tableExists("AgLibraryKeyword") {
                capabilities.hasKeywords = true
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT ki.image AS image, k.name AS name
                        FROM AgLibraryKeywordImage ki
                        JOIN AgLibraryKeyword k ON k.id_local = ki.tag
                        WHERE k.name IS NOT NULL
                        """)
                for row in rows {
                    let image: Int64 = row["image"]
                    let name: String = row["name"]
                    keywordsByImage[image, default: []].append(name)
                }
            }

            var collectionsByImage: [Int64: [String]] = [:]
            if try db.tableExists("AgLibraryCollectionImage")
                && db.tableExists("AgLibraryCollection")
            {
                capabilities.hasCollections = true
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT ci.image AS image, c.name AS name
                        FROM AgLibraryCollectionImage ci
                        JOIN AgLibraryCollection c ON c.id_local = ci.collection
                        WHERE c.name IS NOT NULL
                        """)
                for row in rows {
                    let image: Int64 = row["image"]
                    let name: String = row["name"]
                    collectionsByImage[image, default: []].append(name)
                }
            }

            var developedImages: Set<Int64> = []
            if try db.tableExists("Adobe_libraryImageDevelopHistoryStep") {
                capabilities.hasDevelopHistory = true
                developedImages = Set(
                    try Int64.fetchAll(
                        db,
                        sql: "SELECT DISTINCT image FROM Adobe_libraryImageDevelopHistoryStep"))
            }

            var entries: [LrcatEntry] = []
            for row in try Row.fetchAll(db, sql: sql) {
                let idLocal: Int64 = row["id_local"]
                let rootPathValue: String? = row["root_path"]
                let pathFromRootValue: String? = row["path_from_root"]
                let filenameValue: String? = row["filename"]
                let rootPath = rootPathValue ?? ""
                let pathFromRoot = pathFromRootValue ?? ""
                guard let filename = filenameValue, !filename.isEmpty else { continue }

                let rating: Double? = row["rating"]
                let pick: Double? = row["pick"]
                let label: String? = row["color_label"]
                let captureText: String? = row["capture_time"]

                let normalizedLabel = label?.trimmingCharacters(in: .whitespaces)
                entries.append(
                    LrcatEntry(
                        idLocal: idLocal,
                        absolutePath: rootPath + pathFromRoot + filename,
                        filename: filename,
                        captureTime: Self.parseCaptureTime(captureText),
                        rating: rating.map { Int($0) },
                        flag: Self.flag(fromPick: pick),
                        colorLabel: (normalizedLabel?.isEmpty ?? true)
                            ? nil : normalizedLabel?.lowercased(),
                        keywords: keywordsByImage[idLocal] ?? [],
                        collections: collectionsByImage[idLocal] ?? [],
                        hasDevelopEdits: capabilities.hasDevelopHistory
                            ? developedImages.contains(idLocal) : nil
                    ))
            }

            return LrcatCatalog(capabilities: capabilities, entries: entries)
        }
    }

    static func flag(fromPick pick: Double?) -> Flag? {
        guard let pick else { return nil }
        if pick > 0.5 { return .pick }
        if pick < -0.5 { return .reject }
        return nil
    }

    /// LR stores captureTime like "2014-05-17T11:23:45" (no timezone, sometimes
    /// fractional seconds).
    static func parseCaptureTime(_ text: String?) -> Int64? {
        guard let text, !text.isEmpty else { return nil }
        for formatter in captureFormatters {
            if let date = formatter.date(from: text) {
                return Int64(date.timeIntervalSince1970)
            }
        }
        return nil
    }

    private static let captureFormatters: [DateFormatter] = {
        ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm"].map {
            format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            return formatter
        }
    }()

    /// Copy the catalog (and WAL/SHM if present) into a private temp directory.
    static func makeSnapshot(of path: String) throws -> String {
        let source = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw LrcatReaderError(description: "catalog not found: \(path)")
        }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lrcat-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let target = tempDir.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: target)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: source.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try FileManager.default.copyItem(
                    at: sidecar, to: URL(fileURLWithPath: target.path + suffix))
            }
        }
        return target.path
    }
}
