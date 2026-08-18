import Foundation

/// Where a rating opinion came from. Raw values match rating_records.origin.
public enum RatingOrigin: String, Codable, Sendable, CaseIterable {
    case lrcat
    case xmpSidecar = "xmp_sidecar"
    case c1
    case embeddedXMP = "embedded_xmp"
}

public enum Flag: String, Codable, Sendable {
    case pick
    case reject
}

/// One catalog's opinion about one image — a row of rating_records, resolved.
public struct Claim: Codable, Sendable, Equatable {
    public var origin: RatingOrigin
    public var rating: Int?
    public var flag: Flag?
    public var colorLabel: String?
    public var keywords: [String]
    public var collections: [String]

    public init(
        origin: RatingOrigin,
        rating: Int? = nil,
        flag: Flag? = nil,
        colorLabel: String? = nil,
        keywords: [String] = [],
        collections: [String] = []
    ) {
        self.origin = origin
        self.rating = rating
        self.flag = flag
        self.colorLabel = colorLabel
        self.keywords = keywords
        self.collections = collections
    }
}

/// The resolved, single answer the rest of the app consumes.
public struct EffectiveRating: Sendable, Equatable {
    public var rating: Int?
    public var flag: Flag?
    public var colorLabel: String?
    public var keywords: [String]
    public var collections: [String]
    public var provenance: [Claim]
    /// True when sources disagree on rating or flag. Conflicted images are
    /// auto-protected from flattening by default (ARCHITECTURE.md §3.1).
    public var conflicts: Bool
}

public struct PrecedenceResolver: Sendable {
    /// Highest priority first. Default per ARCHITECTURE.md §3.1;
    /// user-configurable per workspace.
    public var order: [RatingOrigin]

    public init(order: [RatingOrigin] = [.lrcat, .xmpSidecar, .c1, .embeddedXMP]) {
        self.order = order
    }

    public func resolve(_ claims: [Claim]) -> EffectiveRating {
        let sorted = claims.sorted { priority($0.origin) < priority($1.origin) }

        let ratings = sorted.compactMap(\.rating)
        let flags = sorted.compactMap(\.flag)
        let conflicts =
            Set(ratings).count > 1 || Set(flags).count > 1

        // Keywords and collections are unions, order-preserving by precedence.
        var keywords: [String] = []
        var collections: [String] = []
        for claim in sorted {
            for keyword in claim.keywords where !keywords.contains(keyword) {
                keywords.append(keyword)
            }
            for collection in claim.collections where !collections.contains(collection) {
                collections.append(collection)
            }
        }

        return EffectiveRating(
            rating: ratings.first,
            flag: flags.first,
            colorLabel: sorted.compactMap(\.colorLabel).first,
            keywords: keywords,
            collections: collections,
            provenance: sorted,
            conflicts: conflicts
        )
    }

    private func priority(_ origin: RatingOrigin) -> Int {
        order.firstIndex(of: origin) ?? order.count
    }
}
