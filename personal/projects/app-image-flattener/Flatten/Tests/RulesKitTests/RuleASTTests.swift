import Foundation
import XCTest

@testable import RulesKit

final class RuleASTTests: XCTestCase {
    func testPresetJSONRoundTrip() throws {
        // "Unrated ∧ not picked ∧ older than 6 months" — the primary use case.
        let preset: RuleNode = .all([
            .criterion(Criterion(field: .rating, op: .isNull, value: .none)),
            .none([
                .criterion(Criterion(field: .flag, op: .eq, value: .string("pick")))
            ]),
            .criterion(Criterion(field: .captureDate, op: .olderThanMonths, value: .int(6))),
        ])

        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(RuleNode.self, from: data)
        XCTAssertEqual(decoded, preset)
    }

    func testNestedGroupsRoundTrip() throws {
        let rule: RuleNode = .any([
            .all([
                .criterion(Criterion(field: .rating, op: .lte, value: .int(1))),
                .criterion(Criterion(field: .fileType, op: .eq, value: .string("cr3"))),
            ]),
            .criterion(Criterion(field: .flag, op: .eq, value: .string("reject"))),
        ])
        let data = try JSONEncoder().encode(rule)
        XCTAssertEqual(try JSONDecoder().decode(RuleNode.self, from: data), rule)
    }
}
