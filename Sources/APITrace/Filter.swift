//
//  Filter.swift
//  DevLens / APITrace
//
//  Created by Denys Volkov.
//  MIT License.
//

import Foundation

extension APITrace {

    /// Hides noise from the report and the exports without touching what is recorded.
    ///
    /// Typical use: analytics or logging endpoints that fail on a staging backend and would drown
    /// the findings in `-1200` / `-999` errors.
    ///
    /// ```swift
    /// APITrace.shared.filter.excludeTransportErrors = true
    /// APITrace.shared.filter.excludedHosts = ["omtrdc.net", "demdex.net"]
    /// ```
    ///
    /// Marks are never filtered. `snapshot()` always returns everything; the filter applies to
    /// `report()`, `exportPerfetto()`, `exportCSV()`, `exportJSON()` and `share(from:)`.
    public struct Filter: Equatable {

        /// Drop requests that ended with a transport error (`record.error != nil`), for example
        /// `NSURLErrorDomain#-1200` (TLS) or `NSURLErrorDomain#-999` (cancelled).
        public var excludeTransportErrors = false

        /// Drop requests whose HTTP status is 400 or higher.
        public var excludeHTTPErrors = false

        /// Drop requests whose host equals, or is a subdomain of, any entry. `"example.com"`
        /// matches `example.com` and `api.example.com`, not `notexample.com`.
        public var excludedHosts: [String] = []

        /// Keep only requests whose host equals, or is a subdomain of, any entry. Empty keeps all.
        public var includedHosts: [String] = []

        public init(excludeTransportErrors: Bool = false, excludeHTTPErrors: Bool = false,
                    excludedHosts: [String] = [], includedHosts: [String] = []) {
            self.excludeTransportErrors = excludeTransportErrors
            self.excludeHTTPErrors = excludeHTTPErrors
            self.excludedHosts = excludedHosts
            self.includedHosts = includedHosts
        }

        /// Shows everything. This is the default.
        public static let all = Filter()

        /// Hides every request that failed, by transport error or by HTTP status.
        public static let successfulOnly = Filter(excludeTransportErrors: true, excludeHTTPErrors: true)

        public var isActive: Bool { self != .all }

        /// `true` when the record passes the filter. Marks always pass.
        public func includes(_ r: Record) -> Bool {
            guard r.isRequest else { return true }
            if excludeTransportErrors, r.error != nil { return false }
            if excludeHTTPErrors, let s = r.status, s >= 400 { return false }
            if !excludedHosts.isEmpty, let h = r.host, excludedHosts.contains(where: { Filter.host(h, matches: $0) }) { return false }
            if !includedHosts.isEmpty {
                guard let h = r.host, includedHosts.contains(where: { Filter.host(h, matches: $0) }) else { return false }
            }
            return true
        }

        public func apply(_ records: [Record]) -> [Record] {
            isActive ? records.filter(includes) : records
        }

        static func host(_ host: String, matches pattern: String) -> Bool {
            let h = host.lowercased(), p = pattern.lowercased()
            return h == p || h.hasSuffix("." + p)
        }
    }
}
