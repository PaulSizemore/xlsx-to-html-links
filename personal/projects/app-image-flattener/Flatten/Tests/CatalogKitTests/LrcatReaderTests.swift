import Foundation
import GRDB
import XCTest

@testable import CatalogKit

final class LrcatReaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lrcat-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testReadsEntriesWithFullMetadata() throws {
        let path = dir.appendingPathComponent("test.lrcat").path
        try SyntheticCatalog(
            rootPath: "/Volumes/Photos/",
            images: [
                .init(
                    filename: "wedding-001.cr3", folder: "2024/may/",
                    rating: 4, pick: 1, colorLabel: "Red",
                    captureTime: "2024-05-17T11:23:45",
                    keywords: ["wedding", "outdoor"],
                    collections: ["Client Delivery"],
                    hasDevelopHistory: true),
                .init(filename: "extra.nef", folder: "", rating: nil, pick: -1),
            ]
        ).write(to: path)

        let catalog = try LrcatReader(catalogPath: path).read()

        XCTAssertEqual(catalog.capabilities.schemaVersion, "1100000")
        XCTAssertTrue(catalog.capabilities.hasKeywords)
        XCTAssertTrue(catalog.capabilities.hasCollections)
        XCTAssertTrue(catalog.capabilities.hasDevelopHistory)
        XCTAssertEqual(catalog.entries.count, 2)

        let wedding = catalog.entries.first { $0.filename == "wedding-001.cr3" }
        XCTAssertNotNil(wedding)
        XCTAssertEqual(wedding?.absolutePath, "/Volumes/Photos/2024/may/wedding-001.cr3")
        XCTAssertEqual(wedding?.rating, 4)
        XCTAssertEqual(wedding?.flag, .pick)
        XCTAssertEqual(wedding?.colorLabel, "red")
        XCTAssertEqual(wedding?.keywords.sorted(), ["outdoor", "wedding"])
        XCTAssertEqual(wedding?.collections, ["Client Delivery"])
        XCTAssertEqual(wedding?.hasDevelopEdits, true)
        XCTAssertEqual(
            wedding?.captureTime,
            LrcatReader.parseCaptureTime("2024-05-17T11:23:45"))

        let extra = catalog.entries.first { $0.filename == "extra.nef" }
        XCTAssertEqual(extra?.absolutePath, "/Volumes/Photos/extra.nef")
        XCTAssertNil(extra?.rating)
        XCTAssertEqual(extra?.flag, .reject)
        XCTAssertNil(extra?.colorLabel, "empty colorLabels normalizes to nil")
        XCTAssertEqual(extra?.hasDevelopEdits, false)
    }

    func testSnapshotLeavesOriginalUntouched() throws {
        let path = dir.appendingPathComponent("locked.lrcat").path
        try SyntheticCatalog(rootPath: "/p/", images: [.init(filename: "a.cr3", folder: "")])
            .write(to: path)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))

        _ = try LrcatReader(catalogPath: path).read()

        let after = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(before, after)
    }

    func testNonCatalogFailsClosed() throws {
        let path = dir.appendingPathComponent("random.lrcat").path
        // Valid SQLite, but not a Lightroom catalog: must throw, never
        // fabricate a join (fuzz/corrupt inputs fail closed, §7).
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE misc (id INTEGER PRIMARY KEY)")
        }
        XCTAssertThrowsError(try LrcatReader(catalogPath: path).read())
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(
            try LrcatReader(catalogPath: dir.appendingPathComponent("nope.lrcat").path).read())
    }

    func testCaptureTimeParsing() {
        XCTAssertNotNil(LrcatReader.parseCaptureTime("2024-05-17T11:23:45"))
        XCTAssertNotNil(LrcatReader.parseCaptureTime("2024-05-17T11:23:45.123"))
        XCTAssertNotNil(LrcatReader.parseCaptureTime("2024-05-17T11:23"))
        XCTAssertNil(LrcatReader.parseCaptureTime(nil))
        XCTAssertNil(LrcatReader.parseCaptureTime(""))
        XCTAssertNil(LrcatReader.parseCaptureTime("not a date"))
    }
}
