//
//  Note.swift
//  AppleNotes
//
//  Created by David Sherlock on 2026.
//
//  One note: its metadata always, its body when asked for.
//
//  ``blocks`` is empty until a note is read rather than listed, because decoding a body
//  means inflating a gzip stream and walking a protobuf, and a listing of a thousand notes
//  should not pay that to print a thousand titles.
//

import Foundation

/// A note.
public struct Note: Equatable, Hashable, Sendable, Codable, Identifiable {

    /// The row identifier, stable within this database.
    public let id: Int

    /// Apple's own identifier, stable across devices.
    public let identifier: String?

    /// The title Notes displays, which is its first line.
    public let title: String

    /// The preview line Notes shows under the title in its list.
    public let snippet: String?

    /// The folder it sits in.
    public let folder: String?

    /// The account it belongs to.
    public let account: String?

    public let created: Date?
    public let modified: Date?

    /// Whether it is pinned to the top of its folder.
    public let isPinned: Bool

    /// Whether it sits in Recently Deleted.
    public let isDeleted: Bool

    /// Whether it is locked with a password.
    ///
    /// A locked note's body is encrypted and this library does not attempt it: the
    /// passphrase is the user's and belongs nowhere near a command line. Metadata still
    /// reads, so a locked note is listed rather than hidden.
    public let isLocked: Bool

    /// The paragraphs of the body. Empty unless the note was read.
    public let blocks: [Block]

    /// What is embedded in it. Empty unless the note was read.
    public let attachments: [Attachment]

    public init(id: Int, identifier: String? = nil, title: String, snippet: String? = nil,
                folder: String? = nil, account: String? = nil,
                created: Date? = nil, modified: Date? = nil,
                isPinned: Bool = false, isDeleted: Bool = false, isLocked: Bool = false,
                blocks: [Block] = [], attachments: [Attachment] = []) {
        self.id = id
        self.identifier = identifier
        self.title = title
        self.snippet = snippet
        self.folder = folder
        self.account = account
        self.created = created
        self.modified = modified
        self.isPinned = isPinned
        self.isDeleted = isDeleted
        self.isLocked = isLocked
        self.blocks = blocks
        self.attachments = attachments
    }

    /// The hashtags written in the note, without their leading `#`.
    ///
    /// Read from the text, not from Apple's index — see ``Tags``. Empty until the note is
    /// read, like ``blocks``, because there is no body to search before then.
    public var tags: [String] { Tags.found(in: text) }

    /// The body as plain text, one paragraph per line.
    public var text: String {
        blocks.filter { !$0.isAttachmentPlaceholder }.map(\.text).joined(separator: "\n")
    }

    /// The body as Markdown, with attachments named where they sit.
    ///
    /// A placeholder becomes a line naming what is there — including any text macOS already
    /// recognised in it — because an attachment silently vanishing from an export is worse
    /// than an imperfect rendering of it.
    ///
    /// A TABLE IS THE EXCEPTION and renders as a Markdown table, because that is a thing
    /// Markdown can actually say. Everything else gets a one-line description.
    public var markdown: String {
        // By identity first: a placeholder names its own attachment. Position is only the
        // fallback, for a note whose runs predate that field or whose lists disagree.
        let byIdentifier = Dictionary(attachments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var attachmentIndex = 0
        var lines: [String] = []
        for block in blocks {
            if block.isAttachmentPlaceholder {
                let named = block.attachmentIdentifier.flatMap { byIdentifier[$0] }
                if let attachment = named ?? (attachmentIndex < attachments.count
                                              ? attachments[attachmentIndex] : nil) {
                    lines.append(attachment.table?.markdown ?? "[\(attachment.summary)]")
                    attachmentIndex += 1
                } else {
                    lines.append("[attachment]")
                }
            } else {
                lines.append(block.markdown)
            }
        }
        return lines.joined(separator: "\n")
    }
}
