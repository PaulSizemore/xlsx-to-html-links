import Foundation
import IndexStore

/// Journal entry kinds, in the order the finalize protocol emits them.
public enum JournalKind: String, Codable, Sendable {
    case batchStarted = "batch_started"
    case outputCommitted = "output_committed"
    case originalArchived = "original_archived"
    case originalTrashed = "original_trashed"
    case originalDeleted = "original_deleted"
    case itemFailed = "item_failed"
    case batchFinished = "batch_finished"
}

/// Batch-level journal operations: recording and reversing.
public struct Journal: Sendable {
    let store: IndexStore

    public init(store: IndexStore) {
        self.store = store
    }

    public func record(
        batchID: String, imageID: Int64? = nil, kind: JournalKind,
        srcPath: String? = nil, dstPath: String? = nil, detail: String? = nil
    ) async throws {
        try await store.appendJournal(
            JournalEntry(
                batchID: batchID, imageID: imageID, kind: kind.rawValue,
                srcPath: srcPath, dstPath: dstPath, detail: detail,
                createdAt: Int64(Date().timeIntervalSince1970)))
    }

    public struct RestoreReport: Sendable {
        public var originalsRestored = 0
        public var errors: [String] = []
    }

    /// Reverse an archive-rung batch: move originals back to their recorded
    /// locations and mark them present again. Flattened outputs are left in
    /// place (they are additive); the report says what happened.
    public func restore(batchID: String) async throws -> RestoreReport {
        var report = RestoreReport()
        let entries = try await store.fetchJournal(batchID: batchID)

        for entry in entries where entry.kind == JournalKind.originalArchived.rawValue {
            guard let archivedPath = entry.dstPath, let originalPath = entry.srcPath else {
                continue
            }
            do {
                guard FileManager.default.fileExists(atPath: archivedPath) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: originalPath).deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try FileManager.default.moveItem(
                    at: URL(fileURLWithPath: archivedPath),
                    to: URL(fileURLWithPath: originalPath))
                if let imageID = entry.imageID {
                    try await store.markPresent(imageID: imageID)
                }
                report.originalsRestored += 1
            } catch {
                report.errors.append("\(archivedPath): \(error)")
            }
        }
        return report
    }
}
