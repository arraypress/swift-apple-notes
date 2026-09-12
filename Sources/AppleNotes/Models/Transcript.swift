//
//  Transcript.swift
//  AppleNotes
//
//  Created by David Sherlock on 2026.
//
//  What macOS heard in an audio recording attached to a note.
//
//  WORD BY WORD, not sentence by sentence. Apple writes one segment per word, each with the
//  second it starts and how long it lasts, which is more than a transcript usually gives you:
//  a caller can seek to a word, or line the text up against the audio, rather than only read
//  it. ``text`` joins them back together for callers that just want the sentence.
//
//  THE RECONCILIATION THAT SAYS THIS IS READ CORRECTLY is ``isContiguous``: every segment's
//  start plus its duration equals the next segment's start, exactly, across a real recording.
//  That is a property of the data nothing about a wrong field number would preserve — read
//  the wrong field as the timestamp and the sequence stops joining up.
//
//  SPEAKERS ARE CARRIED AND HAVE ALWAYS BEEN EMPTY here. Apple keeps a `speaker` on every
//  segment and the one real recording available left it unset throughout, which is what a
//  single-voice memo should look like. So the field is read and reported as `nil` rather than
//  invented; whether Apple fills it for a call recording is untested.
//

import Foundation

/// A transcription of an audio recording in a note.
public struct Transcript: Equatable, Hashable, Sendable, Codable {

    /// One word, with where it sits in the recording.
    public struct Segment: Equatable, Hashable, Sendable, Codable {

        /// The word, as Apple heard it.
        public let text: String

        /// Seconds from the start of the recording.
        public let start: Double

        /// How long it lasts, in seconds.
        public let duration: Double

        /// Who said it, when Apple worked that out. Always `nil` in anything measured here.
        public let speaker: String?

        public init(text: String, start: Double, duration: Double, speaker: String? = nil) {
            self.text = text
            self.start = start
            self.duration = duration
            self.speaker = speaker
        }

        /// The second the word ends.
        public var end: Double { start + duration }
    }

    /// The words, earliest first.
    public let segments: [Segment]

    public init(segments: [Segment]) { self.segments = segments }

    /// The whole transcription as one line.
    public var text: String { segments.map(\.text).joined(separator: " ") }

    /// Where the last word ends, which is as much of the recording as was transcribed.
    ///
    /// NOT the recording's length — a recording can end in silence, and silence produces no
    /// segment. `ZDURATION` on the attachment row is the recording.
    public var transcribedDuration: Double { segments.last?.end ?? 0 }

    /// Whether every word runs straight into the next.
    ///
    /// True for a real recording, and the check that says the timestamps are being read from
    /// the right field rather than merely producing plausible numbers. A tolerance of a
    /// millisecond absorbs the float arithmetic and nothing else.
    public var isContiguous: Bool {
        guard segments.count > 1 else { return !segments.isEmpty }
        return zip(segments, segments.dropFirst()).allSatisfy {
            abs($0.end - $1.start) < 0.001
        }
    }

    /// A one-line description for a listing.
    public var summary: String {
        guard !segments.isEmpty else { return "no transcript" }
        return String(format: "%d words over %.1fs: “%@”", segments.count,
                      transcribedDuration, text.count > 60 ? String(text.prefix(60)) + "…" : text)
    }
}
