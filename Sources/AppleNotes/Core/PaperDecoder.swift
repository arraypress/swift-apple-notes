//
//  PaperDecoder.swift
//  AppleNotes
//
//  Created by David Sherlock on 2026.
//
//  Reading a drawing out of its own little database.
//
//  Every drawing is a SQLite store of its own holding one table that matters:
//  `Reference(Id, Version, RetainCount, ChildRetainCounts, Data)`. Each row is one object, and
//  `Data` is protobuf — sometimes behind an eight-byte header of the ASCII `crdt` and a
//  version, sometimes not, in the SAME store, so the header is stripped when present rather
//  than assumed either way.
//
//  THE FORMAT IS NOT THE ONE TABLES USE. There is no entry array and no side tables of keys:
//  an object names its own properties inline, under field 6, as plain strings — "strokes",
//  "ink", "signatureItem", "fillColor". That makes it far easier to read selectively and far
//  harder to read exhaustively, which is why this takes the parts it can confirm and leaves
//  stroke geometry alone.
//
//  HOW THE PIECES ARE RECOGNISED, and each was checked against a drawing whose rendering can
//  be looked at:
//
//  - AN INK is a message whose field 2 is a string beginning `com.apple.ink.` and whose
//    field 1 holds four `fixed32` values — red, green, blue, alpha, little-endian because
//    that is what protobuf `fixed32` means.
//  - A SIGNATURE is a keyed archive. Inside it, past an `NSUUID`, is a run of bytes that is a
//    serialised `CGPath`: pairs of `(element kind, point count)` followed by that many points
//    as little-endian floats. The reconciliation that says this is understood rather than
//    plausible is that it CONSUMES EXACTLY — a real signature parsed to 59 elements and
//    1,792 of 1,792 bytes, with no remainder and no element kind above four.
//  - THE CANVAS is four big-endian doubles, and the width and height in them match the
//    `ZSIZEWIDTH` and `ZSIZEHEIGHT` the notes database records for the same attachment.
//

import Foundation
import SQLite3

/// Decoding a `com.apple.paper` attachment.
public enum PaperDecoder {

    /// Where things are, inside a drawing's objects.
    enum Wire {
        static let properties = 6        // inside an object: its property names
        static let propertyName = 2      // inside the property block, repeated

        static let inkColour = 1         // inside an ink: four fixed32 channels
        static let inkIdentifier = 2     // inside an ink: com.apple.ink.something
    }

    /// The prefix some objects carry ahead of their protobuf.
    static let header = Data("crdt".utf8)

    /// How deep to walk one object looking for the pieces. Twelve covers every drawing seen;
    /// the limit is here because a malformed object is otherwise an unbounded descent.
    static let maximumDepth = 12

    /// Read a drawing.
    ///
    /// - Parameters:
    ///   - url: the `.bundle` directory beside the notes database.
    ///   - width: the canvas width, from the attachment row.
    ///   - height: the canvas height, from the attachment row.
    ///   - features: what the attachment's JSON metadata says it uses.
    ///   - preview: the rendered PNG, if there is one.
    /// - Returns: the drawing, or `nil` if the bundle holds no readable store.
    public static func decode(bundleAt url: URL, width: Double, height: Double,
                              features: [String] = [], preview: URL? = nil) -> Drawing? {
        let store = url.appendingPathComponent("Database/data.sqlite3")
        guard FileManager.default.fileExists(atPath: store.path) else { return nil }
        guard let objects = objects(at: store) else { return nil }

        var inks: [String: (colour: [Double], strokes: Int)] = [:]
        var signatures: [Signature] = []
        for object in objects {
            let body = object.starts(with: header) && object.count > 8
                ? object.dropFirst(8) : object[...]
            walk(Data(body)) { message in
                if let (identifier, colour) = ink(message) {
                    inks[identifier, default: (colour, 0)].strokes += 1
                }
                if let signature = signature(message) { signatures.append(signature) }
            }
        }
        return Drawing(width: width, height: height,
                       inks: inks.sorted { $0.value.strokes > $1.value.strokes }.map {
                           Ink(identifier: $0.key, strokes: $0.value.strokes,
                               colour: Colour(red: $0.value.colour[0], green: $0.value.colour[1],
                                              blue: $0.value.colour[2], alpha: $0.value.colour[3]))
                       },
                       signatures: signatures, features: features, previewURL: preview)
    }

    // MARK: - The object store

    /// Every object's bytes, read read-only.
    static func objects(at url: URL) -> [Data]? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2("file:\(url.path)?mode=ro", &handle, SQLITE_OPEN_READONLY |
                              SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }
        guard let handle else { return nil }
        return NoteStore.rows(handle, "SELECT Data FROM Reference;").compactMap { $0[0] as? Data }
    }

    // MARK: - Finding the pieces

    /// Visit a message and everything nested inside it.
    static func walk(_ data: Data, depth: Int = 0, visit: (Data) -> Void) {
        visit(data)
        guard depth < maximumDepth else { return }
        for field in Protobuf.fields(in: data) {
            guard case .bytes(let payload) = field.value, payload.count > 1,
                  !Protobuf.fields(in: payload).isEmpty else { continue }
            walk(payload, depth: depth + 1, visit: visit)
        }
    }

    /// An ink's identifier and colour, if this message is one.
    static func ink(_ data: Data) -> (String, [Double])? {
        let fields = Protobuf.fields(in: data)
        guard let name = fields.first(where: { $0.number == Wire.inkIdentifier }),
              case .bytes(let bytes) = name.value,
              let identifier = String(data: bytes, encoding: .utf8),
              identifier.hasPrefix("com.apple.ink.") else { return nil }
        guard let colours = fields.first(where: { $0.number == Wire.inkColour }),
              case .bytes(let payload) = colours.value else { return nil }

        let channels = Protobuf.fields(in: payload).compactMap { field -> Double? in
            guard case .fixed(let raw) = field.value, raw.count == 4 else { return nil }
            return Double(Float(bitPattern: raw.reversed().reduce(0) { $0 << 8 | UInt32($1) }))
        }
        guard channels.count == 4 else { return nil }
        return (identifier, channels)
    }

    /// A signature, if this message carries one.
    ///
    /// The archive holds a `$objects` array; the path is the one entry that is raw bytes.
    /// Rather than decode the archive's graph, the bytes are tried as a path and kept only
    /// if they parse without remainder — which no other blob in a drawing does.
    static func signature(_ data: Data) -> Signature? {
        for field in Protobuf.fields(in: data) {
            guard case .bytes(let payload) = field.value,
                  payload.starts(with: Data("bplist00".utf8)) else { continue }
            guard let plist = try? PropertyListSerialization.propertyList(
                    from: payload, options: [], format: nil) as? [String: Any],
                  let objects = plist["$objects"] as? [Any] else { continue }
            for object in objects {
                guard let bytes = object as? Data, let path = path(bytes) else { continue }
                return Signature(elements: path)
            }
        }
        return nil
    }

    /// A serialised `CGPath`, or `nil` if these bytes are not one.
    ///
    /// Returns `nil` on ANY surprise — an unknown element kind, a point count that does not
    /// match the kind, a trailing remainder. A partial parse of something that is not a path
    /// is worse than no parse at all, because it produces a signature-shaped nothing.
    static func path(_ data: Data) -> [Signature.Element]? {
        let words = data.count / 4
        guard words >= 4, data.count % 4 == 0 else { return nil }
        func word(_ index: Int) -> UInt32 {
            data[data.startIndex + index * 4 ..< data.startIndex + index * 4 + 4]
                .reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }

        var elements: [Signature.Element] = []
        var index = 0
        while index + 1 < words {
            guard let kind = Signature.Element.Kind(rawValue: Int(word(index))),
                  Int(word(index + 1)) == kind.points else { return nil }
            var points: [Signature.Point] = []
            for offset in 0..<kind.points {
                let base = index + 2 + offset * 2
                guard base + 1 < words else { return nil }
                points.append(Signature.Point(x: Double(Float(bitPattern: word(base))),
                                              y: Double(Float(bitPattern: word(base + 1)))))
            }
            elements.append(Signature.Element(kind: kind, points: points))
            index += 2 + kind.points * 2
        }
        guard index == words, !elements.isEmpty, elements.first?.kind == .move else { return nil }
        return elements
    }
}
