import Foundation
import XCTest

@testable import IndexStore
@testable import RulesKit

final class RuleCompilerTests: XCTestCase {
    private var dir: URL!
    private var store: IndexStore!
    /// Fixed "now" so relative-date rules are deterministic.
    private let now = Date(timeIntervalSince1970: 1_755_000_000)

    private var compiler: RuleCompiler {
        RuleCompiler(options: CompileOptions(now: now))
    }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rules-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try IndexStore(path: dir.appendingPathComponent("index.sqlite").path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// rating_records.source_id is a real foreign key; register a source row.
    private func source(_ label: String) async throws -> Int64 {
        try await store.addSource(kind: "test", path: "/test-source/\(label)", displayName: label)
    }

    @discardableResult
    private func image(
        _ name: String, size: Int64 = 100, captureTime: Int64? = nil,
        rating: Int? = nil, flag: String? = nil,
        origin: String = "lrcat"
    ) async throws -> Int64 {
        let id = try await store.upsertImage(
            ImageRecord(
                volumeUUID: "v", relPath: "/photos/\(name)", absPath: "/photos/\(name)",
                filename: name, ext: (name as NSString).pathExtension.lowercased(),
                fileSize: size, mtime: 0, captureTime: captureTime))
        if rating != nil || flag != nil {
            let sourceID = try await source(origin)
            try await store.upsertRatingRecord(
                RatingRecordRow(
                    imageID: id, sourceID: sourceID, origin: origin,
                    rating: rating, flag: flag, matchConfidence: "exact"))
        }
        return id
    }

    private func evaluate(_ rule: RuleNode, includeConflicts: Bool = false) async throws
        -> RuleEvaluation
    {
        let compiler = RuleCompiler(
            options: CompileOptions(autoProtectConflicts: !includeConflicts, now: now))
        let compiled = try compiler.compile(rule)
        return try await store.evaluate(
            whereSQL: compiled.whereSQL, arguments: compiled.arguments)
    }

    // MARK: The primary use case

    func testUnratedNotPickedOlderThanSixMonths() async throws {
        let sixMonthsAgo = Int64(now.timeIntervalSince1970) - 7 * 2_629_746
        let recent = Int64(now.timeIntervalSince1970) - 1 * 2_629_746

        try await image("old-unrated.cr3", size: 50, captureTime: sixMonthsAgo)
        try await image("old-rated.cr3", size: 60, captureTime: sixMonthsAgo, rating: 4)
        try await image("old-picked.cr3", size: 70, captureTime: sixMonthsAgo, flag: "pick")
        try await image("new-unrated.cr3", size: 80, captureTime: recent)

        let rule: RuleNode = .all([
            .criterion(Criterion(field: .rating, op: .isNull, value: .none)),
            .none([.criterion(Criterion(field: .flag, op: .eq, value: .string("pick")))]),
            .criterion(Criterion(field: .captureDate, op: .olderThanMonths, value: .int(6))),
        ])

        let result = try await evaluate(rule)
        XCTAssertEqual(result.matchedCount, 1, "only old-unrated.cr3 flattens")
        XCTAssertEqual(result.matchedBytes, 50)
        XCTAssertEqual(result.totalCount, 4)
        XCTAssertEqual(result.protectedCount, 3)
    }

    // MARK: Precedence inside SQL

    func testEffectiveRatingUsesPrecedenceInSQL() async throws {
        // Sidecar says 1, catalog says 5 → effective is 5, so "rating <= 2"
        // must NOT match. (Same image, two origins — also a conflict.)
        let id = try await image("both.cr3", rating: 5, origin: "lrcat")
        let sidecarSource = try await source("sidecar")
        try await store.upsertRatingRecord(
            RatingRecordRow(
                imageID: id, sourceID: sidecarSource, origin: "xmp_sidecar",
                rating: 1, matchConfidence: "exact"))

        let lowRated: RuleNode = .criterion(
            Criterion(field: .rating, op: .lte, value: .int(2)))
        let result = try await evaluate(lowRated, includeConflicts: true)
        XCTAssertEqual(result.matchedCount, 0, "lrcat's 5 outranks the sidecar's 1")

        let highRated: RuleNode = .criterion(
            Criterion(field: .rating, op: .gte, value: .int(4)))
        let high = try await evaluate(highRated, includeConflicts: true)
        XCTAssertEqual(high.matchedCount, 1)
    }

    // MARK: Conflict auto-protection and pins

    func testConflictedImagesAreAutoProtected() async throws {
        let id = try await image("conflicted.cr3", rating: 5, origin: "lrcat")
        let sidecarSource = try await source("sidecar")
        try await store.upsertRatingRecord(
            RatingRecordRow(
                imageID: id, sourceID: sidecarSource, origin: "xmp_sidecar",
                rating: 1, matchConfidence: "exact"))

        let matchAll: RuleNode = .all([])
        let protected = try await evaluate(matchAll)
        XCTAssertEqual(protected.matchedCount, 0, "conflicts default to protected")

        let included = try await evaluate(matchAll, includeConflicts: true)
        XCTAssertEqual(included.matchedCount, 1)
    }

    func testPinsSurviveRuleChanges() async throws {
        let matched = try await image("matched.cr3")
        let pinnedOut = try await image("pinned-protect.cr3")
        let pinnedIn = try await image("pinned-flatten.cr3", rating: 5)
        try await store.setOverride(imageID: pinnedOut, action: "protect")
        try await store.setOverride(imageID: pinnedIn, action: "flatten")
        _ = matched

        // Rule matches only unrated images; pins override in both directions.
        let unrated: RuleNode = .criterion(
            Criterion(field: .rating, op: .isNull, value: .none))
        let result = try await evaluate(unrated)
        XCTAssertEqual(
            result.matchedCount, 2, "matched.cr3 plus pinned-flatten; pinned-protect excluded")

        // Clearing the protect pin brings the image back under the rule.
        try await store.setOverride(imageID: pinnedOut, action: nil)
        let after = try await evaluate(unrated)
        XCTAssertEqual(after.matchedCount, 3)
    }

    // MARK: Assorted criteria

    func testFileTypeAndSizeAndPath() async throws {
        try await image("a.cr3", size: 10)
        try await image("b.nef", size: 500)

        let cr3: RuleNode = .criterion(
            Criterion(field: .fileType, op: .eq, value: .string("CR3")))
        let cr3Result = try await evaluate(cr3)
        XCTAssertEqual(cr3Result.matchedCount, 1, "case-insensitive ext match")

        let big: RuleNode = .criterion(
            Criterion(field: .fileSize, op: .gte, value: .int(100)))
        let bigResult = try await evaluate(big)
        XCTAssertEqual(bigResult.matchedCount, 1)

        let pathRule: RuleNode = .criterion(
            Criterion(field: .path, op: .contains, value: .string("/photos/")))
        let pathResult = try await evaluate(pathRule)
        XCTAssertEqual(pathResult.matchedCount, 2)
    }

    func testUnsupportedCombinationsThrow() {
        XCTAssertThrowsError(
            try compiler.compile(
                .criterion(Criterion(field: .rating, op: .contains, value: .string("x")))))
        XCTAssertThrowsError(
            try compiler.compile(
                .criterion(Criterion(field: .megapixels, op: .gte, value: .int(20)))))
    }

    func testEmptyGroupSemantics() async throws {
        try await image("only.cr3")
        let all = try await evaluate(.all([]))
        XCTAssertEqual(all.matchedCount, 1, "empty ALL matches everything")
        let any = try await evaluate(.any([]))
        XCTAssertEqual(any.matchedCount, 0, "empty ANY matches nothing")
    }
}
