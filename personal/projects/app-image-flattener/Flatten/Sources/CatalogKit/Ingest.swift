import Foundation
import IndexStore

public struct IngestReport: Sendable {
    public var schemaVersion: String?
    public var capabilities: LrcatCapabilities?
    public var catalogEntries = 0
    public var matchedExact = 0
    public var matchedRelinked = 0
    public var unmatched = 0
    public var unmatchedSamples: [String] = []
    public var recordsWritten = 0

    public init() {}
}

/// Ingests a Lightroom catalog: read → reconcile each entry → write
/// rating_records claims with origin 'lrcat'.
public struct LrcatIngestor: Sendable {
    let store: IndexStore

    public init(store: IndexStore) {
        self.store = store
    }

    public func ingest(catalogPath: String, sourceID: Int64) async throws -> IngestReport {
        let catalog = try LrcatReader(catalogPath: catalogPath).read()
        let reconciler = Reconciler(store: store)

        var report = IngestReport()
        report.schemaVersion = catalog.capabilities.schemaVersion
        report.capabilities = catalog.capabilities
        report.catalogEntries = catalog.entries.count

        for entry in catalog.entries {
            guard
                let match = try await reconciler.reconcile(
                    absolutePath: entry.absolutePath,
                    filename: entry.filename,
                    captureTime: entry.captureTime)
            else {
                report.unmatched += 1
                if report.unmatchedSamples.count < 10 {
                    report.unmatchedSamples.append(entry.absolutePath)
                }
                continue
            }

            switch match.confidence {
            case .exact: report.matchedExact += 1
            case .relinked: report.matchedRelinked += 1
            case .content: break
            }

            try await store.upsertRatingRecord(
                RatingRecordRow(
                    imageID: match.imageID,
                    sourceID: sourceID,
                    origin: RatingOrigin.lrcat.rawValue,
                    rating: entry.rating,
                    flag: entry.flag?.rawValue,
                    colorLabel: entry.colorLabel,
                    keywords: Self.jsonArray(entry.keywords),
                    collections: Self.jsonArray(entry.collections),
                    hasDevelopEdits: entry.hasDevelopEdits,
                    matchConfidence: match.confidence.rawValue
                ))
            report.recordsWritten += 1
        }
        return report
    }

    static func jsonArray(_ values: [String]) -> String? {
        guard !values.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(values) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Ingests XMP sidecars already discovered by ScanKit (images.xmp_sidecar_path),
/// writing claims with origin 'xmp_sidecar'. Sidecars join by construction —
/// they sit next to their RAW — so confidence is always exact.
public struct SidecarIngestor: Sendable {
    let store: IndexStore

    public init(store: IndexStore) {
        self.store = store
    }

    public struct Report: Sendable {
        public var sidecarsRead = 0
        public var recordsWritten = 0
        public var errors: [String] = []
    }

    /// Pass `under:` to limit to sidecars below a directory; nil ingests all.
    public func ingest(sourceID: Int64, under pathPrefix: String? = nil) async throws -> Report {
        let reader = XmpReader()
        var report = Report()

        for image in try await store.fetchImagesWithSidecars() {
            guard let sidecarPath = image.xmpSidecarPath, let imageID = image.id else { continue }
            if let pathPrefix, !sidecarPath.hasPrefix(pathPrefix) { continue }

            do {
                let metadata = try reader.read(fileURL: URL(fileURLWithPath: sidecarPath))
                report.sidecarsRead += 1

                try await store.upsertRatingRecord(
                    RatingRecordRow(
                        imageID: imageID,
                        sourceID: sourceID,
                        origin: RatingOrigin.xmpSidecar.rawValue,
                        rating: metadata.rating,
                        colorLabel: metadata.label,
                        keywords: LrcatIngestor.jsonArray(metadata.keywords),
                        matchConfidence: MatchConfidence.exact.rawValue
                    ))
                report.recordsWritten += 1
            } catch {
                report.errors.append("\(sidecarPath): \(error)")
            }
        }
        return report
    }
}

/// Reads the stored claims for an image and resolves them (§3.1).
public struct RatingStore: Sendable {
    let store: IndexStore
    let resolver: PrecedenceResolver

    public init(store: IndexStore, resolver: PrecedenceResolver = PrecedenceResolver()) {
        self.store = store
        self.resolver = resolver
    }

    public func effectiveRating(imageID: Int64) async throws -> EffectiveRating {
        let rows = try await store.fetchRatingRecords(imageID: imageID)
        let claims = rows.compactMap { row -> Claim? in
            guard let origin = RatingOrigin(rawValue: row.origin) else { return nil }
            return Claim(
                origin: origin,
                rating: row.rating,
                flag: row.flag.flatMap { Flag(rawValue: $0) },
                colorLabel: row.colorLabel,
                keywords: Self.decodeArray(row.keywords),
                collections: Self.decodeArray(row.collections)
            )
        }
        return resolver.resolve(claims)
    }

    static func decodeArray(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}
