import Foundation
import XCTest

@testable import CatalogKit
@testable import IndexStore

final class IngestTests: XCTestCase {
    private var dir: URL!
    private var store: IndexStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ingest-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try IndexStore(path: dir.appendingPathComponent("index.sqlite").path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func indexImage(
        absPath: String, filename: String, captureTime: Int64? = nil,
        sidecarPath: String? = nil
    ) async throws -> Int64 {
        try await store.upsertImage(
            ImageRecord(
                volumeUUID: "vol", relPath: absPath, absPath: absPath,
                filename: filename, ext: (filename as NSString).pathExtension.lowercased(),
                fileSize: 10, mtime: 0, captureTime: captureTime,
                xmpSidecarPath: sidecarPath))
    }

    // MARK: Reconciler tiers

    func testExactPathMatchIsCaseInsensitive() async throws {
        let id = try await indexImage(
            absPath: "/Volumes/Photos/2024/A.CR3", filename: "A.CR3")
        let match = try await Reconciler(store: store).reconcile(
            absolutePath: "/volumes/photos/2024/a.cr3", filename: "a.cr3", captureTime: nil)
        XCTAssertEqual(match?.imageID, id)
        XCTAssertEqual(match?.confidence, .exact)
    }

    func testRelinkByFilenameAndCaptureTime() async throws {
        // Drive renamed: catalog says /Volumes/OldDrive, disk says /Volumes/New.
        let id = try await indexImage(
            absPath: "/Volumes/New/shoot/b.nef", filename: "b.nef", captureTime: 1_700_000_000)
        let match = try await Reconciler(store: store).reconcile(
            absolutePath: "/Volumes/OldDrive/shoot/b.nef", filename: "b.nef",
            captureTime: 1_700_000_000)
        XCTAssertEqual(match?.imageID, id)
        XCTAssertEqual(match?.confidence, .relinked)
    }

    func testAmbiguousRelinkRefusesToGuess() async throws {
        _ = try await indexImage(
            absPath: "/a/burst.cr3", filename: "burst.cr3", captureTime: 1_700_000_000)
        _ = try await indexImage(
            absPath: "/b/burst.cr3", filename: "burst.cr3", captureTime: 1_700_000_000)
        let match = try await Reconciler(store: store).reconcile(
            absolutePath: "/gone/burst.cr3", filename: "burst.cr3", captureTime: 1_700_000_000)
        XCTAssertNil(match, "two equally plausible candidates must not match")
    }

    func testNoCaptureTimeMeansNoRelinkTier() async throws {
        _ = try await indexImage(absPath: "/a/c.cr3", filename: "c.cr3", captureTime: nil)
        let match = try await Reconciler(store: store).reconcile(
            absolutePath: "/gone/c.cr3", filename: "c.cr3", captureTime: nil)
        XCTAssertNil(match)
    }

    // MARK: End-to-end lrcat ingest

    func testLrcatIngestWritesClaimsAndReport() async throws {
        let matchedID = try await indexImage(
            absPath: "/Volumes/Photos/2024/may/wedding-001.cr3", filename: "wedding-001.cr3")
        _ = try await indexImage(
            absPath: "/Volumes/Photos/unrelated.nef", filename: "unrelated.nef")

        let catalogPath = dir.appendingPathComponent("test.lrcat").path
        try SyntheticCatalog(
            rootPath: "/Volumes/Photos/",
            images: [
                .init(
                    filename: "wedding-001.cr3", folder: "2024/may/",
                    rating: 4, pick: 1, colorLabel: "Red",
                    keywords: ["wedding"], collections: ["Delivery"]),
                .init(filename: "missing-from-disk.cr3", folder: "gone/"),
            ]
        ).write(to: catalogPath)

        let sourceID = try await store.addSource(
            kind: "lrcat", path: catalogPath, displayName: "test")
        let report = try await LrcatIngestor(store: store)
            .ingest(catalogPath: catalogPath, sourceID: sourceID)

        XCTAssertEqual(report.catalogEntries, 2)
        XCTAssertEqual(report.matchedExact, 1)
        XCTAssertEqual(report.matchedRelinked, 0)
        XCTAssertEqual(report.unmatched, 1)
        XCTAssertEqual(report.unmatchedSamples, ["/Volumes/Photos/gone/missing-from-disk.cr3"])
        XCTAssertEqual(report.recordsWritten, 1)

        let effective = try await RatingStore(store: store).effectiveRating(imageID: matchedID)
        XCTAssertEqual(effective.rating, 4)
        XCTAssertEqual(effective.flag, .pick)
        XCTAssertEqual(effective.colorLabel, "red")
        XCTAssertEqual(effective.keywords, ["wedding"])
        XCTAssertEqual(effective.collections, ["Delivery"])
        XCTAssertFalse(effective.conflicts)

        let unknown = try await store.unknownToCatalogsCount()
        XCTAssertEqual(unknown, 1, "unrelated.nef is on disk but unknown to the catalog")

        // Re-ingest is idempotent: same (image, source, origin) updates in place.
        _ = try await LrcatIngestor(store: store)
            .ingest(catalogPath: catalogPath, sourceID: sourceID)
        let recordCount = try await store.ratingRecordCount()
        XCTAssertEqual(recordCount, 1)
    }

    // MARK: Sidecar ingest and conflicts

    func testSidecarIngestAndConflictDetection() async throws {
        let sidecarPath = dir.appendingPathComponent("d.xmp").path
        let xmp = """
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
             <rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="2"/>
            </rdf:RDF>
            """
        try Data(xmp.utf8).write(to: URL(fileURLWithPath: sidecarPath))

        let imageID = try await indexImage(
            absPath: dir.appendingPathComponent("d.cr3").path, filename: "d.cr3",
            sidecarPath: sidecarPath)

        let sidecarSource = try await store.addSource(
            kind: "folder", path: dir.path, displayName: "sidecars")
        let report = try await SidecarIngestor(store: store).ingest(sourceID: sidecarSource)
        XCTAssertEqual(report.sidecarsRead, 1)
        XCTAssertEqual(report.recordsWritten, 1)
        XCTAssertEqual(report.errors, [])

        // The catalog disagrees (rating 5): lrcat wins, conflict is flagged.
        let catalogPath = dir.appendingPathComponent("conflict.lrcat").path
        try SyntheticCatalog(
            rootPath: dir.path + "/",
            images: [.init(filename: "d.cr3", folder: "", rating: 5)]
        ).write(to: catalogPath)
        let lrcatSource = try await store.addSource(
            kind: "lrcat", path: catalogPath, displayName: "conflict")
        _ = try await LrcatIngestor(store: store)
            .ingest(catalogPath: catalogPath, sourceID: lrcatSource)

        let effective = try await RatingStore(store: store).effectiveRating(imageID: imageID)
        XCTAssertEqual(effective.rating, 5, "lrcat outranks the sidecar")
        XCTAssertTrue(effective.conflicts)
        XCTAssertEqual(effective.provenance.count, 2)
    }
}
