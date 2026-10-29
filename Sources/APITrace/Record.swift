//
//  Record.swift
//  DevLens / APITrace
//
//  Created by Denys Volkov.
//  MIT License.
//

import Foundation

extension APITrace {

    /// One timing phase inside a request. Times are seconds since trace start.
    ///
    /// Phase names emitted by the URLSession hook: `dns`, `tcp`, `tls`, `send`, `wait`, `download`.
    public struct Phase: Codable, Equatable {
        public var name: String
        public var start: TimeInterval
        public var end: TimeInterval

        public init(name: String, start: TimeInterval, end: TimeInterval) {
            self.name = name
            self.start = start
            self.end = end
        }

        public var duration: TimeInterval { end - start }
    }

    /// One entry on the timeline: a network request, a WebView event or a UI mark.
    ///
    /// Records are reference types because the hooks fill them in over the life of a task
    /// (start on `resume`, breakdown on metrics, status on completion). They are `Codable` so a
    /// run can be written to disk with `exportJSON()` and compared offline with `trace-compare`.
    ///
    /// Privacy: only `host`, `path` and the query parameter *names* are stored. Never headers,
    /// bodies, cookies or query values.
    public final class Record: Codable {

        /// Monotonic id in allocation order. Allocation order is not start order for WebView events.
        public internal(set) var id: Int
        /// `request` | `mark` | `webview-resource` | `webview-fetch` | `webview-xhr` | `webview-navigation`.
        public var kind: String
        /// `native:<DelegateClass>` | `alamofire` | `react-native` | `no-delegate` | `webview[:host]` | `shared/unknown` | `ui`.
        public var source: String
        /// `"GET host/path"` for requests, the mark text for marks.
        public var name: String
        public var method: String?
        public var host: String?
        public var path: String?
        /// Query parameter names only.
        public var queryKeys: [String] = []
        /// Seconds since trace start.
        public var start: TimeInterval
        /// Seconds since trace start. `nil` while in flight.
        public var end: TimeInterval?
        public var status: Int?
        /// `"<NSErrorDomain>#<code>"` for native requests, free text for WebView events.
        public var error: String?
        public var dns: TimeInterval?
        public var connect: TimeInterval?
        public var tls: TimeInterval?
        /// Request fully sent to first response byte.
        public var ttfb: TimeInterval?
        public var download: TimeInterval?
        public var reusedConnection: Bool?
        public var protocolName: String?
        public var requestBytes: Int64?
        public var responseBytes: Int64?
        public var redirects: Int?
        public var startedOnMainThread: Bool?
        public var queueLabel: String?
        public var phases: [Phase] = []

        // Runtime-only bookkeeping, never encoded.
        var metricsRecorded = false
        var observation: NSKeyValueObservation?

        public var duration: TimeInterval? { end.map { $0 - start } }
        public var isRequest: Bool { kind != "mark" }

        public init(id: Int, kind: String, source: String, name: String, start: TimeInterval, end: TimeInterval? = nil) {
            self.id = id
            self.kind = kind
            self.source = source
            self.name = name
            self.start = start
            self.end = end
        }

        enum CodingKeys: String, CodingKey {
            case id, kind, source, name, method, host, path, queryKeys, start, end, status, error
            case dns, connect, tls, ttfb, download, reusedConnection, protocolName
            case requestBytes, responseBytes, redirects, startedOnMainThread, queueLabel, phases
        }

        /// Fills `method`, `host`, `path`, `queryKeys` and `name` from a URL, keeping only query
        /// parameter names. This is the single place where request URLs are sanitised.
        func apply(url: URL?, method: String) {
            self.method = method
            host = url?.host
            path = url?.path
            if let url = url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                queryKeys = (comps.queryItems ?? []).map { $0.name }
            }
            name = "\(method) \(url?.host ?? "?")\(url?.path ?? "")"
        }
    }

    /// On-disk envelope written by `exportJSON()` and read by `trace-compare`.
    public struct TraceFile: Codable {
        public var version: Int
        public var label: String
        public var startedAt: Date
        public var records: [Record]

        public init(label: String, startedAt: Date, records: [Record], version: Int = 1) {
            self.version = version
            self.label = label
            self.startedAt = startedAt
            self.records = records
        }

        public static func decode(_ data: Data) throws -> TraceFile {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let file = try? decoder.decode(TraceFile.self, from: data) { return file }
            // Also accept a bare array of records.
            let records = try decoder.decode([Record].self, from: data)
            return TraceFile(label: "trace", startedAt: Date(timeIntervalSince1970: 0), records: records)
        }

        public func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(self)
        }
    }
}
