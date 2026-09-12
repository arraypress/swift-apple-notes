//
//  Folder.swift
//  AppleNotes
//
//  Created by David Sherlock on 2026.
//
//  A folder, including the one Notes hides from AppleScript.
//
//  ``parentID`` exists because folders nest and the AppleScript interface cannot see it —
//  the reference tools built on AppleScript document "only notes in top-level folders are
//  accessible" as a limitation. Reading the store directly has no such problem, so nesting
//  is carried here whether or not a given library uses it.
//

import Foundation

/// A folder of notes.
public struct Folder: Equatable, Hashable, Sendable, Codable, Identifiable {

    /// The row identifier, stable within this database.
    public let id: Int

    /// The folder's name.
    public let name: String

    /// The account it belongs to, such as `iCloud`.
    public let account: String?

    /// The folder containing this one, or `nil` at the top level.
    public let parentID: Int?

    /// Whether this is the Recently Deleted folder.
    ///
    /// Its notes still exist and still decode. They are excluded from listings by default
    /// because a deleted note showing up in a search reads as a bug, and included on
    /// request because "what did I just delete" is a real question.
    public let isRecentlyDeleted: Bool

    /// How many notes it holds, deleted ones included.
    public let noteCount: Int

    /// Whether this folder exists only in the local database.
    ///
    /// A live folder in a CloudKit account carries a server record. Fourteen folders on one
    /// real machine did not — remnants with names like "Quick Notes" and "WooCommerce" that
    /// Notes.app does not show and AppleScript flatly denies exist, while the two real ones
    /// had records. Reporting them makes a tool disagree with the app in front of the user,
    /// and moving a note into one fails with "Can't get folder".
    ///
    /// TWO KNOWN LIMITS, both found by testing rather than reasoned about.
    ///
    /// An On My Mac account has no server records at all, so on a machine with one this
    /// would mark every local folder orphaned.
    ///
    /// And the test has a FALSE NEGATIVE. A folder created through AppleScript, used
    /// successfully as the destination of a move, and then left empty, kept its server
    /// record and its zero deletion flags — and AppleScript stopped listing it. So a folder
    /// passing this check is not guaranteed to be one Notes.app shows. The check still earns
    /// its place, because it correctly hides fourteen phantoms out of sixteen folders on a
    /// real machine, but it is a heuristic and not a verdict.
    public let isOrphaned: Bool

    public init(id: Int, name: String, account: String? = nil, parentID: Int? = nil,
                isRecentlyDeleted: Bool = false, noteCount: Int = 0, isOrphaned: Bool = false) {
        self.id = id
        self.name = name
        self.account = account
        self.parentID = parentID
        self.isRecentlyDeleted = isRecentlyDeleted
        self.noteCount = noteCount
        self.isOrphaned = isOrphaned
    }
}
