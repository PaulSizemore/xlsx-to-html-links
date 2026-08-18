import Foundation
import GRDB

/// Builds minimal .lrcat-schema SQLite files for tests: the edge-case
/// generator promised in ARCHITECTURE.md Phase 1 fixtures.
struct SyntheticCatalog {
    struct Image {
        var filename: String
        var folder: String  // pathFromRoot, "" or "sub/dir/" with trailing slash
        var rating: Double?
        var pick: Double = 0
        var colorLabel: String = ""
        var captureTime: String?  // "2024-05-17T11:23:45"
        var keywords: [String] = []
        var collections: [String] = []
        var hasDevelopHistory: Bool = false
    }

    var rootPath: String  // absolutePath of the root folder, with trailing slash
    var images: [Image]
    var schemaVersion = "1100000"

    /// Writes the catalog and returns its path.
    func write(to path: String) throws {
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(
                sql: "CREATE TABLE Adobe_variablesTable (id_local INTEGER PRIMARY KEY, name TEXT, value TEXT)")
            try db.execute(
                sql: "INSERT INTO Adobe_variablesTable (name, value) VALUES ('Adobe_DBVersion', ?)",
                arguments: [schemaVersion])

            try db.execute(
                sql: """
                    CREATE TABLE AgLibraryRootFolder (
                      id_local INTEGER PRIMARY KEY, absolutePath TEXT, name TEXT)
                    """)
            try db.execute(
                sql: """
                    CREATE TABLE AgLibraryFolder (
                      id_local INTEGER PRIMARY KEY, pathFromRoot TEXT, rootFolder INTEGER)
                    """)
            try db.execute(
                sql: """
                    CREATE TABLE AgLibraryFile (
                      id_local INTEGER PRIMARY KEY, folder INTEGER, idx_filename TEXT,
                      baseName TEXT, extension TEXT)
                    """)
            try db.execute(
                sql: """
                    CREATE TABLE Adobe_images (
                      id_local INTEGER PRIMARY KEY, rootFile INTEGER, rating REAL,
                      pick REAL, colorLabels TEXT, captureTime TEXT)
                    """)
            try db.execute(
                sql: "CREATE TABLE AgLibraryKeyword (id_local INTEGER PRIMARY KEY, name TEXT)")
            try db.execute(
                sql: "CREATE TABLE AgLibraryKeywordImage (id_local INTEGER PRIMARY KEY, image INTEGER, tag INTEGER)")
            try db.execute(
                sql: "CREATE TABLE AgLibraryCollection (id_local INTEGER PRIMARY KEY, name TEXT)")
            try db.execute(
                sql: "CREATE TABLE AgLibraryCollectionImage (id_local INTEGER PRIMARY KEY, collection INTEGER, image INTEGER)")
            try db.execute(
                sql: "CREATE TABLE Adobe_libraryImageDevelopHistoryStep (id_local INTEGER PRIMARY KEY, image INTEGER)")

            try db.execute(
                sql: "INSERT INTO AgLibraryRootFolder (id_local, absolutePath, name) VALUES (1, ?, 'root')",
                arguments: [rootPath])

            var keywordIDs: [String: Int64] = [:]
            var collectionIDs: [String: Int64] = [:]
            var folderIDs: [String: Int64] = [:]
            var nextID: Int64 = 100

            for image in images {
                let folderID: Int64
                if let existing = folderIDs[image.folder] {
                    folderID = existing
                } else {
                    nextID += 1
                    folderID = nextID
                    folderIDs[image.folder] = folderID
                    try db.execute(
                        sql: "INSERT INTO AgLibraryFolder (id_local, pathFromRoot, rootFolder) VALUES (?, ?, 1)",
                        arguments: [folderID, image.folder])
                }

                nextID += 1
                let fileID = nextID
                let base = (image.filename as NSString).deletingPathExtension
                let ext = (image.filename as NSString).pathExtension
                try db.execute(
                    sql: """
                        INSERT INTO AgLibraryFile
                          (id_local, folder, idx_filename, baseName, extension)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [fileID, folderID, image.filename, base, ext])

                nextID += 1
                let imageID = nextID
                try db.execute(
                    sql: """
                        INSERT INTO Adobe_images
                          (id_local, rootFile, rating, pick, colorLabels, captureTime)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        imageID, fileID, image.rating, image.pick, image.colorLabel,
                        image.captureTime,
                    ])

                for keyword in image.keywords {
                    let keywordID: Int64
                    if let existing = keywordIDs[keyword] {
                        keywordID = existing
                    } else {
                        nextID += 1
                        keywordID = nextID
                        keywordIDs[keyword] = keywordID
                        try db.execute(
                            sql: "INSERT INTO AgLibraryKeyword (id_local, name) VALUES (?, ?)",
                            arguments: [keywordID, keyword])
                    }
                    nextID += 1
                    try db.execute(
                        sql: "INSERT INTO AgLibraryKeywordImage (id_local, image, tag) VALUES (?, ?, ?)",
                        arguments: [nextID, imageID, keywordID])
                }

                for collection in image.collections {
                    let collectionID: Int64
                    if let existing = collectionIDs[collection] {
                        collectionID = existing
                    } else {
                        nextID += 1
                        collectionID = nextID
                        collectionIDs[collection] = collectionID
                        try db.execute(
                            sql: "INSERT INTO AgLibraryCollection (id_local, name) VALUES (?, ?)",
                            arguments: [collectionID, collection])
                    }
                    nextID += 1
                    try db.execute(
                        sql: "INSERT INTO AgLibraryCollectionImage (id_local, collection, image) VALUES (?, ?, ?)",
                        arguments: [nextID, collectionID, imageID])
                }

                if image.hasDevelopHistory {
                    nextID += 1
                    try db.execute(
                        sql: "INSERT INTO Adobe_libraryImageDevelopHistoryStep (id_local, image) VALUES (?, ?)",
                        arguments: [nextID, imageID])
                }
            }
        }
    }
}
