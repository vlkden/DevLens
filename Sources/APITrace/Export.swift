//
//  Export.swift
//  DevLens / APITrace
//
//  Created by Denys Volkov.
//  MIT License.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Facade

extension APITrace {

    /// Builds the text report (table of requests, marks, findings) for the current trace.
    public func report() -> String {
        TraceExport.report(records: snapshot(), label: label)
    }

    /// Prints the text report to the console and returns it.
    @discardableResult
    public func printReport() -> String {
        let text = report()
        print(text)
        return text
    }

    /// Writes a Chrome Trace Event Format file. Open it at https://ui.perfetto.dev (drag the file in).
    /// - Returns: the file URL, or `nil` if serialisation or writing failed.
    @discardableResult
    public func exportPerfetto() -> URL? {
        guard let data = TraceExport.perfettoData(records: snapshot(), label: label) else { return nil }
        return write(data, ext: "json")
    }

    /// Writes one CSV row per record. See `TraceExport.csvHeader` for the columns.
    @discardableResult
    public func exportCSV() -> URL? {
        write(TraceExport.csv(records: snapshot()).data(using: .utf8) ?? Data(), ext: "csv")
    }

    /// Writes the raw records as JSON (`TraceFile`). This is the input for `trace-compare`.
    @discardableResult
    public func exportJSON() -> URL? {
        let file = TraceFile(label: label, startedAt: startDate, records: snapshot())
        guard let data = try? file.encoded() else { return nil }
        return write(data, ext: "records.json")
    }

    #if canImport(UIKit)
    /// Writes all exports (Perfetto JSON, CSV, raw JSON, text report) and presents a share sheet
    /// (AirDrop / Files / messaging) so the files can leave the device.
    public func share(from viewController: UIViewController) {
        var items: [Any] = []
        if let u = exportPerfetto() { items.append(u) }
        if let u = exportCSV() { items.append(u) }
        if let u = exportJSON() { items.append(u) }
        if let txt = write(report().data(using: .utf8) ?? Data(), ext: "txt") { items.append(txt) }
        guard !items.isEmpty else { return }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = viewController.view
        viewController.present(vc, animated: true)
    }
    #endif

    /// Writes into `exportDirectory/<label>-<yyyyMMdd-HHmmss>.<ext>`. Files are kept across
    /// launches so they can be pulled with Finder or the Files app; nothing cleans them up.
    func write(_ data: Data, ext: String) -> URL? {
        let dir = exportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("\(label)-\(df.string(from: startDate)).\(ext)")
        do { try data.write(to: url); print("APITrace: wrote \(url.path)"); return url } catch { print("APITrace: write failed \(error)"); return nil }
    }
}

// MARK: - Pure builders

/// Pure functions that turn records into the text report, Perfetto JSON and CSV. No file system,
/// no shared state, so the output shape can be unit-tested.
public enum TraceExport {

    public typealias Record = APITrace.Record

    /// Text report: header, request table, marks, findings.
    public static func report(records all: [Record], label: String) -> String {
        let reqs = all.filter { $0.isRequest }
        let marks = all.filter { !$0.isRequest }
        var out: [String] = []
        let spanEnd = reqs.compactMap { $0.end }.max() ?? 0
        let spanStart = reqs.first?.start ?? 0
        out.append("APITrace report  label=\(label)  requests=\(reqs.count)  marks=\(marks.count)  network span=\(Format.f(spanEnd - spanStart))s")
        out.append("")
        out.append(Format.pad("start", 7) + Format.pad("dur", 7) + Format.pad("src", 22) + Format.pad("st", 5) + Format.pad("meth", 6) + Format.pad("dns", 6) + Format.pad("tls", 6) + Format.pad("ttfb", 7) + Format.pad("dl", 6) + Format.pad("reuse", 6) + Format.pad("thr", 5) + "name")
        for r in reqs {
            out.append(
                Format.pad(Format.f(r.start), 7) + Format.pad(r.duration.map(Format.f) ?? "-", 7) + Format.pad(Format.short(r.source), 22) +
                Format.pad(r.status.map(String.init) ?? (r.error != nil ? "ERR" : "-"), 5) + Format.pad(r.method ?? "-", 6) +
                Format.pad(r.dns.map(Format.f) ?? "-", 6) + Format.pad(r.tls.map(Format.f) ?? "-", 6) + Format.pad(r.ttfb.map(Format.f) ?? "-", 7) + Format.pad(r.download.map(Format.f) ?? "-", 6) +
                Format.pad(r.reusedConnection.map { $0 ? "yes" : "NEW" } ?? "-", 6) + Format.pad(r.startedOnMainThread == true ? "main" : "bg", 5) +
                r.name + (r.error.map { "  ⚠︎ \($0)" } ?? "")
            )
        }
        out.append("")
        out.append("Marks:")
        for m in marks { out.append("  \(Format.pad(Format.f(m.start), 8))s  \(m.name)") }
        out.append("")
        out.append("Findings:")
        out.append(contentsOf: Findings.lines(for: reqs))
        return out.joined(separator: "\n")
    }

    /// Chrome Trace Event Format document. One `tid` lane per source plus a `ui-marks` lane;
    /// requests are complete events (`ph: X`) with their phases as child events, marks are
    /// global instant events (`ph: i`).
    public static func perfettoDocument(records all: [Record], label: String) -> [String: Any] {
        var lanes: [String: Int] = [:]
        func lane(_ s: String) -> Int {
            if let l = lanes[s] { return l }
            let l = lanes.count + 1; lanes[s] = l; return l
        }
        var events: [[String: Any]] = []
        for r in all {
            let tid = lane(r.isRequest ? r.source : "ui-marks")
            if r.isRequest {
                var args: [String: Any] = ["kind": r.kind]
                if let v = r.status { args["status"] = v }
                if let v = r.error { args["error"] = v }
                if let v = r.reusedConnection { args["reusedConnection"] = v }
                if let v = r.protocolName { args["protocol"] = v }
                if let v = r.requestBytes { args["requestBytes"] = v }
                if let v = r.responseBytes { args["responseBytes"] = v }
                if let v = r.redirects { args["redirects"] = v }
                if let v = r.queueLabel { args["queue"] = v }
                if !r.queryKeys.isEmpty { args["queryKeys"] = r.queryKeys.joined(separator: ",") }
                events.append(["name": r.name, "cat": r.kind, "ph": "X", "ts": Format.us(r.start), "dur": Format.us(r.duration ?? 0), "pid": 1, "tid": tid, "args": args])
                for p in r.phases where p.end > p.start {
                    events.append(["name": p.name, "cat": "phase", "ph": "X", "ts": Format.us(p.start), "dur": Format.us(p.end - p.start), "pid": 1, "tid": tid])
                }
            } else {
                events.append(["name": r.name, "cat": "mark", "ph": "i", "s": "g", "ts": Format.us(r.start), "pid": 1, "tid": tid])
            }
        }
        for (name, tid) in lanes {
            events.append(["name": "thread_name", "ph": "M", "pid": 1, "tid": tid, "args": ["name": name]])
        }
        events.append(["name": "process_name", "ph": "M", "pid": 1, "args": ["name": "APITrace \(label)"]])
        return ["traceEvents": events, "displayTimeUnit": "ms"]
    }

    /// `perfettoDocument` serialised as pretty-printed JSON.
    public static func perfettoData(records: [Record], label: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: perfettoDocument(records: records, label: label), options: [.prettyPrinted])
    }

    /// CSV column names, in order.
    public static let csvHeader = "id,kind,source,start_s,end_s,duration_s,method,status,error,host,path,query_keys,dns_s,connect_s,tls_s,ttfb_s,download_s,reused,protocol,req_bytes,resp_bytes,redirects,main_thread,queue"

    /// CSV text with `csvHeader` as the first line. For marks, the `path` column carries the mark name.
    public static func csv(records: [Record]) -> String {
        var lines = [csvHeader]
        for r in records {
            let cols: [String] = [
                "\(r.id)", r.kind, r.source, Format.f(r.start), r.end.map(Format.f) ?? "", r.duration.map(Format.f) ?? "",
                r.method ?? "", r.status.map(String.init) ?? "", csvEscape(r.error ?? ""), r.host ?? "", csvEscape(r.isRequest ? (r.path ?? "") : r.name),
                r.queryKeys.joined(separator: "|"), r.dns.map(Format.f) ?? "", r.connect.map(Format.f) ?? "", r.tls.map(Format.f) ?? "", r.ttfb.map(Format.f) ?? "",
                r.download.map(Format.f) ?? "", r.reusedConnection.map { $0 ? "1" : "0" } ?? "", r.protocolName ?? "",
                r.requestBytes.map(String.init) ?? "", r.responseBytes.map(String.init) ?? "", r.redirects.map(String.init) ?? "",
                r.startedOnMainThread.map { $0 ? "1" : "0" } ?? "", csvEscape(r.queueLabel ?? "")
            ]
            lines.append(cols.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// Quotes a field when it contains a comma or a quote; doubles embedded quotes.
    public static func csvEscape(_ s: String) -> String {
        s.contains(",") || s.contains("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
}

// MARK: - Formatting helpers

enum Format {
    /// Seconds with three decimals.
    static func f(_ s: TimeInterval) -> String { String(format: "%.3f", s) }
    /// Seconds to whole milliseconds, for threshold labels.
    static func ms(_ s: TimeInterval) -> Int { Int((s * 1000).rounded()) }
    /// Seconds to microseconds, for Perfetto.
    static func us(_ s: TimeInterval) -> Int { Int(s * 1_000_000) }
    /// Left-aligned fixed-width column; truncates with one trailing space when too long.
    static func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n - 1)) + " " : s + String(repeating: " ", count: n - s.count) }
    /// Drops the `native:` prefix from a source for display.
    static func short(_ s: String) -> String { s.replacingOccurrences(of: "native:", with: "") }
}
