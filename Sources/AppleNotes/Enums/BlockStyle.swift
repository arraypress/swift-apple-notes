//
//  BlockStyle.swift
//  AppleNotes
//
//  Created by David Sherlock on 2026.
//
//  What kind of paragraph a run of text is, from the style code Notes stores against it.
//
//  EVERY CODE HERE IS CONFIRMED, and the last two were settled by asking Apple rather than by
//  finding a note that used them. `NotesShared.framework` exposes `ICTTMutableParagraphStyle`
//  through the Objective-C runtime, and it answers questions about itself: set its `style`
//  property to a number and it will tell you whether that is a header, a list, a checklist
//  and whether it can be indented. Codes 0, 1 and 2 all report `isHeader`; 100, 101 and 102
//  report `isList`; 103 reports both `isList` and `isChecklist` AND creates an `ICTTTodo` of
//  its own. That is Apple's own implementation as the oracle, which beats a decoded sample.
//
//  It also found a bug: code 3 is an explicit BODY style — `canIndent`, not a header, not a
//  list — and was being kept as `.other(3)`. Absent-style and style-3 both mean body text,
//  and only one of them was being read that way.
//
//  Block quote is NOT in this list, and that is the point: it is not a style code at all but
//  its own field on the paragraph style, so it modifies one of these rather than replacing
//  it. See ``Block/isBlockQuote``.
//
//  An unrecognised code becomes ``other`` carrying its number rather than being forced into
//  the nearest case. Apple adds paragraph styles — this is a format that gained collapsible
//  sections and tables after it shipped — and silently rendering a new one as body text is
//  how a tool starts quietly lying about someone's notes.
//

import Foundation

/// The paragraph style of a block of note text.
public enum BlockStyle: Equatable, Hashable, Sendable, Codable {

    /// Ordinary body text: style code 3, or no style code at all.
    ///
    /// Both spellings occur. Notes writes no paragraph style for plain text it never styled,
    /// and writes code 3 for text explicitly set back to Body from the format menu.
    case body
    /// VERIFIED — style code 0.
    case title
    /// VERIFIED — style code 1, which `ICTTParagraphStyle` reports as `isHeader`.
    case heading
    /// VERIFIED — style code 2, which `ICTTParagraphStyle` reports as `isHeader`.
    case subheading
    /// VERIFIED — style code 4.
    case monospaced
    /// VERIFIED — style code 100.
    case bulleted
    /// VERIFIED — style code 101.
    case dashed
    /// VERIFIED — style code 102.
    case numbered
    /// VERIFIED — style code 103, with a nested message carrying the tick state.
    ///
    /// Both states verified against a real note: the nested message's field 2 reads 1 for a
    /// ticked item and 0 for an unticked one, alongside a per-item UUID in field 1.
    case checklist(done: Bool)
    /// A style code this version does not recognise, kept rather than flattened.
    case other(Int)

    /// Whether the style is already a heading of some kind.
    ///
    /// Notes draws these bold, and a Markdown import marks the text bold as well, so a
    /// heading arrives carrying a weight it does not need. See ``Block/markdown``.
    public var isHeading: Bool {
        switch self {
        case .title, .heading, .subheading: return true
        default: return false
        }
    }

    /// The style for a code, and the checklist state when it is one.
    ///
    /// - Parameters:
    ///   - code: the `styleType` from the paragraph style.
    ///   - done: whether a checklist item is ticked; ignored for every other style.
    public static func from(code: Int, done: Bool = false) -> BlockStyle {
        switch code {
        case 0:   return .title
        case 1:   return .heading
        case 2:   return .subheading
        case 3:   return .body
        case 4:   return .monospaced
        case 100: return .bulleted
        case 101: return .dashed
        case 102: return .numbered
        case 103: return .checklist(done: done)
        default:  return .other(code)
        }
    }

    /// Whether this style makes a list item, so a renderer knows to mark it.
    public var isListItem: Bool {
        switch self {
        case .bulleted, .dashed, .numbered, .checklist: return true
        default: return false
        }
    }

    /// The Markdown prefix this style opens its line with.
    public var markdownPrefix: String {
        switch self {
        case .body, .monospaced, .other: return ""
        case .title:                     return "# "
        case .heading:                   return "## "
        case .subheading:                return "### "
        case .bulleted, .dashed:         return "- "
        case .numbered:                  return "1. "
        case .checklist(let done):       return done ? "- [x] " : "- [ ] "
        }
    }
}
