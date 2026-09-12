//
//  Block.swift
//  AppleNotes
//
//  Created by David Sherlock on 2026.
//
//  One paragraph of a note: its text, its style, and how deeply it is indented.
//
//  Notes does not store paragraphs. It stores one string and a list of runs, each carrying a
//  length and a style, and the paragraphs are implied by the newlines inside that string —
//  which is why a run can cover half a line and why two consecutive runs can belong to the
//  same paragraph. ``BodyDecoder`` does that reassembly; this is what comes out.
//

import Foundation

/// A paragraph of note text.
public struct Block: Equatable, Hashable, Sendable, Codable {

    /// The paragraph's text, with its trailing newline removed.
    public let text: String

    /// The paragraph broken into runs of shared character styling.
    ///
    /// Always covers the whole paragraph: an unstyled one is a single plain span. Reading
    /// ``text`` and ignoring this loses links, which is what the first version did.
    public let spans: [Span]

    /// How the paragraph is styled.
    public let style: BlockStyle

    /// Indent level, 0 at the margin. Nested list items count up from there.
    public let indent: Int

    /// How deeply the paragraph is quoted, 0 for not at all.
    ///
    /// A LEVEL, not a flag, and named `blockQuoteLevel` by Apple — confirmed by reading
    /// `ICTTParagraphStyle` out of the Objective-C runtime, where it is a `UInt64` beside
    /// `indent` and `startingItemNumber`. Quotes nest, so a boolean would flatten them.
    ///
    /// It is also a MODIFIER rather than a style, which is why it sits apart from
    /// ``BlockStyle``: a quoted bulleted list is a real thing. The format menu agrees,
    /// putting Block Quote below a separator from the mutually exclusive styles above it.
    public let blockQuoteLevel: Int

    /// Whether the paragraph is quoted at all.
    public var isBlockQuote: Bool { blockQuoteLevel > 0 }

    /// Whether this paragraph is an attachment placeholder rather than text.
    ///
    /// Notes marks an attachment's position in the string with U+FFFC, the object
    /// replacement character, so a paragraph that is nothing but that character is where a
    /// drawing, table or image sits.
    public var isAttachmentPlaceholder: Bool {
        !text.isEmpty && text.allSatisfy { $0 == "\u{FFFC}" }
    }

    /// Which attachment sits here, when this is a placeholder.
    ///
    /// The placeholder NAMES its attachment — the identifier is on the run, and it is the
    /// same one the attachment row carries. Matching the two lists by counting along them
    /// instead is right until it is not: they are ordered independently, and one extra
    /// placeholder slides every attachment after it along by one.
    public var attachmentIdentifier: String? {
        spans.first(where: { $0.attachmentIdentifier != nil })?.attachmentIdentifier
    }

    public init(text: String, style: BlockStyle, indent: Int = 0,
                blockQuoteLevel: Int = 0, spans: [Span]? = nil) {
        self.text = text
        self.style = style
        self.indent = indent
        self.blockQuoteLevel = max(0, blockQuoteLevel)
        self.spans = spans ?? [Span(text: text)]
    }

    /// The paragraph as Markdown, indented and prefixed for its style.
    public var markdown: String {
        if isAttachmentPlaceholder { return "" }
        let padding = String(repeating: "  ", count: max(0, indent))
        // The quote mark goes outside the indent and the list marker both, because that is
        // what Markdown means by a quoted list item.
        let quote = String(repeating: "> ", count: blockQuoteLevel)
        // Monospaced is a paragraph style and a code span is already literal, so character
        // marks inside one would be shown rather than applied.
        if case .monospaced = style { return quote + padding + "`" + text + "`" }
        // A heading is bold in Notes by definition, and a Markdown import marks the text
        // bold on top of that — so rendering both gives `# **Title**`, which is accurate and
        // noise. The same argument the link/underline rule makes in ``Span``.
        let inline = style.isHeading
            ? spans.map { $0.bold ? Span(text: $0.text, italic: $0.italic,
                                         underlined: $0.underlined,
                                         strikethrough: $0.strikethrough, link: $0.link,
                                         highlight: $0.highlight, colour: $0.colour).markdown
                                  : $0.markdown }.joined()
            : spans.map(\.markdown).joined()
        return quote + padding + style.markdownPrefix + (inline.isEmpty ? text : inline)
    }
}
