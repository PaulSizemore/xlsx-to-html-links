import Foundation
import RenderKit

// Phase 3 module. Plan types only in Phase 0.

/// The Safety Ladder (SPEC.md §3.2). Trash and delete rungs are not
/// implemented until Phase 7, by design.
public enum OriginalsPolicy: Codable, Sendable, Equatable {
    case dryRun
    case keepAlongside
    case archive(to: String)
    case trash
    case delete
}

/// Frozen once the user confirms the Plan sheet; rule changes afterwards
/// don't shift the ground under a running batch.
public struct FlattenPlan: Codable, Sendable {
    public var imageIDs: [Int64]
    public var settings: EncodeSettings
    public var originalsPolicy: OriginalsPolicy
    public var destinationRoot: String?

    public init(
        imageIDs: [Int64],
        settings: EncodeSettings,
        originalsPolicy: OriginalsPolicy,
        destinationRoot: String? = nil
    ) {
        self.imageIDs = imageIDs
        self.settings = settings
        self.originalsPolicy = originalsPolicy
        self.destinationRoot = destinationRoot
    }
}
