import Foundation
import XCTest

@testable import IndexStore

final class IndexStoreTests: XCTestCase {
    private func makeStore() throws -> IndexStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flatten-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try IndexStore(path: dir.appendingPathComponent("index.sqlite").path)
    }

    func testMigrationAndSourceRoundTrip() async throws {
        let store = try makeStore()
        let id = try await store.addSource(kind: "folder", path: "/tmp/a", displayName: "a")
        // Same (kind, path) is idempotent.
        let again = try await store.addSource(kind: "folder", path: "/tmp/a", displayName: "a")
        XCTAssertEqual(id, again)

        let other = try await store.addSource(kind: "folder", path: "/tmp/b", displayName: "b")
        XCTAssertNotEqual(id, other)
    }

    func testImageUpsertInsertsThenUpdates() async throws {
        let store = try makeStore()

        let record = ImageRecord(
            volumeUUID: "vol-1", relPath: "/photos/a.cr3", filename: "a.cr3",
            ext: "cr3", fileSize: 100, mtime: 1_000)
        let firstID = try await store.upsertImage(record)

        var changed = record
        changed.fileSize = 200
        changed.cameraModel = "Canon EOS R5"
        let secondID = try await store.upsertImage(changed)

        XCTAssertEqual(firstID, secondID, "same identity must update, not duplicate")
        let count = try await store.imageCount()
        XCTAssertEqual(count, 1)
        let bytes = try await store.totalImageBytes()
        XCTAssertEqual(bytes, 200)

        let fetched = try await store.fetchImage(volumeUUID: "vol-1", relPath: "/photos/a.cr3")
        XCTAssertEqual(fetched?.fileSize, 200)
        XCTAssertEqual(fetched?.cameraModel, "Canon EOS R5")
        XCTAssertEqual(fetched?.state, "present")
    }

    func testDistinctIdentitiesStayDistinct() async throws {
        let store = try makeStore()
        _ = try await store.upsertImage(
            ImageRecord(
                volumeUUID: "vol-1", relPath: "/photos/a.cr3", filename: "a.cr3",
                ext: "cr3", fileSize: 100, mtime: 1_000))
        _ = try await store.upsertImage(
            ImageRecord(
                volumeUUID: "vol-2", relPath: "/photos/a.cr3", filename: "a.cr3",
                ext: "cr3", fileSize: 100, mtime: 1_000))
        let count = try await store.imageCount()
        XCTAssertEqual(count, 2)
    }
}
