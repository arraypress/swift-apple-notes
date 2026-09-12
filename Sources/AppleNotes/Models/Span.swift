//
//  Span.swift
//  AppleNotes
//
//  Created by David Sherlock on 2026.
//
//  A stretch of text inside a paragraph that shares its character styling.
//
//  This exists because the first version threw links away. A paragraph carried its text and
//  its paragraph style and nothing else, so "a link to example.com" survived as those words
//  and `https://example.com/` — the only part that could not be retyped from memory — was
//  silently dropped. Bold, italic, underline and strikethrough went the same way.
//
//  The styling lives on the same attribute runs the paragraph styles come from, so reading it
//  costs nothing extra; it was simply not being read.
//

import Foundation

/// A run of text within a paragraph sharing one set of character attributes.
public struct Span: Equatable, Hashable, Sendable, Codable {

    public let text: String
    public let bold: Bool
    public let italic: Bool
    public let underlined: Bool
    public let strikethrough: Bool

    /// Where the text links to, if anywhere.
    ///
    /// A `String` rather than a `URL` on purpose: Notes will happily hold something `URL`
    /// refuses to parse, and dropping a malformed link is the very loss this type was added
    /// to stop.
    public let link: String?

    /// The colour highlighting this span, if any.
    public let highlight: Highlight?

    /// The colour of the text itself, if it carries one.
    ///
    /// Notes has no control that sets this, so it arrives with pasted rich text and keeps
    /// whatever the source had. It is discarded on a link — Notes always draws those in its
    /// own colour — which is why a coloured link comes back with the link and not the colour.
    public let colour: Colour?

    /// The attachment standing where this span's text does.
    ///
    /// Set only on a U+FFFC placeholder, and it is the attachment's own identifier — so a
    /// caller matches the two up by identity rather than by counting along two lists that
    /// are ordered independently.
    public let attachmentIdentifier: String?

    public init(text: String, bold: Bool = false, italic: Bool = false,
                underlined: Bool = false, strikethrough: Bool = false, link: String? = nil,
                highlight: Highlight? = nil, colour: Colour? = nil,
                attachmentIdentifier: String? = nil) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.underlined = underlined
        self.strikethrough = strikethrough
        self.link = link
        self.highlight = highlight
        self.colour = colour
        self.attachmentIdentifier = attachmentIdentifier
    }

    /// Whether this span carries any styling at all.
    public var isPlain: Bool {
        !bold && !italic && !underlined && !strikethrough && link == nil && highlight == nil && colour == nil
    }

    /// The span as Markdown.
    ///
    /// Underline has no Markdown of its own, so it borrows the HTML tag the format allows
    /// rather than being silently dropped or quietly turned into emphasis it is not.
    ///
    /// Highlighting borrows `<mark>` for the same reason, and carries its colour in a class
    /// rather than an inline style: the class keeps Apple's NAME, which is measured, where a
    /// style would need an RGB value, which is not.
    public var markdown: String {
        guard !text.isEmpty else { return "" }
        // Marks go on the trimmed text: `** bold **` is not bold in any renderer, and
        // Notes routinely leaves a trailing space inside a styled run.
        let leading = String(text.prefix(while: \.isWhitespace))
        let trailing = String(text.reversed().prefix(while: \.isWhitespace).reversed())
        var core = String(text.dropFirst(leading.count).dropLast(trailing.count))
        guard !core.isEmpty else { return text }

        if strikethrough { core = "~~\(core)~~" }
        if bold { core = "**\(core)**" }
        if italic { core = "*\(core)*" }
        // A link is underlined by convention and Notes marks it so, which means the
        // underline carries no information a link does not already carry. Emitting both
        // gives `[<u>text</u>](url)` — accurate, and noise.
        if underlined, link == nil { core = "<u>\(core)</u>" }
        // A colour DOES get an inline style where a highlight does not, and the difference
        // is what is known: this is a measured RGB value, where a highlight is a name whose
        // pixels were never measured.
        if let colour { core = "<span style=\"color:\(colour.hex)\">\(core)</span>" }
        if let highlight { core = "<mark class=\"\(highlight.name)\">\(core)</mark>" }
        if let link { core = "[\(core)](\(link))" }
        return leading + core + trailing
    }
}
