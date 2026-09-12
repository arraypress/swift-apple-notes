//
//  WriterTests.swift
//  AppleNotesTests
//
//  Created by David Sherlock on 2026.
//
//  The parts of writing that can be tested without writing.
//
//  Nothing here runs AppleScript. A unit test that created notes would leave litter in
//  whoever's library ran it, and the interesting failures are not in the scripting — they
//  are in the string handling that decides what the script says. So the escaping, the HTML
//  and the identifier arithmetic are tested, and the two lines that hand a finished script
//  to osascript are not.
//

import XCTest
@testable import AppleNotes

final class EscapingTests: XCTestCase {

    func testQuotesCannotEndTheStringLiteral() {
        // THE security boundary. Note text is arbitrary and goes inside an AppleScript
        // string literal; an unescaped quotation mark ends it and everything after runs as
        // script.
        let escaped = NoteWriter.escape("say \"hello\" then stop")
        XCTAssertFalse(escaped.contains("\"") && !escaped.contains("\\\""),
                       "every quote must be backslashed")
        XCTAssertEqual(escaped, "say \\\"hello\\\" then stop")
    }

    func testBackslashesAreEscapedBeforeQuotes() {
        // Order matters and getting it wrong is subtle: escaping quotes first, then
        // backslashes, turns \" into \\" — which closes the literal after all.
        XCTAssertEqual(NoteWriter.escape("a\\b"), "a\\\\b")
        XCTAssertEqual(NoteWriter.escape("\\\""), "\\\\\\\"")
    }

    func testAnAttemptedBreakoutStaysInsideTheLiteral() {
        let hostile = "\" & (do shell script \"echo owned\") & \""
        let escaped = NoteWriter.escape(hostile)
        // Count unescaped quotes: there must be none.
        var previous: Character = " "
        var bare = 0
        for character in escaped {
            if character == "\"", previous != "\\" { bare += 1 }
            previous = character
        }
        XCTAssertEqual(bare, 0, "no quote may stand unescaped")
    }

    func testHtmlIsEscapedSoANoteAboutTagsIsANoteAboutTags() {
        let html = NoteWriter.html(title: "About <b>", body: "5 < 6 & 7 > 6")
        XCTAssertTrue(html.contains("&lt;b&gt;"))
        XCTAssertTrue(html.contains("5 &lt; 6 &amp; 7 &gt; 6"))
    }

    func testAmpersandsAreEscapedFirst() {
        // Escaping < before & would turn "<" into "&lt;" and then into "&amp;lt;".
        XCTAssertEqual(NoteWriter.escapeHTML("<"), "&lt;")
        XCTAssertEqual(NoteWriter.escapeHTML("&lt;"), "&amp;lt;")
    }
}

final class FormattingTests: XCTestCase {

    func testEachLineBecomesItsOwnParagraph() {
        XCTAssertEqual(NoteWriter.paragraphs("one\ntwo"), "<div>one</div><div>two</div>")
    }

    func testABlankLineSurvivesAsABreak() {
        // An empty <div> is dropped by Notes, so a blank line between paragraphs would
        // silently close up and reflow the note.
        XCTAssertEqual(NoteWriter.paragraphs("a\n\nb"),
                       "<div>a</div><div><br></div><div>b</div>")
    }

    func testTheTitleLeadsTheBody() {
        let html = NoteWriter.html(title: "Shopping", body: "milk")
        XCTAssertTrue(html.hasPrefix("<div><h1>Shopping</h1></div>"))
        XCTAssertTrue(html.contains("<div>milk</div>"))
    }

    func testAnEmptyBodyIsJustTheTitle() {
        XCTAssertEqual(NoteWriter.html(title: "Just this", body: ""),
                       "<div><h1>Just this</h1></div>")
    }
}

final class IdentifierTests: XCTestCase {

    func testBuildsTheIdentifierAppleScriptExpects() {
        // The bridge between the halves: reads return a row id, writes need this shape.
        // Verified against a live library — AppleScript returned exactly this for row 718.
        XCTAssertEqual(
            NoteWriter.appleScriptID(storeUUID: "00000000-1111-2222-3333-444444444444", rowID: 718),
            "x-coredata://00000000-1111-2222-3333-444444444444/ICNote/p718"
        )
    }
}

// MARK: - The verbs added to match what other tools expose

/// `setBody`, `deleteFolder` and the account-column probe.
final class WriterCoverageTests: XCTestCase {

    func testReplacingABodyBuildsParagraphsAndEscapes() {
        // Same paragraph rule as append: one div per line, blanks kept as <br>.
        let html = NoteWriter.paragraphs("first\n\nthird & <b>literal</b>")
        XCTAssertEqual(html,
                       "<div>first</div><div><br></div><div>third &amp; &lt;b&gt;literal&lt;/b&gt;</div>")
    }

    func testTheFirstParagraphIsWhatARenameReplaces() {
        let body = "<div><h1>Old</h1></div><div>kept</div>"
        XCTAssertEqual(NoteWriter.bodyAfterFirstParagraph(body), "<div>kept</div>")
    }

    func testNestedDivsDoNotSplitAParagraphInHalf() {
        // Counting matters: searching for the first `</div>` would cut inside the title and
        // leave a stray closing tag at the front of the note.
        let body = "<div><span><div>nested</div></span></div><div>kept</div>"
        XCTAssertEqual(NoteWriter.bodyAfterFirstParagraph(body), "<div>kept</div>")
    }

    func testABodyWithNoParagraphIsRefusedRatherThanMangled() {
        XCTAssertNil(NoteWriter.bodyAfterFirstParagraph("no markup at all"))
        XCTAssertNil(NoteWriter.bodyAfterFirstParagraph(""))
        XCTAssertNil(NoteWriter.bodyAfterFirstParagraph("<div>unclosed"))
    }

    func testAFolderNameIsEscapedIntoTheScript() {
        // A folder called `He said "no"` must not end the AppleScript string literal.
        XCTAssertEqual(NoteWriter.escape("He said \"no\" \\ here"),
                       "He said \\\"no\\\" \\\\ here")
    }
}
