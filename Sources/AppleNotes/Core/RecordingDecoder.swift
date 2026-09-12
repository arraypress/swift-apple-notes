//
//  RecordingDecoder.swift
//  AppleNotes
//
//  Created by David Sherlock on 2026.
//
//  Pulling the transcription out of an audio recording attachment.
//
//  SAME CRDT AS A TABLE, DIFFERENT SHAPE AND A DIFFERENT WRAPPER. The object graph is the one
//  ``MergeableData`` reads, but a recording's blob is NOT gzipped where a table's is, and its
//  graph sits at the top level where a table's is two envelopes down. Both were in one
//  library at the same time, so neither is a version that will settle down — which is why
//  ``MergeableData`` looks for the graph and tries inflating rather than assuming either.
//
//  SEGMENTS ARE FOUND BY WHAT THEY CARRY, not by walking down to them. The graph nests a
//  recording's `fragments` in one collection type and each fragment's `transcript` in
//  another, neither of which is the ordered set a table uses — supporting both would mean
//  two more container formats for no gain, because a segment is already unique: it is the
//  only object with `text`, `timestamp` and `duration` on it. So they are collected flat.
//
//  ORDER COMES FROM THE TIMESTAMPS. The graph does carry its own order, and for a transcript
//  the timestamps are both the better answer and a self-checking one: sorted by start, every
//  segment's end lands exactly on the next one's start across a real recording. See
//  ``Transcript/isContiguous``. Sorting is stable, so segments with no timestamp — none have
//  been seen — keep the order they were found in rather than jumping to the front.
//

import Foundation

/// Decoding an audio attachment's transcription.
public enum RecordingDecoder {

    /// Attribute names on a transcript segment, measured from a real recording.
    enum Attribute {
        static let text = "text"
        static let timestamp = "timestamp"
        static let duration = "duration"
        static let speaker = "speaker"
        /// The one attribute a wrapped string or number object holds.
        static let value = "self"
        static let double = "doubleValue"
    }

    /// Turn an audio attachment's stored blob into a transcript.
    ///
    /// - Parameter data: the raw `ZMERGEABLEDATA1` blob.
    /// - Returns: the transcript, or `nil` if there is none. A recording that has not been
    ///   transcribed carries the container with no segments in it, which is `nil` here
    ///   rather than an empty transcript — there is nothing to show either way, and `nil`
    ///   does not invite a caller to print an empty quotation.
    public static func decode(_ data: Data) -> Transcript? {
        guard let graph = MergeableData.graph(data) else { return nil }

        var segments: [Transcript.Segment] = []
        for entry in graph.entries {
            guard case .map(_, let attributes) = entry,
                  let textReference = attributes[Attribute.text],
                  let text = string(textReference, in: graph) else { continue }
            segments.append(Transcript.Segment(
                text: text,
                start: number(attributes[Attribute.timestamp], in: graph) ?? 0,
                duration: number(attributes[Attribute.duration], in: graph) ?? 0,
                speaker: attributes[Attribute.speaker].flatMap { string($0, in: graph) }))
        }
        guard !segments.isEmpty else { return nil }

        // Stable, so anything without a timestamp keeps where it was rather than sorting
        // to the front as if it were the first word.
        return Transcript(segments: segments.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element))
    }

    /// A string held one hop away, in an object whose only attribute is `self`.
    static func string(_ reference: MergeableData.Reference?,
                       in graph: MergeableData.Graph) -> String? {
        guard case .register(let inner)? = graph.entry(reference),
              case .map(_, let holder)? = graph.entry(inner),
              case .string(let value)? = holder[Attribute.value] else { return nil }
        return value
    }

    /// A number held one hop away, in an object whose only attribute is `doubleValue`.
    ///
    /// The value is a protobuf `fixed64`, so it is a little-endian IEEE double — the same
    /// byte order as an ink's colour and the opposite of a drawing's canvas bounds. Getting
    /// it wrong produces timestamps in the 1e-300 range, which sort into an order and look
    /// like a transcript until you read the numbers.
    static func number(_ reference: MergeableData.Reference?,
                       in graph: MergeableData.Graph) -> Double? {
        guard case .register(let inner)? = graph.entry(reference),
              case .map(_, let holder)? = graph.entry(inner),
              case .double(let value)? = holder[Attribute.double] else { return nil }
        return value
    }
}
