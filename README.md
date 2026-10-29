# DevLens

Debug-only iOS developer utilities for finding out where the time goes: network and UI timeline tracing today, launch timing and main-thread watchdog next. Everything in DevLens is built for **DEBUG builds**. Nothing installs itself on import; each tool has an explicit `start()` that you wrap in `#if DEBUG`. Never ship it enabled.

[![CI](https://github.com/vlkden/DevLens/actions/workflows/ci.yml/badge.svg)](https://github.com/vlkden/DevLens/actions/workflows/ci.yml)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange)
![iOS 13+](https://img.shields.io/badge/iOS-13%2B-blue)
![License MIT](https://img.shields.io/badge/License-MIT-green)

## Installation

### Swift Package Manager (Xcode)

File ▸ Add Package Dependencies… and paste:

```
https://github.com/vlkden/DevLens
```

Add the `DevLens` product for everything, or just `APITrace` for the network tracer.

### Swift Package Manager (`Package.swift`)

```swift
dependencies: [
    .package(url: "https://github.com/vlkden/DevLens", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "DevLens", package: "DevLens"),   // or .product(name: "APITrace", package: "DevLens")
    ]),
]
```

### Copy-in (no external packages allowed)

Drag the folder `Sources/APITrace` into your app target. It has no dependencies beyond Foundation, WebKit and UIKit, and no `import APITrace` is needed because the type now lives in your module. Every file is a self-contained part of one type, so copy the whole folder, not individual files.

## Quick start

```swift
// AppDelegate.swift
import APITrace   // or DevLens

func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    #if DEBUG
    APITrace.shared.start(label: "login-cold-wifi", autoAttachWebViews: true)
    #endif
    return true
}

// Anywhere in the flow you are measuring
APITrace.shared.mark("LoginTapped")
APITrace.shared.mark("HomeAppeared")

// From a debug menu or a shake handler
APITrace.shared.printReport()                 // console table + findings
APITrace.shared.share(from: viewController)   // AirDrop / Files the Perfetto, CSV, JSON and text files
```

Calls to `mark()` and the exports are cheap no-ops while not recording, so they can stay in the code behind `#if DEBUG`. See [Examples/README.md](Examples/README.md) for a complete wiring including a SwiftUI debug screen.

## Modules

### APITrace

Puts every network call and every UI milestone on one timeline, in-process, without a proxy and without touching call sites.

- **Every `URLSessionTask`** in the app: plain URLSession, Alamofire, React Native (`RCTNetworking` uses NSURLSession), vendor SDKs. Hooked through the ObjC runtime on the first `start()`.
- **Per-request breakdown** from `URLSessionTaskMetrics`: DNS, connect, TLS, wait (TTFB), download, connection reuse, protocol, bytes, redirects, plus whether `resume()` was called on the main thread.
- **WKWebView traffic** via an injected script that reads Resource Timing entries, because web content loads in another process where URLSession hooks never see it. Read-only by default; see below.
- **UI marks** you add yourself. Each also emits an `os_signpost`, so they show up in Instruments too.

```swift
APITrace.shared.start(label: "checkout", autoAttachWebViews: true)
APITrace.shared.mark("CartOpened")
// ... drive the flow ...
APITrace.shared.stop()

let records = APITrace.shared.snapshot()          // [APITrace.Record], sorted by start
let text    = APITrace.shared.report()            // same as printReport(), without printing
let perf    = APITrace.shared.exportPerfetto()    // URL of a Chrome Trace Event JSON
let csv     = APITrace.shared.exportCSV()
let json    = APITrace.shared.exportJSON()        // raw records, input for trace-compare

APITrace.shared.attach(to: webView)               // for web views created before start()
APITrace.shared.exportDirectory = someURL         // default: <Documents>/APITrace
```

#### WebViews

With `autoAttachWebViews: true`, every `WKWebView` gets the tracing script on its first `load`. The default script only reads `PerformanceObserver` entries and never modifies page globals, so login and payment pages guarded by anti-tamper scripts keep working. It gives start, duration, DNS/TLS/TTFB and size, but not HTTP status codes. To also get status codes, opt in to wrapping `fetch` and `XMLHttpRequest`, knowing that security layers may detect it:

```swift
APITrace.shared.webViewOptions = .all        // .resourceTiming (default) or [.resourceTiming, .fetchAndXHRStatus]
```

Web views loaded through `load(_:mimeType:characterEncodingName:baseURL:)` or created before `start()` need an explicit `attach(to:)` before their first load.

#### Filtering noise

Analytics or logging endpoints that fail on a staging backend can bury the findings in `-1200` and `-999` errors. Hide them from the report and the exports without changing what is recorded:

```swift
APITrace.shared.filter.excludeTransportErrors = true          // error != nil, e.g. NSURLErrorDomain#-1200
APITrace.shared.filter.excludeHTTPErrors = true               // status >= 400
APITrace.shared.filter.excludedHosts = ["omtrdc.net", "demdex.net"]   // the host and its subdomains
APITrace.shared.filter.includedHosts = ["example.com"]        // keep only these (and subdomains)
APITrace.shared.filter = .successfulOnly                      // or .all to reset
```

Marks are never filtered, `snapshot()` always returns everything, and the report header says `hidden by filter=N` so a filtered report is never mistaken for a full one. The filter survives `start()`.

The analyses behind the report are plain functions over `[APITrace.Record]`, so you can run them on any record list, live or decoded from a JSON export:

```swift
let reqs = records.filter { $0.isRequest }
Findings.serialChains(reqs)      // waterfall length
Findings.duplicates(reqs)        // same endpoint fetched more than once
Findings.idleGaps(reqs)          // time with nothing in flight
Findings.newConnections(reqs)    // TLS handshakes you could have avoided
Findings.lines(for: reqs)        // the "Findings:" section as text
```

## Reading the output

### The text report

```
APITrace report  label=login-cold-wifi  requests=14  marks=5  network span=3.412s

start  dur    src                   st   meth  dns   tls   ttfb   dl    reuse thr  name
0.312  0.618  AppAPIClient          200  POST  0.021 0.094 0.401  0.012 NEW   main POST api.example.com/v1/auth/token
0.941  0.233  AppAPIClient          200  GET   -     -     0.201  0.009 yes   bg   GET api.example.com/v1/me
...
```

| Column | Meaning |
|---|---|
| `start` / `dur` | Seconds since `start()`, and request duration |
| `src` | Who issued it: the URLSession delegate class, `alamofire`, `react-native`, `no-delegate`, `webview:<host>`, or `shared/unknown` for `URLSession.shared` |
| `st` | HTTP status, `ERR` for transport errors, `-` while in flight |
| `dns` / `tls` / `ttfb` / `dl` | DNS lookup, TLS handshake, request-sent-to-first-byte (server time), body download |
| `reuse` | `yes` = reused connection, `NEW` = new TCP+TLS handshake |
| `thr` | `main` if `resume()` was called on the main thread |

Then the marks, then **Findings**: requests by source, serialized chains (requests that waited for everything before them), duplicates, new connections and their TLS cost, summed server wait, slowest five, errors, main-thread starts, and idle gaps (time inside the network span with nothing in flight, which is client-side work).

### Perfetto

Open <https://ui.perfetto.dev> and drag the `.json` file in. One lane per source plus a `ui-marks` lane; each request is a bar with its phases (`dns`, `tcp`, `tls`, `send`, `wait`, `download`) nested under it. Press `W`/`S` to zoom, `A`/`D` to pan, click a bar for its status, bytes, protocol and query keys.

### trace-compare

Export JSON from two runs (for example before and after a change) and compare them offline:

```
swift run trace-compare before.records.json after.records.json
```

It prints the request count delta, longest serialized chain delta, network span delta, per-endpoint median duration before/after, and endpoints that were added or removed.

## Measurement protocol

1. Fix T0: call `start()` in the same place every time, as early as possible.
2. Measure cold start (kill the app, wait 10 s) and warm start separately.
3. Measure on Wi-Fi and on cellular separately. Never compare numbers across network types.
4. Five runs per configuration. Report the median and the worst.
5. Use the same build type (Debug, same optimisation flags) and the same device for before and after.
6. Record build number, device model, OS version and network type in the trace label, e.g. `"login-cold-wifi-b1234-iphone13"`.
7. Compare with `trace-compare`, not by eye.
8. One change at a time between runs.
9. Keep the exported files; they are small.
10. Check "Started on main thread" and idle gaps before blaming the backend.

## Privacy and limitations

- Records scheme, host, path and **query parameter names** only. Never headers, bodies, cookies or query values.
- Still a debug tool: it swizzles system classes and keeps every request in memory. Wrap `start()` in `#if DEBUG` and never ship it enabled.
- `URLSession.shared` is created before the hooks exist, so its requests get start, end and status via KVO but no DNS/TLS breakdown.
- Tasks created with a completion handler do not reach the session delegate's completion callback (Foundation bypasses it). They still get metrics, and completion comes from KVO on the task state.
- WebView cross-origin resources only expose full timing if the server sends `Timing-Allow-Origin`. You always get start and duration; status codes need the opt-in `fetchAndXHRStatus` option.
- Background URLSessions use a different task class hierarchy and are not hooked.
- Exports are written to `<Documents>/APITrace` and are never cleaned up automatically.

## Roadmap

- `ScreenTrace`: automatic `Appear:`/`Disappear:` marks for view controllers and a SwiftUI modifier.
- `LaunchTrace`: pre-main, main-to-didFinishLaunching and first-frame breakdown.
- `NetworkConditions`: tag every run with Wi-Fi / cellular / expensive / constrained.
- `MainThreadWatchdog`: record main-thread stalls as marks.
- `DebugMenu`: SwiftUI screen with start/stop, live counts, report and share.

## License

MIT. Copyright (c) 2026 Denys Volkov.
