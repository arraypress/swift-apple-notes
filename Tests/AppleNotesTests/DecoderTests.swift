//
//  DecoderTests.swift
//  AppleNotesTests
//
//  Created by David Sherlock on 2026.
//
//  The body decoder, against notes whose content is known before they are decoded.
//

import XCTest
@testable import AppleNotes

final class GzipTests: XCTestCase {

    func testRoundTripsThroughAGzipWrapper() {
        let original = Data("the quick brown fox jumps over the lazy dog".utf8)
        let inflated = Gzip.inflate(Fixtures.gzip(original))
        XCTAssertEqual(inflated, original)
    }

    func testHandlesDataLargerThanTheFirstGuess() {
        // Highly compressible input makes the deflate stream far smaller than the output,
        // which is exactly when a buffer sized from the compressed length is too small.
        let original = Data(String(repeating: "note ", count: 20_000).utf8)
        XCTAssertEqual(Gzip.inflate(Fixtures.gzip(original)), original)
    }

    func testRejectsSomethingThatIsNotGzip() {
        XCTAssertNil(Gzip.inflate(Data("plain text, no magic bytes at all here".utf8)))
        XCTAssertNil(Gzip.inflate(Data()))
        XCTAssertNil(Gzip.inflate(Data([0x1f, 0x8b])))
    }

    func testSkipsTheOptionalHeaderFields() {
        // FNAME and FCOMMENT are NUL-terminated strings between the header and the payload.
        // Reading the payload from a fixed offset of 10 would land inside the filename.
        var withName = Fixtures.gzip(Data("payload".utf8))
        withName[3] = 0x08                                  // FNAME
        withName.insert(contentsOf: Data("note.txt\0".utf8), at: 10)
        XCTAssertEqual(Gzip.inflate(withName), Data("payload".utf8))
    }
}

final class ProtobufTests: XCTestCase {

    func testReadsVarintsAndLengthDelimitedFields() {
        let message = Fixtures.field(1, varint: 300) + Fixtures.field(2, bytes: Data("hi".utf8))
        XCTAssertEqual(Protobuf.integer(1, in: message), 300)
        XCTAssertEqual(Protobuf.message(2, in: message), Data("hi".utf8))
    }

    func testKeepsEveryOccurrenceOfARepeatedField() {
        // Attribute runs are all field 5. Collapsing them to one leaves a note with a single
        // run and every style after the first in the wrong place.
        let message = (1...4).map { Fixtures.field(5, bytes: Data([UInt8($0)])) }.reduce(Data(), +)
        XCTAssertEqual(Protobuf.messages(5, in: message).count, 4)
        XCTAssertEqual(Protobuf.messages(5, in: message).map { $0.first }, [1, 2, 3, 4])
    }

    func testReturnsWhatWasReadableFromATruncatedMessage() {
        let full = Fixtures.field(1, varint: 7) + Fixtures.field(2, bytes: Data(repeating: 9, count: 40))
        let cut = full.prefix(6)
        XCTAssertEqual(Protobuf.integer(1, in: cut), 7, "the complete field before the cut survives")
    }

    func testIgnoresAnUnknownFieldRatherThanFailing() {
        // Apple adds fields every release; a reader that stops at one it does not know
        // loses everything after it.
        let message = Fixtures.field(99, bytes: Data("future".utf8)) + Fixtures.field(1, varint: 42)
        XCTAssertEqual(Protobuf.integer(1, in: message), 42)
    }
}

final class BodyDecoderTests: XCTestCase {

    private func blocks(_ runs: [Fixtures.Run]) -> [Block] {
        BodyDecoder.decode(Fixtures.note(runs)) ?? []
    }

    func testDecodesPlainText() {
        let result = blocks([.init(text: "hello world")])
        XCTAssertEqual(result.map(\.text), ["hello world"])
        XCTAssertEqual(result.map(\.style), [.body])
    }

    func testSplitsOnNewlinesRatherThanOnRuns() {
        // A run is a span sharing attributes, NOT a paragraph: a real note split
        // "My Test Note" across runs of 1, 7 and 5 characters. Treating runs as lines
        // shatters every paragraph.
        let result = blocks([
            .init(text: "My "), .init(text: "Test "), .init(text: "Note\n"),
            .init(text: "second line"),
        ])
        XCTAssertEqual(result.map(\.text), ["My Test Note", "second line"])
    }

    func testCarriesEveryVerifiedStyleCode() {
        let result = blocks([
            .init(text: "A title\n", styleCode: 0),
            .init(text: "code\n", styleCode: 4),
            .init(text: "bullet\n", styleCode: 100),
            .init(text: "dash\n", styleCode: 101),
            .init(text: "number\n", styleCode: 102),
        ])
        XCTAssertEqual(result.map(\.style),
                       [.title, .monospaced, .bulleted, .dashed, .numbered])
    }

    func testReadsTheTickStateOfAChecklist() {
        let result = blocks([
            .init(text: "done\n", styleCode: 103, checklistDone: true),
            .init(text: "not done", styleCode: 103, checklistDone: false),
        ])
        XCTAssertEqual(result.map(\.style), [.checklist(done: true), .checklist(done: false)])
    }

    func testAnUnknownStyleKeepsItsCodeRatherThanBecomingBodyText() {
        // Apple has added paragraph styles to this format before. Rendering a new one as
        // ordinary text is how a tool quietly misreports someone's notes.
        let result = blocks([.init(text: "something new", styleCode: 777)])
        XCTAssertEqual(result.first?.style, .other(777))
    }

    func testAParagraphStyleCarryingOnlyAnIndentIsStillBodyText() {
        // The absence of a style code is not the code zero: zero means Title.
        let result = blocks([.init(text: "indented", indent: 2)])
        XCTAssertEqual(result.first?.style, .body)
        XCTAssertEqual(result.first?.indent, 2)
    }

    func testLengthsAreCountedInUtf16Units() {
        // Apple stores this as an attributed string and attributed strings count UTF-16, so
        // an emoji is two units and a String.count of one. Counting characters shifts every
        // style after the first emoji.
        let result = blocks([
            .init(text: "🎹 piano\n", styleCode: 0),
            .init(text: "after", styleCode: 100),
        ])
        XCTAssertEqual(result.map(\.text), ["🎹 piano", "after"])
        XCTAssertEqual(result.map(\.style), [.title, .bulleted],
                       "the style after an emoji must not slide")
    }

    func testMarksAttachmentPlaceholders() {
        let result = blocks([.init(text: "text\n"), .init(text: "\u{FFFC}")])
        XCTAssertFalse(result[0].isAttachmentPlaceholder)
        XCTAssertTrue(result[1].isAttachmentPlaceholder)
    }

    func testKeepsBlankLines() {
        let result = blocks([.init(text: "one\n"), .init(text: "\n"), .init(text: "two")])
        XCTAssertEqual(result.map(\.text), ["one", "", "two"], "dropping a blank line reflows the note")
    }

    func testRefusesSomethingThatIsNotANoteBody() {
        XCTAssertNil(BodyDecoder.decode(Data("not gzip".utf8)))
        XCTAssertNil(BodyDecoder.decode(Fixtures.gzip(Data("gzip, but not a note".utf8))))
    }
}

final class RenderingTests: XCTestCase {

    private func note(_ runs: [Fixtures.Run], attachments: [Attachment] = []) -> Note {
        Note(id: 1, title: "t", blocks: BodyDecoder.decode(Fixtures.note(runs)) ?? [],
             attachments: attachments)
    }

    func testRendersMarkdownForEachStyle() {
        let markdown = note([
            .init(text: "Title\n", styleCode: 0),
            .init(text: "ticked\n", styleCode: 103, checklistDone: true),
            .init(text: "unticked\n", styleCode: 103, checklistDone: false),
            .init(text: "item\n", styleCode: 100),
            .init(text: "code", styleCode: 4),
        ]).markdown
        XCTAssertEqual(markdown, "# Title\n- [x] ticked\n- [ ] unticked\n- item\n`code`")
    }

    func testNamesAnAttachmentWhereItSits() {
        // A vanished attachment is worse than an imperfectly rendered one: the reader has
        // no way to know something was there.
        let drawing = Attachment(id: "a", kind: .drawing, recognisedText: "shopping list")
        let markdown = note([.init(text: "before\n"), .init(text: "\u{FFFC}")],
                            attachments: [drawing]).markdown
        XCTAssertTrue(markdown.contains("drawing"))
        XCTAssertTrue(markdown.contains("shopping list"))
    }

    func testAPlaceholderWithNoMatchingAttachmentStillShows() {
        // A sync conflict can leave more placeholders than attachments.
        let markdown = note([.init(text: "\u{FFFC}")], attachments: []).markdown
        XCTAssertEqual(markdown, "[attachment]")
    }

    func testPlainTextDropsPlaceholdersEntirely() {
        let text = note([.init(text: "a\n"), .init(text: "\u{FFFC}"), .init(text: "\nb")]).text
        XCTAssertFalse(text.contains("\u{FFFC}"))
        XCTAssertTrue(text.contains("a"))
    }
}

// MARK: - Character styling

final class SpanTests: XCTestCase {

    private func blocks(_ runs: [Fixtures.Run]) -> [Block] {
        BodyDecoder.decode(Fixtures.note(runs)) ?? []
    }

    func testReadsBoldItalicUnderlineAndStrikethrough() {
        let result = blocks([
            .init(text: "plain "), .init(text: "bold", weight: 1),
            .init(text: " "), .init(text: "italic", weight: 2),
            .init(text: " "), .init(text: "under", underlined: true),
            .init(text: " "), .init(text: "struck", strikethrough: true),
        ])
        let spans = result[0].spans
        XCTAssertEqual(spans.first(where: \.bold)?.text, "bold")
        XCTAssertEqual(spans.first(where: \.italic)?.text, "italic")
        XCTAssertEqual(spans.first(where: \.underlined)?.text, "under")
        XCTAssertEqual(spans.first(where: \.strikethrough)?.text, "struck")
    }

    func testFontWeightIsAnEnumNotAFlag() {
        // 1 is bold and 2 is italic. Testing for non-zero makes every italic word bold too,
        // which is the mistake this encoding invites.
        XCTAssertEqual(blocks([.init(text: "x", weight: 2)])[0].spans[0].italic, true)
        XCTAssertEqual(blocks([.init(text: "x", weight: 2)])[0].spans[0].bold, false)
        XCTAssertEqual(blocks([.init(text: "x", weight: 1)])[0].spans[0].bold, true)
        XCTAssertEqual(blocks([.init(text: "x", weight: 3)])[0].spans[0].bold, true)
        XCTAssertEqual(blocks([.init(text: "x", weight: 3)])[0].spans[0].italic, true)
    }

    func testKeepsTheLinkUrl() {
        // The failure this whole type exists for: the words survived and the address, the
        // one part nobody can retype from memory, was dropped.
        let result = blocks([.init(text: "go to "), .init(text: "example", link: "https://example.com/")])
        XCTAssertEqual(result[0].spans.last?.link, "https://example.com/")
        XCTAssertTrue(result[0].markdown.contains("(https://example.com/)"))
    }

    func testMergesAdjacentRunsThatAgree() {
        // Notes splits runs for reasons of its own — a real note broke "My Test Note" into
        // three — and one span per run would make the Markdown unreadable.
        let result = blocks([.init(text: "My "), .init(text: "Test "), .init(text: "Note")])
        XCTAssertEqual(result[0].spans.count, 1)
        XCTAssertEqual(result[0].spans[0].text, "My Test Note")
    }

    func testAnUnstyledParagraphIsOnePlainSpan() {
        let span = blocks([.init(text: "nothing special")])[0].spans
        XCTAssertEqual(span.count, 1)
        XCTAssertTrue(span[0].isPlain)
    }

    func testMarksGoOutsideTheTextAndInsideTheSpaces() {
        // Notes routinely leaves a trailing space inside a styled run, and `** bold **`
        // is not bold in any renderer.
        let span = Span(text: "bold ", bold: true)
        XCTAssertEqual(span.markdown, "**bold** ")
    }

    func testALinkDoesNotAlsoRenderItsUnderline() {
        // Notes underlines links by default; emitting both gives [<u>x</u>](url), which is
        // accurate and noise.
        let span = Span(text: "example", underlined: true, link: "https://example.com/")
        XCTAssertEqual(span.markdown, "[example](https://example.com/)")
    }

    func testStylingSurvivesIntoTheBlockMarkdown() {
        let result = blocks([
            .init(text: "see ", styleCode: 100),
            .init(text: "this", styleCode: 100, link: "https://a.example"),
        ])
        XCTAssertEqual(result[0].markdown, "- see [this](https://a.example)")
    }

    func testMonospacedIgnoresInlineMarksBecauseACodeSpanIsLiteral() {
        let result = blocks([.init(text: "let x = 1", styleCode: 4, weight: 1)])
        XCTAssertEqual(result[0].markdown, "`let x = 1`")
    }
}

// MARK: - Tags

final class TagTests: XCTestCase {

    func testFindsTagsInOrderWithoutDuplicates() {
        XCTAssertEqual(Tags.found(in: "about #swift and #macos and #swift again"),
                       ["swift", "macos"])
    }

    func testATagEndsAtWhitespaceOrPunctuation() {
        XCTAssertEqual(Tags.found(in: "#one, #two. #three!"), ["one", "two", "three"])
        XCTAssertEqual(Tags.found(in: "#notatag#either"), ["notatag"])
    }

    func testAHashInsideAWordIsNotATag() {
        // `C#` is a language and `item#3` is a reference. Notes does not tag either.
        XCTAssertTrue(Tags.found(in: "written in C# mostly").isEmpty)
        XCTAssertTrue(Tags.found(in: "see item#3 below").isEmpty)
    }

    func testDigitsAloneAreNotATag() {
        // "#4" is a house number.
        XCTAssertTrue(Tags.found(in: "flat #4, and #42").isEmpty)
        XCTAssertEqual(Tags.found(in: "#v2release"), ["v2release"])
    }

    func testUnderscoresAndUnicodeLettersCount() {
        XCTAssertEqual(Tags.found(in: "#to_do and #café and #日本語"),
                       ["to_do", "café", "日本語"])
    }

    func testDuplicatesDifferingOnlyInCaseCountOnce() {
        XCTAssertEqual(Tags.found(in: "#Swift and #swift"), ["Swift"])
    }

    func testATagAtTheVeryEndIsStillFound() {
        XCTAssertEqual(Tags.found(in: "ending on #atag"), ["atag"])
    }

    func testANoteExposesItsOwnTags() {
        let blocks = BodyDecoder.decode(Fixtures.note([
            .init(text: "Shopping\n"), .init(text: "milk #urgent #food"),
        ])) ?? []
        let note = Note(id: 1, title: "Shopping", blocks: blocks)
        XCTAssertEqual(note.tags, ["urgent", "food"])
    }

    func testNoTextMeansNoTags() {
        XCTAssertTrue(Tags.found(in: "").isEmpty)
        XCTAssertTrue(Tags.found(in: "#").isEmpty)
        XCTAssertTrue(Tags.found(in: "nothing here").isEmpty)
    }
}

// MARK: - Tables, when the grid will not decode

/// The flattened summary Notes writes beside every table.
///
/// It is the FALLBACK now that ``TableDecoder`` reconstructs the grid — see `TableTests` —
/// and it stays tested because it is what a caller gets when a blob will not decode. Note
/// what it cannot do: it drops empty cells, so its count is not rows times columns.
final class TableFallbackTests: XCTestCase {

    private func table(_ summary: String?) -> Attachment {
        Attachment(id: "t", kind: .table, recognisedText: summary)
    }

    func testSplitsTheSummaryIntoCells() {
        XCTAssertEqual(table("Name\nAge\nAda\n36").tableCells, ["Name", "Age", "Ada", "36"])
    }

    func testDropsTheBlankLinesNotesLeaves() {
        // A real table's summary ended with several empty lines.
        XCTAssertEqual(table("Table\ntable\nTable\ntable\n\n\n").tableCells,
                       ["Table", "table", "Table", "table"])
    }

    func testOnlyATableHasCells() {
        XCTAssertTrue(Attachment(id: "d", kind: .drawing, recognisedText: "a\nb").tableCells.isEmpty)
        XCTAssertTrue(Attachment(id: "i", kind: .image(uti: "public.png"),
                                 recognisedText: "a\nb").tableCells.isEmpty)
    }

    func testNoSummaryMeansNoCells() {
        XCTAssertTrue(table(nil).tableCells.isEmpty)
        XCTAssertTrue(table("").tableCells.isEmpty)
    }

    func testTheSummaryLineCountsTheCells() {
        let summary = table("Name\nAge\nAda\n36").summary
        XCTAssertTrue(summary.contains("4 cells"))
        XCTAssertTrue(summary.contains("Name | Age"))
    }
}

// MARK: - Block quotes

final class BlockQuoteTests: XCTestCase {

    private func blocks(_ runs: [Fixtures.Run]) -> [Block] {
        BodyDecoder.decode(Fixtures.note(runs)) ?? []
    }

    func testReadsQuotingFromItsOwnField() {
        // Block quote is NOT a styleType. A quoted note carried no style code at all and
        // was distinguished only by paragraph-style field 8, which is why reading styleType
        // alone misses quoting entirely.
        let result = blocks([.init(text: "quoted", blockQuote: 1)])
        XCTAssertTrue(result[0].isBlockQuote)
        XCTAssertEqual(result[0].style, .body, "quoting does not replace the style")
    }

    func testQuotingCombinesWithAStyle() {
        // The format menu puts Block Quote below a separator, apart from the nine mutually
        // exclusive styles — because it modifies one rather than being one.
        let result = blocks([.init(text: "quoted item", styleCode: 100, blockQuote: 1)])
        XCTAssertEqual(result[0].style, .bulleted)
        XCTAssertTrue(result[0].isBlockQuote)
        XCTAssertEqual(result[0].markdown, "> - quoted item")
    }

    func testAnUnquotedParagraphIsNotMarked() {
        XCTAssertFalse(blocks([.init(text: "plain")])[0].isBlockQuote)
        XCTAssertEqual(blocks([.init(text: "plain")])[0].markdown, "plain")
    }

    func testTheQuoteMarkGoesOutsideTheIndent() {
        let result = blocks([.init(text: "nested", styleCode: 100, indent: 1, blockQuote: 1)])
        XCTAssertEqual(result[0].markdown, ">   - nested")
    }

    func testQuotedMonospacedKeepsBoth() {
        let result = blocks([.init(text: "code", styleCode: 4, blockQuote: 1)])
        XCTAssertEqual(result[0].markdown, "> `code`")
    }
}

// MARK: - Attachment kinds

final class AttachmentKindTests: XCTestCase {

    func testRecognisesEveryKindSeenOnRealNotes() {
        XCTAssertEqual(AttachmentKind.from(uti: "com.apple.paper"), .drawing)
        XCTAssertEqual(AttachmentKind.from(uti: "com.apple.notes.table"), .table)
        XCTAssertEqual(AttachmentKind.from(uti: "public.png"), .image(uti: "public.png"))
        XCTAssertEqual(AttachmentKind.from(uti: "com.apple.m4a-audio"),
                       .audio(uti: "com.apple.m4a-audio"))
    }

    func testAudioIsNotMistakenForAFile() {
        // A recording arrives as com.apple.m4a-audio, which has no "public." prefix and
        // would otherwise fall through to `.file` and print its raw identifier.
        XCTAssertEqual(AttachmentKind.from(uti: "com.apple.m4a-audio").name, "audio")
        XCTAssertEqual(AttachmentKind.from(uti: "public.mpeg-4-audio").name, "audio")
    }

    func testAnUnknownTypeKeepsItsIdentifier() {
        XCTAssertEqual(AttachmentKind.from(uti: "com.example.future"),
                       .file(uti: "com.example.future"))
        XCTAssertEqual(AttachmentKind.from(uti: "com.example.future").name, "com.example.future")
    }
}

// MARK: - Confirmed against Apple's own class

final class RuntimeConfirmedTests: XCTestCase {

    private func style(_ code: Int) -> BlockStyle {
        BodyDecoder.decode(Fixtures.note([.init(text: "x", styleCode: code)]))?.first?.style ?? .body
    }

    func testTheThreeHeaderCodesAreHeaders() {
        // ICTTParagraphStyle reports isHeader for 0, 1 and 2 — which is how heading and
        // subheading were settled without ever finding a note that used them.
        XCTAssertEqual(style(0), .title)
        XCTAssertEqual(style(1), .heading)
        XCTAssertEqual(style(2), .subheading)
    }

    func testCodeThreeIsBodyNotAnUnknown() {
        // The bug Apple's own class found. Notes writes no paragraph style for text it
        // never styled, and code 3 for text explicitly set back to Body — so both spellings
        // occur and only one of them was being read as body.
        XCTAssertEqual(style(3), .body)
        XCTAssertNotEqual(style(3), .other(3))
    }

    func testTheThreeListCodesAreLists() {
        // ICTTParagraphStyle reports isList for 100, 101 and 102.
        XCTAssertTrue(style(100).isListItem)
        XCTAssertTrue(style(101).isListItem)
        XCTAssertTrue(style(102).isListItem)
    }

    func testQuotingIsALevelAndNests() {
        // Apple types blockQuoteLevel as an unsigned integer beside indent, so it counts
        // nesting. A boolean would flatten a quote inside a quote.
        let blocks = BodyDecoder.decode(Fixtures.note([
            .init(text: "once\n", blockQuote: 1),
            .init(text: "twice", blockQuote: 2),
        ])) ?? []
        XCTAssertEqual(blocks[0].blockQuoteLevel, 1)
        XCTAssertEqual(blocks[1].blockQuoteLevel, 2)
        XCTAssertEqual(blocks[0].markdown, "> once")
        XCTAssertEqual(blocks[1].markdown, "> > twice")
        XCTAssertTrue(blocks[1].isBlockQuote)
    }

    func testAStillUnknownCodeIsStillKept() {
        // Code 5 exists in the runtime and does not correspond to anything in the format
        // menu; whatever it is, it must not be flattened into body text.
        XCTAssertEqual(style(5), .other(5))
    }
}
