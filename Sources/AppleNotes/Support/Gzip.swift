//
//  Gzip.swift
//  AppleNotes
//
//  Created by David Sherlock on 2026.
//
//  Inflating the gzip stream every Apple Notes body is stored as.
//
//  Foundation cannot do this and Apple's `Compression` framework only ALMOST can: its
//  `COMPRESSION_ZLIB` is raw DEFLATE, with no gzip framing. So the 10-byte header, its four
//  optional extra fields and the 8-byte trailer are stripped here by hand and the middle is
//  handed over. Verified against Python's `zlib` on a real note: byte-for-byte identical.
//
//  The trailer's ISIZE is the uncompressed size modulo 2^32, which makes it a good starting
//  guess and a bad promise — a note over 4 GB would wrap it, and a corrupt trailer can say
//  anything. So it seeds the buffer and the buffer grows if the decoder fills it exactly,
//  because "filled the buffer" and "needed exactly that much" are indistinguishable.
//

import Compression
import Foundation

/// Gzip decompression.
public enum Gzip {

    /// How many times the output buffer may double before giving up. Twelve doublings of
    /// the ISIZE hint covers any note that is not pathological.
    static let maximumAttempts = 12

    /// Inflate a gzip stream.
    ///
    /// - Parameter data: a complete gzip member, magic bytes included.
    /// - Returns: the inflated bytes, or `nil` if the input is not gzip or will not inflate.
    public static func inflate(_ data: Data) -> Data? {
        guard let start = deflateStart(in: data), start < data.count - 8 else { return nil }
        let deflated = data.subdata(in: start..<(data.count - 8))
        guard !deflated.isEmpty else { return Data() }

        // ISIZE, little-endian, in the last four bytes.
        let hinted = data.suffix(4).reversed().reduce(0) { $0 << 8 | Int($1) }
        var capacity = max(hinted, deflated.count * 4, 1024)

        for _ in 0..<maximumAttempts {
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { destination in
                deflated.withUnsafeBytes { source in
                    compression_decode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        source.bindMemory(to: UInt8.self).baseAddress!, deflated.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            // Exactly filling the buffer is ambiguous — it may have stopped early because
            // there was no room — so only a short write proves the output is complete.
            if written > 0, written < capacity { return out.prefix(written) }
            capacity *= 2
        }
        return nil
    }

    /// Where the DEFLATE payload begins, past the gzip header and its optional fields.
    ///
    /// - Returns: `nil` when the input does not begin with a DEFLATE-method gzip header.
    static func deflateStart(in data: Data) -> Int? {
        guard data.count > 18 else { return nil }
        let bytes = [UInt8](data.prefix(512))
        guard bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else { return nil }

        let flags = bytes[3]
        var index = 10
        func readable(_ n: Int) -> Bool { index + n <= bytes.count }

        if flags & 0x04 != 0 {                                   // FEXTRA: a length then that many bytes
            guard readable(2) else { return nil }
            index += 2 + (Int(bytes[index]) | Int(bytes[index + 1]) << 8)
        }
        if flags & 0x08 != 0 {                                   // FNAME: NUL-terminated
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x10 != 0 {                                   // FCOMMENT: NUL-terminated
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x02 != 0 { index += 2 }                      // FHCRC
        return index < data.count ? index : nil
    }
}
