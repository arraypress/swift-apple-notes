//
//  Highlight.swift
//  AppleNotes
//
//  Created by David Sherlock on 2026.
//
//  The colour behind highlighted text.
//
//  A CODE, NOT A COLOUR. Notes stores highlighting as a small integer on the attribute run —
//  1 to 5 — rather than as a colour value, which is why the palette is closed: the format menu
//  offers exactly five and there is no way to write a sixth. Apple models it the same way,
//  and the app names the picker `updateHighlightColorPickerWithType:`. A *type*.
//
//  DO NOT CONFUSE IT WITH RUN FIELD 10, which is a real RGBA colour — four little-endian
//  floats — and appears on text pasted in from elsewhere rather than on anything highlighted
//  in Notes. Two different fields, two different things, and the highlight is the integer.
//
//  THE MAPPING WAS MEASURED, from a note holding five highlighted lines each of which names
//  its own colour. That makes it self-checking: the text says "Mint" and the code says 4, so
//  there is no step where a colour had to be recognised by eye. The codes run in the order the
//  format menu lists them.
//
//  Apple's own RGB values for these are NOT recorded here. The names come from the menu and
//  are exact; the pixels a renderer should use were never measured, and inventing five plausible
//  hex codes would be the kind of guess this library does not make.
//

import Foundation

/// The colour of a text highlight.
public enum Highlight: Equatable, Hashable, Sendable, Codable {

    case purple
    case pink
    case orange
    case mint
    case blue

    /// A code Notes wrote that this version does not know.
    ///
    /// Kept rather than flattened to a default, so a palette Apple adds later reads as an
    /// unknown highlight instead of quietly becoming purple.
    case other(Int)

    /// The highlight for a stored code, or `nil` for none.
    ///
    /// - Parameter code: run field 14. Zero and absent both mean unhighlighted.
    public static func from(code: Int) -> Highlight? {
        switch code {
        case 0: return nil
        case 1: return .purple
        case 2: return .pink
        case 3: return .orange
        case 4: return .mint
        case 5: return .blue
        default: return .other(code)
        }
    }

    /// The code Notes stores.
    public var code: Int {
        switch self {
        case .purple: return 1
        case .pink: return 2
        case .orange: return 3
        case .mint: return 4
        case .blue: return 5
        case .other(let code): return code
        }
    }

    /// Apple's name for the colour, as the format menu writes it.
    public var name: String {
        switch self {
        case .purple: return "purple"
        case .pink: return "pink"
        case .orange: return "orange"
        case .mint: return "mint"
        case .blue: return "blue"
        case .other(let code): return "highlight-\(code)"
        }
    }
}
