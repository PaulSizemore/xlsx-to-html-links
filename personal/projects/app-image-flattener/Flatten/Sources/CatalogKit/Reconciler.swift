import Foundation
import IndexStore

public enum MatchConfidence: String, Sendable {
    case exact
    case relinked
    case content
}

/// Matches a catalog's notion of a file to a scanned image, in strictly
/// decreasing confidence. Ambiguity yields "unmatched", never a guess
/// (ARCHITECTURE.md §3.2). Tier 3 (content) requires catalog previews and
/// lands later in Phase 1.
public struct Reconciler: Sendable {
    let store: IndexStore

    public init(store: IndexStore) {
        self.store = store
    }

    public func reconcile(absolutePath: String, filename: String, captureTime: Int64?)
        async throws -> (imageID: Int64, confidence: MatchConfidence)?
    {
        // Tier 1: exact absolute path.
        let exact = try await store.findImageIDs(absPath: absolutePath)
        if exact.count == 1 {
            return (exact[0], .exact)
        }
        if exact.count > 1 {
            return nil  // ambiguous — refuse to guess
        }

        // Tier 2: relink by filename + capture time; must be unique.
        if let captureTime {
            let candidates = try await store.findImageIDs(
                filename: filename, captureTime: captureTime)
            if candidates.count == 1 {
                return (candidates[0], .relinked)
            }
        }

        return nil
    }
}
