//
//  BodyDecoder.swift
//  AppleNotes
//
//  Created by David Sherlock on 2026.
//
//  A note's stored body — gzip over protobuf — turned into paragraphs.
//
//  THE FIELD NUMBERS BELOW WERE ESTABLISHED BY MEASUREMENT, not from a schema, because Apple
//  publishes none. A real note was decoded and the attribute-run lengths were summed: they
//  came to exactly the character count of the text, twice, on two different notes. That
//  reconciliation is what says field 1 is a length and field 5 is the run list rather than
//  something that merely looks plausible.
//
//  RUNS ARE NOT PARAGRAPHS and assuming they are produces nonsense. A run is a span sharing
//  one set of attributes, so a single line arrives as several — a real note split
//  "My Test Note" into runs of 1, 7 and 5 characters — and one run can also span several
//  lines. The paragraphs live in the newlines inside the text, so the styles are expanded
//  to one per character and the text is then split on newlines, each paragraph taking the
//  style at its first character.
//
//  CHARACTER STYLING RIDES THE SAME RUNS. Field 5 is a weight — 1 bold, 2 italic, which is
//  an enum rather than the flag it looks like — field 6 underline, field 7 strikethrough and
//  field 9 the link URL. The first version read only the paragraph style and so dropped every
//  link in every note: the words survived and the address, the one part nobody can retype
//  from memory, did not.
//
//  A PLACEHOLDER NAMES ITS OWN ATTACHMENT. Field 12 on the run carries the attachment's
//  identifier, which is the same `ZIDENTIFIER` the attachment row has. Before this was read,
//  placeholders were matched to attachments BY POSITION — first placeholder to first
//  attachment — which is right until it is not: the two lists are ordered independently, and
//  a note with more placeholders than attachments silently slid every one of them along by
//  one. Now the identifier decides and position is only the fallback.
//
//  LENGTHS ARE IN UTF-16 UNITS, which matters the moment a note contains an emoji. Apple
//  stores this as an attributed string and attributed strings count UTF-16; a Swift
//  `String.count` counts grapheme clusters, so an emoji would shift every style after it by
//  one. Everything here indexes UTF-16 and converts back at the end.
//

import Foundation

/// Decoding a note's body.
public enum BodyDecoder {

    /// Field numbers, measured from real notes. See the file note above.
    enum Wire {
        static let document = 2          // top level
        static let note = 3              // inside document
        static let text = 2              // inside note
        static let attributeRun = 5      // inside note, repeated
        static let runLength = 1         // inside a run
        static let paragraphStyle = 2    // inside a run
        static let styleType = 1         // inside a paragraph style
        static let indent = 4            // inside a paragraph style
        static let checklist = 5         // inside a paragraph style
        static let blockQuote = 8        // inside a paragraph style: Apple's blockQuoteLevel
        static let checklistDone = 2     // inside a checklist
        static let fontWeight = 5        // inside a run: 1 bold, 2 italic
        static let underlined = 6        // inside a run
        static let strikethrough = 7     // inside a run
        static let link = 9              // inside a run, the URL
        static let colour = 10           // inside a run: the text colour, four fixed32
        static let highlight = 14        // inside a run: which of five highlight colours
        static let attachment = 12       // inside a run: which attachment sits here
        static let attachmentID = 1      // inside that: the attachment's identifier
    }

    /// Turn a stored body into paragraphs.
    ///
    /// - Parameter data: the raw `ZICNOTEDATA.ZDATA` blob.
    /// - Returns: the paragraphs, or `nil` if the blob will not inflate or holds no note.
    public static func decode(_ data: Data) -> [Block]? {
        guard let inflated = Gzip.inflate(data) else { return nil }
        guard let document = Protobuf.message(Wire.document, in: inflated),
              let note = Protobuf.message(Wire.note, in: document),
              let textData = Protobuf.message(Wire.text, in: note),
              let text = String(data: textData, encoding: .utf8)
        else { return nil }

        let units = Array(text.utf16)
        var styles = [BlockStyle](repeating: .body, count: units.count)
        var indents = [Int](repeating: 0, count: units.count)
        var quotes = [Int](repeating: 0, count: units.count)
        var inline = [Inline](repeating: Inline(), count: units.count)

        var position = 0
        for run in Protobuf.messages(Wire.attributeRun, in: note) {
            let length = Int(Protobuf.integer(Wire.runLength, in: run) ?? 0)
            guard length > 0 else { continue }
            let end = min(position + length, units.count)
            guard position < end else { position += length; continue }

            let (style, indent, quoted) = interpret(run)
            let character = characterStyle(run)
            for i in position..<end {
                styles[i] = style
                indents[i] = indent
                quotes[i] = quoted
                inline[i] = character
            }
            position = end
        }

        return paragraphs(units: units, styles: styles, indents: indents,
                          quotes: quotes, inline: inline)
    }

    /// The style, indent and quoting a single attribute run carries.
    static func interpret(_ run: Data) -> (BlockStyle, Int, Int) {
        guard let paragraph = Protobuf.message(Wire.paragraphStyle, in: run) else {
            return (.body, 0, 0)
        }
        let indent = Int(Protobuf.integer(Wire.indent, in: paragraph) ?? 0)
        // Block quote is its own field, NOT a styleType — which is why a quoted bulleted
        // list is a thing and why looking only at styleType misses quoting entirely. Apple
        // calls it `blockQuoteLevel` and types it as an unsigned integer, so it counts
        // nesting rather than flagging it.
        let quoted = Int(Protobuf.integer(Wire.blockQuote, in: paragraph) ?? 0)

        var done = false
        if let checklist = Protobuf.message(Wire.checklist, in: paragraph) {
            done = (Protobuf.integer(Wire.checklistDone, in: checklist) ?? 0) != 0
        }
        // No style code and no checklist means ordinary body text. A paragraph style that
        // exists only to carry an indent is common and must not become `.other(0)`, which is
        // why the absence of the field is distinguished from the value zero.
        guard let code = Protobuf.integer(Wire.styleType, in: paragraph) else {
            return (.body, indent, quoted)
        }
        return (.from(code: Int(code), done: done), indent, quoted)
    }

    /// Character styling carried by one attribute run.
    struct Inline: Equatable {
        var bold = false
        var italic = false
        var underlined = false
        var strikethrough = false
        var link: String?
        var attachment: String?
        var highlight: Highlight?
        var colour: Colour?
    }

    /// The character styling on a run.
    static func characterStyle(_ run: Data) -> Inline {
        var inline = Inline()
        // A WEIGHT, not a flag: 1 is bold and 2 is italic, so testing for non-zero would
        // make every italic word bold as well.
        switch Protobuf.integer(Wire.fontWeight, in: run) {
        case 1: inline.bold = true
        case 2: inline.italic = true
        case 3: inline.bold = true; inline.italic = true
        default: break
        }
        inline.underlined = (Protobuf.integer(Wire.underlined, in: run) ?? 0) != 0
        inline.strikethrough = (Protobuf.integer(Wire.strikethrough, in: run) ?? 0) != 0
        // A code from a closed palette of five, not a colour value. See ``Highlight``.
        inline.highlight = Highlight.from(code: Int(Protobuf.integer(Wire.highlight, in: run) ?? 0))
        // The TEXT colour, and measured as such: writing `color:#FF0000` through Notes puts
        // exactly #FF0000 here, and `background-color` puts nothing anywhere. Notes has no
        // control that sets one, so in practice it arrives with pasted rich text — and it is
        // discarded on a link, which Notes always draws in its own colour.
        if let colour = Protobuf.message(Wire.colour, in: run) {
            let channels = Protobuf.fields(in: colour).compactMap { field -> Double? in
                guard case .fixed(let raw) = field.value, raw.count == 4 else { return nil }
                return Double(Float(bitPattern: raw.reversed().reduce(0) { $0 << 8 | UInt32($1) }))
            }
            if channels.count == 4 {
                inline.colour = Colour(red: channels[0], green: channels[1],
                                       blue: channels[2], alpha: channels[3])
            }
        }
        // Which attachment stands here. Present only on a placeholder run, and the same
        // identifier the attachment row carries, so the two match by identity.
        if let attachment = Protobuf.message(Wire.attachment, in: run),
           let identifier = Protobuf.message(Wire.attachmentID, in: attachment) {
            inline.attachment = String(data: identifier, encoding: .utf8)
        }
        if let url = Protobuf.message(Wire.link, in: run),
           let text = String(data: url, encoding: .utf8), !text.isEmpty {
            inline.link = text
        }
        return inline
    }

    /// Split the text on newlines, each paragraph taking the style at its first character.
    static func paragraphs(units: [UInt16], styles: [BlockStyle], indents: [Int],
                           quotes: [Int], inline: [Inline]) -> [Block] {
        var blocks: [Block] = []
        var start = 0

        func append(upTo end: Int) {
            guard start < end || start < units.count else { return }
            let slice = Array(units[start..<end])
            let text = String(decoding: slice, as: UTF16.self)
            let style = start < styles.count ? styles[start] : .body
            let indent = start < indents.count ? indents[start] : 0
            // An empty line between paragraphs carries no style worth keeping, but it IS a
            // blank line and dropping it would reflow someone's note.
            blocks.append(Block(text: text, style: text.isEmpty ? .body : style, indent: indent,
                                blockQuoteLevel: start < quotes.count ? quotes[start] : 0,
                                spans: spans(units: units, inline: inline, from: start, to: end)))
        }

        for i in 0..<units.count where units[i] == 0x000A {   // \n
            append(upTo: i)
            start = i + 1
        }
        if start < units.count { append(upTo: units.count) }
        return blocks
    }

    /// Spans for a run of text carrying attribute runs but no paragraphs.
    ///
    /// A TABLE CELL IS THIS. Its text is an attributed string with the same character-style
    /// vocabulary a note body uses — weight, underline, strikethrough, colour, and the link
    /// URL — and reading only the plain text throws the URL away, which is the exact loss
    /// this library treats as a bug rather than a rendering choice.
    ///
    /// Paragraph styles are NOT read here, because a cell's runs do not carry one: field 2
    /// on a cell run is a CRDT identifier where on a body run it is the paragraph style.
    /// Interpreting it as a style would invent headings inside table cells.
    ///
    /// - Parameters:
    ///   - text: the whole string the runs describe.
    ///   - runs: the attribute runs, in order.
    static func characterSpans(text: String, runs: [Data]) -> [Span] {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return [] }
        var inline = [Inline](repeating: Inline(), count: units.count)

        var position = 0
        for run in runs {
            let length = Int(Protobuf.integer(Wire.runLength, in: run) ?? 0)
            guard length > 0 else { continue }
            let end = min(position + length, units.count)
            guard position < end else { position += length; continue }
            let style = characterStyle(run)
            for index in position..<end { inline[index] = style }
            position = end
        }
        return spans(units: units, inline: inline, from: 0, to: units.count)
    }

    /// Group a paragraph's characters into runs of identical styling.
    ///
    /// Adjacent characters that agree are merged, because Notes splits runs for reasons of
    /// its own — a real note broke "My Test Note" into three — and one span per character
    /// would make the Markdown unreadable.
    static func spans(units: [UInt16], inline: [Inline], from start: Int, to end: Int) -> [Span] {
        guard start < end, end <= units.count else { return [] }
        var spans: [Span] = []
        var runStart = start

        func flush(_ upTo: Int) {
            guard runStart < upTo else { return }
            let text = String(decoding: Array(units[runStart..<upTo]), as: UTF16.self)
            let style = runStart < inline.count ? inline[runStart] : Inline()
            spans.append(Span(text: text, bold: style.bold, italic: style.italic,
                              underlined: style.underlined, strikethrough: style.strikethrough,
                              link: style.link, highlight: style.highlight,
                              colour: style.colour, attachmentIdentifier: style.attachment))
        }

        for i in (start + 1)..<end where i < inline.count && inline[i] != inline[runStart] {
            flush(i)
            runStart = i
        }
        flush(end)
        return spans
    }
}
