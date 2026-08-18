import ArgumentParser
import Foundation
import IndexStore
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
        abstract: "Ingest ratings from a catalog (.lrcat) or XMP sidecars. [Phase 1]")

    @OptionGroup var options: WorkspaceOptions

    @Argument(help: "Path to a .lrcat file or a folder of XMP sidecars.")
    var catalog: String

    mutating func run() async throws {
        print("ingest: not implemented until Phase 1 (catalog ingestion & the join)")
        throw ExitCode(64)
    }
}

struct Query: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Evaluate a rules JSON file against the index. [Phase 2]")

    @OptionGroup var options: WorkspaceOptions

    @Argument(help: "Path to a rules JSON file (RuleNode AST).")
    var rules: String

    mutating func run() async throws {
        print("query: not implemented until Phase 2 (rules engine)")
        throw ExitCode(64)
    }
}

struct Plan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build a flatten plan from rules and settings. [Phase 2]")

    @OptionGroup var options: WorkspaceOptions

    mutating func run() async throws {
        print("plan: not implemented until Phase 2 (dry-run economics)")
        throw ExitCode(64)
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Execute a confirmed flatten plan. [Phase 3]")

    @OptionGroup var options: WorkspaceOptions

    mutating func run() async throws {
        print("run: not implemented until Phase 3 (pipeline)")
        throw ExitCode(64)
    }
}
