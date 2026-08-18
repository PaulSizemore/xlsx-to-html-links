import Foundation
import GRDB

/// A bound SQL parameter. Rule compilation (RulesKit) produces these so it
/// stays a pure, GRDB-free compiler; IndexStore binds them at execution.
public enum SQLArg: Sendable, Equatable {
    case int(Int64)
    case string(String)
}

public struct RuleEvaluation: Sendable, Equatable {
    public var matchedCount: Int
    public var matchedBytes: Int64
    public var totalCount: Int
    public var totalBytes: Int64

    public var protectedCount: Int { totalCount - matchedCount }
    public var protectedBytes: Int64 { totalBytes - matchedBytes }
}

extension IndexStore {
    /// Evaluate a compiled rule predicate. `whereSQL` comes from RulesKit's
    /// compiler (never user text); values arrive as bound arguments.
    public func evaluate(whereSQL: String, arguments: [SQLArg]) throws -> RuleEvaluation {
        try pool.read { db in
            let bound = StatementArguments(arguments.map(\.databaseValue))
            guard
                let matched = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) AS c, COALESCE(SUM(file_size), 0) AS b
                        FROM images WHERE \(whereSQL)
                        """,
                    arguments: bound),
                let total = try Row.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) AS c, COALESCE(SUM(file_size), 0) AS b FROM images")
            else {
                throw DatabaseError(message: "evaluation query returned no row")
            }
            return RuleEvaluation(
                matchedCount: matched["c"],
                matchedBytes: matched["b"],
                totalCount: total["c"],
                totalBytes: total["b"]
            )
        }
    }

    /// Matched image ids, for plans and sample listings.
    public func matchingImageIDs(
        whereSQL: String, arguments: [SQLArg], limit: Int? = nil
    ) throws -> [Int64] {
        try pool.read { db in
            let bound = StatementArguments(arguments.map(\.databaseValue))
            let limitClause = limit.map { " LIMIT \($0)" } ?? ""
            return try Int64.fetchAll(
                db,
                sql: "SELECT id FROM images WHERE \(whereSQL) ORDER BY id\(limitClause)",
                arguments: bound)
        }
    }

    /// Per-image pin that survives rule changes; nil clears.
    public func setOverride(imageID: Int64, action: String?) throws {
        try pool.write { db in
            if let action {
                try db.execute(
                    sql: """
                        INSERT INTO overrides (image_id, action) VALUES (?, ?)
                        ON CONFLICT(image_id) DO UPDATE SET action = excluded.action
                        """,
                    arguments: [imageID, action])
            } else {
                try db.execute(
                    sql: "DELETE FROM overrides WHERE image_id = ?", arguments: [imageID])
            }
        }
    }
}

extension SQLArg {
    var databaseValue: DatabaseValue {
        switch self {
        case .int(let value): return value.databaseValue
        case .string(let value): return value.databaseValue
        }
    }
}
