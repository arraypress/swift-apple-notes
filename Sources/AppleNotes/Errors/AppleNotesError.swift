//
//  AppleNotesError.swift
//  AppleNotes
//
//  Created by David Sherlock on 2026.
//
//  Every way reading the Notes store can fail, each saying what to do about it.
//
//  ``permissionDenied`` carries the fix in its message on purpose. The store lives inside a
//  TCC-protected container, so the first thing anyone meets is a refusal that looks like a
//  missing file — and the answer is a checkbox in System Settings that nothing about the
//  error would otherwise suggest.
//

import Foundation

/// A failure reading the Notes store.
public enum AppleNotesError: Error, LocalizedError, Equatable, Sendable {

    /// No Notes database on this machine.
    case storeNotFound(URL)

    /// The database exists and macOS refused to open it.
    case permissionDenied(URL)

    /// SQLite refused the file or a query.
    case databaseError(String)

    /// A note's body would not inflate or would not parse.
    case undecodableBody(noteID: Int)

    /// No note with that identifier.
    case noteNotFound(String)

    /// Notes.app refused a write, or could not be asked.
    ///
    /// Carries whatever osascript said, which is usually specific enough to act on — a
    /// missing folder names the folder, and a refused Automation permission says so.
    case scriptFailed(String)

    public var errorDescription: String? {
        switch self {
        case .storeNotFound(let url):
            return "No Notes database at \(url.path). Notes may never have been opened on this Mac."
        case .permissionDenied(let url):
            return """
                Permission denied reading \(url.path).
                The Notes store is protected by macOS privacy controls: grant Full Disk \
                Access to the program running this (System Settings ▸ Privacy & Security ▸ \
                Full Disk Access), then try again.
                """
        case .databaseError(let detail):
            return "Notes database error: \(detail)"
        case .undecodableBody(let id):
            return "The body of note \(id) could not be decoded."
        case .noteNotFound(let reference):
            return "No note matching \(reference)."
        case .scriptFailed(let detail):
            return detail.isEmpty ? "Notes refused the change." : "Notes refused the change: \(detail)"
        }
    }
}
