import Foundation
import IndexStore

public struct CompiledRule: Sendable {
    /// WHERE-clause predicate over the `images` table (aliased as `images`).
    public let whereSQL: String
    public let arguments: [SQLArg]
}

public struct RuleCompileError: Error, CustomStringConvertible {
    public let description: String
}

public struct CompileOptions: Sendable {
    /// Rating-origin precedence, highest first. Only known origins are
    /// accepted (values are inlined into SQL, so this is a closed set).
    public var precedence: [String]
    /// Images whose sources disagree on rating/flag are excluded from any
    /// match — the "conflicted images are auto-protected" default (§3.1).
    public var autoProtectConflicts: Bool
    /// "Now" for relative-date criteria; injected for testability.
    public var now: Date

    public init(
        precedence: [String] = ["lrcat", "xmp_sidecar", "c1", "embedded_xmp"],
        autoProtectConflicts: Bool = true,
        now: Date
    ) {
        self.precedence = precedence
        self.autoProtectConflicts = autoProtectConflicts
        self.now = now
    }

    static let knownOrigins: Set<String> = ["lrcat", "xmp_sidecar", "c1", "embedded_xmp"]
}

/// Compiles a RuleNode AST into one SQL predicate over
/// images ⋈ rating_records ⋈ overrides. The filter engine is SQLite, not
/// Swift loops — that is how the <100 ms @ 100k target is met (§4.3).
public struct RuleCompiler: Sendable {
    let options: CompileOptions

    public init(options: CompileOptions) {
        self.options = options
    }

    /// The full match predicate: (rule ∧ not conflicted ∧ not pinned-protect)
    /// ∨ pinned-flatten. Pins survive rule changes by construction.
    public func compile(_ rule: RuleNode) throws -> CompiledRule {
        var (sql, args) = try compileNode(rule)
        if options.autoProtectConflicts {
            sql = "(\(sql)) AND NOT \(Self.conflictSQL)"
        }
        let protectPin =
            "EXISTS (SELECT 1 FROM overrides o WHERE o.image_id = images.id AND o.action = 'protect')"
        let flattenPin =
            "EXISTS (SELECT 1 FROM overrides o WHERE o.image_id = images.id AND o.action = 'flatten')"
        return CompiledRule(
            whereSQL: "(((\(sql)) AND NOT \(protectPin)) OR \(flattenPin))",
            arguments: args
        )
    }

    /// The bare rule predicate without conflict/pin handling (for previews
    /// and tests).
    public func compileBare(_ rule: RuleNode) throws -> CompiledRule {
        let (sql, args) = try compileNode(rule)
        return CompiledRule(whereSQL: sql, arguments: args)
    }

    // MARK: Groups

    private func compileNode(_ node: RuleNode) throws -> (String, [SQLArg]) {
        switch node {
        case .all(let children):
            return try compileGroup(children, joiner: " AND ", empty: "1")
        case .any(let children):
            return try compileGroup(children, joiner: " OR ", empty: "0")
        case .none(let children):
            let (sql, args) = try compileGroup(children, joiner: " OR ", empty: "0")
            return ("NOT (\(sql))", args)
        case .criterion(let criterion):
            return try compileCriterion(criterion)
        }
    }

    private func compileGroup(
        _ children: [RuleNode], joiner: String, empty: String
    ) throws -> (String, [SQLArg]) {
        guard !children.isEmpty else { return (empty, []) }
        var parts: [String] = []
        var args: [SQLArg] = []
        for child in children {
            let (sql, childArgs) = try compileNode(child)
            parts.append("(\(sql))")
            args.append(contentsOf: childArgs)
        }
        return (parts.joined(separator: joiner), args)
    }

    // MARK: Effective-rating scalar subqueries

    private var precedenceCase: String {
        let known = options.precedence.filter { CompileOptions.knownOrigins.contains($0) }
        let whens = known.enumerated()
            .map { "WHEN '\($1)' THEN \($0)" }
            .joined(separator: " ")
        return "CASE r.origin \(whens) ELSE 99 END"
    }

    private func effective(_ column: String) -> String {
        """
        (SELECT r.\(column) FROM rating_records r \
        WHERE r.image_id = images.id AND r.\(column) IS NOT NULL \
        ORDER BY \(precedenceCase) LIMIT 1)
        """
    }

    static let conflictSQL = """
        ((SELECT COUNT(DISTINCT r.rating) FROM rating_records r \
        WHERE r.image_id = images.id AND r.rating IS NOT NULL) > 1 \
        OR (SELECT COUNT(DISTINCT r.flag) FROM rating_records r \
        WHERE r.image_id = images.id AND r.flag IS NOT NULL) > 1)
        """

    // MARK: Criteria

    private func compileCriterion(_ criterion: Criterion) throws -> (String, [SQLArg]) {
        let field = criterion.field
        let op = criterion.op

        switch field {
        case .rating:
            return try nullableComparable(effective("rating"), criterion, argName: "rating")

        case .flag:
            return try nullableEquatable(effective("flag"), criterion, argName: "flag")

        case .colorLabel:
            return try nullableEquatable(effective("color_label"), criterion, argName: "colorLabel")

        case .hasDevelopEdits:
            guard op == .eq, case .bool(let wanted) = criterion.value else {
                throw RuleCompileError(description: "hasDevelopEdits supports eq with a bool")
            }
            let sql = "COALESCE(\(effective("has_develop_edits")), 0) = ?"
            return (sql, [.int(wanted ? 1 : 0)])

        case .keyword, .collection:
            let column = field == .keyword ? "keywords" : "collections"
            guard case .string(let value) = criterion.value else {
                throw RuleCompileError(description: "\(field.rawValue) requires a string value")
            }
            let exists = """
                EXISTS (SELECT 1 FROM rating_records r \
                WHERE r.image_id = images.id AND r.\(column) LIKE '%' || ? || '%')
                """
            switch op {
            case .contains: return (exists, [.string(value)])
            case .notContains: return ("NOT \(exists)", [.string(value)])
            default:
                throw RuleCompileError(
                    description: "\(field.rawValue) supports contains/notContains")
            }

        case .captureDate, .fileDate:
            let column = field == .captureDate ? "images.capture_time" : "images.mtime"
            switch (op, criterion.value) {
            case (.before, .date(let date)):
                return ("\(column) < ?", [.int(Int64(date.timeIntervalSince1970))])
            case (.after, .date(let date)):
                return ("\(column) > ?", [.int(Int64(date.timeIntervalSince1970))])
            case (.olderThanMonths, .int(let months)):
                // Mean Gregorian month; relative-date rules are approximate by
                // nature. Unknown capture time never matches "older than".
                let cutoff = Int64(options.now.timeIntervalSince1970) - months * 2_629_746
                return ("\(column) < ?", [.int(cutoff)])
            case (.isNull, _):
                return ("\(column) IS NULL", [])
            case (.isNotNull, _):
                return ("\(column) IS NOT NULL", [])
            default:
                throw RuleCompileError(
                    description:
                        "\(field.rawValue) supports before/after dates, olderThanMonths, isNull")
            }

        case .cameraModel, .lens:
            let column = field == .cameraModel ? "images.camera_model" : "images.lens"
            guard case .string(let value) = criterion.value else {
                throw RuleCompileError(description: "\(field.rawValue) requires a string value")
            }
            switch op {
            case .eq: return ("\(column) = ? COLLATE NOCASE", [.string(value)])
            case .ne: return ("\(column) <> ? COLLATE NOCASE", [.string(value)])
            case .contains:
                return ("\(column) LIKE '%' || ? || '%'", [.string(value)])
            default:
                throw RuleCompileError(description: "\(field.rawValue) supports eq/ne/contains")
            }

        case .fileType:
            guard case .string(let value) = criterion.value else {
                throw RuleCompileError(description: "fileType requires a string value")
            }
            switch op {
            case .eq: return ("images.ext = ? COLLATE NOCASE", [.string(value)])
            case .ne: return ("images.ext <> ? COLLATE NOCASE", [.string(value)])
            default:
                throw RuleCompileError(description: "fileType supports eq/ne")
            }

        case .fileSize:
            guard case .int(let value) = criterion.value else {
                throw RuleCompileError(description: "fileSize requires an int value (bytes)")
            }
            switch op {
            case .gte: return ("images.file_size >= ?", [.int(value)])
            case .lte: return ("images.file_size <= ?", [.int(value)])
            default:
                throw RuleCompileError(description: "fileSize supports gte/lte")
            }

        case .path:
            guard case .string(let value) = criterion.value else {
                throw RuleCompileError(description: "path requires a string value")
            }
            let like = "COALESCE(images.abs_path, images.rel_path) LIKE '%' || ? || '%'"
            switch op {
            case .contains: return (like, [.string(value)])
            case .notContains: return ("NOT (\(like))", [.string(value)])
            default:
                throw RuleCompileError(description: "path supports contains/notContains")
            }

        case .isDuplicate:
            guard op == .eq, case .bool(let wanted) = criterion.value else {
                throw RuleCompileError(description: "isDuplicate supports eq with a bool")
            }
            let dupe = """
                (images.content_key IS NOT NULL AND EXISTS \
                (SELECT 1 FROM images o WHERE o.content_key = images.content_key \
                AND o.id <> images.id))
                """
            return (wanted ? dupe : "NOT \(dupe)", [])

        case .conflictingRatings:
            guard op == .eq, case .bool(let wanted) = criterion.value else {
                throw RuleCompileError(description: "conflictingRatings supports eq with a bool")
            }
            return (wanted ? Self.conflictSQL : "NOT \(Self.conflictSQL)", [])

        case .megapixels:
            throw RuleCompileError(
                description: "megapixels is unsupported until dimensions are indexed")
        }
    }

    // MARK: Shared shapes

    private func nullableComparable(
        _ expr: String, _ criterion: Criterion, argName: String
    ) throws -> (String, [SQLArg]) {
        switch (criterion.op, criterion.value) {
        case (.isNull, _): return ("\(expr) IS NULL", [])
        case (.isNotNull, _): return ("\(expr) IS NOT NULL", [])
        case (.eq, .int(let value)): return ("\(expr) = ?", [.int(value)])
        case (.ne, .int(let value)): return ("\(expr) <> ?", [.int(value)])
        case (.gte, .int(let value)): return ("\(expr) >= ?", [.int(value)])
        case (.lte, .int(let value)): return ("\(expr) <= ?", [.int(value)])
        default:
            throw RuleCompileError(
                description: "\(argName) supports eq/ne/gte/lte with an int, or isNull/isNotNull")
        }
    }

    private func nullableEquatable(
        _ expr: String, _ criterion: Criterion, argName: String
    ) throws -> (String, [SQLArg]) {
        switch (criterion.op, criterion.value) {
        case (.isNull, _): return ("\(expr) IS NULL", [])
        case (.isNotNull, _): return ("\(expr) IS NOT NULL", [])
        case (.eq, .string(let value)):
            return ("\(expr) = ? COLLATE NOCASE", [.string(value)])
        case (.ne, .string(let value)):
            // NULL never equals anything in SQL; ne should still match unrated.
            return ("(\(expr) IS NULL OR \(expr) <> ? COLLATE NOCASE)", [.string(value)])
        default:
            throw RuleCompileError(
                description: "\(argName) supports eq/ne with a string, or isNull/isNotNull")
        }
    }
}
