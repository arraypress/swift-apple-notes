//
//  AttachmentKind.swift
//  AppleNotes
//
//  Created by David Sherlock on 2026.
//
//  What an attachment IS, from the uniform type identifier Notes stores against it.
//
//  Every case below was seen on a real note built to exercise it. What macOS has
//  already worked out about each — OCR'd text, a classifier's reading — comes along for the
//  price of reading a column; see ``Attachment/recognisedText`` for which parts of that are
//  verified and which are not.
//

import Foundation

/// The kind of thing attached to a note.
public enum AttachmentKind: Equatable, Hashable, Sendable, Codable {

    /// A drawing — `com.apple.paper`. Its strokes live in a SQLite store of its own; the
    /// handwriting summary beside it IS read off them. See ``Attachment/drawing``.
    case drawing
    /// A table — `com.apple.notes.table`. Its cells live in a separate CRDT blob, decoded
    /// into a grid by ``Attachment/table``.
    case table
    /// An image, by its own type — `public.png`, `public.jpeg` and the rest.
    case image(uti: String)

    /// A recording made in the note — `com.apple.m4a-audio`.
    case audio(uti: String)
    /// Anything else, keeping the identifier rather than discarding it.
    case file(uti: String)

    /// The kind for a uniform type identifier.
    ///
    /// - Parameter uti: the `ZTYPEUTI` recorded against the attachment.
    public static func from(uti: String) -> AttachmentKind {
        switch uti {
        case "com.apple.paper", "com.apple.drawing", "com.apple.drawing.2":
            return .drawing
        case "com.apple.notes.table":
            return .table
        case let value where isAudio(value):
            return .audio(uti: value)
        case let value where value.hasPrefix("public.") && isImage(value):
            return .image(uti: value)
        case let value:
            return .file(uti: value)
        }
    }

    private static func isAudio(_ uti: String) -> Bool {
        ["com.apple.m4a-audio", "public.mpeg-4-audio", "public.mp3", "public.audio",
         "com.apple.coreaudio-format", "public.aiff-audio"].contains(uti)
    }

    private static func isImage(_ uti: String) -> Bool {
        ["public.png", "public.jpeg", "public.heic", "public.tiff", "public.gif",
         "public.image", "public.webp"].contains(uti)
    }

    /// A short word for the kind, for a listing.
    public var name: String {
        switch self {
        case .drawing:            return "drawing"
        case .table:              return "table"
        case .image(let uti):     return uti.replacingOccurrences(of: "public.", with: "")
        case .audio:              return "audio"

        case .file(let uti):      return uti
        }
    }
}
