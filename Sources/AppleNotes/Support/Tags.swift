//
//  Tags.swift
//  AppleNotes
//
//  Created by David Sherlock on 2026.
//
//  Finding the hashtags in a note's text.
//
//  THE DATABASE HAS A TABLE FOR THIS AND IT IS EMPTY. `ICHashtag` is a real entity in the
//  Core Data model, there is no join table alongside it, and on a machine with `#claudetest`
//  and `#decoding` sitting in a note's body it held zero rows. That note was created through
//  AppleScript, and the likeliest reading is that Notes.app registers a tag when someone
//  types one rather than when text containing one arrives — so the entity may populate for
//  tags typed by hand and has not been seen to.
//
//  So this reads the text instead, which works either way and is honest about what it is: the
//  hashtags PRESENT IN A NOTE, not Apple's index of them. The difference matters if Apple ever
//  supports renaming a tag, because the index would be the truth and this would be a copy.
//
//  THE RULES ARE APPLE'S, as far as they can be observed. A tag is `#` then letters, digits or
//  underscores — no spaces, and a `#` inside a word is not one, so `C#` in prose and `#4` as a
//  house number do not become tags. Unicode letters count, because Notes accepts them.
//

import Foundation

/// Hashtag extraction.
public enum Tags {

    /// The hashtags in a string, in order, without duplicates.
    ///
    /// - Parameter text: a note's body.
    /// - Returns: tag names WITHOUT the leading `#`.
    public static func found(in text: String) -> [String] {
        var tags: [String] = []
        var seen = Set<String>()
        var current = ""
        var collecting = false
        var previous: Character?

        func finish() {
            defer { current = ""; collecting = false }
            guard !current.isEmpty else { return }
            // A tag of digits alone is a number — "#4" is a house number, not a tag, and
            // Notes does not make one either.
            guard current.contains(where: { $0.isLetter || $0 == "_" }) else { return }
            let lowered = current.lowercased()
            guard seen.insert(lowered).inserted else { return }
            tags.append(current)
        }

        for character in text {
            if collecting {
                if character.isLetter || character.isNumber || character == "_" {
                    current.append(character)
                    previous = character
                    continue
                }
                finish()
            }
            if character == "#" {
                // A `#` glued to the end of a word is not a tag opener: `C#` is a language
                // and `item#3` is a reference.
                let attached = previous.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false
                collecting = !attached
            }
            previous = character
        }
        finish()
        return tags
    }
}
