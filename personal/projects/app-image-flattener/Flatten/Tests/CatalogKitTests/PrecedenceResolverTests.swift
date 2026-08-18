import XCTest

@testable import CatalogKit

final class PrecedenceResolverTests: XCTestCase {
    let resolver = PrecedenceResolver()

    func testLrcatWinsOverSidecar() {
        let effective = resolver.resolve([
            Claim(origin: .xmpSidecar, rating: 2, keywords: ["old"]),
            Claim(origin: .lrcat, rating: 4, flag: .pick, keywords: ["wedding"]),
        ])
        XCTAssertEqual(effective.rating, 4)
        XCTAssertEqual(effective.flag, .pick)
        XCTAssertTrue(effective.conflicts, "differing ratings across sources is a conflict")
        XCTAssertEqual(effective.keywords, ["wedding", "old"], "union, precedence order first")
    }

    func testAgreementIsNotAConflict() {
        let effective = resolver.resolve([
            Claim(origin: .lrcat, rating: 3),
            Claim(origin: .xmpSidecar, rating: 3),
        ])
        XCTAssertEqual(effective.rating, 3)
        XCTAssertFalse(effective.conflicts)
    }

    func testLowerPrecedenceFillsGaps() {
        // lrcat has no color label; the sidecar's label still comes through.
        let effective = resolver.resolve([
            Claim(origin: .xmpSidecar, rating: 5, colorLabel: "red"),
            Claim(origin: .lrcat, rating: 5),
        ])
        XCTAssertEqual(effective.colorLabel, "red")
        XCTAssertFalse(effective.conflicts)
    }

    func testEmptyClaimsResolveToUnrated() {
        let effective = resolver.resolve([])
        XCTAssertNil(effective.rating)
        XCTAssertNil(effective.flag)
        XCTAssertFalse(effective.conflicts)
    }

    func testCustomOrderIsRespected() {
        let sidecarFirst = PrecedenceResolver(order: [.xmpSidecar, .lrcat, .c1, .embeddedXMP])
        let effective = sidecarFirst.resolve([
            Claim(origin: .lrcat, rating: 4),
            Claim(origin: .xmpSidecar, rating: 2),
        ])
        XCTAssertEqual(effective.rating, 2)
    }
}
