//
//  TestHelpers.swift
//  DevLens / APITraceTests
//
//  Created by Denys Volkov.
//  MIT License.
//

import Foundation
@testable import APITrace

/// Hand-built request record. `name` defaults to "GET host/path" like the real hook produces.
func req(_ id: Int, _ host: String = "api.example.com", _ path: String = "/v1/items",
         method: String = "GET", start: TimeInterval, end: TimeInterval?,
         source: String = "native:AppClient", status: Int? = 200, error: String? = nil,
         reused: Bool? = true, tls: TimeInterval? = nil, ttfb: TimeInterval? = nil, download: TimeInterval? = nil,
         onMain: Bool? = false) -> APITrace.Record {
    let r = APITrace.Record(id: id, kind: "request", source: source, name: "\(method) \(host)\(path)", start: start, end: end)
    r.method = method
    r.host = host
    r.path = path
    r.status = status
    r.error = error
    r.reusedConnection = reused
    r.tls = tls
    r.ttfb = ttfb
    r.download = download
    r.startedOnMainThread = onMain
    return r
}

func mark(_ id: Int, _ name: String, at start: TimeInterval) -> APITrace.Record {
    APITrace.Record(id: id, kind: "mark", source: "ui", name: name, start: start)
}
