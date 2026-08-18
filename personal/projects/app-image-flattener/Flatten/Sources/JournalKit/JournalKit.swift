import Foundation

// Phase 3 module. Types only in Phase 0.

/// Every original-file mutation is journaled before it happens
/// (ARCHITECTURE.md §4.5 finalize ordering).
public enum JournalEntryKind: String, Codable, Sendable {
    case outputCommitted = "output_committed"
    case originalArchived = "original_archived"
    case originalTrashed = "original_trashed"
    case originalDeleted = "original_deleted"
    case batchStarted = "batch_started"
    case batchFinished = "batch_finished"
}
