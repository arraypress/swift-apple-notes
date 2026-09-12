//
//  Fixtures.swift
//  AppleNotesTests
//
//  Created by David Sherlock on 2026.
//
//  Note bodies built by hand, so a test knows the answer before it decodes one.
//
//  A real note cannot be a fixture here: it belongs to whoever owns the Mac, it cannot go in
//  a repository, and it changes whenever they edit it. So these assemble the same gzip over
//  protobuf that Notes writes — which also means the encoder and the decoder are independent,
//  and a test passing says the FORMAT is understood rather than that one function is
//  self-consistent.
//

import Compression
import Foundation

enum Fixtures {

    // MARK: Protobuf writing

    static func varint(_ value: Int) -> Data {
        var v = UInt64(value), out = Data()
        repeat {
            var byte = UInt8(v & 0x7f)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    static func field(_ number: Int, varint value: Int) -> Data {
        varint(number << 3 | 0) + varint(value)
    }

    static func field(_ number: Int, bytes: Data) -> Data {
        varint(number << 3 | 2) + varint(bytes.count) + bytes
    }

    /// The bytes of the first field with this number — enough to take a fixture apart again.
    static func message(_ number: Int, in data: Data) -> Data? {
        var index = data.startIndex
        while index < data.endIndex {
            var key = 0, shift = 0
            while index < data.endIndex {
                let byte = data[index]; index += 1
                key |= Int(byte & 0x7f) << shift
                if byte & 0x80 == 0 { break }
                shift += 7
            }
            guard key >> 3 > 0, key & 7 == 2 else { return nil }
            var length = 0; shift = 0
            while index < data.endIndex {
                let byte = data[index]; index += 1
                length |= Int(byte & 0x7f) << shift
                if byte & 0x80 == 0 { break }
                shift += 7
            }
            let end = index + length
            guard end <= data.endIndex else { return nil }
            if key >> 3 == number { return Data(data[index..<end]) }
            index = end
        }
        return nil
    }

    // MARK: A note

    /// One run of styled text.
    struct Run {
        let text: String
        /// `nil` leaves the paragraph style out entirely, which is how body text is stored.
        var styleCode: Int?
        var indent: Int?
        var checklistDone: Bool?
        /// 1 bold, 2 italic, 3 both — a weight, not a flag.
        var weight: Int?
        var underlined: Bool?
        var strikethrough: Bool?
        var link: String?
        var blockQuote: Int?
        /// The identifier of the attachment standing here, on a U+FFFC placeholder run.
        var attachment: String?
        /// A highlight code, 1-5 for Apple's five colours.
        var highlight: Int?
        /// A text colour's channels, 0 to 1. Four of them is a colour; anything else is
        /// what a decoder has to refuse rather than read half of.
        var colour: [Double]?
    }

    /// Assemble a note body exactly as Notes stores one.
    static func note(_ runs: [Run]) -> Data {
        let text = runs.map(\.text).joined()

        var body = field(2, bytes: Data(text.utf8))
        for run in runs {
            var style = Data()
            if let code = run.styleCode { style += field(1, varint: code) }
            if let indent = run.indent { style += field(4, varint: indent) }
            if let q = run.blockQuote { style += field(8, varint: q) }
            if let done = run.checklistDone {
                style += field(5, bytes: field(2, varint: done ? 1 : 0))
            }

            var attributeRun = field(1, varint: run.text.utf16.count)
            if !style.isEmpty { attributeRun += field(2, bytes: style) }
            if let weight = run.weight { attributeRun += field(5, varint: weight) }
            if run.underlined == true { attributeRun += field(6, varint: 1) }
            if run.strikethrough == true { attributeRun += field(7, varint: 1) }
            if let link = run.link { attributeRun += field(9, bytes: Data(link.utf8)) }
            if let colour = run.colour {
                var channels = Data()
                for (index, value) in colour.enumerated() {
                    channels.append(UInt8((index + 1) << 3 | 5))
                    withUnsafeBytes(of: Float(value).bitPattern.littleEndian) {
                        channels.append(contentsOf: $0)
                    }
                }
                attributeRun += field(10, bytes: channels)
            }
            if let highlight = run.highlight { attributeRun += field(14, varint: highlight) }
            if let attachment = run.attachment {
                attributeRun += field(12, bytes: field(1, bytes: Data(attachment.utf8)))
            }
            body += field(5, bytes: attributeRun)
        }

        let document = field(3, bytes: body)
        return gzip(field(2, bytes: document))
    }

    // MARK: Gzip writing

    /// Deflate with a gzip wrapper, the mirror of what ``Gzip`` reads.
    static func gzip(_ data: Data) -> Data {
        let capacity = max(data.count * 2, 512)
        var deflated = Data(count: capacity)
        let written = deflated.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        out += deflated.prefix(written)
        out += crc32(data)
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        out += Data(bytes: &size, count: 4)
        return out
    }

    static func crc32(_ data: Data) -> Data {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        var value = (crc ^ 0xFFFF_FFFF).littleEndian
        return Data(bytes: &value, count: 4)
    }
}

// MARK: - A table

extension Fixtures {

    /// Build the CRDT blob Notes stores for a table.
    ///
    /// Written from the shape the decoder expects rather than by copying a real blob, so the
    /// two are independent: the encoder lays out the object graph — side tables, ordered sets
    /// keyed one way and cell dictionaries keyed another — and a passing test says the format
    /// is understood rather than that one function agrees with itself.
    ///
    /// The awkward part is reproduced deliberately. Each axis element is TWO objects with two
    /// different UUIDs, and every column allocates its own copy of the row key, which is what
    /// broke the first decoder and so is what a fixture has to exercise.
    /// - Parameters:
    ///   - cells: the grid, outer array rows.
    ///   - rightToLeft: write the right-to-left column direction.
    ///   - deletedRows: how many tombstoned rows to leave in the ordering's contents without
    ///     listing them in the order. A CRDT keeps these forever; a decoder that counted the
    ///     contents rather than the order would report a table taller than it is.
    ///   - reversedPairs: write each ordering-contents pair the other way round. Real tables
    ///     put the element first, so this is the orientation nothing has been seen to use —
    ///     which is the point: the decoder claims to take either, and this tests the claim.
    ///   - shuffledAttachments: emit the ordering's attachments back to front while keeping
    ///     their index numbers. The order lives in the numbers, not the emission order.
    static func table(_ cells: [[String]], rightToLeft: Bool = false,
                      deletedRows: Int = 0, reversedPairs: Bool = false,
                      shuffledAttachments: Bool = false) -> Data {
        table(styled: cells.map { $0.map { [Run(text: $0)] } }, rightToLeft: rightToLeft,
              deletedRows: deletedRows, reversedPairs: reversedPairs,
              shuffledAttachments: shuffledAttachments)
    }

    /// The same, with each cell given as the attribute runs styling it.
    ///
    /// A cell is an attributed string, not a plain one — it carries weight, underline,
    /// strikethrough, colour and a link URL exactly as a note body does. Building one that
    /// way here is what proves the reader keeps them.
    static func table(styled cells: [[[Run]]], rightToLeft: Bool = false,
                      deletedRows: Int = 0, reversedPairs: Bool = false,
                      shuffledAttachments: Bool = false) -> Data {
        let keys = ["identity", "crTableColumnDirection", "self", "crRows",
                    "UUIDIndex", "crColumns", "cellColumns"]
        let rowCount = cells.count
        let columnCount = cells.first?.count ?? 0

        var uuids: [Data] = [Data(repeating: 0, count: 16)]
        func newUUID() -> Int {
            uuids.append(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
            return uuids.count - 1
        }

        var entries: [Data] = []
        func add(_ entry: Data) -> Int { entries.append(entry); return entries.count - 1 }

        // Reference shapes: an object index, a number, an inline string.
        func object(_ index: Int) -> Data { field(6, varint: index) }
        func number(_ value: Int) -> Data { field(2, varint: value) }
        func string(_ value: String) -> Data { field(4, bytes: Data(value.utf8)) }

        func map(_ attributes: [(String, Data)]) -> Data {
            let body = attributes.reduce(Data()) { partial, attribute in
                guard let key = keys.firstIndex(of: attribute.0) else { return partial }
                // Protobuf omits a zero varint, so key index 0 is written as an absent field.
                let entry = (key == 0 ? Data() : field(1, varint: key)) + field(2, bytes: attribute.1)
                return partial + field(3, bytes: entry)
            }
            return field(13, bytes: field(1, varint: 16) + body)
        }
        /// A dictionary's pairs, with no entry tag around them. An ordering's contents is
        /// one of these inline; a dictionary ENTRY is the same body under field 6.
        func pairs(_ pairs: [(Data, Data)]) -> Data {
            pairs.reduce(Data()) {
                $0 + field(1, bytes: field(1, bytes: $1.0) + field(2, bytes: $1.1))
            }
        }
        func dictionary(_ elements: [(Data, Data)]) -> Data { field(6, bytes: pairs(elements)) }
        /// A cell: its text, then one attribute run per styled fragment.
        func text(_ runs: [Run]) -> Data {
            let whole = runs.map(\.text).joined()
            var body = field(2, bytes: Data(whole.utf8))
            for run in runs {
                var attributeRun = field(1, varint: run.text.utf16.count)
                if let weight = run.weight { attributeRun += field(5, varint: weight) }
                if run.underlined == true { attributeRun += field(6, varint: 1) }
                if run.strikethrough == true { attributeRun += field(7, varint: 1) }
                if let link = run.link { attributeRun += field(9, bytes: Data(link.utf8)) }
                if let highlight = run.highlight { attributeRun += field(14, varint: highlight) }
                body += field(5, bytes: attributeRun)
            }
            return field(10, bytes: body)
        }

        /// An ordered set: an attachment list giving the order, and a contents dictionary
        /// pairing each element with the object everything else refers to it by.
        func orderedSet(_ members: [(object: Int, uuid: Int, key: Int)], live: Int? = nil) -> Data {
            let ordered = Array(members.prefix(live ?? members.count)).enumerated()
            let emitted = shuffledAttachments ? Array(ordered.reversed()) : Array(ordered)
            let attachments = emitted.reduce(Data()) { partial, member in
                partial + field(2, bytes: field(1, varint: member.offset)
                                        + field(2, bytes: uuids[member.element.uuid]))
            }
            let placeholders = String(repeating: "\u{FFFC}", count: emitted.count)
            let array = field(1, bytes: field(2, bytes: Data(placeholders.utf8))) + attachments
            let contents = field(2, bytes: pairs(members.map {
                reversedPairs ? (object($0.key), object($0.object))
                              : (object($0.object), object($0.key))
            }))
            return field(16, bytes: field(1, bytes: field(1, bytes: array) + contents))
        }

        // 0 root, filled in last once every object it points at exists.
        _ = add(Data())
        _ = add(field(1, bytes: field(2, bytes: object(2))))
        _ = add(map([("self", string(rightToLeft ? "CRTableColumnDirectionRightToLeft"
                                                 : "CRTableColumnDirectionLeftToRight"))]))

        /// One axis: two objects per element, and the set that orders them. Returns the
        /// UUID-table index of each element's KEY, which is what the cells are matched on.
        func axis(_ count: Int, tombstones: Int = 0) -> (set: Int, keyUUIDs: [Int]) {
            var members: [(object: Int, uuid: Int, key: Int)] = []
            var keyUUIDs: [Int] = []
            for index in 0..<(count + tombstones) {
                let keyUUID = newUUID()
                let key = add(map([("UUIDIndex", number(keyUUID))]))
                let elementUUID = newUUID()
                let element = add(map([("UUIDIndex", number(elementUUID))]))
                members.append((object: element, uuid: elementUUID, key: key))
                if index < count { keyUUIDs.append(keyUUID) }
            }
            // A tombstone stays in the contents and leaves the order, which is exactly what
            // a delete does to a CRDT.
            return (add(orderedSet(members, live: count)), keyUUIDs)
        }
        let rows = axis(rowCount, tombstones: deletedRows)
        let columns = axis(columnCount)

        // One dictionary per column, each keyed by its OWN copy of every row — a fresh
        // object carrying the same UUID, exactly as Notes writes it.
        var columnPairs: [(Data, Data)] = []
        for column in 0..<columnCount {
            var cellPairs: [(Data, Data)] = []
            for row in 0..<rowCount {
                let rowKey = add(map([("UUIDIndex", number(rows.keyUUIDs[row]))]))
                cellPairs.append((object(rowKey), object(add(text(cells[row][column])))))
            }
            let columnKey = add(map([("UUIDIndex", number(columns.keyUUIDs[column]))]))
            columnPairs.append((object(columnKey), object(add(dictionary(cellPairs)))))
        }
        entries[0] = map([("identity", string("00000000-0000-0000-0000-000000000000")),
                          ("crTableColumnDirection", object(1)),
                          ("crRows", object(rows.set)),
                          ("crColumns", object(columns.set)),
                          ("cellColumns", object(add(dictionary(columnPairs))))])

        let graph = entries.reduce(Data()) { $0 + field(3, bytes: $1) }
            + keys.reduce(Data()) { $0 + field(4, bytes: Data($1.utf8)) }
            + uuids.reduce(Data()) { $0 + field(6, bytes: $1) }
        return gzip(field(2, bytes: field(3, bytes: graph)))
    }

}

// MARK: - An audio recording's transcript

extension Fixtures {

    /// Build the CRDT blob Notes stores for a transcribed recording.
    ///
    /// Deliberately raw and ungzipped, with the graph at the top level — which is how a real
    /// recording is stored and the opposite of a table on both counts. A decoder that assumes
    /// either fails here, which is the point of not reusing the table fixture's wrapper.
    ///
    /// - Parameter words: each word with the second it starts and how long it lasts.
    static func recording(_ words: [(text: String, start: Double, duration: Double)],
                          speaker: String? = nil) -> Data {
        let keys = ["identity", "text", "timestamp", "duration", "speaker", "self", "doubleValue"]

        var entries: [Data] = []
        func add(_ entry: Data) -> Int { entries.append(entry); return entries.count - 1 }

        func object(_ index: Int) -> Data { field(6, varint: index) }
        func string(_ value: String) -> Data { field(4, bytes: Data(value.utf8)) }
        func double(_ value: Double) -> Data {
            // Field 3, wire type 1: a fixed64, little-endian.
            var out = varint(3 << 3 | 1)
            withUnsafeBytes(of: value.bitPattern.littleEndian) { out.append(contentsOf: $0) }
            return out
        }
        func map(_ attributes: [(String, Data)]) -> Data {
            let body = attributes.reduce(Data()) { partial, attribute in
                guard let key = keys.firstIndex(of: attribute.0) else { return partial }
                let entry = (key == 0 ? Data() : field(1, varint: key)) + field(2, bytes: attribute.1)
                return partial + field(3, bytes: entry)
            }
            return field(13, bytes: field(1, varint: 16) + body)
        }
        /// A value one hop away: a register pointing at an object holding just that value.
        func wrapped(_ attribute: String, _ value: Data) -> Data {
            let holder = add(map([(attribute, value)]))
            return object(add(field(1, bytes: field(2, bytes: object(holder)))))
        }

        _ = add(Data())                                     // a root the decoder ignores
        for word in words {
            var attributes: [(String, Data)] = [
                ("identity", string(UUID().uuidString)),
                ("text", wrapped("self", string(word.text))),
                ("timestamp", wrapped("doubleValue", double(word.start))),
                ("duration", wrapped("doubleValue", double(word.duration)))]
            if let speaker { attributes.append(("speaker", wrapped("self", string(speaker)))) }
            _ = add(map(attributes))
        }

        return entries.reduce(Data()) { $0 + field(3, bytes: $1) }
            + keys.reduce(Data()) { $0 + field(4, bytes: Data($1.utf8)) }
    }
}
