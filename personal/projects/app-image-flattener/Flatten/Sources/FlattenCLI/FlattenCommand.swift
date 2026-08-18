import ArgumentParser
import CatalogKit
import Foundation
import IndexStore
import RulesKit
import ScanKit

@main
struct FlattenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "flatten-cli",
        abstract: "Headless harness for the Flatten engine.",
        subcommands: [Scan.self, Ingest.self, Query.self, Plan.self, Run.self]
    )
}

struct WorkspaceOptions: ParsableArguments {
    @Option(
        name: .long,
        help: "Workspace directory holding the index database and thumbnail cache.")
    var workspace: String = ".flatten-workspace"

    func openStore() throws -> (store: IndexStore, thumbnails: ThumbnailCache) {
        let workspaceURL = URL(fileURLWithPath: workspace, isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaceURL, withIntermediateDirectories: true)
        let store = try IndexStore(
            path: workspaceURL.appendingPathComponent("index.sqlite").path)
        let thumbnails = try ThumbnailCache(
            directory: workspaceURL.appendingPathComponent("thumbs", isDirectory: true))
        return (store, thumbnails)
    }
}

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan a folder tree for RAW images and index them.")

    @OptionGroup var options: WorkspaceOptions

    @Argument(help: "Folder to scan recursively.")
    var path: String

    mutating func run() async throws {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ValidationError("Not a directory: \(root.path)")
        }

        let (store, thumbnails) = try options.openStore()
        let sourceID = try await store.addSource(
            kind: "folder", path: root.path, displayName: root.lastPathComponent)

        #if canImport(ImageIO)
        let exif: any ExifFastPathReading = ImageIOExifReader()
        #else
        let exif: any ExifFastPathReading = NullExifReader()
        print("warning: ImageIO unavailable on this platform; EXIF fields and thumbnails skipped")
        #endif

        print("Scanning \(root.path) …")
        let scanner = ImageScanner(store: store, exif: exif, thumbnails: thumbnails)
        let summary = try await scanner.scan(root: root, sourceID: sourceID)

        let indexedCount = try await store.imageCount()
        let indexedBytes = try await store.totalImageBytes()

        print("")
        print("Files seen:          \(summary.filesSeen)")
        print("RAW images indexed:  \(summary.logicalImages)")
        print("RAW+JPEG pairs:      \(summary.rawJpegPairs)")
        print("XMP sidecars:        \(summary.sidecars)")
        print("Thumbnails cached:   \(summary.thumbnailsCached)")
        print("RAW bytes this scan: \(Self.formatBytes(summary.totalRawBytes))")
        print("Workspace total:     \(indexedCount) images, \(Self.formatBytes(indexedBytes))")
        if !summary.errors.isEmpty {
            print("Errors (\(summary.errors.count)):")
            for line in summary.errors.prefix(20) {
                print("  \(line)")
            }
        }
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct Ingest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: """
            Ingest ratings into the index: from a .lrcat catalog, or from the \
            XMP sidecars discovered during scan when given a folder.
            """)

    @OptionGroup var options: WorkspaceOptions

    @Argument(help: "Path to a .lrcat file, or a scanned folder (ingests its XMP sidecars).")
    var catalog: String

    mutating func run() async throws {
        let (store, _) = try options.openStore()
        let url = URL(fileURLWithPath: catalog)

        if url.pathExtension.lowercased() == "lrcat" {
            let sourceID = try await store.addSource(
                kind: "lrcat", path: url.path, displayName: url.lastPathComponent)
            print("Ingesting Lightroom catalog \(url.lastPathComponent) …")
            let report = try await LrcatIngestor(store: store)
                .ingest(catalogPath: url.path, sourceID: sourceID)

            print("")
            print("Schema version:     \(report.schemaVersion ?? "unknown")")
            if let caps = report.capabilities {
                print(
                    "Capabilities:       keywords=\(caps.hasKeywords) "
                        + "collections=\(caps.hasCollections) "
                        + "develop-history=\(caps.hasDevelopHistory)")
            }
            print("Catalog entries:    \(report.catalogEntries)")
            print("Matched (exact):    \(report.matchedExact)")
            print("Matched (relinked): \(report.matchedRelinked)")
            print("Unmatched:          \(report.unmatched)")
            if !report.unmatchedSamples.isEmpty {
                print("Unmatched samples:")
                for path in report.unmatchedSamples {
                    print("  \(path)")
                }
            }
            print("Claims written:     \(report.recordsWritten)")
        } else {
            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                throw ValidationError("Expected a .lrcat file or a directory: \(url.path)")
            }
            let sourceID = try await store.addSource(
                kind: "folder", path: url.path, displayName: url.lastPathComponent)
            print("Ingesting XMP sidecars under \(url.path) …")
            let report = try await SidecarIngestor(store: store)
                .ingest(sourceID: sourceID, under: url.standardizedFileURL.path)

            print("")
            print("Sidecars read:  \(report.sidecarsRead)")
            print("Claims written: \(report.recordsWritten)")
            for line in report.errors.prefix(20) {
                print("  error: \(line)")
            }
        }

        let unknown = try await store.unknownToCatalogsCount()
        let total = try await store.imageCount()
        print("On disk but unknown to any catalog: \(unknown) of \(total) indexed images")
    }
}

struct Query: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Evaluate a rules JSON file (RuleNode AST) against the index.")

    @OptionGroup var options: WorkspaceOptions

    @Argument(help: "Path to a rules JSON file (RuleNode AST).")
    var rules: String

    @ArgumentParser.Flag(
        help: "Include images whose catalogs disagree (normally auto-protected).")
    var includeConflicts = false

    @Option(help: "Print up to N matching image paths.")
    var samples: Int = 0

    mutating func run() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: rules))
        let rule = try JSONDecoder().decode(RuleNode.self, from: data)

        let compiler = RuleCompiler(
            options: CompileOptions(autoProtectConflicts: !includeConflicts, now: Date()))
        let compiled = try compiler.compile(rule)

        let (store, _) = try options.openStore()
        let evaluation = try await store.evaluate(
            whereSQL: compiled.whereSQL, arguments: compiled.arguments)

        print("Matched:   \(evaluation.matchedCount) images · \(Scan.formatBytes(evaluation.matchedBytes))")
        print("Protected: \(evaluation.protectedCount) images · \(Scan.formatBytes(evaluation.protectedBytes))")
        print("Total:     \(evaluation.totalCount) images · \(Scan.formatBytes(evaluation.totalBytes))")

        if samples > 0 {
            let ids = try await store.matchingImageIDs(
                whereSQL: compiled.whereSQL, arguments: compiled.arguments, limit: samples)
            for id in ids {
                if let image = try await store.fetchImageByID(id) {
                    print("  \(image.absPath ?? image.relPath)")
                }
            }
        }
    }
}

struct Plan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Freeze a flatten plan from rules and settings.")

    @OptionGroup var options: WorkspaceOptions

    @Argument(help: "Path to a rules JSON file (RuleNode AST).")
    var rules: String

    @Option(help: "Output format: heic or jpeg.")
    var format: String = "heic"

    @Option(help: "Encode quality 0.0–1.0.")
    var quality: Double = 0.8

    @Option(help: "Originals policy: dry-run, alongside, or archive:<path>.")
    var originals: String = "dry-run"

    @Option(help: "Write outputs under this root instead of next to originals.")
    var destination: String?

    mutating func run() async throws {
        guard let outputFormat = OutputFormat(rawValue: format),
            outputFormat == .heic || outputFormat == .jpeg
        else {
            throw ValidationError("format must be heic or jpeg (others land in Phase 6)")
        }
        let policy: OriginalsPolicy
        switch originals {
        case "dry-run": policy = .dryRun
        case "alongside": policy = .keepAlongside
        default:
            guard originals.hasPrefix("archive:") else {
                throw ValidationError("originals must be dry-run, alongside, or archive:<path>")
            }
            policy = .archive(to: String(originals.dropFirst("archive:".count)))
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: rules))
        let rule = try JSONDecoder().decode(RuleNode.self, from: data)
        let compiled = try RuleCompiler(options: CompileOptions(now: Date())).compile(rule)

        let (store, _) = try options.openStore()
        let ids = try await store.matchingImageIDs(
            whereSQL: compiled.whereSQL, arguments: compiled.arguments)
        let evaluation = try await store.evaluate(
            whereSQL: compiled.whereSQL, arguments: compiled.arguments)

        let plan = FlattenPlan(
            imageIDs: ids,
            settings: EncodeSettings(format: outputFormat, quality: quality),
            originalsPolicy: policy,
            destinationRoot: destination)

        let plansDir = URL(fileURLWithPath: options.workspace, isDirectory: true)
            .appendingPathComponent("plans", isDirectory: true)
        try FileManager.default.createDirectory(at: plansDir, withIntermediateDirectories: true)
        let planID = "plan-\(Int(Date().timeIntervalSince1970))"
        let planURL = plansDir.appendingPathComponent("\(planID).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(plan).write(to: planURL)

        print("Plan frozen: \(planURL.path)")
        print("Images:      \(ids.count)")
        print("Input bytes: \(Scan.formatBytes(evaluation.matchedBytes))")
        print("Originals:   \(originals)")
        print("Run it with: flatten-cli run \(planURL.path) --workspace \(options.workspace)")
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Execute a frozen flatten plan.")

    @OptionGroup var options: WorkspaceOptions

    @Argument(help: "Path to a plan JSON file produced by `plan`.")
    var plan: String

    mutating func run() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: plan))
        let flattenPlan = try JSONDecoder().decode(FlattenPlan.self, from: data)
        let (store, _) = try options.openStore()

        #if canImport(ImageIO)
        let transcoder: any Transcoding = ImageIOTranscoder()
        let verifier: any OutputVerifying = ImageIOVerifier()
        #else
        let transcoder: any Transcoding = UnavailableTranscoder()
        struct NoVerifier: OutputVerifying {
            func verify(output: URL, expected: TranscodeResult) throws {}
        }
        let verifier: any OutputVerifying = NoVerifier()
        #endif

        let batchID = "batch-\(Int(Date().timeIntervalSince1970))"
        let runner = BatchRunner(store: store, transcoder: transcoder, verifier: verifier)
        print("Running \(flattenPlan.imageIDs.count) items as \(batchID) …")
        let result = try await runner.run(plan: flattenPlan, batchID: batchID)

        print("")
        print("Completed: \(result.completed)")
        print("Skipped:   \(result.skipped)")
        print("Failed:    \(result.failed.count)")
        for failure in result.failed.prefix(20) {
            print("  image \(failure.imageID): \(failure.reason)")
        }
        if case .dryRun = flattenPlan.originalsPolicy {
            print("Dry run — nothing was written.")
        } else {
            print("In:  \(Scan.formatBytes(result.bytesIn))")
            print("Out: \(Scan.formatBytes(result.bytesOut))")
            print("Reclaimable: \(Scan.formatBytes(result.bytesIn - result.bytesOut))")
        }
        print("Journal batch id: \(batchID)")
    }
}
