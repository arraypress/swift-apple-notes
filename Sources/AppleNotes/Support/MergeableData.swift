//
//  MergeableData.swift
//  AppleNotes
//
//  Created by David Sherlock on 2026.
//
//  The object graph Apple stores in `ZMERGEABLEDATA1`, read back out.
//
//  A note's BODY is a document. An attachment's mergeable data is not: it is a serialised
//  CRDT — a flat array of objects that refer to one another by index, with three side tables
//  holding the strings so no string is ever written twice. Nothing in it is positional, so it
//  cannot be read top to bottom; it has to be resolved.
//
//  THE THREE SIDE TABLES are the key to it. `keys` names attributes ("crRows", "cellColumns"),
//  `types` names classes ("com.apple.notes.ICTable"), and `uuids` holds 16 raw bytes each.
//  An object refers to any of them by index, and an index is 0-BASED into the table as
//  written — verified by resolving a table's key indices against its own key table and
//  getting attribute names that read as English rather than off-by-one nonsense.
//
//  ENTRY KINDS, measured from a table and an audio recording. Field 1 is a register holding
//  one value, 6 a dictionary of pairs, 10 a run of text, 13 a map of named attributes, and
//  16 an ordered set. An entry carries exactly one of them.
//
//  WHERE THE GRAPH STARTS DIFFERS BY WHAT WROTE IT, which was the one real surprise here: a
//  table's graph is wrapped in two envelopes and an audio recording's is at the top level of
//  the blob, with the same shape underneath both. So this looks for the graph rather than
//  indexing to it — the alternative is a branch on the attachment type, which breaks the next
//  time Apple adds one.
//
//  THE BLOB MAY OR MAY NOT BE GZIPPED for the same reason. A table's is; an audio recording's
//  is raw protobuf. Both were in one library at the same time, so this is not a version
//  difference that will settle down.
//

import Foundation

/// Reading Apple's serialised CRDT.
public enum MergeableData {

    /// Field numbers, measured from real attachments. See the file note above.
    enum Wire {
        static let entry = 3             // inside the graph, repeated
        static let keyItem = 4           // inside the graph, repeated: attribute names
        static let typeItem = 5          // inside the graph, repeated: class names
        static let uuidItem = 6          // inside the graph, repeated: 16 raw bytes

        static let register = 1          // an entry holding a single value
        static let dictionary = 6        // an entry holding key/value pairs
        static let text = 10             // an entry holding a run of text
        static let map = 13              // an entry holding named attributes
        static let orderedSet = 16       // an entry holding an ordered collection

        static let registerValue = 2     // inside a register
        static let dictionaryElement = 1 // inside a dictionary, repeated
        static let elementKey = 1        // inside a dictionary element
        static let elementValue = 2      // inside a dictionary element
        static let textContent = 2       // inside a text entry
        static let textRun = 5           // inside a text entry, repeated: an attribute run
        static let mapType = 1           // inside a map: index into the type table
        static let mapEntry = 3          // inside a map, repeated
        static let mapKey = 1            // inside a map entry: index into the key table
        static let mapValue = 2          // inside a map entry

        static let ordering = 1          // inside an ordered set
        static let orderingArray = 1     // inside an ordering
        static let orderingContents = 2  // inside an ordering: a dictionary
        static let attachment = 2        // inside an ordering array, repeated
        static let attachmentIndex = 1   // inside an attachment: position in the order
        static let attachmentUUID = 2    // inside an attachment: 16 raw bytes

        static let referenceInteger = 2  // inside a reference
        static let referenceDouble = 3   // inside a reference: a fixed64 IEEE double
        static let referenceString = 4   // inside a reference
        static let referenceObject = 6   // inside a reference: index into the entry array
    }

    /// How one object points at another, or at a literal.
    public enum Reference: Equatable, Hashable, Sendable {
        /// An index into the entry array.
        case object(Int)
        /// A string held inline rather than in a side table.
        case string(String)
        /// A number, which is also how an index into the UUID table is written.
        case integer(UInt64)
        /// A floating-point number — a transcript's timestamps and durations.
        case double(Double)
    }

    /// An ordered set: the order is kept apart from the membership.
    ///
    /// `order` comes from the ordering array's attachments, each of which pairs a position
    /// with the UUID of the element at it. `pairs` comes from the ordering's contents, and
    /// links the element carrying that UUID to the object the rest of the graph refers to it
    /// by — which is a DIFFERENT object with a different UUID, and the reason a first attempt
    /// at this produced a table of the right shape with every cell empty.
    public struct OrderedSet: Sendable {
        public let order: [Data]
        public let pairs: [(Reference, Reference)]
    }

    /// One object in the graph.
    public enum Entry: Sendable {
        case register(Reference?)
        case dictionary([(key: Reference, value: Reference)])
        /// Text with the attribute runs styling it — a table cell is one of these, and its
        /// runs use the same character vocabulary a note body does.
        case text(String, runs: [Data])
        case map(type: Int?, attributes: [String: Reference])
        case orderedSet(OrderedSet)
        /// An entry of a kind nothing here reads. Kept so indices stay aligned.
        case other
    }

    /// A resolved object graph.
    public struct Graph: Sendable {
        public let entries: [Entry]
        public let keys: [String]
        public let types: [String]
        public let uuids: [Data]

        /// The entry at an object reference, or `nil` for anything else.
        public func entry(_ reference: Reference?) -> Entry? {
            guard case .object(let index) = reference, entries.indices.contains(index) else {
                return nil
            }
            return entries[index]
        }

        /// The UUID a reference stands for.
        ///
        /// Rows and columns are named by a small map holding one attribute, `UUIDIndex`,
        /// whose value indexes the UUID table. Two different objects can carry the same
        /// UUID — a table allocates a fresh row reference inside every column — so matching
        /// on UUID is the only way to line a cell up with its row.
        public func uuid(of reference: Reference?) -> Data? {
            guard case .map(_, let attributes) = entry(reference),
                  case .integer(let index)? = attributes["UUIDIndex"],
                  uuids.indices.contains(Int(index)) else { return nil }
            return uuids[Int(index)]
        }

        /// The text a reference stands for, following one register hop.
        public func text(of reference: Reference?) -> String? {
            switch entry(reference) {
            case .text(let value, _): return value
            case .register(let inner): if case .text(let value, _)? = entry(inner) { return value }
            default: break
            }
            return nil
        }
    }

    // MARK: - Reading

    /// Read an attachment's mergeable data.
    ///
    /// - Parameter data: the raw `ZMERGEABLEDATA1` blob, gzipped or not.
    /// - Returns: the resolved graph, or `nil` if there is no object graph in it.
    public static func graph(_ data: Data) -> Graph? {
        let inflated = Gzip.inflate(data) ?? data
        guard let body = locateGraph(inflated) else { return nil }

        let keys = Protobuf.messages(Wire.keyItem, in: body).compactMap { String(data: $0, encoding: .utf8) }
        let types = Protobuf.messages(Wire.typeItem, in: body).compactMap { String(data: $0, encoding: .utf8) }
        let uuids = Protobuf.messages(Wire.uuidItem, in: body)
        let entries = Protobuf.messages(Wire.entry, in: body).map { entry($0, keys: keys) }
        return Graph(entries: entries, keys: keys, types: types, uuids: uuids)
    }

    /// Find the message holding the object graph.
    ///
    /// A graph is recognised by carrying BOTH a key table and at least one entry, which no
    /// envelope around it does. The depth limit is three because the deepest seen is two and
    /// an unbounded walk over a malformed blob is a way to spend a long time finding nothing.
    static func locateGraph(_ data: Data, depth: Int = 0) -> Data? {
        let fields = Protobuf.fields(in: data)
        let hasKeys = fields.contains { $0.number == Wire.keyItem }
        let hasEntries = fields.contains { $0.number == Wire.entry }
        if hasKeys && hasEntries { return data }
        guard depth < 3 else { return nil }

        for field in fields {
            guard case .bytes(let payload) = field.value, !payload.isEmpty else { continue }
            if let found = locateGraph(payload, depth: depth + 1) { return found }
        }
        return nil
    }

    /// One entry, by whichever of the five kinds it carries.
    static func entry(_ data: Data, keys: [String]) -> Entry {
        for field in Protobuf.fields(in: data) {
            guard case .bytes(let payload) = field.value else { continue }
            switch field.number {
            case Wire.register:
                return .register(Protobuf.message(Wire.registerValue, in: payload).map(reference))
            case Wire.dictionary:
                return .dictionary(pairs(payload))
            case Wire.text:
                let content = Protobuf.message(Wire.textContent, in: payload) ?? Data()
                return .text(String(data: content, encoding: .utf8) ?? "",
                             runs: Protobuf.messages(Wire.textRun, in: payload))
            case Wire.map:
                var attributes: [String: Reference] = [:]
                for element in Protobuf.messages(Wire.mapEntry, in: payload) {
                    // Protobuf omits a varint of zero, so the FIRST key — index 0, which is
                    // always "identity" — arrives as an absent field rather than a zero.
                    let index = Int(Protobuf.integer(Wire.mapKey, in: element) ?? 0)
                    guard keys.indices.contains(index),
                          let value = Protobuf.message(Wire.mapValue, in: element) else { continue }
                    attributes[keys[index]] = reference(value)
                }
                return .map(type: Protobuf.integer(Wire.mapType, in: payload).map(Int.init),
                            attributes: attributes)
            case Wire.orderedSet:
                return .orderedSet(orderedSet(payload))
            default:
                continue
            }
        }
        return .other
    }

    /// A dictionary's key/value pairs.
    static func pairs(_ data: Data) -> [(key: Reference, value: Reference)] {
        Protobuf.messages(Wire.dictionaryElement, in: data).compactMap { element in
            guard let key = Protobuf.message(Wire.elementKey, in: element),
                  let value = Protobuf.message(Wire.elementValue, in: element) else { return nil }
            return (reference(key), reference(value))
        }
    }

    /// An ordered set's order and membership.
    static func orderedSet(_ data: Data) -> OrderedSet {
        guard let ordering = Protobuf.message(Wire.ordering, in: data) else {
            return OrderedSet(order: [], pairs: [])
        }
        var order: [(Int, Data)] = []
        if let array = Protobuf.message(Wire.orderingArray, in: ordering) {
            for attachment in Protobuf.messages(Wire.attachment, in: array) {
                let index = Protobuf.integer(Wire.attachmentIndex, in: attachment) ?? 0
                guard let uuid = Protobuf.message(Wire.attachmentUUID, in: attachment) else { continue }
                order.append((Int(index), uuid))
            }
        }
        let contents = Protobuf.message(Wire.orderingContents, in: ordering).map(pairs) ?? []
        return OrderedSet(order: order.sorted { $0.0 < $1.0 }.map(\.1),
                          pairs: contents.map { ($0.key, $0.value) })
    }

    /// One reference, by whichever field carries it.
    static func reference(_ data: Data) -> Reference {
        for field in Protobuf.fields(in: data) {
            switch (field.number, field.value) {
            case (Wire.referenceObject, .varint(let value)): return .object(Int(value))
            case (Wire.referenceInteger, .varint(let value)): return .integer(value)
            case (Wire.referenceDouble, .fixed(let raw)) where raw.count == 8:
                // A protobuf fixed64, so little-endian — the same way round as an ink's
                // colour and the opposite of a drawing's canvas bounds.
                return .double(Double(bitPattern: raw.reversed().reduce(0) { $0 << 8 | UInt64($1) }))
            case (Wire.referenceString, .bytes(let value)):
                // The bytes ARE the string. An earlier version tried to unwrap one more
                // message out of them, which happens to work on the two strings a table
                // holds and would corrupt any string beginning with a quotation mark —
                // 0x22 is also the tag for field 4, so it unwraps into nonsense.
                return .string(String(data: value, encoding: .utf8) ?? "")
            default: continue
            }
        }
        return .integer(0)
    }
}
