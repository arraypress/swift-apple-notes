//
//  NoteStore.swift
//  AppleNotes
//
//  Created by David Sherlock on 2026.
//
//  Reading the Apple Notes database, without touching it.
//
//  IT OPENS `mode=ro`, NOT `immutable=1`, and that distinction is the whole correctness of
//  this file. `immutable=1` is the obviously-safer-looking choice — it promises SQLite the
//  file cannot change, so nothing is locked and nothing is written — and it silently ignores
//  the write-ahead log. Measured on a live library: `immutable=1` returned 4 notes and
//  `mode=ro` returned 5, the missing one being the note written seconds earlier and still
//  sitting in a 1.8 MB uncheckpointed WAL. Read-only reads the WAL; immutable reads
//  yesterday.
//
//  Read-only is genuinely read-only, and that was verified rather than assumed: after a
//  batch of queries the database, its `-wal` and its `-shm` were all byte-identical. The
//  `-shm` is the one worth checking, because WAL readers ordinarily need to write to it.
//
//  ENTITY IDS ARE LOOKED UP, NEVER HARDCODED. `Z_ENT` distinguishes a note from a folder,
//  and Core Data assigns those numbers when it builds the model — they are 12 and 15 on this
//  machine and there is no guarantee they are on the next macOS. `Z_PRIMARYKEY` maps names
//  to numbers, so the names are what this file relies on.
//
//  A LIVE NOTE IS NOT JUST A ROW. Core Data leaves tombstones behind: a real library here
//  held 597 note rows of which 593 had no title, no body and no folder. A count of rows is
//  not a count of notes, and the difference is large enough to make a tool look broken.
//

import Foundation
import SQLite3

/// A read-only connection to the Apple Notes store.
public final class NoteStore {

    /// Where Notes keeps its database.
    public static var defaultLocation: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
    }

    private let handle: OpaquePointer
    private let entities: [String: Int]

    /// The Core Data store's UUID, from `Z_METADATA`.
    ///
    /// The bridge to the write half: AppleScript addresses a note as
    /// `x-coredata://<this>/ICNote/p<row id>`, and a row id is what every read returns.
    /// Verified against a live library — the UUID here matched the one AppleScript reported.
    public let storeUUID: String

    /// Open the store.
    ///
    /// - Parameter url: the database; defaults to the live one.
    /// - Throws: ``AppleNotesError/storeNotFound(_:)`` when there is none,
    ///   ``AppleNotesError/permissionDenied(_:)`` when macOS refuses it.
    public init(url: URL = NoteStore.defaultLocation) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AppleNotesError.storeNotFound(url)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw AppleNotesError.permissionDenied(url)
        }

        var handle: OpaquePointer?
        let uri = "file:\(url.path)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open"
            sqlite3_close(handle)
            // An unreadable protected container surfaces here rather than at the file check,
            // because TCC lets the path stat and refuses the open.
            throw message.lowercased().contains("authoriz") || message.lowercased().contains("permission")
                ? AppleNotesError.permissionDenied(url)
                : AppleNotesError.databaseError(message)
        }
        self.handle = opened

        var found: [String: Int] = [:]
        for row in NoteStore.rows(opened, "SELECT Z_NAME, Z_ENT FROM Z_PRIMARYKEY;") {
            if let name = row[0] as? String, let ent = row[1] as? Int64 { found[name] = Int(ent) }
        }
        self.entities = found
        self.storeUUID = (NoteStore.rows(opened, "SELECT Z_UUID FROM Z_METADATA;")
            .first?.first as? String) ?? ""
        // Attachment files sit beside the database rather than inside it.
        self.container = url.deletingLastPathComponent()
    }

    /// The group container holding the database, and beside it every attachment's bytes.
    public let container: URL

    /// Cached result of ``accountColumn()``.
    private var resolvedAccountColumn: String?

    /// The identifier AppleScript uses for a note in this store.
    public func appleScriptID(forNote rowID: Int) -> String {
        NoteWriter.appleScriptID(storeUUID: storeUUID, rowID: rowID)
    }

    deinit { sqlite3_close(handle) }

    /// The `Z_ENT` for a Core Data entity name.
    func entity(_ name: String) throws -> Int {
        guard let value = entities[name] else {
            throw AppleNotesError.databaseError("no entity named \(name) in this store")
        }
        return value
    }

    // MARK: - Queries

    /// The column linking a folder to its account, found rather than hardcoded.
    ///
    /// Core Data names a relationship column `ZACCOUNT`, `ZACCOUNT1`, `ZACCOUNT2` and so on,
    /// and WHICH number a given relationship gets is decided when Core Data builds the model.
    /// One real store used `ZACCOUNT8` with eleven other `ZACCOUNT*` columns beside it, all
    /// null. Hardcoding the number is the same trap as hardcoding a `Z_ENT`, and it fails the
    /// same way: silently, returning zero of everything.
    ///
    /// So the candidates are tried and the one that actually joins folders to accounts wins.
    /// Resolved once, on first use.
    private func accountColumn() throws -> String {
        if let cached = resolvedAccountColumn { return cached }
        let folder = try entity("ICFolder")
        let account = try entity("ICAccount")

        let candidates = NoteStore.rows(handle, "PRAGMA table_info(ZICCLOUDSYNCINGOBJECT);")
            .compactMap { $0.count > 1 ? $0[1] as? String : nil }
            .filter { $0.hasPrefix("ZACCOUNT") && ($0 == "ZACCOUNT" || Int($0.dropFirst(8)) != nil) }

        var best = ("ZACCOUNT", 0)
        for column in candidates {
            let sql = """
                SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT f
                JOIN ZICCLOUDSYNCINGOBJECT a ON f.\(column) = a.Z_PK AND a.Z_ENT = \(account)
                WHERE f.Z_ENT = \(folder);
                """
            let matches = Int(NoteStore.rows(handle, sql).first?.first as? Int64 ?? 0)
            if matches > best.1 { best = (column, matches) }
        }
        resolvedAccountColumn = best.0
        return best.0
    }

    /// Every account with notes in it.
    ///
    /// The counts come from the same live-note rule the listings use — a folder AND a body —
    /// so an account of nothing but Core Data tombstones reports zero rather than hundreds.
    public func accounts() throws -> [Account] {
        let account = try entity("ICAccount")
        let note = try entity("ICNote")
        let folder = try entity("ICFolder")
        let link = try accountColumn()
        let sql = """
            SELECT a.Z_PK, a.ZIDENTIFIER, a.ZNAME,
                   (SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT n
                      JOIN ZICNOTEDATA d ON d.ZNOTE = n.Z_PK
                      JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = n.ZFOLDER
                     WHERE n.Z_ENT = \(note) AND d.ZDATA IS NOT NULL
                           AND COALESCE(f.ZFOLDERTYPE, 0) != 1
                           AND f.\(link) = a.Z_PK),
                   (SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT f
                     WHERE f.Z_ENT = \(folder) AND f.\(link) = a.Z_PK)
            FROM ZICCLOUDSYNCINGOBJECT a
            WHERE a.Z_ENT = \(account) AND a.ZNAME IS NOT NULL
            ORDER BY a.ZNAME;
            """
        return NoteStore.rows(handle, sql).map { row in
            Account(id: Int(row[0] as? Int64 ?? 0),
                    identifier: row[1] as? String ?? "",
                    name: row[2] as? String ?? "",
                    noteCount: Int(row[3] as? Int64 ?? 0),
                    folderCount: Int(row[4] as? Int64 ?? 0))
        }
    }

    /// Every folder, Recently Deleted included.
    ///
    /// - Parameter includeOrphaned: also return folders that exist only in the local
    ///   database — see ``Folder/isOrphaned``. Off by default, so the answer matches what
    ///   Notes.app shows.
    public func folders(includeOrphaned: Bool = false) throws -> [Folder] {
        let folder = try entity("ICFolder")
        let note = try entity("ICNote")
        let sql = """
            SELECT f.Z_PK, f.ZTITLE2, a.ZNAME, f.ZPARENT, COALESCE(f.ZFOLDERTYPE, 0),
                   (SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT n
                      WHERE n.Z_ENT = \(note) AND n.ZFOLDER = f.Z_PK),
                   f.ZSERVERRECORDDATA IS NULL
            FROM ZICCLOUDSYNCINGOBJECT f
            LEFT JOIN ZICCLOUDSYNCINGOBJECT a ON f.\(try accountColumn()) = a.Z_PK
            WHERE f.Z_ENT = \(folder) AND f.ZTITLE2 IS NOT NULL
            ORDER BY f.ZTITLE2;
            """
        return NoteStore.rows(handle, sql).compactMap { row in
            let orphaned = (row[6] as? Int64 ?? 0) == 1
            guard includeOrphaned || !orphaned else { return nil }
            return Folder(id: Int(row[0] as? Int64 ?? 0),
                          name: row[1] as? String ?? "",
                          account: row[2] as? String,
                          parentID: (row[3] as? Int64).map(Int.init),
                          isRecentlyDeleted: (row[4] as? Int64 ?? 0) == 1,
                          noteCount: Int(row[5] as? Int64 ?? 0),
                          isOrphaned: orphaned)
        }
    }

    /// Notes, newest first.
    ///
    /// - Parameters:
    ///   - folder: only this folder, by name, case-insensitively.
    ///   - includeDeleted: include Recently Deleted. Off by default — a deleted note turning
    ///     up in a listing reads as a bug.
    ///   - limit: how many at most.
    public func notes(inFolder folder: String? = nil,
                      includeDeleted: Bool = false,
                      limit: Int? = nil) throws -> [Note] {
        var clauses = [liveNotePredicate(try entity("ICNote"))]
        if !includeDeleted { clauses.append("COALESCE(f.ZFOLDERTYPE, 0) != 1") }
        if let folder { clauses.append("LOWER(f.ZTITLE2) = LOWER('\(escape(folder))')") }

        let sql = """
            \(noteSelect)
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY n.ZISPINNED DESC, n.ZMODIFICATIONDATE1 DESC
            \(limit.map { "LIMIT \($0)" } ?? "");
            """
        return NoteStore.rows(handle, sql).map(makeNote)
    }

    /// Notes whose title, preview or recognised attachment text contains `query`.
    ///
    /// Title and snippet are indexed columns, so this does not decode a single body — a
    /// search over a large library stays fast. The cost is that it cannot match a word that
    /// appears only deep inside a note; ``notes(matching:inBodies:)`` does that, slowly.
    public func search(_ query: String, includeDeleted: Bool = false) throws -> [Note] {
        let term = escape(query).lowercased()
        var clauses = [liveNotePredicate(try entity("ICNote")),
                       "(LOWER(n.ZTITLE1) LIKE '%\(term)%' OR LOWER(n.ZSNIPPET) LIKE '%\(term)%')"]
        if !includeDeleted { clauses.append("COALESCE(f.ZFOLDERTYPE, 0) != 1") }

        let sql = """
            \(noteSelect)
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY n.ZMODIFICATIONDATE1 DESC;
            """
        return NoteStore.rows(handle, sql).map(makeNote)
    }

    /// One note with its body and attachments decoded.
    ///
    /// - Parameter id: the row identifier from a listing.
    public func note(id: Int) throws -> Note {
        let sql = "\(noteSelect) WHERE n.Z_PK = \(id);"
        guard let row = NoteStore.rows(handle, sql).first else {
            throw AppleNotesError.noteNotFound("id \(id)")
        }
        let note = makeNote(row)

        var blocks: [Block] = []
        if let body = row[11] as? Data, !note.isLocked {
            guard let decoded = BodyDecoder.decode(body) else {
                throw AppleNotesError.undecodableBody(noteID: id)
            }
            blocks = decoded
        }
        return Note(id: note.id, identifier: note.identifier, title: note.title,
                    snippet: note.snippet, folder: note.folder, account: note.account,
                    created: note.created, modified: note.modified,
                    isPinned: note.isPinned, isDeleted: note.isDeleted, isLocked: note.isLocked,
                    blocks: blocks, attachments: try attachments(ofNote: id))
    }

    /// Every hashtag written in the library, with how many notes carry it.
    ///
    /// SLOW BY NATURE, and the reason is worth knowing before calling it on a large library:
    /// tags are not indexed anywhere — Apple's `ICHashtag` table exists and stays empty —
    /// so finding them means inflating and parsing every note body. Everything else in this
    /// type reads indexed columns and is instant; this one is linear in the size of the
    /// library.
    ///
    /// - Parameter includeDeleted: also search Recently Deleted.
    /// - Returns: tag names mapped to the row ids carrying them, most-used first.
    public func tags(includeDeleted: Bool = false) throws -> [(tag: String, notes: [Int])] {
        var found: [String: [Int]] = [:]
        var casing: [String: String] = [:]

        for note in try notes(includeDeleted: includeDeleted) {
            guard let full = try? self.note(id: note.id) else { continue }
            for tag in full.tags {
                let key = tag.lowercased()
                casing[key] = casing[key] ?? tag
                found[key, default: []].append(note.id)
            }
        }
        return found
            .map { (tag: casing[$0.key] ?? $0.key, notes: $0.value) }
            .sorted { ($0.notes.count, $1.tag) > ($1.notes.count, $0.tag) }
    }

    /// What is embedded in a note.
    ///
    /// TOP-LEVEL ONLY. An attachment can own another: an audio recording is a
    /// `com.apple.m4a-audio` row with a `public.mpeg-4-audio` child holding the media, and
    /// returning both makes one recording look like two things and leaves more attachments
    /// than the body has placeholders to match them to.
    public func attachments(ofNote id: Int) throws -> [Attachment] {
        let attachment = try entity("ICAttachment")
        // The media row holds the file's own identifier and name; the account row holds the
        // directory everything for that account lives under.
        let sql = """
            SELECT a.ZIDENTIFIER, a.ZTYPEUTI, a.ZFILENAME, a.ZTITLE,
                   COALESCE(a.ZHANDWRITINGSUMMARY, a.ZOCRSUMMARY, a.ZSUMMARY, a.ZALTTEXT),
                   a.ZCREATIONDATE, a.ZMODIFICATIONDATE, a.ZMERGEABLEDATA1,
                   a.ZSIZEWIDTH, a.ZSIZEHEIGHT, a.ZFALLBACKIMAGEGENERATION, a.ZMETADATADATA,
                   m.ZIDENTIFIER, m.ZFILENAME, account.ZIDENTIFIER
            FROM ZICCLOUDSYNCINGOBJECT a
            LEFT JOIN ZICCLOUDSYNCINGOBJECT m ON m.Z_PK = a.ZMEDIA
            LEFT JOIN ZICCLOUDSYNCINGOBJECT account ON account.Z_PK = a.ZACCOUNT1
            WHERE a.Z_ENT = \(attachment) AND a.ZNOTE = \(id)
                  AND a.ZPARENTATTACHMENT IS NULL;
            """
        return NoteStore.rows(handle, sql).map { row in
            let identifier = row[0] as? String ?? ""
            let kind = AttachmentKind.from(uti: row[1] as? String ?? "")
            let account = (row[14] as? String).map {
                container.appendingPathComponent("Accounts/\($0)")
            }
            return Attachment(
                id: identifier,
                kind: kind,
                filename: row[2] as? String,
                title: row[3] as? String,
                recognisedText: (row[4] as? String).flatMap { $0.isEmpty ? nil : $0 },
                created: appleDate(row[5]),
                modified: appleDate(row[6]),
                table: (row[7] as? Data).flatMap(TableDecoder.decode),
                drawing: drawing(kind: kind, identifier: identifier, account: account,
                                 width: row[8] as? Double ?? 0, height: row[9] as? Double ?? 0,
                                 generation: row[10] as? String, metadata: row[11] as? Data),
                transcript: (row[7] as? Data).flatMap(RecordingDecoder.decode),
                url: file(account: account, media: row[12] as? String, name: row[13] as? String))
        }
    }

    /// The file an attachment's bytes are in.
    ///
    /// Media lives under the MEDIA row's identifier, not the attachment's, in a generation
    /// directory whose name the database does not record for these rows — so the one
    /// directory there is enumerated rather than guessed.
    private func file(account: URL?, media: String?, name: String?) -> URL? {
        guard let account, let media, let name else { return nil }
        let base = account.appendingPathComponent("Media/\(media)")
        let generations = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        for generation in generations.sorted() {
            let candidate = base.appendingPathComponent("\(generation)/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// A drawing, read from the bundle beside the database.
    private func drawing(kind: AttachmentKind, identifier: String, account: URL?,
                         width: Double, height: Double,
                         generation: String?, metadata: Data?) -> Drawing? {
        guard case .drawing = kind, let account else { return nil }
        let preview = generation.map {
            account.appendingPathComponent("FallbackImages/\(identifier)/\($0)/FallbackImage.png")
        }
        let bundle = account.appendingPathComponent("Paper/Bundles/\(identifier).bundle")
        let features = NoteStore.features(metadata)
        let rendered = preview.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        }
        if let drawing = PaperDecoder.decode(bundleAt: bundle, width: width, height: height,
                                             features: features, preview: rendered) {
            return drawing
        }
        // No bundle. Report what the database knows only if it knows something: opening the
        // markup canvas and closing it again leaves a `com.apple.paper` row with no size, no
        // features and no bundle, and the body has no placeholder for it. A zero-by-zero
        // drawing there reads like a failed decode rather than the nothing it is.
        guard width > 0 || height > 0 || !features.isEmpty || rendered != nil else { return nil }
        return Drawing(width: width, height: height, features: features, previewURL: rendered)
    }

    /// What a drawing's JSON metadata says it uses.
    ///
    /// The blob is a flat object of booleans — `hasMathKey`, `hasGraphKey`, `hasNewInks2023Key`
    /// — naming features rather than content. Only the true ones are kept, and the `has`
    /// prefix and `Key` suffix are trimmed off: what survives is a list a person can read.
    static func features(_ data: Data?) -> [String] {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return object.compactMap { key, value in
            guard (value as? Bool) == true else { return nil }
            var name = key
            if name.hasPrefix("has") { name.removeFirst(3) }
            if name.hasSuffix("Key") { name.removeLast(3) }
            return name.isEmpty ? nil : name.prefix(1).lowercased() + name.dropFirst()
        }.sorted()
    }

    // MARK: - Building the query

    /// What makes a row a real, listable note.
    ///
    /// A folder AND a body. Core Data tombstones have neither, and a library here held 593
    /// of them against 4 real notes.
    private func liveNotePredicate(_ note: Int) -> String {
        "n.Z_ENT = \(note) AND n.ZFOLDER IS NOT NULL AND d.ZDATA IS NOT NULL"
    }

    private var noteSelect: String {
        """
        SELECT n.Z_PK, n.ZIDENTIFIER, n.ZTITLE1, n.ZSNIPPET, f.ZTITLE2, a.ZNAME,
               n.ZCREATIONDATE1, n.ZMODIFICATIONDATE1,
               COALESCE(n.ZISPINNED, 0), COALESCE(f.ZFOLDERTYPE, 0),
               COALESCE(n.ZISPASSWORDPROTECTED, 0), d.ZDATA
        FROM ZICCLOUDSYNCINGOBJECT n
        JOIN ZICNOTEDATA d ON d.ZNOTE = n.Z_PK
        LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON n.ZFOLDER = f.Z_PK
        LEFT JOIN ZICCLOUDSYNCINGOBJECT a ON n.ZACCOUNT7 = a.Z_PK
        """
    }

    private func makeNote(_ row: [Any?]) -> Note {
        Note(id: Int(row[0] as? Int64 ?? 0),
             identifier: row[1] as? String,
             title: row[2] as? String ?? "(untitled)",
             snippet: (row[3] as? String).flatMap { $0.isEmpty ? nil : $0 },
             folder: row[4] as? String,
             account: row[5] as? String,
             created: appleDate(row[6]),
             modified: appleDate(row[7]),
             isPinned: (row[8] as? Int64 ?? 0) != 0,
             isDeleted: (row[9] as? Int64 ?? 0) == 1,
             isLocked: (row[10] as? Int64 ?? 0) != 0)
    }

    /// Core Data stores dates as seconds since 1 January 2001, not since 1970.
    private func appleDate(_ value: Any?) -> Date? {
        guard let seconds = value as? Double, seconds > 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Single quotes doubled, so a note titled `Bob's` cannot end a string literal early.
    ///
    /// Every value reaching SQL here is a folder name or a search term supplied by the
    /// caller; binding would be better still, and this file has no write path for an
    /// injection to reach even if one got through.
    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    // MARK: - SQLite

    /// Run a query and materialise every row.
    ///
    /// Notes libraries are small — a very large one is a few thousand rows — so the
    /// simplicity of an array beats a cursor here.
    static func rows(_ handle: OpaquePointer, _ sql: String) -> [[Any?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var results: [[Any?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = sqlite3_column_count(statement)
            var row: [Any?] = []
            for column in 0..<count {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT:   row.append(sqlite3_column_double(statement, column))
                case SQLITE_TEXT:
                    row.append(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_bytes(statement, column)
                    if let pointer = sqlite3_column_blob(statement, column), bytes > 0 {
                        row.append(Data(bytes: pointer, count: Int(bytes)))
                    } else { row.append(nil) }
                default: row.append(nil)
                }
            }
            results.append(row)
        }
        return results
    }
}
