import Foundation
import XCTest

@testable import IndexStore
@testable import JournalKit
@testable import PipelineKit
@testable import RenderKit

/// Deterministic stand-in codec: "encodes" by writing a marker plus half the
/// source bytes. Fails on demand for filenames containing "poison".
private struct StubTranscoder: Transcoding {
    func transcode(source: URL, destination: URL, settings: EncodeSettings) throws
        -> TranscodeResult
    {
        if source.lastPathComponent.contains("poison") {
            throw TranscodeError("stub decode failure")
        }
        let input = try Data(contentsOf: source)
        var output = Data("FLAT".utf8)
        output.append(input.prefix(input.count / 2))
        try output.write(to: destination)
        return TranscodeResult(outputBytes: Int64(output.count), width: 100, height: 50)
    }
}

private struct StubVerifier: OutputVerifying {
    var failEverything = false

    func verify(output: URL, expected: TranscodeResult) throws {
        if failEverything {
            throw TranscodeError("stub verification failure")
        }
        let data = try Data(contentsOf: output)
        guard data.prefix(4) == Data("FLAT".utf8) else {
            throw TranscodeError("marker missing")
        }
        guard Int64(data.count) == expected.outputBytes else {
            throw TranscodeError("size mismatch")
        }
    }
}

final class BatchRunnerTests: XCTestCase {
    private var dir: URL!
    private var store: IndexStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("photos"), withIntermediateDirectories: true)
        store = try IndexStore(path: dir.appendingPathComponent("index.sqlite").path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeRaw(_ name: String, bytes: Int = 100) async throws -> Int64 {
        let url = dir.appendingPathComponent("photos/\(name)")
        try Data(repeating: 0x42, count: bytes).write(to: url)
        return try await store.upsertImage(
            ImageRecord(
                volumeUUID: "v", relPath: "/photos/\(name)", absPath: url.path,
                filename: name, ext: (name as NSString).pathExtension.lowercased(),
                fileSize: Int64(bytes), mtime: 0))
    }

    private func runner(verifier: StubVerifier = StubVerifier()) -> BatchRunner {
        BatchRunner(store: store, transcoder: StubTranscoder(), verifier: verifier)
    }

    func testAlongsideFlattenHappyPath() async throws {
        let id = try await makeRaw("a.cr3")
        let plan = FlattenPlan(
            imageIDs: [id], settings: EncodeSettings(format: .heic),
            originalsPolicy: .keepAlongside)

        let result = try await runner().run(plan: plan, batchID: "b1")
        XCTAssertEqual(result.completed, 1)
        XCTAssertEqual(result.failed.count, 0)
        XCTAssertEqual(result.bytesIn, 100)
        XCTAssertEqual(result.bytesOut, 54)

        let output = dir.appendingPathComponent("photos/a.heic")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("photos/a.cr3").path),
            "alongside keeps the original")

        let state = try await store.imageState(imageID: id)
        XCTAssertEqual(state, "flattened")

        let journal = try await store.fetchJournal(batchID: "b1")
        let kinds = journal.map(\.kind)
        XCTAssertEqual(
            kinds, ["batch_started", "output_committed", "batch_finished"])
    }

    func testVerifyFailureLeavesOriginalAndNoOutput() async throws {
        let id = try await makeRaw("b.nef")
        let plan = FlattenPlan(
            imageIDs: [id], settings: EncodeSettings(format: .heic),
            originalsPolicy: .archive(to: dir.appendingPathComponent("cold").path))

        let result = try await runner(verifier: StubVerifier(failEverything: true))
            .run(plan: plan, batchID: "b2")
        XCTAssertEqual(result.completed, 0)
        XCTAssertEqual(result.failed.count, 1)
        XCTAssertTrue(result.failed[0].reason.contains("original untouched"))

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("photos/b.nef").path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("photos/b.heic").path))
        let state = try await store.imageState(imageID: id)
        XCTAssertEqual(state, "present")
    }

    func testArchiveMovesOriginalAndRestoreBringsItBack() async throws {
        let id = try await makeRaw("c.arw")
        let archiveRoot = dir.appendingPathComponent("cold").path
        let plan = FlattenPlan(
            imageIDs: [id], settings: EncodeSettings(format: .heic),
            originalsPolicy: .archive(to: archiveRoot))

        let result = try await runner().run(plan: plan, batchID: "b3")
        XCTAssertEqual(result.completed, 1)

        let originalPath = dir.appendingPathComponent("photos/c.arw").path
        let archivedPath = archiveRoot + "/photos/c.arw"
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalPath))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: archivedPath), "mirrored structure")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("photos/c.heic").path))

        // Restore reverses the archive rung completely.
        let restore = try await Journal(store: store).restore(batchID: "b3")
        XCTAssertEqual(restore.originalsRestored, 1)
        XCTAssertEqual(restore.errors, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archivedPath))
        let state = try await store.imageState(imageID: id)
        XCTAssertEqual(state, "present")
    }

    func testDryRunTouchesNothing() async throws {
        let id = try await makeRaw("d.raf")
        let plan = FlattenPlan(
            imageIDs: [id], settings: EncodeSettings(format: .heic),
            originalsPolicy: .dryRun)

        let result = try await runner().run(plan: plan, batchID: "b4")
        XCTAssertEqual(result.completed, 1)
        XCTAssertEqual(result.bytesIn, 100)
        XCTAssertEqual(result.bytesOut, 0)

        let contents = try FileManager.default.contentsOfDirectory(
            atPath: dir.appendingPathComponent("photos").path)
        XCTAssertEqual(contents.sorted(), ["d.raf"], "no outputs, no temp files")
        let state = try await store.imageState(imageID: id)
        XCTAssertEqual(state, "present")
    }

    func testPerItemFailureDoesNotAbortBatch() async throws {
        let good = try await makeRaw("e.cr3")
        let bad = try await makeRaw("poison.cr3")
        let alsoGood = try await makeRaw("f.cr3")
        let plan = FlattenPlan(
            imageIDs: [good, bad, alsoGood], settings: EncodeSettings(format: .heic),
            originalsPolicy: .keepAlongside)

        let result = try await runner().run(plan: plan, batchID: "b5")
        XCTAssertEqual(result.completed, 2)
        XCTAssertEqual(result.failed.count, 1)
        XCTAssertEqual(result.failed[0].imageID, bad)

        let journal = try await store.fetchJournal(batchID: "b5")
        XCTAssertTrue(journal.contains { $0.kind == "item_failed" })
    }

    func testRerunSkipsAlreadyFlattened() async throws {
        let id = try await makeRaw("g.cr3")
        let plan = FlattenPlan(
            imageIDs: [id], settings: EncodeSettings(format: .heic),
            originalsPolicy: .keepAlongside)

        let first = try await runner().run(plan: plan, batchID: "b6")
        XCTAssertEqual(first.completed, 1)
        let second = try await runner().run(plan: plan, batchID: "b7")
        XCTAssertEqual(second.completed, 0)
        XCTAssertEqual(second.skipped, 1)
    }
}
