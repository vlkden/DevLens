//
//  TraceCompare.swift
//  DevLens / APITrace
//
//  Created by Denys Volkov.
//  MIT License.
//

import Foundation

/// Compares two recorded runs (for example before and after an optimisation). Pure functions,
/// used by the `trace-compare` executable and by the tests.
public enum TraceCompare {

    public typealias Record = APITrace.Record

    public struct Endpoint: Equatable {
        public var name: String
        public var countBefore: Int
        public var countAfter: Int
        public var medianBefore: TimeInterval?
        public var medianAfter: TimeInterval?
    }

    public struct Result: Equatable {
        public var labelBefore: String
        public var labelAfter: String
        public var requestsBefore: Int
        public var requestsAfter: Int
        public var longestChainBefore: Int
        public var longestChainAfter: Int
        public var spanBefore: TimeInterval
        public var spanAfter: TimeInterval
        /// Endpoints present in both runs, sorted by name.
        public var endpoints: [Endpoint]
        /// Endpoint names only present in `after`, sorted.
        public var added: [String]
        /// Endpoint names only present in `before`, sorted.
        public var removed: [String]

        public var requestsDelta: Int { requestsAfter - requestsBefore }
        public var longestChainDelta: Int { longestChainAfter - longestChainBefore }
        public var spanDelta: TimeInterval { spanAfter - spanBefore }
    }

    public static func compare(before: APITrace.TraceFile, after: APITrace.TraceFile) -> Result {
        compare(before: before.records, after: after.records, labelBefore: before.label, labelAfter: after.label)
    }

    public static func compare(before: [Record], after: [Record], labelBefore: String = "before", labelAfter: String = "after") -> Result {
        let b = before.filter { $0.isRequest }.sorted { $0.start < $1.start }
        let a = after.filter { $0.isRequest }.sorted { $0.start < $1.start }
        let bByName = Dictionary(grouping: b, by: { $0.name })
        let aByName = Dictionary(grouping: a, by: { $0.name })
        let common = Set(bByName.keys).intersection(aByName.keys).sorted()
        let endpoints = common.map { name in
            Endpoint(name: name,
                     countBefore: bByName[name]?.count ?? 0,
                     countAfter: aByName[name]?.count ?? 0,
                     medianBefore: median((bByName[name] ?? []).compactMap { $0.duration }),
                     medianAfter: median((aByName[name] ?? []).compactMap { $0.duration }))
        }
        return Result(
            labelBefore: labelBefore,
            labelAfter: labelAfter,
            requestsBefore: b.count,
            requestsAfter: a.count,
            longestChainBefore: Findings.serialChains(b).longest,
            longestChainAfter: Findings.serialChains(a).longest,
            spanBefore: networkSpan(b),
            spanAfter: networkSpan(a),
            endpoints: endpoints,
            added: Set(aByName.keys).subtracting(bByName.keys).sorted(),
            removed: Set(bByName.keys).subtracting(aByName.keys).sorted()
        )
    }

    /// First request start to last request end, in seconds. Zero when nothing finished.
    public static func networkSpan(_ reqs: [Record]) -> TimeInterval {
        guard let first = reqs.map({ $0.start }).min(), let last = reqs.compactMap({ $0.end }).max() else { return 0 }
        return max(0, last - first)
    }

    public static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }

    /// Human-readable summary of a comparison.
    public static func render(_ r: Result) -> String {
        func sec(_ v: TimeInterval?) -> String { v.map { String(format: "%.3f", $0) } ?? "-" }
        func signed(_ v: Int) -> String { v > 0 ? "+\(v)" : "\(v)" }
        func signedSec(_ v: TimeInterval) -> String { (v > 0 ? "+" : "") + String(format: "%.3f", v) }
        var out: [String] = []
        out.append("trace-compare  before=\(r.labelBefore)  after=\(r.labelAfter)")
        out.append("")
        out.append(String(format: "  %-22@ %8d  ->  %8d   (%@)", "Requests" as NSString, r.requestsBefore, r.requestsAfter, signed(r.requestsDelta) as NSString))
        out.append(String(format: "  %-22@ %8d  ->  %8d   (%@)", "Longest serial chain" as NSString, r.longestChainBefore, r.longestChainAfter, signed(r.longestChainDelta) as NSString))
        out.append(String(format: "  %-22@ %7.3fs  -> %7.3fs   (%@s)", "Network span" as NSString, r.spanBefore, r.spanAfter, signedSec(r.spanDelta) as NSString))
        out.append("")
        out.append("  Per-endpoint median duration (s), endpoints in both runs:")
        out.append("  " + Format.pad("endpoint", 48) + Format.pad("n", 8) + Format.pad("before", 9) + Format.pad("after", 9) + "delta")
        for e in r.endpoints {
            let delta: String
            if let mb = e.medianBefore, let ma = e.medianAfter { delta = signedSec(ma - mb) } else { delta = "-" }
            out.append("  " + Format.pad(e.name, 48) + Format.pad("\(e.countBefore)/\(e.countAfter)", 8) + Format.pad(sec(e.medianBefore), 9) + Format.pad(sec(e.medianAfter), 9) + delta)
        }
        if r.endpoints.isEmpty { out.append("  (none)") }
        out.append("")
        out.append("  Added endpoints (\(r.added.count)):" + (r.added.isEmpty ? " none" : ""))
        out.append(contentsOf: r.added.map { "    + \($0)" })
        out.append("  Removed endpoints (\(r.removed.count)):" + (r.removed.isEmpty ? " none" : ""))
        out.append(contentsOf: r.removed.map { "    - \($0)" })
        return out.joined(separator: "\n")
    }
}
