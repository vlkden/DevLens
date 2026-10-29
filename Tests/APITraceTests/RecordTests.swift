//
//  RecordTests.swift
//  DevLens / APITraceTests
//
//  Created by Denys Volkov.
//  MIT License.
//

import XCTest
@testable import APITrace

final class RecordTests: XCTestCase {

    func testURLSanitisationKeepsQueryKeysOnly() {
        let r = APITrace.Record(id: 1, kind: "request", source: "x", name: "", start: 0)
        r.apply(url: URL(string: "https://api.example.com/v1/items?page=2&token=SECRET&q=hello%20world"), method: "GET")
        XCTAssertEqual(r.host, "api.example.com")
        XCTAssertEqual(r.path, "/v1/items")
        XCTAssertEqual(r.queryKeys, ["page", "token", "q"])
        XCTAssertEqual(r.name, "GET api.example.com/v1/items")
        // No value may leak anywhere in the record.
        let dump = "\(r.name)\(r.host ?? "")\(r.path ?? "")\(r.queryKeys.joined())"
        XCTAssertFalse(dump.contains("SECRET"))
        XCTAssertFalse(dump.contains("hello"))
    }

    func testURLSanitisationWithoutURL() {
        let r = APITrace.Record(id: 1, kind: "request", source: "x", name: "", start: 0)
        r.apply(url: nil, method: "POST")
        XCTAssertEqual(r.name, "POST ?")
        XCTAssertNil(r.host)
        XCTAssertEqual(r.queryKeys, [])
    }

    func testDurationAndIsRequest() {
        XCTAssertEqual(req(1, start: 1.0, end: 1.5).duration ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertNil(req(1, start: 1.0, end: nil).duration)
        XCTAssertTrue(req(1, start: 0, end: 1).isRequest)
        XCTAssertFalse(mark(2, "Home", at: 0).isRequest)
        let web = APITrace.Record(id: 3, kind: "webview-fetch", source: "webview", name: "GET h/p", start: 0)
        XCTAssertTrue(web.isRequest)
    }

    func testCodableRoundTrip() throws {
        let r = req(7, start: 0.25, end: 1.0, status: 201, tls: 0.1, ttfb: 0.3, download: 0.05)
        r.queryKeys = ["a", "b"]
        r.phases = [.init(name: "dns", start: 0.25, end: 0.3), .init(name: "wait", start: 0.5, end: 0.8)]
        r.requestBytes = 120
        r.responseBytes = 4096
        r.redirects = 1
        r.protocolName = "h2"
        r.queueLabel = "com.apple.main-thread"
        r.metricsRecorded = true   // runtime-only, must not be encoded

        let data = try JSONEncoder().encode(r)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("metricsRecorded"))
        XCTAssertFalse(json.contains("observation"))

        let back = try JSONDecoder().decode(APITrace.Record.self, from: data)
        XCTAssertEqual(back.id, 7)
        XCTAssertEqual(back.name, r.name)
        XCTAssertEqual(back.status, 201)
        XCTAssertEqual(back.queryKeys, ["a", "b"])
        XCTAssertEqual(back.phases, r.phases)
        XCTAssertEqual(back.requestBytes, 120)
        XCTAssertEqual(back.protocolName, "h2")
        XCTAssertEqual(back.duration ?? -1, 0.75, accuracy: 1e-9)
        XCTAssertFalse(back.metricsRecorded)
    }

    func testTraceFileRoundTripAndBareArrayFallback() throws {
        let file = APITrace.TraceFile(label: "run-a", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                      records: [mark(1, "TraceStart", at: 0), req(2, start: 0.1, end: 0.4)])
        let data = try file.encoded()
        let back = try APITrace.TraceFile.decode(data)
        XCTAssertEqual(back.version, 1)
        XCTAssertEqual(back.label, "run-a")
        XCTAssertEqual(back.startedAt.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
        XCTAssertEqual(back.records.count, 2)

        let bare = try JSONEncoder().encode(file.records)
        let fromBare = try APITrace.TraceFile.decode(bare)
        XCTAssertEqual(fromBare.records.count, 2)
        XCTAssertEqual(fromBare.label, "trace")
    }
}
