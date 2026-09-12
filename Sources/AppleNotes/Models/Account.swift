//
//  Account.swift
//  AppleNotes
//
//  Created by David Sherlock on 2026.
//
//  One of the accounts a library's notes belong to.
//
//  Usually one — an iCloud account — but Notes also carries "On My Mac" for anything local,
//  and one per IMAP account that has notes turned on. They matter for two reasons: a folder
//  name is only unique WITHIN an account, so moving a note to "Notes" is ambiguous across
//  two of them; and an account is where the attachment files live on disk, under its
//  ``identifier``.
//
//  `ZISPASSWORDPROTECTED` is on the ACCOUNT as well as the note, and it means the account has
//  a password set rather than that everything in it is locked. It is not read here, because
//  the only honest thing to do with it is ignore it: what a caller wants to know is whether a
//  given note is locked, and ``Note/isLocked`` answers that.
//

import Foundation

/// An account holding notes.
public struct Account: Equatable, Hashable, Sendable, Codable, Identifiable {

    /// The row id.
    public let id: Int

    /// Apple's stable identifier — also the directory attachment files live under.
    public let identifier: String

    /// What Notes shows in the sidebar: "iCloud", "On My Mac".
    public let name: String

    /// How many notes it holds, Recently Deleted excluded.
    public let noteCount: Int

    /// How many folders it holds, Recently Deleted included.
    public let folderCount: Int

    public init(id: Int, identifier: String, name: String,
                noteCount: Int = 0, folderCount: Int = 0) {
        self.id = id
        self.identifier = identifier
        self.name = name
        self.noteCount = noteCount
        self.folderCount = folderCount
    }
}
