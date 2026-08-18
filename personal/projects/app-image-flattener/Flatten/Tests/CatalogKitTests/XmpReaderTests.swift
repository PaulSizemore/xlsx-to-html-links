import Foundation
import XCTest

@testable import CatalogKit

final class XmpReaderTests: XCTestCase {
    let reader = XmpReader()

    func testLightroomAttributeForm() {
        // Lightroom's compact serialization: values as rdf:Description attributes.
        let xmp = """
            <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
             <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about=""
                xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                xmlns:dc="http://purl.org/dc/elements/1.1/"
                xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
                xmp:Rating="3"
                xmp:Label="Blue">
               <dc:subject>
                <rdf:Bag>
                 <rdf:li>wedding</rdf:li>
                 <rdf:li>outdoor</rdf:li>
                </rdf:Bag>
               </dc:subject>
               <lr:hierarchicalSubject>
                <rdf:Bag>
                 <rdf:li>events|wedding</rdf:li>
                </rdf:Bag>
               </lr:hierarchicalSubject>
              </rdf:Description>
             </rdf:RDF>
            </x:xmpmeta>
            <?xpacket end="w"?>
            """
        let metadata = reader.read(data: Data(xmp.utf8))
        XCTAssertEqual(metadata.rating, 3)
        XCTAssertEqual(metadata.label, "blue")
        XCTAssertEqual(metadata.keywords, ["wedding", "outdoor"])
    }

    func testElementForm() {
        // Bridge/darktable-style: values as child elements.
        let xmp = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
             <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about=""
                xmlns:xmp="http://ns.adobe.com/xap/1.0/">
               <xmp:Rating>5</xmp:Rating>
               <xmp:Label>Green</xmp:Label>
              </rdf:Description>
             </rdf:RDF>
            </x:xmpmeta>
            """
        let metadata = reader.read(data: Data(xmp.utf8))
        XCTAssertEqual(metadata.rating, 5)
        XCTAssertEqual(metadata.label, "green")
        XCTAssertEqual(metadata.keywords, [])
    }

    func testHierarchicalLeavesWithoutFlatMirror() {
        let xmp = """
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
             <rdf:Description rdf:about=""
               xmlns:lr="http://ns.adobe.com/lightroom/1.0/">
              <lr:hierarchicalSubject>
               <rdf:Bag>
                <rdf:li>travel|japan|tokyo</rdf:li>
               </rdf:Bag>
              </lr:hierarchicalSubject>
             </rdf:Description>
            </rdf:RDF>
            """
        let metadata = reader.read(data: Data(xmp.utf8))
        XCTAssertEqual(metadata.keywords, ["tokyo"], "leaf of the hierarchy")
    }

    func testUnratedAndGarbageInputs() {
        XCTAssertEqual(reader.read(data: Data("<not-xmp/>".utf8)), XmpMetadata())
        XCTAssertEqual(reader.read(data: Data("total garbage".utf8)), XmpMetadata())

        let outOfRange = """
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
             <rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="9"/>
            </rdf:RDF>
            """
        XCTAssertNil(reader.read(data: Data(outOfRange.utf8)).rating)
    }
}
