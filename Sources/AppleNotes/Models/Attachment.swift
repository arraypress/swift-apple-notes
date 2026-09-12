//
//  Attachment.swift
//  AppleNotes
//
//  Created by David Sherlock on 2026.
//
//  Something embedded in a note, and whatever Apple already worked out about it.
//
//  ``recognisedText`` is the reason this type earns its place: macOS does the work anyway and
//  leaves the answer in the same database, so a reader gets it for free with no model.
//
//  WHAT IS VERIFIED, on a real note. `ZOCRSUMMARY` on a PNG held the actual text from a
//  screenshot, and `ZSUMMARY` held a classifier's reading of it — "Document Documents Papers
//  Written Document". Both confirmed.
//
//  A TABLE IS DIFFERENT and is decoded rather than summarised — see ``table``. Apple writes a
//  flattened reading of one into the same summary column, and it drops empty cells, so a
//  table with a blank row arrives short with no hint that anything is missing.
//
//  A DRAWING IS NOT IN THIS DATABASE AT ALL — see ``drawing``. Its contents are in a SQLite
//  store of their own inside a `.bundle` beside the notes database, which is why every
//  drawing has a NULL `ZMERGEABLEDATA1` and looks empty to a reader that stops here.
//
//  HANDWRITING IS RECOGNISED, and that is now measured rather than assumed. Two drawings
//  containing nothing but freehand scribble — no text box anywhere in either — came back with
//  `ZHANDWRITINGSUMMARY` holding "③" and "}". Nonsense, because the input was nonsense, but
//  nonsense that could only have come from the strokes. An earlier version of this comment
//  said the opposite, on the strength of one drawing whose summary held TYPED text.
//
//  WHAT IS STILL UNTESTED is how well it reads real handwriting, for want of anything legibly
//  handwritten to try. So: the column is fed by the recogniser, and nothing here claims the
//  answer is right.

import Foundation

/// A file, drawing or table embedded in a note.
public struct Attachment: Equatable, Hashable, Sendable, Codable, Identifiable {

    /// Apple's stable identifier for the attachment.
    public let id: String

    /// What kind of thing it is.
    public let kind: AttachmentKind

    /// The original filename, when it had one.
    public let filename: String?

    /// A title Notes shows for it, such as a link's page title.
    public let title: String?

    /// What macOS already recognised inside it, without being asked.
    ///
    /// Handwriting recognition for a drawing, OCR for an image, a classifier's summary for
    /// a photograph — whichever the system produced. `nil` when it produced nothing.
    ///
    /// For a drawing this really is read off the strokes: two scribbles with no text box in
    /// either produced "③" and "}". It is only as good as the handwriting, and a scribble
    /// gets a scribble's answer.
    public let recognisedText: String?

    /// When it was added.
    public let created: Date?

    /// When it last changed.
    public let modified: Date?

    /// The grid, when this is a table.
    ///
    /// Reconstructed from the CRDT Notes stores, so empty cells and empty rows are present
    /// and the cells are in a shape rather than an order. `nil` for everything that is not a
    /// table, and for a table whose stored blob will not decode.
    public let table: Table?

    /// What is in it, when this is a drawing.
    ///
    /// Read from the drawing's own bundle: canvas size, the inks used and their colours, and
    /// any signature as a path. `nil` for everything that is not a drawing.
    public let drawing: Drawing?

    /// What macOS heard, when this is an audio recording.
    ///
    /// Word by word, each with the second it starts and how long it lasts. `nil` when the
    /// recording has not been transcribed — which is what an untranscribed one looks like,
    /// container present and empty.
    public let transcript: Transcript?

    /// The file holding this attachment's bytes, when there is one.
    ///
    /// An image, a recording, a scanned document — the original, in the group container, at
    /// the path macOS put it. `nil` for the attachments that have no file of their own:
    /// tables live in the database and drawings in a bundle.
    public let url: URL?

    public init(id: String, kind: AttachmentKind, filename: String? = nil, title: String? = nil,
                recognisedText: String? = nil, created: Date? = nil, modified: Date? = nil,
                table: Table? = nil, drawing: Drawing? = nil, transcript: Transcript? = nil,
                url: URL? = nil) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.title = title
        self.recognisedText = recognisedText
        self.created = created
        self.modified = modified
        self.table = table
        self.drawing = drawing
        self.transcript = transcript
        self.url = url
    }

    /// A table's cells, row by row.
    ///
    /// Every cell including the empty ones, which is what separates this from the flattened
    /// summary Notes writes. Empty for everything that is not a table.
    ///
    /// Falls back to that summary when the blob will not decode, and the fallback is the
    /// weaker answer on purpose: it silently omits empty cells, so its count cannot be
    /// trusted to be rows times columns.
    public var tableCells: [String] {
        guard case .table = kind else { return [] }
        if let table { return table.cells }
        return (recognisedText ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A one-line description for a listing.
    public var summary: String {
        // A drawing's own summary already names itself, so it replaces the kind rather
        // than following it — otherwise the line reads "drawing · 768×665 drawing".
        var parts = drawing == nil ? [kind.name] : []
        if let filename { parts.append(filename) }
        else if let title, !title.isEmpty { parts.append(title) }
        if let drawing {
            parts.append(drawing.summary)
        } else if let transcript {
            parts.append(transcript.summary)
        } else if let table {
            parts.append(table.summary)
            parts.append(table.cells.prefix(6).map { $0.isEmpty ? "·" : $0 }.joined(separator: " | "))
        } else if case .table = kind, !tableCells.isEmpty {
            parts.append("\(tableCells.count) cells: " + tableCells.prefix(6).joined(separator: " | "))
        } else if let recognisedText, !recognisedText.isEmpty {
            let flat = recognisedText.replacingOccurrences(of: "\n", with: " ")
            parts.append("“\(flat.prefix(60))”")
        }
        return parts.joined(separator: " · ")
    }
}
