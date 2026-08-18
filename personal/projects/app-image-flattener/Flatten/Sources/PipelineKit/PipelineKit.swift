import Foundation
import IndexStore
import JournalKit
import RenderKit

/// The Safety Ladder (SPEC §3.2). Trash and delete rungs are deliberately
/// unimplemented until Phase 7 — the engine earns them.
public enum OriginalsPolicy: Codable, Sendable, Equatable {
    case dryRun
    case keepAlongside
    case archive(to: String)
}

/// Frozen once confirmed; rule changes afterwards don't shift the ground
/// under a running batch.
public struct FlattenPlan: Codable, Sendable {
    public var imageIDs: [Int64]
    public var settings: EncodeSettings
    public var originalsPolicy: OriginalsPolicy
    /// nil → outputs land next to their originals.
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

public struct BatchResult: Sendable {
    public var completed = 0
    public var skipped = 0
    public var failed: [(imageID: Int64, reason: String)] = []
    public var bytesIn: Int64 = 0
    public var bytesOut: Int64 = 0
}

/// Runs a confirmed plan with the crash-safe ordering of §4.5:
/// encode to temp → fsync (transcoder) → verify → atomic rename → journal
/// committed → finalize original → journal finalized. An original is never
/// touched before its output is verified and committed; per-item failures
/// never abort the batch; already-flattened items are skipped on re-run.
public actor BatchRunner {
    private let store: IndexStore
    private let transcoder: any Transcoding
    private let verifier: any OutputVerifying
    private let journal: Journal

    public init(
        store: IndexStore, transcoder: any Transcoding, verifier: any OutputVerifying
    ) {
        self.store = store
        self.transcoder = transcoder
        self.verifier = verifier
        self.journal = Journal(store: store)
    }

    public func run(plan: FlattenPlan, batchID: String) async throws -> BatchResult {
        var result = BatchResult()
        try await journal.record(
            batchID: batchID, kind: .batchStarted,
            detail: "\(plan.imageIDs.count) items, \(plan.settings.format.rawValue)")

        for imageID in plan.imageIDs {
            do {
                let outcome = try await processItem(imageID: imageID, plan: plan, batchID: batchID)
                switch outcome {
                case .completed(let bytesIn, let bytesOut):
                    result.completed += 1
                    result.bytesIn += bytesIn
                    result.bytesOut += bytesOut
                case .skipped:
                    result.skipped += 1
                }
            } catch {
                result.failed.append((imageID, "\(error)"))
                try await journal.record(
                    batchID: batchID, imageID: imageID, kind: .itemFailed,
                    detail: "\(error)")
            }
        }

        try await journal.record(
            batchID: batchID, kind: .batchFinished,
            detail: "completed=\(result.completed) skipped=\(result.skipped) "
                + "failed=\(result.failed.count)")
        return result
    }

    private enum ItemOutcome {
        case completed(bytesIn: Int64, bytesOut: Int64)
        case skipped
    }

    private func processItem(
        imageID: Int64, plan: FlattenPlan, batchID: String
    ) async throws -> ItemOutcome {
        guard let image = try await store.fetchImageByID(imageID) else {
            throw TranscodeError("image \(imageID) not in index")
        }
        guard image.state == "present" else {
            return .skipped  // flattened by an earlier run, or offline
        }
        guard let sourcePath = image.absPath else {
            throw TranscodeError("image \(imageID) has no absolute path")
        }
        let sourceURL = URL(fileURLWithPath: sourcePath)

        if case .dryRun = plan.originalsPolicy {
            return .completed(bytesIn: image.fileSize, bytesOut: 0)
        }

        // Output path: alongside the original (same basename, new extension,
        // LR-relink-friendly) or mirrored under destinationRoot.
        let outputURL = Self.outputURL(for: image, plan: plan)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Encode to a temp file in the destination directory (same volume →
        // atomic rename), verify, then commit.
        let tempURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).flatten-tmp")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let transcodeResult: TranscodeResult
        do {
            transcodeResult = try transcoder.transcode(
                source: sourceURL, destination: tempURL, settings: plan.settings)
            try verifier.verify(output: tempURL, expected: transcodeResult)
        } catch {
            throw TranscodeError("original untouched: \(error)")
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: outputURL)
        try await journal.record(
            batchID: batchID, imageID: imageID, kind: .outputCommitted,
            srcPath: sourcePath, dstPath: outputURL.path,
            detail: "\(transcodeResult.outputBytes) bytes")

        // Only now, with a verified committed output, touch the original.
        switch plan.originalsPolicy {
        case .dryRun:
            break
        case .keepAlongside:
            break
        case .archive(let archiveRoot):
            let archiveURL = URL(fileURLWithPath: archiveRoot)
                .appendingPathComponent(Self.mirrorPath(for: image))
            try FileManager.default.createDirectory(
                at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: sourceURL, to: archiveURL)
            try await journal.record(
                batchID: batchID, imageID: imageID, kind: .originalArchived,
                srcPath: sourcePath, dstPath: archiveURL.path)
        }

        try await store.markFlattened(imageID: imageID, outputPath: outputURL.path)
        return .completed(bytesIn: image.fileSize, bytesOut: transcodeResult.outputBytes)
    }

    static func outputURL(for image: ImageRecord, plan: FlattenPlan) -> URL {
        let filename =
            (image.filename as NSString).deletingPathExtension + "."
            + plan.settings.format.fileExtension
        if let root = plan.destinationRoot {
            return URL(fileURLWithPath: root)
                .appendingPathComponent(
                    (Self.mirrorPath(for: image) as NSString).deletingLastPathComponent)
                .appendingPathComponent(filename)
        }
        let sourceDir = URL(fileURLWithPath: image.absPath ?? image.relPath)
            .deletingLastPathComponent()
        return sourceDir.appendingPathComponent(filename)
    }

    /// Volume-relative mirror path used for archive and destination trees.
    static func mirrorPath(for image: ImageRecord) -> String {
        let rel = image.relPath.hasPrefix("/") ? String(image.relPath.dropFirst()) : image.relPath
        return rel
    }
}
