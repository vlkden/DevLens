//
//  LifecycleTests.swift
//  DevLens / APITraceTests
//
//  Created by Denys Volkov.
//  MIT License.
//
//  Uses the shared tracer. `start()` installs the process-wide hooks, which is fine in a test
//  process; the hooks are no-ops while not recording.
//

import XCTest
@testable import APITrace

final class LifecycleTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("APITraceTests-\(UUID().uuidString)", isDirectory: true)
        APITrace.shared.exportDirectory = tempDir
    }

    override func tearDown() {
        APITrace.shared.stop()
        APITrace.shared.filter = .all
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testFilterAppliesToReportAndExportsButNotSnapshot() throws {
        APITrace.shared.start(label: "filtered")
        // Inject records directly; the hooks are covered elsewhere.
        let ok = req(0, "api.example.com", "/me", start: 0.1, end: 0.2)
        let bad = req(0, "metrics.omtrdc.net", "/b/ss", start: 0.2, end: 0.3, status: nil, error: "NSURLErrorDomain#-1200")
        APITrace.shared.queue.sync { APITrace.shared.records.append(contentsOf: [ok, bad]) }

        APITrace.shared.filter.excludeTransportErrors = true
        XCTAssertEqual(APITrace.shared.snapshot().filter { $0.isRequest }.count, 2)
        XCTAssertEqual(APITrace.shared.filteredSnapshot().filter { $0.isRequest }.count, 1)
        XCTAssertTrue(APITrace.shared.report().hasPrefix("APITrace report  label=filtered  requests=1  marks=1  network span=0.100s  hidden by filter=1"))

        let csv = try String(contentsOf: XCTUnwrap(APITrace.shared.exportCSV()))
        XCTAssertFalse(csv.contains("omtrdc"))
        let json = try APITrace.TraceFile.decode(Data(contentsOf: XCTUnwrap(APITrace.shared.exportJSON())))
        XCTAssertEqual(json.records.filter { $0.isRequest }.map { $0.host }, ["api.example.com"])

        // Filter survives start(); only records are reset.
        APITrace.shared.start(label: "again")
        XCTAssertTrue(APITrace.shared.filter.excludeTransportErrors)
    }

    func testExportDirectoryIsUsed() throws {
        APITrace.shared.start(label: "dir")
        let url = try XCTUnwrap(APITrace.shared.exportCSV())
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, tempDir.standardizedFileURL)
    }

    func testStartResetsAndRecordsTraceStart() {
        APITrace.shared.start(label: "first")
        APITrace.shared.mark("A")
        XCTAssertTrue(APITrace.shared.isRecording)
        XCTAssertEqual(APITrace.shared.label, "first")
        XCTAssertEqual(APITrace.shared.snapshot().map { $0.name }, ["TraceStart", "A"])

        APITrace.shared.start(label: "second")
        let snap = APITrace.shared.snapshot()
        XCTAssertEqual(APITrace.shared.label, "second")
        XCTAssertEqual(snap.map { $0.name }, ["TraceStart"])
        XCTAssertEqual(snap.first?.id, 1)
        XCTAssertEqual(snap.first?.kind, "mark")
        XCTAssertEqual(snap.first?.source, "ui")
    }

    func testStopIgnoresMarksAndKeepsRecords() {
        APITrace.shared.start(label: "t")
        APITrace.shared.mark("kept")
        APITrace.shared.stop()
        XCTAssertFalse(APITrace.shared.isRecording)
        APITrace.shared.mark("dropped")
        XCTAssertEqual(APITrace.shared.snapshot().map { $0.name }, ["TraceStart", "kept"])
    }

    func testMarksAreOrderedAndIDsIncrease() {
        APITrace.shared.start(label: "t")
        for i in 0..<5 { APITrace.shared.mark("m\(i)") }
        let snap = APITrace.shared.snapshot()
        XCTAssertEqual(snap.map { $0.id }, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(snap.map { $0.start }, snap.map { $0.start }.sorted())
    }

    func testReportAndExportsRunOnLiveTracer() throws {
        APITrace.shared.start(label: "export-test")
        APITrace.shared.mark("X")
        XCTAssertTrue(APITrace.shared.report().hasPrefix("APITrace report  label=export-test  requests=0  marks=2"))

        let json = try XCTUnwrap(APITrace.shared.exportJSON())
        XCTAssertTrue(json.lastPathComponent.hasPrefix("export-test-"))
        XCTAssertTrue(json.lastPathComponent.hasSuffix(".records.json"))
        let file = try APITrace.TraceFile.decode(Data(contentsOf: json))
        XCTAssertEqual(file.label, "export-test")
        XCTAssertEqual(file.records.map { $0.name }, ["TraceStart", "X"])
        XCTAssertEqual(file.startedAt.timeIntervalSince1970, APITrace.shared.startDate.timeIntervalSince1970, accuracy: 1)

        let perfetto = try XCTUnwrap(APITrace.shared.exportPerfetto())
        XCTAssertTrue(perfetto.lastPathComponent.hasSuffix(".json"))
        XCTAssertFalse(perfetto.lastPathComponent.hasSuffix(".records.json"))

        let csv = try XCTUnwrap(APITrace.shared.exportCSV())
        XCTAssertEqual(try String(contentsOf: csv).components(separatedBy: "\n").count, 3)
    }
}
