//
//  TranscriptTests.swift
//  AppleNotesTests
//
//  Created by David Sherlock on 2026.
//
//  What macOS heard in a recording, and the ways reading it can go quietly wrong.
//
//  The fixture is raw and ungzipped with its graph at the top level, because that is how a
//  real recording is stored — a table is gzipped and wrapped in two envelopes. Both shapes
//  existed in one library at once, so a decoder that assumes either is wrong half the time.
//

import XCTest
@testable import AppleNotes

final class TranscriptTests: XCTestCase {

    private let spoken: [(text: String, start: Double, duration: Double)] = [
        ("Just", 0.72, 0.30), ("a", 1.02, 0.24), ("test", 1.26, 0.54)
    ]

    func testReadsWordsWithTheirTimings() {
        let transcript = RecordingDecoder.decode(Fixtures.recording(spoken))
        XCTAssertEqual(transcript?.segments.count, 3)
        XCTAssertEqual(transcript?.text, "Just a test")
        XCTAssertEqual(transcript?.segments.first?.start ?? 0, 0.72, accuracy: 0.0001)
        XCTAssertEqual(transcript?.segments.first?.end ?? 0, 1.02, accuracy: 0.0001)
        XCTAssertEqual(transcript?.transcribedDuration ?? 0, 1.80, accuracy: 0.0001)
    }

    func testTheWordsJoinUp() {
        // Every word's end lands on the next word's start. This is the reconciliation that
        // says the timestamp is being read from the right field: a wrong one still sorts
        // into an order and still looks like a transcript.
        XCTAssertEqual(RecordingDecoder.decode(Fixtures.recording(spoken))?.isContiguous, true)
    }

    func testNoticesWhenTheWordsDoNotJoinUp() {
        let gapped = [("one", 0.0, 0.5), ("two", 2.0, 0.5)] as [(String, Double, Double)]
        XCTAssertEqual(RecordingDecoder.decode(Fixtures.recording(gapped))?.isContiguous, false)
    }

    func testPutsTheWordsInTimeOrder() {
        let shuffled = [spoken[2], spoken[0], spoken[1]]
        XCTAssertEqual(RecordingDecoder.decode(Fixtures.recording(shuffled))?.text, "Just a test")
    }

    func testReadsTimestampsLittleEndian() {
        // Read big-endian these become numbers around 1e-300. They still sort, and they
        // still produce a transcript — one whose every word starts at zero.
        let transcript = RecordingDecoder.decode(Fixtures.recording(spoken))
        XCTAssertGreaterThan(transcript?.segments.last?.start ?? 0, 1)
    }

    func testCarriesASpeakerWhenThereIsOne() {
        XCTAssertNil(RecordingDecoder.decode(Fixtures.recording(spoken))?.segments.first?.speaker)
        let named = Fixtures.recording(spoken, speaker: "Speaker 1")
        XCTAssertEqual(RecordingDecoder.decode(named)?.segments.first?.speaker, "Speaker 1")
    }

    func testAnUntranscribedRecordingIsNothingRatherThanEmpty() {
        // A recording that has not been transcribed carries the container with no segments.
        // Nil rather than an empty transcript: it does not invite printing an empty quote.
        XCTAssertNil(RecordingDecoder.decode(Fixtures.recording([])))
        XCTAssertNil(RecordingDecoder.decode(Data()))
        XCTAssertNil(RecordingDecoder.decode(Data("not protobuf".utf8)))
    }

    func testDoesNotMistakeATableForATranscript() {
        XCTAssertNil(RecordingDecoder.decode(Fixtures.table([["a", "b"]])))
    }

    func testDoesNotMistakeATranscriptForATable() {
        XCTAssertNil(TableDecoder.decode(Fixtures.recording(spoken)))
    }

    func testSummarisesWhatItHeard() {
        let transcript = RecordingDecoder.decode(Fixtures.recording(spoken))
        XCTAssertEqual(transcript?.summary, "3 words over 1.8s: “Just a test”")
        XCTAssertEqual(Transcript(segments: []).summary, "no transcript")
    }
}
