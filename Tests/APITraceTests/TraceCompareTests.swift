//
//  TraceCompareTests.swift
//  DevLens / APITraceTests
//
//  Created by Denys Volkov.
//  MIT License.
//

import XCTest
@testable import APITrace

final class TraceCompareTests: XCTestCase {

    func testMedian() {
        XCTAssertNil(TraceCompare.median([]))
        XCTAssertEqual(TraceCompare.median([3]), 3)
        XCTAssertEqual(TraceCompare.median([3, 1, 2]), 2)
        XCTAssertEqual(TraceCompare.median([4, 1, 3, 2]) ?? 0, 2.5, accuracy: 1e-9)
    }

    func testNetworkSpan() {
        XCTAssertEqual(TraceCompare.networkSpan([]), 0)
        XCTAssertEqual(TraceCompare.networkSpan([req(1, start: 0.5, end: nil)]), 0)
        XCTAssertEqual(TraceCompare.networkSpan([req(1, start: 0.5, end: 1.0), req(2, start: 0.2, end: 0.6)]), 0.8, accuracy: 1e-9)
    }

    func testCompareBeforeAfter() {
        // Before: a 4-step waterfall with a duplicate.
        let before = [
            mark(0, "TraceStart", at: 0),
            req(1, "api.example.com", "/config", start: 0.00, end: 0.20),
            req(2, "api.example.com", "/me", start: 0.25, end: 0.55),
            req(3, "api.example.com", "/me", start: 0.60, end: 0.80),
            req(4, "api.example.com", "/feed", start: 0.85, end: 1.45),
            req(5, "legacy.example.com", "/flags", start: 1.50, end: 1.70),
        ]
        // After: parallel, duplicate removed, legacy endpoint gone, a new one added.
        let after = [
            mark(0, "TraceStart", at: 0),
            req(1, "api.example.com", "/config", start: 0.00, end: 0.20),
            req(2, "api.example.com", "/me", start: 0.00, end: 0.25),
            req(3, "api.example.com", "/feed", start: 0.00, end: 0.50),
            req(4, "api.example.com", "/bootstrap", start: 0.00, end: 0.30),
        ]
        let r = TraceCompare.compare(before: before, after: after, labelBefore: "b", labelAfter: "a")
        XCTAssertEqual(r.requestsBefore, 5)
        XCTAssertEqual(r.requestsAfter, 4)
        XCTAssertEqual(r.requestsDelta, -1)
        XCTAssertEqual(r.longestChainBefore, 5)
        XCTAssertEqual(r.longestChainAfter, 1)
        XCTAssertEqual(r.spanBefore, 1.70, accuracy: 1e-9)
        XCTAssertEqual(r.spanAfter, 0.50, accuracy: 1e-9)
        XCTAssertEqual(r.spanDelta, -1.20, accuracy: 1e-9)
        XCTAssertEqual(r.added, ["GET api.example.com/bootstrap"])
        XCTAssertEqual(r.removed, ["GET legacy.example.com/flags"])
        XCTAssertEqual(r.endpoints.map { $0.name }, ["GET api.example.com/config", "GET api.example.com/feed", "GET api.example.com/me"])
        let me = r.endpoints[2]
        XCTAssertEqual(me.countBefore, 2)
        XCTAssertEqual(me.countAfter, 1)
        XCTAssertEqual(me.medianBefore ?? 0, 0.25, accuracy: 1e-9)
        XCTAssertEqual(me.medianAfter ?? 0, 0.25, accuracy: 1e-9)

        let text = TraceCompare.render(r)
        XCTAssertTrue(text.hasPrefix("trace-compare  before=b  after=a"))
        XCTAssertTrue(text.contains("Requests"))
        XCTAssertTrue(text.contains("(-1)"))
        XCTAssertTrue(text.contains("+ GET api.example.com/bootstrap"))
        XCTAssertTrue(text.contains("- GET legacy.example.com/flags"))
    }

    func testCompareTraceFiles() throws {
        let b = APITrace.TraceFile(label: "before", startedAt: Date(), records: [req(1, start: 0, end: 1)])
        let a = APITrace.TraceFile(label: "after", startedAt: Date(), records: [req(1, start: 0, end: 0.5)])
        let r = TraceCompare.compare(before: try APITrace.TraceFile.decode(b.encoded()), after: try APITrace.TraceFile.decode(a.encoded()))
        XCTAssertEqual(r.labelBefore, "before")
        XCTAssertEqual(r.labelAfter, "after")
        XCTAssertEqual(r.endpoints.first?.medianAfter ?? 0, 0.5, accuracy: 1e-9)
    }
}
