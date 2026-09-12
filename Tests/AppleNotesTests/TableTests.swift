//
//  TableTests.swift
//  AppleNotesTests
//
//  Created by David Sherlock on 2026.
//
//  The table decoder, against grids whose shape is known before they are decoded.
//
//  The fixtures reproduce the two things that make a table awkward: an ordered set names its
//  elements by one UUID and the cells key on a different one, and every column allocates its
//  own copy of every row key. A decoder that matched on object index instead of UUID passed
//  a naive fixture and lost the third column of a real table.
//

import XCTest
@testable import AppleNotes

final class TableTests: XCTestCase {

    func testReadsAGridInRowMajorOrder() {
        let table = TableDecoder.decode(Fixtures.table([["A1", "B1", "C1"], ["A2", "B2", "C2"]]))
        XCTAssertEqual(table?.rowCount, 2)
        XCTAssertEqual(table?.columnCount, 3)
        XCTAssertEqual(table?.rows.map { $0.map(\.text) }, [["A1", "B1", "C1"], ["A2", "B2", "C2"]])
        XCTAssertEqual(table?[1, 2], "C2")
    }

    func testKeepsEmptyCellsAndEmptyRows() {
        // The flattened summary Notes writes alongside drops these, so a 3×2 table with a
        // blank last row reads as four cells there and six here.
        let table = TableDecoder.decode(Fixtures.table([["Table", "table"],
                                                        ["Table", "table"],
                                                        ["", ""]]))
        XCTAssertEqual(table?.rowCount, 3)
        XCTAssertEqual(table?.cells.count, 6)
        XCTAssertEqual(table?.rows.last?.map(\.text), ["", ""])
    }

    func testReadsASingleCell() {
        let table = TableDecoder.decode(Fixtures.table([["only"]]))
        XCTAssertEqual(table?.rows.map { $0.map(\.text) }, [["only"]])
        XCTAssertEqual(table?.summary, "1×1 table")
    }

    func testReportsColumnDirectionWithoutApplyingIt() {
        let table = TableDecoder.decode(Fixtures.table([["A", "B"]], rightToLeft: true))
        XCTAssertEqual(table?.isRightToLeft, true)
        // Reported, not applied: the cells stay in stored order.
        XCTAssertEqual(table?.rows.map { $0.map(\.text) }, [["A", "B"]])
        XCTAssertEqual(TableDecoder.decode(Fixtures.table([["A", "B"]]))?.isRightToLeft, false)
    }

    func testKeepsCellsWithTheSameTextApart() {
        // Two cells holding the same string must not collapse into one another: if rows were
        // matched by content rather than identity this is where it would show.
        let table = TableDecoder.decode(Fixtures.table([["same", "same"], ["same", "other"]]))
        XCTAssertEqual(table?.rows.map { $0.map(\.text) }, [["same", "same"], ["same", "other"]])
    }

    func testHandlesTextThatLooksLikeProtobuf() {
        // A cell beginning with a quotation mark is 0x22 on the wire, which is also the tag
        // for a length-delimited field 4 — the shape an inline string reference takes.
        let table = TableDecoder.decode(Fixtures.table([["\"quoted\"", "plain"]]))
        XCTAssertEqual(table?.rows.map { $0.map(\.text) }, [["\"quoted\"", "plain"]])
    }

    func testIgnoresRowsThatWereDeleted() {
        // A CRDT never forgets: a deleted row stays in the ordering's contents as a
        // tombstone. The order holds only the live ones, so counting the contents would
        // report a five-row table where the note shows two.
        let table = TableDecoder.decode(Fixtures.table([["A1", "B1"], ["A2", "B2"]],
                                                       deletedRows: 3))
        XCTAssertEqual(table?.rowCount, 2)
        XCTAssertEqual(table?.rows.map { $0.map(\.text) }, [["A1", "B1"], ["A2", "B2"]])
    }

    func testTakesThePairsInEitherOrientation() {
        // The ordering's contents pair an element with the object the cells key on. Real
        // tables put the element first; the decoder does not rely on that, and this is what
        // says so rather than the comment claiming it.
        let table = TableDecoder.decode(Fixtures.table([["A1", "B1"], ["A2", "B2"]],
                                                       reversedPairs: true))
        XCTAssertEqual(table?.rows.map { $0.map(\.text) }, [["A1", "B1"], ["A2", "B2"]])
    }

    func testTakesTheOrderFromTheIndexNotTheEmissionOrder() {
        let table = TableDecoder.decode(Fixtures.table([["A1", "B1"], ["A2", "B2"]],
                                                       shuffledAttachments: true))
        XCTAssertEqual(table?.rows.map { $0.map(\.text) }, [["A1", "B1"], ["A2", "B2"]])
    }

    func testRejectsABlobThatIsNotATable() {
        XCTAssertNil(TableDecoder.decode(Data()))
        XCTAssertNil(TableDecoder.decode(Data("not protobuf at all".utf8)))
        XCTAssertNil(TableDecoder.decode(Fixtures.note([Fixtures.Run(text: "a note, not a table")])))
    }

    func testRejectsATableWithNoRowsOrNoColumns() {
        // A root object that looks like a table but has an empty axis is not a table. An
        // earlier version returned an empty grid here, which reads as "a table with nothing
        // in it" rather than "this was never a table".
        XCTAssertNil(TableDecoder.decode(Fixtures.table([])))
        XCTAssertNil(TableDecoder.decode(Fixtures.table([[], []])))
    }

    func testRendersMarkdown() {
        let table = TableDecoder.decode(Fixtures.table([["Name", "Role"], ["Ada", "Analyst"]]))
        XCTAssertEqual(table?.markdown, """
            | Name | Role |
            | --- | --- |
            | Ada | Analyst |
            """)
    }

    func testEscapesPipesInMarkdown() {
        let table = TableDecoder.decode(Fixtures.table([["a|b", "c\nd"]]))
        XCTAssertEqual(table?.markdown.contains("a\\|b"), true)
        XCTAssertEqual(table?.markdown.contains("c d"), true)
    }

    func testSubscriptStaysInsideTheTable() {
        let table = TableDecoder.decode(Fixtures.table([["A", "B"]]))
        XCTAssertNil(table?[0, 2])
        XCTAssertNil(table?[1, 0])
        XCTAssertNil(table?[-1, 0])
    }

    func testAttachmentPrefersTheGridOverTheFlattenedSummary() {
        let table = Table(rows: [["a", ""], ["c", "d"]].map { $0.map { Table.Cell(text: $0) } })
        let attachment = Attachment(id: "1", kind: .table, recognisedText: "a\nc\nd", table: table)
        XCTAssertEqual(attachment.tableCells, ["a", "", "c", "d"])

        // With no grid it falls back, and the fallback is short by the empty cell.
        let fallback = Attachment(id: "1", kind: .table, recognisedText: "a\nc\nd")
        XCTAssertEqual(fallback.tableCells, ["a", "c", "d"])
    }
}

// MARK: - The object graph underneath

/// The CRDT reader itself, apart from what a table makes of it.
final class MergeableDataTests: XCTestCase {

    private func root(_ data: Data) -> [String: MergeableData.Reference]? {
        guard case .map(_, let attributes)? = MergeableData.graph(data)?.entries.first else {
            return nil
        }
        return attributes
    }

    func testReadsTheFirstKeyEvenThoughProtobufOmitsIt() {
        // Key index 0 is written as an ABSENT field, because protobuf drops a zero varint.
        // Defaulting a missing index to anything else files every such attribute under the
        // wrong name — and quietly, because the next attribute overwrites it.
        XCTAssertEqual(root(Fixtures.table([["a"]]))?["identity"],
                       .string("00000000-0000-0000-0000-000000000000"))
    }

    func testFindsTheGraphWhateverIsWrappedRoundIt() {
        // A table's graph sits two envelopes down and an audio recording's at the top level,
        // so the reader looks for it rather than indexing to it.
        let graph = Fixtures.table([["a"]])
        XCTAssertNotNil(MergeableData.graph(graph))

        let inflated = Gzip.inflate(graph) ?? Data()
        let bare = Fixtures.message(3, in: Fixtures.message(2, in: inflated) ?? Data()) ?? Data()
        XCTAssertNotNil(MergeableData.graph(bare), "the graph unwrapped, and not gzipped")
    }

    func testReturnsNothingForBytesWithNoGraphInThem() {
        XCTAssertNil(MergeableData.graph(Data()))
        XCTAssertNil(MergeableData.graph(Data("plain text".utf8)))
        XCTAssertNil(MergeableData.graph(Fixtures.gzip(Data("plain text".utf8))))
    }

    func testResolvesAReferenceToNothingSafely() {
        let graph = MergeableData.graph(Fixtures.table([["a"]]))
        XCTAssertNil(graph?.entry(.object(9_999)))
        XCTAssertNil(graph?.entry(.string("not an object")))
        XCTAssertNil(graph?.uuid(of: .integer(3)))
        XCTAssertNil(graph?.text(of: nil))
    }
}

// MARK: - Placeholders and the attachments they stand for

/// Matching a U+FFFC placeholder to its attachment.
///
/// This used to be done by counting along two lists, and the two lists are ordered
/// independently — the placeholders in document order, the attachments in database order. On
/// a real note with three attachments that put every one of them in the wrong place.
final class AttachmentMatchingTests: XCTestCase {

    private func note(runs: [Fixtures.Run], attachments: [Attachment]) -> Note {
        Note(id: 1, identifier: "n", title: "t", snippet: "",
             blocks: BodyDecoder.decode(Fixtures.note(runs)) ?? [], attachments: attachments)
    }

    func testAPlaceholderNamesItsOwnAttachment() {
        let blocks = BodyDecoder.decode(Fixtures.note([
            .init(text: "\u{FFFC}", attachment: "AAA")])) ?? []
        XCTAssertTrue(blocks[0].isAttachmentPlaceholder)
        XCTAssertEqual(blocks[0].attachmentIdentifier, "AAA")
    }

    func testMatchesByIdentityNotByPosition() {
        // Document order is A then B; the attachments arrive B then A. Counting along puts
        // each one where the other belongs, and both lines still look plausible.
        let note = note(runs: [.init(text: "\u{FFFC}", attachment: "AAA"),
                               .init(text: "\n"),
                               .init(text: "\u{FFFC}", attachment: "BBB")],
                        attachments: [Attachment(id: "BBB", kind: .table,
                                                 table: Table(rows: [[Table.Cell(text: "B")]])),
                                      Attachment(id: "AAA", kind: .image(uti: "public.png"),
                                                 filename: "a.png")])
        let markdown = note.markdown
        let png = try! XCTUnwrap(markdown.range(of: "a.png"))
        let table = try! XCTUnwrap(markdown.range(of: "| B |"))
        XCTAssertTrue(png.lowerBound < table.lowerBound,
                      "AAA is the first placeholder whatever order the attachments arrived in")
    }

    func testFallsBackToPositionWhenNothingIsNamed() {
        // A run with no identifier still has to render something rather than vanish.
        let note = note(runs: [.init(text: "\u{FFFC}")],
                        attachments: [Attachment(id: "X", kind: .image(uti: "public.png"),
                                                 filename: "only.png")])
        XCTAssertTrue(note.markdown.contains("only.png"))
    }

    func testAPlaceholderWithNoAttachmentAtAllStillPrints() {
        let note = note(runs: [.init(text: "\u{FFFC}", attachment: "GONE")], attachments: [])
        XCTAssertEqual(note.markdown, "[attachment]")
    }

    func testTwoPlaceholdersNeverMergeIntoOne() {
        // Identically styled adjacent runs merge, which is right for text and would lose an
        // attachment: two placeholders side by side are two different things.
        let blocks = BodyDecoder.decode(Fixtures.note([
            .init(text: "\u{FFFC}", attachment: "AAA"),
            .init(text: "\u{FFFC}", attachment: "BBB")])) ?? []
        XCTAssertEqual(blocks[0].spans.count, 2)
        XCTAssertEqual(blocks[0].spans.map(\.attachmentIdentifier), ["AAA", "BBB"])
    }

    func testOrdinaryTextCarriesNoAttachment() {
        let blocks = BodyDecoder.decode(Fixtures.note([.init(text: "just words")])) ?? []
        XCTAssertNil(blocks[0].attachmentIdentifier)
        XCTAssertFalse(blocks[0].isAttachmentPlaceholder)
    }
}

// MARK: - What is inside a cell

/// A table cell is an attributed string, not a plain one.
///
/// The first version of the decoder read only the text, which dropped the URL out of a cell
/// holding a link — the words survived and the address did not. That is the same loss that
/// created `Span`, and it went unnoticed because the cell still rendered as words.
final class TableCellTests: XCTestCase {

    private func table(_ cells: [[[Fixtures.Run]]]) -> Table? {
        TableDecoder.decode(Fixtures.table(styled: cells))
    }

    func testACellKeepsALinksURL() {
        let grid = table([[[.init(text: "a "), .init(text: "link", link: "https://bbc.co.uk"),
                            .init(text: " in a cell")]]])
        XCTAssertEqual(grid?[0, 0], "a link in a cell", "the plain text is still the plain text")
        XCTAssertEqual(grid?.cell(row: 0, column: 0)?.spans.compactMap(\.link),
                       ["https://bbc.co.uk"])
        XCTAssertEqual(grid?.markdown.contains("[link](https://bbc.co.uk)"), true)
    }

    func testACellKeepsCharacterStyling() {
        let grid = table([[[.init(text: "bold", weight: 1)], [.init(text: "italic", weight: 2)]],
                          [[.init(text: "struck", strikethrough: true)],
                           [.init(text: "under", underlined: true)]]])
        XCTAssertEqual(grid?.cell(row: 0, column: 0)?.markdown, "**bold**")
        XCTAssertEqual(grid?.cell(row: 0, column: 1)?.markdown, "*italic*")
        XCTAssertEqual(grid?.cell(row: 1, column: 0)?.markdown, "~~struck~~")
        XCTAssertEqual(grid?.cell(row: 1, column: 1)?.markdown, "<u>under</u>")
    }

    func testAPlainCellIsOneSpan() {
        let cell = table([[[.init(text: "plain")]]])?.cell(row: 0, column: 0)
        XCTAssertEqual(cell?.spans.count, 1)
        XCTAssertEqual(cell?.spans.first?.isPlain, true)
        XCTAssertEqual(cell?.markdown, "plain")
    }

    func testAnEmptyCellHasNothingInIt() {
        let cell = table([[[.init(text: "")], [.init(text: "x")]]])?.cell(row: 0, column: 0)
        XCTAssertEqual(cell?.text, "")
        XCTAssertTrue(cell?.isEmpty ?? false)
        XCTAssertEqual(cell?.markdown, "")
        XCTAssertTrue(cell?.spans.isEmpty ?? false)
    }

    func testACellDoesNotReadParagraphStyles() {
        // Field 2 on a CELL run is a CRDT identifier; on a BODY run it is the paragraph
        // style. Interpreting it would invent headings and checklists inside table cells.
        let grid = table([[[.init(text: "not a heading", styleCode: 0)]]])
        XCTAssertEqual(grid?[0, 0], "not a heading")
        XCTAssertEqual(grid?.cell(row: 0, column: 0)?.markdown, "not a heading")
    }

    func testMarkdownStillEscapesAPipeInsideAStyledCell() {
        let grid = table([[[.init(text: "a|b", weight: 1)]]])
        XCTAssertEqual(grid?.markdown.contains("**a\\|b**"), true)
    }
}
