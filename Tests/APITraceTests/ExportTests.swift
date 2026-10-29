//
//  ExportTests.swift
//  DevLens / APITraceTests
//
//  Created by Denys Volkov.
//  MIT License.
//

import XCTest
@testable import APITrace

final class ExportTests: XCTestCase {

    private func sample() -> [APITrace.Record] {
        let r1 = req(1, "api.example.com", "/v1/me", start: 0.10, end: 0.40, source: "native:AppClient", reused: false, tls: 0.05, ttfb: 0.1, download: 0.02, onMain: true)
        r1.queryKeys = ["page", "limit"]
        r1.phases = [.init(name: "dns", start: 0.10, end: 0.12), .init(name: "tls", start: 0.15, end: 0.20), .init(name: "empty", start: 0.3, end: 0.3)]
        r1.protocolName = "h2"
        r1.requestBytes = 100
        r1.responseBytes = 2048
        r1.redirects = 0
        r1.queueLabel = "com.apple.main-thread"
        let r2 = req(2, "cdn.example.com", "/img/a.png", start: 0.45, end: nil, source: "webview:www.example.com", status: nil, error: "TypeError: Failed to fetch", reused: nil)
        r2.kind = "webview-fetch"
        return [mark(0, "TraceStart", at: 0), r1, r2, mark(3, "HomeAppeared", at: 0.5)]
    }

    // MARK: CSV

    func testCSVEscape() {
        XCTAssertEqual(TraceExport.csvEscape("plain"), "plain")
        XCTAssertEqual(TraceExport.csvEscape("a,b"), "\"a,b\"")
        XCTAssertEqual(TraceExport.csvEscape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(TraceExport.csvEscape(""), "")
    }

    func testCSVShape() {
        let csv = TraceExport.csv(records: sample())
        let lines = csv.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], TraceExport.csvHeader)
        XCTAssertEqual(lines.count, 5)
        let columns = TraceExport.csvHeader.components(separatedBy: ",").count
        for line in lines.dropFirst() {
            // No embedded commas in this sample except the quoted error, so a split is a fair column count.
            XCTAssertEqual(line.components(separatedBy: ",").count, columns, line)
        }
        // Mark rows carry the mark name in the path column.
        XCTAssertTrue(lines[1].hasPrefix("0,mark,ui,0.000,,,,,,,TraceStart,"))
        // Query keys joined with |, never values.
        XCTAssertTrue(lines[2].contains(",page|limit,"))
        XCTAssertTrue(lines[2].hasSuffix(",1,com.apple.main-thread"))
    }

    func testCSVQuotesCommaInError() {
        let r = req(1, start: 0, end: 1, status: nil, error: "a,b")
        let line = TraceExport.csv(records: [r]).components(separatedBy: "\n")[1]
        XCTAssertTrue(line.contains(",\"a,b\","))
    }

    // MARK: Perfetto

    func testPerfettoDocumentShape() throws {
        let doc = TraceExport.perfettoDocument(records: sample(), label: "run-1")
        XCTAssertEqual(doc["displayTimeUnit"] as? String, "ms")
        let events = try XCTUnwrap(doc["traceEvents"] as? [[String: Any]])

        let complete = events.filter { $0["ph"] as? String == "X" }
        let instants = events.filter { $0["ph"] as? String == "i" }
        let meta = events.filter { $0["ph"] as? String == "M" }

        // 2 requests + 2 non-empty phases (the zero-length phase is dropped).
        XCTAssertEqual(complete.count, 4)
        XCTAssertEqual(complete.filter { $0["cat"] as? String == "phase" }.count, 2)
        XCTAssertEqual(instants.count, 2)
        XCTAssertTrue(instants.allSatisfy { $0["s"] as? String == "g" && $0["cat"] as? String == "mark" })

        // Lanes: native:AppClient, webview:www.example.com, ui-marks -> 3 thread_name + 1 process_name.
        XCTAssertEqual(meta.filter { $0["name"] as? String == "thread_name" }.count, 3)
        let process = try XCTUnwrap(meta.first { $0["name"] as? String == "process_name" })
        XCTAssertEqual((process["args"] as? [String: Any])?["name"] as? String, "APITrace run-1")

        let me = try XCTUnwrap(complete.first { $0["name"] as? String == "GET api.example.com/v1/me" })
        XCTAssertEqual(me["ts"] as? Int, 100_000)
        XCTAssertEqual(me["dur"] as? Int, 300_000)
        XCTAssertEqual(me["pid"] as? Int, 1)
        let args = try XCTUnwrap(me["args"] as? [String: Any])
        XCTAssertEqual(args["status"] as? Int, 200)
        XCTAssertEqual(args["reusedConnection"] as? Bool, false)
        XCTAssertEqual(args["protocol"] as? String, "h2")
        XCTAssertEqual(args["queryKeys"] as? String, "page,limit")
        XCTAssertEqual(args["responseBytes"] as? Int64, 2048)

        // In-flight request has zero duration and its error in args.
        let open = try XCTUnwrap(complete.first { $0["name"] as? String == "GET cdn.example.com/img/a.png" })
        XCTAssertEqual(open["dur"] as? Int, 0)
        XCTAssertEqual((open["args"] as? [String: Any])?["error"] as? String, "TypeError: Failed to fetch")

        // Serialises to valid JSON.
        let data = try XCTUnwrap(TraceExport.perfettoData(records: sample(), label: "run-1"))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
    }

    func testPerfettoEmptyTrace() throws {
        let doc = TraceExport.perfettoDocument(records: [], label: "empty")
        let events = try XCTUnwrap(doc["traceEvents"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["name"] as? String, "process_name")
    }

    // MARK: Report

    func testReportHeaderAndSections() {
        let text = TraceExport.report(records: sample(), label: "run-1")
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "APITrace report  label=run-1  requests=2  marks=2  network span=0.300s")
        XCTAssertTrue(lines[2].hasPrefix("start  dur    src"))
        XCTAssertTrue(lines[2].hasSuffix("name"))
        XCTAssertTrue(lines[3].contains("GET api.example.com/v1/me"))
        XCTAssertTrue(lines[3].contains("main"))
        XCTAssertTrue(lines[4].contains("ERR"))
        XCTAssertTrue(lines[4].contains("⚠︎ TypeError: Failed to fetch"))
        XCTAssertTrue(text.contains("Marks:\n  0.000   s  TraceStart\n  0.500   s  HomeAppeared"))
        XCTAssertTrue(text.contains("\nFindings:\n  Requests by source: AppClient=1, webview:www.example.com=1"))
    }

    func testReportEmpty() {
        let text = TraceExport.report(records: [], label: "x")
        XCTAssertTrue(text.hasPrefix("APITrace report  label=x  requests=0  marks=0  network span=0.000s"))
        XCTAssertTrue(text.hasSuffix("Findings:\n  (no requests recorded)"))
    }
}
