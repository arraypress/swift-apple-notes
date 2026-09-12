//
//  Protobuf.swift
//  AppleNotes
//
//  Created by David Sherlock on 2026.
//
//  Just enough protobuf to read a note.
//
//  A wire-format reader rather than a generated one, because Apple publishes no `.proto` for
//  this and a hand-written schema would be a guess frozen into types. The wire format itself
//  is stable and self-describing enough to walk: every field carries its number and one of
//  six wire types, and a reader that does not recognise a field can skip it by length. That
//  is what keeps this working when Apple adds a field — which they do, every release.
//
//  Nothing here validates a schema. ``BodyDecoder`` interprets the field numbers, and its
//  own doc comment records how each was established: by decoding a real note and checking
//  the attribute-run lengths sum to the character count.
//

import Foundation

/// A protobuf wire-format reader.
public enum Protobuf {

    /// One field as it appears on the wire.
    public struct Field {
        public let number: Int
        public let value: Value
    }

    /// A field's payload, by wire type.
    public enum Value {
        /// Wire type 0 — varint: bools, enums and integers.
        case varint(UInt64)
        /// Wire type 2 — a length-delimited run of bytes: strings and nested messages.
        case bytes(Data)
        /// Wire types 1 and 5 — fixed 64- and 32-bit. Read and skipped; nothing here uses them.
        case fixed(Data)
    }

    /// Every field in a message, in order.
    ///
    /// Repeated fields appear repeatedly, which is the whole reason this returns an array
    /// rather than a dictionary: a note's attribute runs are all field 5, and collapsing
    /// them would leave one run and a scrambled document.
    ///
    /// - Parameter data: one serialised message.
    /// - Returns: the fields read before the first malformed byte; a truncated message
    ///   yields what was readable rather than nothing.
    public static func fields(in data: Data) -> [Field] {
        var fields: [Field] = []
        let bytes = [UInt8](data)
        var index = 0

        while index < bytes.count {
            guard let (key, afterKey) = varint(bytes, at: index) else { break }
            index = afterKey
            let number = Int(key >> 3)
            guard number > 0 else { break }

            switch key & 0x07 {
            case 0:
                guard let (value, next) = varint(bytes, at: index) else { return fields }
                fields.append(Field(number: number, value: .varint(value)))
                index = next
            case 2:
                guard let (length, next) = varint(bytes, at: index) else { return fields }
                let end = next + Int(length)
                guard length <= UInt64(bytes.count), end <= bytes.count else { return fields }
                fields.append(Field(number: number, value: .bytes(Data(bytes[next..<end]))))
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return fields }
                fields.append(Field(number: number, value: .fixed(Data(bytes[index..<(index + 4)]))))
                index += 4
            case 1:
                guard index + 8 <= bytes.count else { return fields }
                fields.append(Field(number: number, value: .fixed(Data(bytes[index..<(index + 8)]))))
                index += 8
            default:
                // Wire types 3 and 4 are the deprecated group markers and have no length,
                // so there is no way to skip one. Stop rather than misread everything after.
                return fields
            }
        }
        return fields
    }

    /// The bytes of the first field with this number, or `nil`.
    public static func message(_ number: Int, in data: Data) -> Data? {
        for field in fields(in: data) {
            if field.number == number, case .bytes(let payload) = field.value { return payload }
        }
        return nil
    }

    /// The bytes of every field with this number, in order.
    public static func messages(_ number: Int, in data: Data) -> [Data] {
        fields(in: data).compactMap { field in
            guard field.number == number, case .bytes(let payload) = field.value else { return nil }
            return payload
        }
    }

    /// The varint value of the first field with this number, or `nil`.
    public static func integer(_ number: Int, in data: Data) -> UInt64? {
        for field in fields(in: data) {
            if field.number == number, case .varint(let value) = field.value { return value }
        }
        return nil
    }

    /// A base-128 varint, and the index after it.
    static func varint(_ bytes: [UInt8], at start: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var index = start
        // Ten groups of seven bits is the most a 64-bit value can occupy; beyond that the
        // input is malformed and shifting further is undefined.
        while index < bytes.count, shift < 70 {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return (result, index) }
            shift += 7
        }
        return nil
    }
}
