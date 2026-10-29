//
//  Findings.swift
//  DevLens / APITrace
//
//  Created by Denys Volkov.
//  MIT License.
//

import Foundation

/// Pure analyses over a list of request records. No networking, no state; everything here is
/// unit-testable with hand-built `APITrace.Record` arrays.
///
/// Pass only requests (`record.isRequest == true`). Marks are ignored by the report but would
/// skew the counts here.
public enum Findings {

    public typealias Record = APITrace.Record

    /// Tunable thresholds. The defaults match the original report text.
    public struct Thresholds {
        /// A request that starts within this window after everything before it finished counts as serialized.
        public var serialWindow: TimeInterval = 0.150
        /// Minimum idle time, with no request in flight, to report as a gap.
        public var idleGap: TimeInterval = 0.300
        /// How many entries the "Slowest" line lists.
        public var slowestLimit: Int = 5

        public init() {}
        public static let `default` = Thresholds()
    }

    public struct SerialChains: Equatable {
        /// Number of requests that started within `serialWindow` after everything before them had finished.
        public var serialized: Int
        /// Longest run of consecutive serialized requests, counting the first request of the run.
        public var longest: Int
    }

    public struct Duplicate: Equatable {
        public var name: String
        public var count: Int
    }

    public struct NewConnections: Equatable {
        public var count: Int
        public var tlsTotal: TimeInterval
        public var hosts: [String]
    }

    public struct Gap: Equatable {
        public var start: TimeInterval
        public var end: TimeInterval
        public var duration: TimeInterval { end - start }
    }

    /// Requests grouped by `source`, with counts.
    public static func bySource(_ reqs: [Record]) -> [String: Int] {
        Dictionary(grouping: reqs, by: { $0.source }).mapValues { $0.count }
    }

    /// Serialized chains: a request that starts shortly after the previous ones ended, with nothing
    /// else in flight. Long chains are the classic "waterfall" that parallel fetching removes.
    public static func serialChains(_ reqs: [Record], window: TimeInterval = Thresholds.default.serialWindow) -> SerialChains {
        let reqs = reqs.sorted { $0.start < $1.start }
        guard reqs.count > 1 else { return SerialChains(serialized: 0, longest: 0) }
        var longest = 1, current = 1, serialized = 0
        var maxEnd: TimeInterval? = reqs[0].end
        for i in 1..<reqs.count {
            let prevEnd = maxEnd ?? reqs[i - 1].start
            let gap = reqs[i].start - prevEnd
            if gap >= -0.005 && gap < window { serialized += 1; current += 1 } else { current = 1 }
            longest = max(longest, current)
            if let e = reqs[i].end { maxEnd = max(maxEnd ?? e, e) }
        }
        return SerialChains(serialized: serialized, longest: longest)
    }

    /// Same `name` ("METHOD host/path") recorded more than once, sorted by name.
    public static func duplicates(_ reqs: [Record]) -> [Duplicate] {
        Dictionary(grouping: reqs, by: { $0.name })
            .filter { $0.value.count > 1 }
            .map { Duplicate(name: $0.key, count: $0.value.count) }
            .sorted { $0.name < $1.name }
    }

    /// Requests that opened a new connection, with the summed TLS cost and the hosts involved.
    public static func newConnections(_ reqs: [Record]) -> NewConnections {
        let fresh = reqs.filter { $0.reusedConnection == false }
        return NewConnections(
            count: fresh.count,
            tlsTotal: fresh.compactMap { $0.tls }.reduce(0, +),
            hosts: Set(fresh.compactMap { $0.host }).sorted()
        )
    }

    /// Time inside the network span where nothing was in flight. That is client-side work, or
    /// waiting on the user, between network bursts.
    public static func idleGaps(_ reqs: [Record], threshold: TimeInterval = Thresholds.default.idleGap) -> [Gap] {
        let intervals = reqs.compactMap { r -> (TimeInterval, TimeInterval)? in r.end.map { (r.start, $0) } }.sorted { $0.0 < $1.0 }
        var gaps: [Gap] = []
        if var cursor = intervals.first?.1 {
            for iv in intervals.dropFirst() {
                if iv.0 > cursor + threshold { gaps.append(Gap(start: cursor, end: iv.0)) }
                cursor = max(cursor, iv.1)
            }
        }
        return gaps
    }

    /// Finished requests sorted by duration, longest first.
    public static func slowest(_ reqs: [Record], limit: Int = Thresholds.default.slowestLimit) -> [Record] {
        Array(reqs.filter { $0.duration != nil }.sorted { ($0.duration ?? 0) > ($1.duration ?? 0) }.prefix(limit))
    }

    /// Requests with a transport error or a 4xx/5xx status.
    public static func errors(_ reqs: [Record]) -> [Record] {
        reqs.filter { $0.error != nil || ($0.status ?? 200) >= 400 }
    }

    /// Requests whose `resume()` was called on the main thread.
    public static func mainThreadStarts(_ reqs: [Record]) -> Int {
        reqs.filter { $0.startedOnMainThread == true }.count
    }

    /// Summed server wait (TTFB) and summed download time. Sums overlap when requests run in parallel.
    public static func summedWaits(_ reqs: [Record]) -> (ttfb: TimeInterval, download: TimeInterval) {
        (reqs.compactMap { $0.ttfb }.reduce(0, +), reqs.compactMap { $0.download }.reduce(0, +))
    }

    /// The "Findings:" section of the text report, one line per finding.
    public static func lines(for reqs: [Record], thresholds: Thresholds = .default) -> [String] {
        var lines: [String] = []
        guard !reqs.isEmpty else { return ["  (no requests recorded)"] }

        lines.append("  Requests by source: " + bySource(reqs).map { "\(Format.short($0.key))=\($0.value)" }.sorted().joined(separator: ", "))

        let chains = serialChains(reqs, window: thresholds.serialWindow)
        lines.append("  Serialized: \(chains.serialized) of \(reqs.count) requests started within \(Format.ms(thresholds.serialWindow))ms after everything before them finished. Longest chain: \(chains.longest).")

        let dup = duplicates(reqs)
        if !dup.isEmpty {
            lines.append("  Duplicates: " + dup.map { "\($0.name) ×\($0.count)" }.sorted().joined(separator: "; "))
        }

        let fresh = newConnections(reqs)
        if fresh.count > 0 {
            lines.append("  New connections: \(fresh.count) (TLS handshakes total \(Format.f(fresh.tlsTotal))s). Hosts: " + fresh.hosts.joined(separator: ", "))
        }

        let sums = summedWaits(reqs)
        lines.append("  Summed server wait (TTFB): \(Format.f(sums.ttfb))s. Summed download: \(Format.f(sums.download))s. (sums overlap when parallel)")

        let slow = slowest(reqs, limit: thresholds.slowestLimit)
        lines.append("  Slowest: " + slow.map { "\($0.name) \(Format.f($0.duration ?? 0))s" }.joined(separator: "; "))

        let errs = errors(reqs)
        if !errs.isEmpty {
            lines.append("  Errors/4xx/5xx: " + errs.map { "\($0.name) [\($0.status.map(String.init) ?? "-")] \($0.error ?? "")" }.joined(separator: "; "))
        }

        lines.append("  Started on main thread: \(mainThreadStarts(reqs)).")

        let gaps = idleGaps(reqs, threshold: thresholds.idleGap)
        if !gaps.isEmpty {
            lines.append("  Idle gaps > \(Format.ms(thresholds.idleGap))ms (no request in flight): " + gaps.map { "\(Format.f($0.start))→\(Format.f($0.end))s (\(Format.f($0.duration))s)" }.joined(separator: ", "))
        }
        return lines
    }
}
