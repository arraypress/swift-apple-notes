//
//  Table.swift
//  AppleNotes
//
//  Created by David Sherlock on 2026.
//
//  A table in a note, as a grid.
//
//  THE GRID IS RECONSTRUCTED, not read. Notes also writes a flattened reading of every cell
//  into the same summary column it uses for OCR, which is free and nearly useless: it drops
//  empty cells silently, so a 3×2 table with a blank last row arrives as four cells and no
//  hint that a row is missing. A real table in this library did exactly that. The grid here
//  comes from the CRDT instead and reports all six.
//
//  ROW-MAJOR IS MEASURED. A 2×3 table reading A1 B1 C1 / A2 B2 C2 was decoded and the cells
//  landed where their names say they should, which is what settles a question the flattened
//  summary cannot answer: whether its order runs along rows or down columns.
//
//  A CELL IS NOT A STRING. Its text is an attributed string carrying the same character
//  styling a note body does — bold, italic, underline, strikethrough, colour, and a link URL.
//  The first version of this type read only the plain text, which dropped the URL out of a
//  cell holding a link: the words survived and the address did not. That is the same loss
//  that created ``Span``, so a cell carries spans.
//

import Foundation

/// A table embedded in a note.
public struct Table: Equatable, Hashable, Sendable, Codable {

    /// One cell.
    public struct Cell: Equatable, Hashable, Sendable, Codable {

        /// The cell's text, with no marks.
        public let text: String

        /// The text broken into runs of shared character styling.
        ///
        /// Always covers the whole cell: an unstyled one is a single plain span. Reading
        /// ``text`` and ignoring this loses a link's URL.
        public let spans: [Span]

        public init(text: String, spans: [Span] = []) {
            self.text = text
            self.spans = spans.isEmpty && !text.isEmpty ? [Span(text: text)] : spans
        }

        /// The cell as Markdown, styling included.
        public var markdown: String { spans.map(\.markdown).joined() }

        /// Whether the cell holds nothing.
        public var isEmpty: Bool { text.isEmpty }
    }

    /// The cells, outer array rows, inner array columns.
    ///
    /// Rectangular: a cell no column wrote is an empty one rather than a missing entry, so
    /// `rows[r][c]` is safe for every `r` and `c` inside the counts.
    public let rows: [[Cell]]

    /// Whether the columns run right to left.
    ///
    /// Read from the table's own `crTableColumnDirection`. It is REPORTED AND NOT APPLIED —
    /// the cells stay in stored order — because no right-to-left table was available to
    /// establish whether Apple stores those columns reversed or renders them reversed, and
    /// guessing wrong would silently mirror somebody's table.
    public let isRightToLeft: Bool

    public init(rows: [[Cell]], isRightToLeft: Bool = false) {
        self.rows = rows
        self.isRightToLeft = isRightToLeft
    }

    /// How many rows.
    public var rowCount: Int { rows.count }

    /// How many columns.
    public var columnCount: Int { rows.first?.count ?? 0 }

    /// Every cell's text, row by row.
    public var cells: [String] { rows.flatMap { $0 }.map(\.text) }

    /// One cell's text, or `nil` if either index is outside the table.
    public subscript(row: Int, column: Int) -> String? {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return nil }
        return rows[row][column].text
    }

    /// One cell with its styling, or `nil` if either index is outside the table.
    public func cell(row: Int, column: Int) -> Cell? {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return nil }
        return rows[row][column]
    }

    /// The table as a Markdown table.
    ///
    /// The first row becomes the header, because Markdown has no way to write a table
    /// without one. Notes does not mark a header row, so this is a rendering decision and
    /// not a claim about the table.
    public var markdown: String {
        guard let first = rows.first else { return "" }
        func line(_ cells: [Cell]) -> String {
            "| " + cells.map { $0.markdown.replacingOccurrences(of: "|", with: "\\|")
                                          .replacingOccurrences(of: "\n", with: " ") }
                        .joined(separator: " | ") + " |"
        }
        let rule = "| " + Array(repeating: "---", count: first.count).joined(separator: " | ") + " |"
        return ([line(first), rule] + rows.dropFirst().map(line)).joined(separator: "\n")
    }

    /// A one-line description for a listing.
    public var summary: String {
        "\(rowCount)×\(columnCount) table" + (isRightToLeft ? " (right to left)" : "")
    }
}
