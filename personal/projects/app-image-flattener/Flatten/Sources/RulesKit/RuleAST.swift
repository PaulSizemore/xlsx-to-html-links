import Foundation

/// The filter rule AST. Presets are serialized RuleNode JSON.
/// SQL compilation over images ⋈ effective_ratings lands in Phase 2.
public indirect enum RuleNode: Codable, Sendable, Equatable {
    case all([RuleNode])
    case any([RuleNode])
    case none([RuleNode])
    case criterion(Criterion)
}

public struct Criterion: Codable, Sendable, Equatable {
    public var field: Field
    public var op: Operator
    public var value: Value

    public init(field: Field, op: Operator, value: Value) {
        self.field = field
        self.op = op
        self.value = value
    }
}

public enum Field: String, Codable, Sendable, CaseIterable {
    case rating
    case flag
    case colorLabel
    case hasDevelopEdits
    case collection
    case keyword
    case captureDate
    case fileDate
    case cameraModel
    case lens
    case fileType
    case fileSize
    case megapixels
    case isDuplicate
    case path
    case conflictingRatings
}

public enum Operator: String, Codable, Sendable, CaseIterable {
    case eq
    case ne
    case gte
    case lte
    case contains
    case notContains
    case before
    case after
    case olderThanMonths
    case isNull
    case isNotNull
}

public enum Value: Codable, Sendable, Equatable {
    case int(Int64)
    case string(String)
    case date(Date)
    case bool(Bool)
    case none
}
