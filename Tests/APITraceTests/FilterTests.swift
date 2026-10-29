//
//  FilterTests.swift
//  DevLens / APITraceTests
//
//  Created by Denys Volkov.
//  MIT License.
//

import XCTest
@testable import APITrace

final class FilterTests: XCTestCase {

    private let records: [APITrace.Record] = [
        mark(0, "TraceStart", at: 0),
        req(1, "api.example.com", "/me", start: 0.1, end: 0.3),
        req(2, "api.example.com", "/missing", start: 0.2, end: 0.4, status: 404),
        req(3, "metrics.omtrdc.net", "/b/ss", start: 0.3, end: 0.5, status: nil, error: "NSURLErrorDomain#-1200"),
        req(4, "dpm.demdex.net", "/id", start: 0.4, end: 0.6, status: nil, error: "NSURLErrorDomain#-999"),
        req(5, "cdn.example.com", "/img.png", start: 0.5, end: 0.7),
        mark(6, "HomeAppeared", at: 0.8),
    ]

    func testDefaultKeepsEverything() {
        XCTAssertFalse(APITrace.Filter.all.isActive)
        XCTAssertEqual(APITrace.Filter.all.apply(records).count, records.count)
    }

    func testExcludeTransportErrors() {
        let f = APITrace.Filter(excludeTransportErrors: true)
        XCTAssertEqual(f.apply(records).map { $0.id }, [0, 1, 2, 5, 6])
    }

    func testExcludeHTTPErrors() {
        let f = APITrace.Filter(excludeHTTPErrors: true)
        XCTAssertEqual(f.apply(records).map { $0.id }, [0, 1, 3, 4, 5, 6])
    }

    func testSuccessfulOnly() {
        XCTAssertEqual(APITrace.Filter.successfulOnly.apply(records).map { $0.id }, [0, 1, 5, 6])
    }

    func testExcludedHostsMatchDomainAndSubdomains() {
        let f = APITrace.Filter(excludedHosts: ["omtrdc.net", "DEMDEX.net"])
        XCTAssertEqual(f.apply(records).map { $0.id }, [0, 1, 2, 5, 6])
        XCTAssertTrue(APITrace.Filter.host("a.b.example.com", matches: "example.com"))
        XCTAssertTrue(APITrace.Filter.host("example.com", matches: "example.com"))
        XCTAssertFalse(APITrace.Filter.host("notexample.com", matches: "example.com"))
    }

    func testIncludedHosts() {
        let f = APITrace.Filter(includedHosts: ["example.com"])
        XCTAssertEqual(f.apply(records).map { $0.id }, [0, 1, 2, 5, 6])
    }

    func testMarksAlwaysPass() {
        let f = APITrace.Filter(excludeTransportErrors: true, excludeHTTPErrors: true, excludedHosts: ["example.com", "omtrdc.net", "demdex.net"])
        XCTAssertEqual(f.apply(records).map { $0.id }, [0, 6])
    }

    func testReportHeaderShowsHiddenCount() {
        let shown = APITrace.Filter.successfulOnly.apply(records)
        let text = TraceExport.report(records: shown, label: "x", hidden: records.count - shown.count)
        XCTAssertTrue(text.hasPrefix("APITrace report  label=x  requests=2  marks=2  network span=0.600s  hidden by filter=3"), text)
        XCTAssertFalse(text.contains("omtrdc"))
        XCTAssertFalse(text.contains("Errors/4xx/5xx"))
        XCTAssertFalse(TraceExport.report(records: records, label: "x").contains("hidden by filter"))
    }
}
