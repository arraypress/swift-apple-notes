//
//  HighlightTests.swift
//  AppleNotesTests
//
//  Created by David Sherlock on 2026.
//
//  Highlighted text, and the five colours Notes will write.
//
//  The mapping came from a note holding one highlighted line per colour, each line naming the
//  colour it is highlighted in — so "Mint" carried code 4 and no colour had to be recognised
//  by eye. These tests encode that reading rather than re-deriving it.
//

import XCTest
@testable import AppleNotes

final class HighlightTests: XCTestCase {

    private func spans(_ runs: [Fixtures.Run]) -> [Span] {
        (BodyDecoder.decode(Fixtures.note(runs)) ?? []).first?.spans ?? []
    }

    func testTheFiveColoursInMenuOrder() {
        let expected: [Highlight] = [.purple, .pink, .orange, .mint, .blue]
        for (index, colour) in expected.enumerated() {
            XCTAssertEqual(Highlight.from(code: index + 1), colour)
            XCTAssertEqual(colour.code, index + 1)
        }
        XCTAssertEqual(expected.map(\.name), ["purple", "pink", "orange", "mint", "blue"])
    }

    func testUnhighlightedIsNothingRatherThanAColour() {
        XCTAssertNil(Highlight.from(code: 0))
        XCTAssertNil(spans([.init(text: "plain")]).first?.highlight)
        XCTAssertTrue(spans([.init(text: "plain")])[0].isPlain)
    }

    func testAColourThisVersionDoesNotKnowIsKeptRatherThanFlattened() {
        // Apple can add a sixth. Reading it as purple would be a silent lie about someone's
        // note; `.other` says a highlight is there and that its name is not known.
        XCTAssertEqual(Highlight.from(code: 9), .other(9))
        XCTAssertEqual(Highlight.other(9).code, 9)
        XCTAssertEqual(Highlight.other(9).name, "highlight-9")
    }

    func testReadsTheHighlightOffTheRun() {
        let result = spans([.init(text: "Mint", highlight: 4)])
        XCTAssertEqual(result.first?.highlight, .mint)
        XCTAssertFalse(result[0].isPlain)
    }

    func testRendersAMarkCarryingTheColourName() {
        // A class rather than an inline style: the name is measured, an RGB value is not.
        XCTAssertEqual(spans([.init(text: "Blue", highlight: 5)])[0].markdown,
                       "<mark class=\"blue\">Blue</mark>")
    }

    func testCombinesWithOtherStyling() {
        let result = spans([.init(text: "both", weight: 1, highlight: 2)])
        XCTAssertEqual(result[0].highlight, .pink)
        XCTAssertEqual(result[0].markdown, "<mark class=\"pink\">**both**</mark>")
    }

    func testRunsInDifferentColoursStayApart() {
        // Notes splits a highlighted phrase across several runs; adjacent runs merge only
        // when everything about them agrees, and the colour is part of that.
        let result = spans([.init(text: "one", highlight: 1), .init(text: "two", highlight: 3)])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.highlight), [.purple, .orange])
    }

    func testRunsInTheSameColourMergeBackTogether() {
        let result = spans([.init(text: "Weekend", highlight: 1), .init(text: " Plan", highlight: 1)])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "Weekend Plan")
    }

    func testASpanSurvivesEncodingWithItsColour() throws {
        let span = Span(text: "x", highlight: .mint)
        let data = try JSONEncoder().encode(span)
        XCTAssertEqual(try JSONDecoder().decode(Span.self, from: data).highlight, .mint)
        let unknown = Span(text: "x", highlight: .other(7))
        let round = try JSONDecoder().decode(Span.self,
                                             from: try JSONEncoder().encode(unknown))
        XCTAssertEqual(round.highlight, .other(7))
    }
}

/// Text colour, which is a real colour where a highlight is a code.
///
/// Notes has no control that sets one, so the mapping was measured by writing known values
/// through AppleScript: `color:#FF0000` came back as exactly #FF0000, `<font color>` the
/// same, and `background-color` came back as nothing at all.
final class TextColourTests: XCTestCase {

    private func spans(_ runs: [Fixtures.Run]) -> [Span] {
        (BodyDecoder.decode(Fixtures.note(runs)) ?? []).first?.spans ?? []
    }

    func testReadsTheColourOffTheRun() {
        let result = spans([.init(text: "red", colour: [1, 0, 0, 1])])
        XCTAssertEqual(result.first?.colour?.hex, "#FF0000")
        XCTAssertEqual(result.first?.colour?.alpha, 1)
        XCTAssertFalse(result[0].isPlain)
    }

    func testReadsTheChannelsLittleEndian() {
        // Big-endian puts every channel near zero, which is black — a valid colour, so this
        // renders wrong rather than failing.
        XCTAssertEqual(spans([.init(text: "x", colour: [0.988, 0.722, 0.153, 1])])
            .first?.colour?.hex, "#FCB827")
    }

    func testRendersAnInlineStyle() {
        // A colour gets a style where a highlight gets a class: this is a measured RGB
        // value, where a highlight is a name whose pixels were never measured.
        XCTAssertEqual(spans([.init(text: "red", colour: [1, 0, 0, 1])])[0].markdown,
                       "<span style=\"color:#FF0000\">red</span>")
    }

    func testAColourAndAHighlightAreDifferentFields() {
        let both = spans([.init(text: "x", highlight: 4, colour: [1, 0, 0, 1])])[0]
        XCTAssertEqual(both.highlight, .mint)
        XCTAssertEqual(both.colour?.hex, "#FF0000")
        XCTAssertEqual(both.markdown, "<mark class=\"mint\"><span style=\"color:#FF0000\">x</span></mark>")
    }

    func testRefusesAColourThatIsNotFourChannels() {
        // Accepting a short one does not degrade — it reads the first channel and then
        // indexes past the end of the array for the other three.
        XCTAssertNil(spans([.init(text: "x", colour: [0.5, 0.5])]).first?.colour)
        XCTAssertNil(spans([.init(text: "x", colour: [0.5, 0.5, 0.5])]).first?.colour)
        XCTAssertNil(spans([.init(text: "x", colour: [])]).first?.colour)
    }

    func testNoColourIsNothing() {
        XCTAssertNil(spans([.init(text: "plain")]).first?.colour)
        XCTAssertTrue(spans([.init(text: "plain")])[0].isPlain)
    }

    func testRunsInDifferentColoursStayApart() {
        let result = spans([.init(text: "one", colour: [1, 0, 0, 1]),
                            .init(text: "two", colour: [0, 0, 1, 1])])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map { $0.colour?.hex }, ["#FF0000", "#0000FF"])
    }

    func testHexClampsRatherThanOverflowing() {
        XCTAssertEqual(Colour(red: 2, green: -1, blue: 0.5).hex, "#FF0080")
    }
}
