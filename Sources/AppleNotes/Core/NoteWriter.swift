//
//  NoteWriter.swift
//  AppleNotes
//
//  Created by David Sherlock on 2026.
//
//  Creating and appending to notes — through Notes.app, never through its database.
//
//  READS GO ROUND THE APP AND WRITES GO THROUGH IT, and the asymmetry is deliberate rather
//  than lazy. Reading the store is fast, complete and provably harmless. Writing to it is
//  none of those: that database is one half of a CloudKit sync, and the other half is a
//  server holding a change token, a record for every note and a version vector per field.
//  Editing the local copy behind Notes.app's back leaves those disagreeing, and what comes
//  back is not an error but a silent conflict resolved in favour of whichever side the
//  server believes — which can mean the edit vanishing, or the note doing so.
//
//  AppleScript is slow and limited, and for writing neither matters: a person adds one note,
//  not ten thousand, and Notes.app updates its own indexes, its own snippet, its own search
//  state and its own sync records as a consequence of being asked properly.
//
//  WHAT CANNOT BE WRITTEN, because the scripting dictionary has no property for it: PINNING
//  and TAGS. A note exposes name, id, container, body, plaintext, the two dates, password
//  protected and shared, and nothing else. Pinned state reads perfectly well from the store
//  and there is no supported way to set it — the only route would be driving the menu through
//  Accessibility, which needs another permission, breaks on any UI change, and is exactly the
//  kind of automation this library exists to avoid. Locking is left alone on principle: it
//  takes the user's passphrase, which belongs nowhere near this.
//
//  THE ESCAPING IS THE SECURITY BOUNDARY. Note text is arbitrary and goes into an AppleScript
//  string literal; a body containing a quotation mark would otherwise end the literal and the
//  rest would be executed as script. Everything user-supplied goes through ``escape(_:)``,
//  and the tests include a body that tries exactly that.
//

//  WHAT CAN AND CANNOT BE WRITTEN, and WHY — established by calling Apple's own importer
//  rather than by guessing at tags. `+[ICNote attributedStringFromHTMLString:]` is a generic
//  Cocoa HTML reader: hand it `<h1>` and it returns an `NSFont` of bold 24pt; hand it
//  `<blockquote>` and it returns an `NSPresentationIntent`; hand it any checklist markup at
//  all and it returns nothing. It NEVER produces an `ICTTParagraphStyle`.
//
//  So Notes' own paragraph styles are unreachable from here, and the ones that do survive
//  survive because Notes infers them afterwards from ordinary Cocoa attributes: an
//  `NSTextList` becomes bulleted, dashed or numbered, and a Courier font becomes monospaced.
//  Nothing infers a title, a heading, a checklist or a quote — a checklist item needs an
//  `ICTTTodo` carrying its own UUID, and an HTML reader has no way to make one.
//
//  THE CEILING OF THIS DOOR — what AppleScript accepts: bold, italic, underline,
//  strikethrough, links, text colour, `<ul>`, `<ol>`, nesting via nested lists, `<tt>` for
//  monospaced, and `<table><tr><td>`, which makes a real table attachment rather than a
//  picture of one. NOT: checklists, block quotes, or real Title/Heading/Subheading styles.
//
//  THERE IS ANOTHER DOOR, AND IT DOES ALL OF IT. Notes imports Markdown files, and that
//  importer is not the HTML reader: opening a `.md` produced style 0 for `#`, style 1 for
//  `##`, style 103 WITH ITS TICK STATE for `- [x]`, a real `blockQuoteLevel` for `>`, and a
//  genuine table attachment for a pipe table. Everything this door refuses, that one does.
//
//  IT IS NOT AUTOMATABLE. The import is a Finder-level `open`, it raises Notes, it asks the
//  user to confirm before it will run, and it drops the note in an "Imported Notes" folder of
//  its own choosing. So it is the answer to "can Notes be given a checklist at all" — yes —
//  and not the answer to "can a script give Notes a checklist" — still no, not without
//  driving a dialog. Markdown is NOT in Notes' scripting dictionary; the sdef exposes two
//  commands and nine note properties, and `body` is the only content door in it.
//
//  WHAT THIS TYPE ACTUALLY WRITES IS PLAIN PARAGRAPHS, well under that ceiling. ``html`` and
//  ``paragraphs`` escape their input, so a body becomes a title line and one `<div>` per
//  line and nothing else — none of the formatting above is reachable from ``create`` or
//  ``append``. That is a gap in this code rather than a limit of Notes, and it is written
//  down here so the next person does not rediscover the ceiling and assume this reaches it.
//
//  The bridge is lossy in the other direction too, which is the corroborating evidence:
//  export one of Notes' own checklists through AppleScript and it comes back a plain
//  bulleted list with the tick state gone.
//

//  A WRITE DOES NOT LAND IN THE DATABASE STRAIGHT AWAY, and this catches anyone who writes
//  through here and then reads through ``NoteStore``. Notes applies the change to its own
//  model at once — AppleScript sees it immediately — and writes the database on its own
//  schedule. Creating and renaming were visible within a couple of seconds; DELETING took
//  over a minute to move the note into Recently Deleted, during which the note still read
//  back as live. Nothing is lost and nothing needs retrying: a read-after-write can simply
//  be stale, and a caller that needs certainty has to poll rather than assume.
//

import Foundation

/// Writing to Notes, through Notes.app.
public enum NoteWriter {

    /// How long a single AppleScript call may take before it is abandoned.
    ///
    /// Notes.app can be busy syncing, and an `osascript` that never returns would hang a
    /// script with no way out. Thirty seconds is far beyond a normal write, which is
    /// two to four.
    public static let timeout: TimeInterval = 30

    // MARK: - Creating

    /// Create a note.
    ///
    /// - Parameters:
    ///   - title: the first line, which is what Notes shows as the name.
    ///   - body: the rest, as plain text. Newlines become paragraphs.
    ///   - folder: which folder; `nil` uses the account's default.
    ///   - account: which account; `nil` uses the default.
    /// - Returns: the new note's identifier, in AppleScript's `x-coredata://…` form.
    @discardableResult
    public static func create(title: String, body: String = "",
                              folder: String? = nil, account: String? = nil) throws -> String {
        let html = self.html(title: title, body: body)
        // NO `name` PROPERTY, and that is the fix for a real bug. Notes takes a note's
        // displayed name from the first line of its body, and setting `name` as well does
        // not override that — it INSERTS the name as an extra plain line above it. Every
        // note this created carried its own title twice, once plain and once styled.
        let properties = "{body:\"\(escape(html))\"}"

        let target: String
        if let folder {
            target = "folder \"\(escape(folder))\""
        } else {
            target = "default folder"
        }
        let scope = account.map { "account \"\(escape($0))\"" } ?? "default account"

        let script = """
            tell application "Notes"
              tell \(scope)
                set newNote to make new note at \(target) with properties \(properties)
                return id of newNote
              end tell
            end tell
            """
        return try run(script)
    }

    // MARK: - Appending

    /// Add text to the end of an existing note.
    ///
    /// The note's body is read and rewritten with the addition on the end, which is how
    /// AppleScript exposes it — there is no append. That makes an empty read dangerous, so
    /// one is treated as a failure rather than as an empty note: rewriting a note that
    /// merely failed to read would erase it.
    ///
    /// - Parameters:
    ///   - id: the note's AppleScript identifier, from ``appleScriptID(storeUUID:rowID:)``.
    ///   - text: plain text to add. Newlines become paragraphs.
    public static func append(noteID id: String, text: String) throws {
        let addition = paragraphs(text)
        let script = """
            tell application "Notes"
              set theNote to note id "\(escape(id))"
              set existing to body of theNote
              if existing is missing value then error "the note's body could not be read"
              set body of theNote to existing & "\(escape(addition))"
              return id of theNote
            end tell
            """
        _ = try run(script)
    }

    /// Replace a note's body.
    ///
    /// THE WHOLE BODY, title line included — Notes takes a note's name from its first line,
    /// so `text` must begin with one or the note is renamed to whatever follows. Use
    /// ``rename(noteID:to:)`` to change only that line.
    ///
    /// DESTRUCTIVE in a way ``append(noteID:text:)`` is not: whatever was there is gone, and
    /// Recently Deleted does not catch it because the note was not deleted. It reads the old
    /// body first anyway — not to keep it, but because a body that will not read is a note
    /// that should not be written over.
    ///
    /// - Parameters:
    ///   - id: the note's AppleScript identifier.
    ///   - text: plain text. Newlines become paragraphs; nothing is interpreted as markup.
    public static func setBody(noteID id: String, text: String) throws {
        _ = try body(noteID: id)
        let script = """
            tell application "Notes"
              set theNote to note id "\(escape(id))"
              set body of theNote to "\(escape(paragraphs(text)))"
              return id of theNote
            end tell
            """
        _ = try run(script)
    }

    // MARK: - Moving and renaming

    /// Move a note to another folder.
    ///
    /// `container` is one of the few writable properties Notes exposes, which is why this is
    /// possible where pinning is not.
    ///
    /// - Parameters:
    ///   - id: the note's AppleScript identifier.
    ///   - folder: the destination folder's name.
    ///   - account: which account holds it; `nil` uses the default.
    public static func move(noteID id: String, toFolder folder: String,
                            account: String? = nil) throws {
        let scope = account.map { "account \"\(escape($0))\"" } ?? "default account"
        let script = """
            tell application "Notes"
              set theNote to note id "\(escape(id))"
              tell \(scope)
                set destination to folder "\(escape(folder))"
              end tell
              move theNote to destination
              return id of theNote
            end tell
            """
        _ = try run(script)
    }

    /// Rename a note, by rewriting the line its name comes from.
    ///
    /// SETTING THE `name` PROPERTY DOES NOT RENAME A NOTE, which is worth stating plainly
    /// because AppleScript accepts it and reports success. It was measured: after setting
    /// `name`, AppleScript reads the new name back while the note's first line, the title
    /// shown in the app, and `ZTITLE1` in the database all still hold the old one. The
    /// property is a shadow nothing else reads.
    ///
    /// So this replaces the first paragraph of the body instead, which is where the name
    /// actually comes from. Like ``append(noteID:text:)`` it reads before it writes, and an
    /// unreadable body is an error rather than an empty one — rewriting a note that merely
    /// failed to read would erase it.
    ///
    /// - Parameters:
    ///   - id: the note's AppleScript identifier.
    ///   - title: the new first line.
    public static func rename(noteID id: String, to title: String) throws {
        let existing = try body(noteID: id)
        guard let rest = bodyAfterFirstParagraph(existing) else {
            throw AppleNotesError.scriptFailed(
                "the note's body has no first paragraph to rename; it was left alone")
        }
        let updated = "<div><h1>\(escapeHTML(title))</h1></div>" + rest
        let script = """
            tell application "Notes"
              set theNote to note id "\(escape(id))"
              set body of theNote to "\(escape(updated))"
              return id of theNote
            end tell
            """
        _ = try run(script)
    }

    /// A note's body, as Notes hands it over.
    ///
    /// - Throws: ``AppleNotesError/scriptFailed(_:)`` if the body cannot be read, so a
    ///   caller about to rewrite it stops rather than writing over nothing.
    static func body(noteID id: String) throws -> String {
        let script = """
            tell application "Notes"
              set theNote to note id "\(escape(id))"
              set existing to body of theNote
              if existing is missing value then error "the note's body could not be read"
              return existing
            end tell
            """
        let html = try run(script)
        guard !html.isEmpty else {
            throw AppleNotesError.scriptFailed("the note's body came back empty")
        }
        return html
    }

    /// Everything after the first balanced `<div>…</div>`, or `nil` if there is not one.
    ///
    /// Counted rather than searched for the first `</div>`: a title line is usually flat but
    /// nothing promises it, and a nested div would otherwise split the body mid-paragraph
    /// and leave a stray closing tag at the front of the note.
    static func bodyAfterFirstParagraph(_ html: String) -> String? {
        let characters = Array(html)
        var index = 0, depth = 0, opened = false

        func matches(_ tag: String, at position: Int) -> Bool {
            let end = position + tag.count
            guard end <= characters.count else { return false }
            return String(characters[position..<end]).lowercased() == tag
        }

        while index < characters.count {
            if matches("<div", at: index) {
                depth += 1
                opened = true
                index += 4
            } else if matches("</div>", at: index) {
                depth -= 1
                index += 6
                if opened && depth == 0 { return String(characters[index...]) }
            } else {
                index += 1
            }
        }
        return nil
    }

    /// Move a note to Recently Deleted.
    ///
    /// DELETING TWICE DESTROYS THE NOTE. The first call moves it to Recently Deleted, where
    /// it is recoverable for thirty days. A second call on the same id PURGES it, and there
    /// is nothing to put back. Notes' own interface makes you go to the folder and confirm;
    /// AppleScript does it on the second call with no ceremony at all.
    ///
    /// This matters because it is easy to talk yourself into retrying. After the first call
    /// `osascript` exits 0, the database still lists the note where it was — it lags, see
    /// above — and AppleScript still resolves the note by id, because a note in Recently
    /// Deleted is still a note. All three of those look exactly like nothing happened.
    /// Something did. Retrying does not fix a failure; it removes the safety net.
    ///
    /// An earlier version of this comment said a delete can silently no-op and advised
    /// issuing it again. That was wrong on both counts, and measured to be wrong: three
    /// notes deleted once each all reached Recently Deleted, while still resolving by id
    /// twenty seconds later.
    ///
    /// SLOW TO SHOW UP. This is the write that takes longest to reach the database — over a
    /// minute, measured — so a `NoteStore` read straight afterwards will still list the note
    /// in its old folder. It is not lost and it does not need doing again.
    ///
    /// Notes' own delete is a move to Recently Deleted, where it stays for thirty days and
    /// can be put back — so this is recoverable rather than destructive. It is still the only
    /// call here that removes something from where the user left it, so a caller should make
    /// it deliberate.
    public static func delete(noteID id: String) throws {
        let script = """
            tell application "Notes"
              delete note id "\(escape(id))"
            end tell
            """
        _ = try run(script)
    }

    /// Delete a folder, and everything in it.
    ///
    /// The notes inside go to Recently Deleted with it, so this is recoverable for thirty
    /// days the same way deleting a note is. It is still the widest-reaching verb here: one
    /// name can take a hundred notes with it.
    ///
    /// ADDRESSED BY NAME, because AppleScript gives a folder no usable id — and a name is
    /// only unique within an account, which is why `account` is worth passing when there is
    /// more than one.
    ///
    /// - Parameters:
    ///   - name: the folder's name.
    ///   - account: which account holds it; `nil` uses the default.
    public static func deleteFolder(named name: String, account: String? = nil) throws {
        let scope = account.map { "account \"\(escape($0))\"" } ?? "default account"
        // `tell <account> to delete folder "x"` is the form that works. Binding the folder to
        // a variable first and deleting that fails with "Can't get folder" — the same script,
        // one step apart, and only one of them does anything.
        let script = """
            tell application "Notes"
              tell \(scope)
                delete folder "\(escape(name))"
              end tell
            end tell
            """
        _ = try run(script)
    }

    /// Whether Notes can still resolve a note by id.
    ///
    /// NOT A CHECK THAT A DELETE WORKED, and it was written to be one before being measured.
    /// A note in Recently Deleted is still a note, so this keeps returning `true` after a
    /// successful delete — three test notes all reached Recently Deleted and all still
    /// resolved twenty seconds later. It only goes `false` once a note is PURGED, which is
    /// what deleting an already-deleted note does.
    ///
    /// What it is good for is telling a live id from a dead one before acting on it.
    ///
    /// - Parameter id: the note's AppleScript identifier.
    /// - Returns: whether Notes can still find it, Recently Deleted included. A script
    ///   failure of any other kind reads as `false`.
    public static func exists(noteID id: String) -> Bool {
        let script = """
            tell application "Notes"
              return name of note id "\(escape(id))"
            end tell
            """
        return (try? run(script)) != nil
    }

    /// Create a folder.
    public static func createFolder(named name: String, account: String? = nil) throws {
        let scope = account.map { "account \"\(escape($0))\"" } ?? "default account"
        let script = """
            tell application "Notes"
              tell \(scope)
                make new folder with properties {name:"\(escape(name))"}
              end tell
            end tell
            """
        _ = try run(script)
    }

    // MARK: - Identifiers

    /// The identifier AppleScript uses for a note, built from what the database knows.
    ///
    /// This is the bridge between the two halves: reads come back with a row id, writes need
    /// `x-coredata://<store UUID>/ICNote/p<row id>`. The store UUID is in `Z_METADATA`.
    public static func appleScriptID(storeUUID: String, rowID: Int) -> String {
        "x-coredata://\(storeUUID)/ICNote/p\(rowID)"
    }

    // MARK: - Formatting

    /// Wrap plain text as the HTML Notes expects for a body.
    ///
    /// PLAIN TEXT IN, PLAIN TEXT OUT. Everything is escaped, so a caller cannot smuggle
    /// formatting through the body — which is the right default, because a note about
    /// `<script>` should be a note about `<script>`. It also means this writes none of the
    /// formatting Notes would accept; see the file note for the ceiling.
    static func html(title: String, body: String) -> String {
        var out = "<div><h1>\(escapeHTML(title))</h1></div>"
        if !body.isEmpty { out += paragraphs(body) }
        return out
    }

    /// One `<div>` per line, which is how Notes represents a paragraph.
    ///
    /// A blank line becomes `<div><br></div>` rather than an empty div, which Notes drops.
    static func paragraphs(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "<div><br></div>" : "<div>\(escapeHTML(String($0)))</div>" }
            .joined()
    }

    /// Escape for an AppleScript string literal.
    ///
    /// Backslash FIRST: escaping quotes first would then escape the backslashes this adds,
    /// turning `\"` into `\\"` and ending the literal after all.
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Escape for HTML, so a note about `<script>` is a note about `<script>`.
    static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Running

    /// Run an AppleScript and return its output.
    ///
    /// - Throws: ``AppleNotesError/scriptFailed(_:)`` with whatever `osascript` said, which
    ///   is usually specific enough to act on — a missing folder names the folder.
    static func run(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        // The script goes in on stdin rather than as an argument: a note body can be longer
        // than the argument limit, and arguments are visible to anyone running `ps`.
        do { try process.run() } catch {
            throw AppleNotesError.scriptFailed("could not run osascript: \(error.localizedDescription)")
        }
        input.fileHandleForWriting.write(Data(script.utf8))
        input.fileHandleForWriting.closeFile()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            throw AppleNotesError.scriptFailed("Notes did not answer within \(Int(timeout))s")
        }

        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw AppleNotesError.scriptFailed(err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
