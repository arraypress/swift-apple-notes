//
//  PipeCollectorTests.swift
//  AppleNotesTests
//
//  The runner's pipes are read while the child runs: 1 MB on each stream,
//  past the 64 KB a pipe holds, comes back whole without waiting on a
//  timeout. No Notes, no osascript — a shell writes the payload.
//

import Foundation
import XCTest
@testable import AppleNotes

final class PipeCollectorTests: XCTestCase {

    func testBothStreamsPastAPipeBufferComeBackWhole() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "head -c 1048576 /dev/zero | tr '\\0' a; head -c 1048576 /dev/zero | tr '\\0' b >&2"]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let out = PipeCollector(output), err = PipeCollector(errors)
        try process.run()
        let started = Date()
        process.waitUntilExit()
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertEqual(out.collected().count, 1_048_576)
        XCTAssertEqual(err.collected().count, 1_048_576)
    }
}
