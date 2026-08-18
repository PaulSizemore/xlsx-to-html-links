import Foundation
import XCTest

@testable import IndexStore
@testable import ScanKit

final class ImageScannerTests: XCTestCase {
    private var root: URL!
    private var store: IndexStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flatten-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("shoot1"), withIntermediateDirectories: true)
        store = try IndexStore(path: root.appendingPathComponent("index.sqlite").path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ relative: String, bytes: Int = 16) throws {
        let url = root.appendingPathComponent(relative)
        let data = Data(repeating: 0xAB, count: bytes)
        try data.write(to: url)
    }

    func testScanFindsRawsPairsAndSidecars() async throws {
        // a: RAW + JPEG + sidecar, b: bare RAW, c: JPEG only (not indexed),
        // notes.txt: skipped.
        try touch("shoot1/A.CR3", bytes: 100)
        try touch("shoot1/a.jpg")
        try touch("shoot1/a.xmp")
        try touch("shoot1/b.nef", bytes: 50)
        try touch("shoot1/c.jpg")
        try touch("shoot1/notes.txt")

        let sourceID = try await store.addSource(
            kind: "folder", path: root.path, displayName: "test")
        // NullExifReader keeps this deterministic: the fake files aren't real RAWs.
        let scanner = ImageScanner(store: store, exif: NullExifReader(), thumbnails: nil)
        let summary = try await scanner.scan(root: root, sourceID: sourceID)

        XCTAssertEqual(summary.logicalImages, 2)
        XCTAssertEqual(summary.rawJpegPairs, 1, "A.CR3 pairs with a.jpg case-insensitively")
        XCTAssertEqual(summary.sidecars, 1)
        XCTAssertEqual(summary.totalRawBytes, 150)
        XCTAssertEqual(summary.errors, [])

        let count = try await store.imageCount()
        XCTAssertEqual(count, 2)
        let images = try await store.fetchImages(limit: 10)

        let rawA = images.first { $0.filename == "A.CR3" }
        XCTAssertNotNil(rawA)
        XCTAssertEqual(rawA?.ext, "cr3")
        XCTAssertNotNil(rawA?.jpegSiblingPath)
        XCTAssertNotNil(rawA?.xmpSidecarPath)

        let rawB = images.first { $0.filename == "b.nef" }
        XCTAssertNotNil(rawB)
        XCTAssertNil(rawB?.jpegSiblingPath)
        XCTAssertNil(rawB?.xmpSidecarPath)
    }

    func testRescanIsIdempotent() async throws {
        try touch("shoot1/b.nef", bytes: 50)
        let sourceID = try await store.addSource(
            kind: "folder", path: root.path, displayName: "test")
        let scanner = ImageScanner(store: store, exif: NullExifReader(), thumbnails: nil)

        _ = try await scanner.scan(root: root, sourceID: sourceID)
        _ = try await scanner.scan(root: root, sourceID: sourceID)
        let count = try await store.imageCount()
        XCTAssertEqual(count, 1)
    }
}
