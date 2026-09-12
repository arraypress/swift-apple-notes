//
//  DrawingTests.swift
//  AppleNotesTests
//
//  Created by David Sherlock on 2026.
//
//  Drawings: the inks, the signature path, and what the metadata says.
//
//  The signature path parser is the part worth attacking. It is handed arbitrary bytes out of
//  a keyed archive and asked whether they are a `CGPath`, so the interesting tests are the
//  ones where they are NOT — a wrong element kind, a point count that disagrees with the
//  kind, a trailing word. Each must return nothing rather than a partial path, because a
//  partial parse produces a signature-shaped nothing that no caller can tell from a real one.
//

import XCTest
@testable import AppleNotes

final class SignaturePathTests: XCTestCase {

    /// A serialised path: each element is its kind, its point count, then the points.
    private func path(_ elements: [(Int, [(Float, Float)])]) -> Data {
        var data = Data()
        func word(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        for (kind, points) in elements {
            word(UInt32(kind))
            word(UInt32(points.count))
            for point in points { word(point.0.bitPattern); word(point.1.bitPattern) }
        }
        return data
    }

    func testReadsAMoveAndACurve() {
        let elements = PaperDecoder.path(path([(0, [(10, 20)]),
                                               (3, [(1, 2), (3, 4), (5, 6)])]))
        XCTAssertEqual(elements?.count, 2)
        XCTAssertEqual(elements?[0].kind, .move)
        XCTAssertEqual(elements?[0].points, [.init(x: 10, y: 20)])
        XCTAssertEqual(elements?[1].kind, .cubic)
        XCTAssertEqual(elements?[1].points.count, 3)
    }

    func testRejectsAnUnknownElementKind() {
        XCTAssertNil(PaperDecoder.path(path([(0, [(1, 1)]), (7, [(2, 2)])])))
    }

    func testRejectsAPointCountThatDisagreesWithTheKind() {
        // A cubic carries three points. Two is not a shorter cubic, it is not a path.
        var bytes = path([(0, [(1, 1)]), (3, [(2, 2), (3, 3), (4, 4)])])
        bytes[20] = 2                               // the curve's point-count word
        XCTAssertNil(PaperDecoder.path(bytes))
    }

    func testRejectsATrailingRemainder() {
        // Consuming exactly is the reconciliation that says this is a path at all.
        var bytes = path([(0, [(1, 1)])])
        bytes.append(contentsOf: [0, 0, 0, 0])
        XCTAssertNil(PaperDecoder.path(bytes))
    }

    func testRejectsBytesThatDoNotBeginWithAMove() {
        XCTAssertNil(PaperDecoder.path(path([(1, [(1, 1)])])))
    }

    func testRejectsSomethingTooShortOrMisaligned() {
        XCTAssertNil(PaperDecoder.path(Data()))
        XCTAssertNil(PaperDecoder.path(Data([0, 0, 0, 0, 1, 0, 0, 0])))
        XCTAssertNil(PaperDecoder.path(Data(repeating: 0, count: 17)))
    }

    func testDescribesTheSignatureItRead() {
        let elements = PaperDecoder.path(path([(0, [(0, 0)]), (3, [(1, 2), (3, 4), (10, 20)]),
                                               (0, [(5, 5)]), (1, [(6, 30)])]))
        let signature = Signature(elements: try! XCTUnwrap(elements))
        XCTAssertEqual(signature.strokeCount, 2, "two pen-downs")
        let bounds = try! XCTUnwrap(signature.bounds)
        XCTAssertEqual(bounds.width, 10, accuracy: 0.001)
        XCTAssertEqual(bounds.height, 30, accuracy: 0.001)
        XCTAssertTrue(signature.svgPath.hasPrefix("M 0.00 0.00 C 1.00 2.00"))
        XCTAssertTrue(signature.svgPath.contains("L 6.00 30.00"))
    }

    func testTheSvgFillsRatherThanStrokes() {
        // Stroking draws each mark as two hollow parallel lines, because the path traces
        // both sides of the pen. It looks almost right, which is the danger.
        let elements = try! XCTUnwrap(PaperDecoder.path(path([(0, [(0, 0)]), (1, [(4, 8)])])))
        let svg = Signature(elements: elements).svg
        XCTAssertTrue(svg.contains("fill=\"black\""))
        XCTAssertFalse(svg.contains("stroke="))
        XCTAssertTrue(svg.contains("viewBox="))
        XCTAssertEqual(Signature(elements: []).svg, "")
    }
}

final class InkTests: XCTestCase {

    /// An ink: four little-endian `fixed32` channels, then the identifier.
    private func ink(_ identifier: String, _ rgba: (Float, Float, Float, Float)) -> Data {
        var colour = Data()
        for (index, channel) in [rgba.0, rgba.1, rgba.2, rgba.3].enumerated() {
            colour.append(UInt8((index + 1) << 3 | 5))
            withUnsafeBytes(of: channel.bitPattern.littleEndian) { colour.append(contentsOf: $0) }
        }
        return Fixtures.field(1, bytes: colour) + Fixtures.field(2, bytes: Data(identifier.utf8))
    }

    func testReadsTheIdentifierAndColour() {
        let read = PaperDecoder.ink(ink("com.apple.ink.marker", (1, 0.417, 0, 1)))
        XCTAssertEqual(read?.0, "com.apple.ink.marker")
        XCTAssertEqual(read?.1[1] ?? 0, 0.417, accuracy: 0.0001)
    }

    func testIgnoresAnythingThatIsNotAnInk() {
        XCTAssertNil(PaperDecoder.ink(ink("com.apple.something.else", (1, 1, 1, 1))))
        XCTAssertNil(PaperDecoder.ink(Fixtures.field(2, bytes: Data("com.apple.ink.pen".utf8))))
        XCTAssertNil(PaperDecoder.ink(Data()))
    }

    func testRejectsAColourThatIsNotFourChannels() {
        // Accepting a short colour does not degrade — it reads the first channel and then
        // indexes past the end of the array for the other three.
        var colour = Data()
        for index in 0..<2 {
            colour.append(UInt8((index + 1) << 3 | 5))
            withUnsafeBytes(of: Float(0.5).bitPattern.littleEndian) { colour.append(contentsOf: $0) }
        }
        let short = Fixtures.field(1, bytes: colour)
                  + Fixtures.field(2, bytes: Data("com.apple.ink.pen".utf8))
        XCTAssertNil(PaperDecoder.ink(short))
    }

    func testNamesAndHexTheColour() {
        let ink = Ink(identifier: "com.apple.ink.marker", strokes: 9,
                      colour: Colour(red: 1, green: 0.417, blue: 0))
        XCTAssertEqual(ink.name, "marker")
        XCTAssertEqual(ink.hex, "#FF6A00")
        XCTAssertEqual(Ink(identifier: "pen", strokes: 1,
                           colour: Colour(red: 0, green: 0, blue: 0)).hex, "#000000")
        // Out-of-range channels clamp rather than overflowing the format.
        XCTAssertEqual(Ink(identifier: "x", strokes: 1,
                           colour: Colour(red: 2, green: -1, blue: 0.5)).hex, "#FF0080")
    }

    func testColoursAreReadLittleEndian() {
        // The other colours in a drawing are big-endian. Reading an ink that way gives a
        // number near zero, which is still a valid colour — black — so this renders wrong
        // rather than failing.
        let read = PaperDecoder.ink(ink("com.apple.ink.pen", (0.9647, 0.8078, 0.2745, 1)))
        XCTAssertEqual(read?.1[0] ?? 0, 0.9647, accuracy: 0.0001)
    }
}

final class DrawingMetadataTests: XCTestCase {

    func testKeepsOnlyTheFeaturesThatAreOn() {
        let json = Data(#"{"hasGraphKey":false,"hasMathKey":true,"hasNewInks2023Key":true}"#.utf8)
        XCTAssertEqual(NoteStore.features(json), ["math", "newInks2023"])
    }

    func testSurvivesMetadataThatIsMissingOrRubbish() {
        XCTAssertEqual(NoteStore.features(nil), [])
        XCTAssertEqual(NoteStore.features(Data("not json".utf8)), [])
        XCTAssertEqual(NoteStore.features(Data("[1,2,3]".utf8)), [])
        XCTAssertEqual(NoteStore.features(Data(#"{"hasGraphKey":"yes"}"#.utf8)), [],
                       "a string is not true")
    }

    func testTheSummaryNamesWhatIsInTheDrawing() {
        let drawing = Drawing(width: 768, height: 665,
                              inks: [Ink(identifier: "com.apple.ink.marker", strokes: 9,
                                         colour: Colour(red: 1, green: 0.417, blue: 0))],
                              signatures: [Signature(elements: [])],
                              features: ["math"])
        XCTAssertEqual(drawing.summary, "768×665 drawing · marker #FF6A00 · 1 signature · math")
        XCTAssertEqual(Drawing(width: 10, height: 20).summary, "10×20 drawing")
    }
}

/// A drawing that is not there.
final class EmptyDrawingTests: XCTestCase {

    func testABundleThatIsNotThereIsNotADrawing() {
        // Opening the markup canvas and closing it leaves a com.apple.paper row with no
        // size, no features, no bundle, and no placeholder in the body pointing at it.
        let nowhere = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).bundle")
        XCTAssertNil(PaperDecoder.decode(bundleAt: nowhere, width: 0, height: 0))
        XCTAssertNil(PaperDecoder.decode(bundleAt: nowhere, width: 768, height: 250))
    }

    func testASizedDrawingStillSummarisesWithoutABundle() {
        // The size and the features come from the database, so they survive a bundle that
        // cannot be read — that IS worth reporting, unlike nothing at all.
        let drawing = Drawing(width: 768, height: 250, features: ["math"])
        XCTAssertEqual(drawing.summary, "768×250 drawing · math")
    }
}
