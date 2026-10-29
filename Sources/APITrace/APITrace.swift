//
//  APITrace.swift
//  DevLens / APITrace
//
//  Created by Denys Volkov.
//  MIT License.
//
//  Debug-only tracer that puts every network call and every UI milestone on one timeline.
//
//  What it captures, in-process, without a proxy and without touching call sites:
//    • Every URLSessionTask in the app: plain URLSession, Alamofire, React Native (RCTNetworking
//      uses NSURLSession under the hood), vendor SDKs that use URLSession.
//    • Per-request breakdown from URLSessionTaskMetrics: DNS, connect, TLS, wait (TTFB), download,
//      connection reuse, protocol, bytes, redirects.
//    • WKWebView traffic via an injected script (PerformanceObserver + fetch/XHR wrappers), because
//      WKWebView networking runs in a separate process and URLSession hooks never see it.
//    • UI milestones you mark yourself: APITrace.shared.mark("HomeAppeared").
//
//  What it exports:
//    • printReport()      console table + automatic findings (serial chains, duplicates, new
//                         connections, idle gaps, errors)
//    • exportPerfetto()   JSON you open at https://ui.perfetto.dev for a zoomable waterfall
//    • exportCSV()        for a spreadsheet
//    • exportJSON()       raw records, for `trace-compare` and offline analysis
//    • share(from:)       share sheet with all files, to get them off a device
//
//  Usage:
//      #if DEBUG
//      APITrace.shared.start(label: "login-cold-wifi", autoAttachWebViews: true)   // early, e.g. didFinishLaunching
//      #endif
//      APITrace.shared.mark("LoginTapped")
//      APITrace.shared.mark("HomeAppeared")
//      APITrace.shared.printReport()
//      APITrace.shared.share(from: viewController)
//
//  Privacy: records scheme, host, path and query KEYS only. Never headers, bodies, cookies,
//  or query values. Still: DEBUG builds only. Wrap the start() call in #if DEBUG.
//
//  Known limits:
//    • Hooks are installed via the ObjC runtime. They are idempotent and only installed once,
//      and only when start() is called. Nothing runs on import.
//    • Sessions created with delegate: nil get a lightweight observer delegate so metrics flow.
//    • For URLSession.shared (no delegate, created before we run) you get start/end/status via KVO
//      but no DNS/TLS breakdown.
//    • WebView cross-origin resources only expose full timing if the server sends
//      Timing-Allow-Origin. You always get start, duration, and (via fetch/XHR wrappers) status.
//

import Foundation
import os.log

/// Debug-only network and UI timeline tracer. See the file header for an overview.
///
/// All public methods are safe to call from any thread. Records are mutated on a private serial
/// queue; `snapshot()` returns a sorted copy.
public final class APITrace: NSObject {

    /// The one tracer per process. Hooks are process-wide, so there is no point in having two.
    public static let shared = APITrace()

    // MARK: State

    /// Free-text label for the current run, e.g. `"login-cold-wifi"`. Used in file names and report headers.
    public private(set) var label: String = "trace"
    /// `true` between `start()` and `stop()`.
    public internal(set) var isRecording = false

    var t0 = Date()
    var records: [Record] = []
    var nextID = 0
    let queue = DispatchQueue(label: "apitrace.records")
    let taskMap = NSMapTable<URLSessionTask, Record>.weakToStrongObjects()
    var hooksInstalled = false
    var hookedDelegateClasses = Set<ObjectIdentifier>()
    private var _filter = Filter.all
    private let poiLog = OSLog(subsystem: "apitrace", category: .pointsOfInterest)

    private override init() { super.init() }

    // MARK: Public API

    /// Installs hooks (once) and starts a fresh timeline. Call this early, e.g. in
    /// `application(_:didFinishLaunchingWithOptions:)`, wrapped in `#if DEBUG`.
    ///
    /// - Parameters:
    ///   - label: name of this run; shows up in the report header and in exported file names.
    ///   - autoAttachWebViews: hook `WKWebView` init so every web view created afterwards is traced.
    ///     Web views created before `start()` need an explicit `attach(to:)`.
    public func start(label: String = "trace", autoAttachWebViews: Bool = true) {
        queue.sync {
            self.label = label
            t0 = Date()
            records.removeAll()
            nextID = 0
            taskMap.removeAllObjects()
            isRecording = true
        }
        installHooksIfNeeded(autoAttachWebViews: autoAttachWebViews)
        mark("TraceStart")
    }

    /// Stops recording. Hooks stay installed but become no-ops. Records are kept until the next `start()`.
    public func stop() { queue.sync { isRecording = false } }

    /// Adds a UI milestone to the timeline. Also emits an `os_signpost` so it shows in Instruments.
    public func mark(_ name: String) {
        os_signpost(.event, log: poiLog, name: "APITrace", "%{public}s", name)
        let t = now()
        queue.async {
            guard self.isRecording else { return }
            self.records.append(Record(id: self.allocID(), kind: "mark", source: "ui", name: name, start: t))
        }
    }

    /// Snapshot of everything recorded so far, sorted by start. Not affected by `filter`.
    public func snapshot() -> [Record] {
        queue.sync { records.sorted { $0.start < $1.start } }
    }

    /// `snapshot()` with `filter` applied. This is what the report and the exports use.
    public func filteredSnapshot() -> [Record] {
        let (all, f) = queue.sync { (records.sorted { $0.start < $1.start }, _filter) }
        return f.apply(all)
    }

    /// What the report and the exports show. Defaults to `.all`. Survives `start()`.
    /// See `APITrace.Filter`.
    public var filter: Filter {
        get { queue.sync { _filter } }
        set { queue.sync { _filter = newValue } }
    }

    /// Wall-clock date of the current trace's T0. All record times are relative to it.
    public var startDate: Date { queue.sync { t0 } }

    /// Where exports are written. Defaults to `<Documents>/APITrace`, which is visible in the Files
    /// app and in Finder when file sharing is enabled. Set it before exporting to redirect.
    public lazy var exportDirectory: URL = (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
        .appendingPathComponent("APITrace", isDirectory: true)

    // MARK: Helpers

    /// Call on `queue`.
    func allocID() -> Int { nextID += 1; return nextID }
    func now() -> TimeInterval { Date().timeIntervalSince(t0) }
}
