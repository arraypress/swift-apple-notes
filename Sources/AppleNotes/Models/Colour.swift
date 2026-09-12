//
//  Colour.swift
//  AppleNotes
//
//  Created by David Sherlock on 2026.
//
//  A colour, as Notes stores one: four channels from zero to one.
//
//  NOT THE SAME THING AS A HIGHLIGHT. Highlighting is a code from a closed palette of five
//  and has no colour value at all — see ``Highlight``. This is a real colour, and the two
//  live on different fields of the same attribute run.
//
//  BYTE ORDER IS NOT CONSISTENT ACROSS THE FORMAT and this is the type that keeps having to
//  say so. A run's colour and an ink's colour are protobuf `fixed32`, so little-endian. A
//  drawing's shape and canvas colours are bare blobs of BIG-endian floats. Read either the
//  wrong way round and every channel lands near zero — which is black, a perfectly valid
//  colour — so the mistake renders rather than failing.
//

import Foundation

/// A colour with an alpha channel, each from 0 to 1.
public struct Colour: Equatable, Hashable, Sendable, Codable {

    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// The colour as `#RRGGBB`. Alpha is not in it; read ``alpha`` for that.
    public var hex: String {
        func channel(_ value: Double) -> Int { Int((max(0, min(1, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(red), channel(green), channel(blue))
    }
}
