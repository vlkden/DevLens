//
//  FindingsTests.swift
//  DevLens / APITraceTests
//
//  Created by Denys Volkov.
//  MIT License.
//

import XCTest
@testable import APITrace

final class FindingsTests: XCTestCase {

    // MARK: Serial chains

    func testSerialChainsDetectsWaterfall() {
        // Four requests, each starting 50ms after the previous one ends.
        let reqs = [
            req(1, "a.example.com", "/1", start: 0.00, end: 0.20),
            req(2, "a.example.com", "/2", start: 0.25, end: 0.40),
            req(3, "a.example.com", "/3", start: 0.45, end: 0.60),
            req(4, "a.example.com", "/4", start: 0.65, end: 0.80),
        ]
        XCTAssertEqual(Findings.serialChains(reqs), .init(serialized: 3, longest: 4))
    }

    func testSerialChainsIgnoresParallelRequests() {
        // All four start at the same time.
        let reqs = (1...4).map { req($0, "a.example.com", "/\($0)", start: 0.0, end: 0.3) }
        XCTAssertEqual(Findings.serialChains(reqs), .init(serialized: 0, longest: 1))
    }

    func testSerialChainsBreaksOnLongGap() {
        let reqs = [
            req(1, "a.example.com", "/1", start: 0.0, end: 0.2),
            req(2, "a.example.com", "/2", start: 0.25, end: 0.4),   // serialized
            req(3, "a.example.com", "/3", start: 1.00, end: 1.2),   // gap 600ms, chain breaks
            req(4, "a.example.com", "/4", start: 1.25, end: 1.4),   // serialized
        ]
        XCTAssertEqual(Findings.serialChains(reqs), .init(serialized: 2, longest: 2))
    }

    func testSerialChainsUsesMaxEndOfEverythingBefore() {
        // Request 1 is long; request 2 starts and ends inside it; request 3 starts right after 2 ends
        // but 1 is still in flight, so 3 is NOT serialized.
        let reqs = [
            req(1, "a.example.com", "/1", start: 0.0, end: 1.0),
            req(2, "a.example.com", "/2", start: 0.1, end: 0.3),
            req(3, "a.example.com", "/3", start: 0.35, end: 0.5),
        ]
        XCTAssertEqual(Findings.serialChains(reqs).serialized, 0)
    }

    func testSerialChainsEdgeCases() {
        XCTAssertEqual(Findings.serialChains([]), .init(serialized: 0, longest: 0))
        XCTAssertEqual(Findings.serialChains([req(1, start: 0, end: 1)]), .init(serialized: 0, longest: 0))
    }

    func testSerialChainsWindowIsConfigurable() {
        let reqs = [req(1, start: 0.0, end: 0.2), req(2, "b.example.com", start: 0.5, end: 0.7)]
        XCTAssertEqual(Findings.serialChains(reqs, window: 0.150).serialized, 0)
        XCTAssertEqual(Findings.serialChains(reqs, window: 0.400).serialized, 1)
    }

    // MARK: Duplicates

    func testDuplicates() {
        let reqs = [
            req(1, "a.example.com", "/me", start: 0, end: 1),
            req(2, "a.example.com", "/me", start: 0, end: 1),
            req(3, "a.example.com", "/me", start: 0, end: 1),
            req(4, "a.example.com", "/config", start: 0, end: 1),
            req(5, "a.example.com", "/config", start: 0, end: 1),
            req(6, "a.example.com", "/once", start: 0, end: 1),
            req(7, "a.example.com", "/me", method: "POST", start: 0, end: 1),   // different method, not a dup
        ]
        XCTAssertEqual(Findings.duplicates(reqs), [
            .init(name: "GET a.example.com/config", count: 2),
            .init(name: "GET a.example.com/me", count: 3),
        ])
        XCTAssertEqual(Findings.duplicates([req(1, start: 0, end: 1)]), [])
    }

    // MARK: New connections

    func testNewConnections() {
        let reqs = [
            req(1, "a.example.com", start: 0, end: 1, reused: false, tls: 0.10),
            req(2, "b.example.com", start: 0, end: 1, reused: false, tls: 0.15),
            req(3, "a.example.com", start: 0, end: 1, reused: true, tls: nil),
            req(4, "c.example.com", start: 0, end: 1, reused: nil),
        ]
        let fresh = Findings.newConnections(reqs)
        XCTAssertEqual(fresh.count, 2)
        XCTAssertEqual(fresh.tlsTotal, 0.25, accuracy: 1e-9)
        XCTAssertEqual(fresh.hosts, ["a.example.com", "b.example.com"])
    }

    // MARK: Idle gaps

    func testIdleGaps() {
        let reqs = [
            req(1, start: 0.0, end: 0.5),
            req(2, start: 0.2, end: 0.6),     // overlaps 1
            req(3, start: 0.7, end: 0.9),     // 100ms gap, below threshold
            req(4, start: 1.5, end: 1.6),     // 600ms gap
            req(5, start: 1.55, end: 3.0),    // overlaps 4
            req(6, start: 3.4, end: 3.5),     // 400ms gap
            req(7, start: 3.45, end: nil),    // in flight, ignored
        ]
        let gaps = Findings.idleGaps(reqs)
        XCTAssertEqual(gaps.count, 2)
        XCTAssertEqual(gaps[0], .init(start: 0.9, end: 1.5))
        XCTAssertEqual(gaps[1], .init(start: 3.0, end: 3.4))
        XCTAssertEqual(gaps[0].duration, 0.6, accuracy: 1e-9)
        XCTAssertEqual(Findings.idleGaps(reqs, threshold: 0.05).count, 3)
        XCTAssertEqual(Findings.idleGaps([]), [])
    }

    // MARK: Slowest / errors / main thread

    func testSlowest() {
        let reqs = [
            req(1, "a.example.com", "/fast", start: 0, end: 0.1),
            req(2, "a.example.com", "/slow", start: 0, end: 2.0),
            req(3, "a.example.com", "/mid", start: 0, end: 0.5),
            req(4, "a.example.com", "/open", start: 0, end: nil),
        ]
        XCTAssertEqual(Findings.slowest(reqs).map { $0.path }, ["/slow", "/mid", "/fast"])
        XCTAssertEqual(Findings.slowest(reqs, limit: 1).map { $0.path }, ["/slow"])
    }

    func testErrors() {
        let reqs = [
            req(1, "a.example.com", "/ok", start: 0, end: 1, status: 200),
            req(2, "a.example.com", "/notfound", start: 0, end: 1, status: 404),
            req(3, "a.example.com", "/boom", start: 0, end: 1, status: 500),
            req(4, "a.example.com", "/offline", start: 0, end: 1, status: nil, error: "NSURLErrorDomain#-1009"),
            req(5, "a.example.com", "/pending", start: 0, end: nil, status: nil),
            req(6, "a.example.com", "/redirect", start: 0, end: 1, status: 302),
        ]
        XCTAssertEqual(Findings.errors(reqs).map { $0.path }, ["/notfound", "/boom", "/offline"])
    }

    func testMainThreadStartsAndBySource() {
        let reqs = [
            req(1, start: 0, end: 1, source: "native:A", onMain: true),
            req(2, start: 0, end: 1, source: "native:A", onMain: false),
            req(3, start: 0, end: 1, source: "alamofire", onMain: true),
            req(4, start: 0, end: 1, source: "alamofire", onMain: nil),
        ]
        XCTAssertEqual(Findings.mainThreadStarts(reqs), 2)
        XCTAssertEqual(Findings.bySource(reqs), ["native:A": 2, "alamofire": 2])
    }

    // MARK: Lines

    func testLinesEmpty() {
        XCTAssertEqual(Findings.lines(for: []), ["  (no requests recorded)"])
    }

    func testLinesContainEverySection() {
        let reqs = [
            req(1, "a.example.com", "/me", start: 0.0, end: 0.3, source: "native:AppClient", reused: false, tls: 0.08, ttfb: 0.1, download: 0.02, onMain: true),
            req(2, "a.example.com", "/me", start: 0.35, end: 0.5, source: "alamofire", reused: true, ttfb: 0.05, download: 0.01),
            req(3, "a.example.com", "/fail", start: 1.0, end: 1.2, source: "alamofire", status: 500, reused: true),
        ]
        let lines = Findings.lines(for: reqs)
        XCTAssertEqual(lines[0], "  Requests by source: AppClient=1, alamofire=2")
        XCTAssertEqual(lines[1], "  Serialized: 1 of 3 requests started within 150ms after everything before them finished. Longest chain: 2.")
        XCTAssertEqual(lines[2], "  Duplicates: GET a.example.com/me ×2")
        XCTAssertEqual(lines[3], "  New connections: 1 (TLS handshakes total 0.080s). Hosts: a.example.com")
        XCTAssertEqual(lines[4], "  Summed server wait (TTFB): 0.150s. Summed download: 0.030s. (sums overlap when parallel)")
        XCTAssertEqual(lines[5], "  Slowest: GET a.example.com/me 0.300s; GET a.example.com/fail 0.200s; GET a.example.com/me 0.150s")
        XCTAssertEqual(lines[6], "  Errors/4xx/5xx: GET a.example.com/fail [500] ")
        XCTAssertEqual(lines[7], "  Started on main thread: 1.")
        XCTAssertEqual(lines[8], "  Idle gaps > 300ms (no request in flight): 0.500→1.000s (0.500s)")
        XCTAssertEqual(lines.count, 9)
    }
}
