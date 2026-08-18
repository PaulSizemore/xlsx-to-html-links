import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct XmpMetadata: Sendable, Equatable {
    public var rating: Int?
    public var label: String?
    public var keywords: [String]

    public init(rating: Int? = nil, label: String? = nil, keywords: [String] = []) {
        self.rating = rating
        self.label = label
        self.keywords = keywords
    }
}

/// Parses XMP sidecars (and embedded XMP packets) for xmp:Rating, xmp:Label,
/// dc:subject and lr:hierarchicalSubject. Handles both serializations in the
/// wild: values as rdf:Description attributes (Lightroom's compact form) and
/// as child elements (Bridge/darktable and others).
public struct XmpReader: Sendable {
    public init() {}

    public func read(fileURL: URL) throws -> XmpMetadata {
        try read(data: Data(contentsOf: fileURL))
    }

    public func read(data: Data) -> XmpMetadata {
        let delegate = XmpParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.result()
    }
}

private final class XmpParserDelegate: NSObject, XMLParserDelegate {
    private var rating: Int?
    private var label: String?
    private var flatKeywords: [String] = []
    private var hierarchicalKeywords: [String] = []

    private var elementStack: [String] = []
    private var currentText = ""

    func result() -> XmpMetadata {
        // Prefer lr:hierarchicalSubject leaves when present; dc:subject is the
        // flat mirror of the same set.
        var keywords = flatKeywords
        for path in hierarchicalKeywords {
            let leaf = path.split(separator: "|").last.map(String.init) ?? path
            if !keywords.contains(leaf) {
                keywords.append(leaf)
            }
        }
        return XmpMetadata(rating: rating, label: label, keywords: keywords)
    }

    private static func localName(_ qualified: String) -> String {
        qualified.split(separator: ":").last.map(String.init) ?? qualified
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        elementStack.append(Self.localName(elementName))
        currentText = ""

        // Attribute form: <rdf:Description xmp:Rating="3" xmp:Label="Red" …>
        for (key, value) in attributeDict {
            switch Self.localName(key) {
            case "Rating":
                if rating == nil, let parsed = Self.parseRating(value) { rating = parsed }
            case "Label":
                if label == nil, !value.isEmpty { label = value.lowercased() }
            default:
                break
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        let name = Self.localName(elementName)
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "Rating":
            if rating == nil, let parsed = Self.parseRating(text) { rating = parsed }
        case "Label":
            if label == nil, !text.isEmpty { label = text.lowercased() }
        case "li":
            if !text.isEmpty {
                if elementStack.contains("subject") {
                    flatKeywords.append(text)
                } else if elementStack.contains("hierarchicalSubject") {
                    hierarchicalKeywords.append(text)
                }
            }
        default:
            break
        }

        if elementStack.last == name {
            elementStack.removeLast()
        }
        currentText = ""
    }

    private static func parseRating(_ text: String) -> Int? {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)) else { return nil }
        let rating = Int(value)
        return (0...5).contains(rating) ? rating : nil
    }
}
