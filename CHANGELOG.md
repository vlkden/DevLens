# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.1] - 2026-10-29

### Added
- `APITrace.Filter` and `APITrace.shared.filter`: hide requests with transport errors, HTTP 4xx/5xx, or from given hosts from the report and all exports. `snapshot()` stays unfiltered; `filteredSnapshot()` returns what the exports see. The report header shows `hidden by filter=N`.
- `APITrace.WebViewOptions` and `APITrace.shared.webViewOptions`: choose what the WebView script does. `.resourceTiming` (default) is read-only; `.fetchAndXHRStatus` wraps `fetch`/XHR for status codes.
- `isAttached(_:)` to check whether a web view carries the tracing script.
- `start(autoAttachWebViews: true)` now installs the WebView hook even if an earlier `start()` passed `false`.

### Changed
- The WebView script no longer wraps `window.fetch` and `XMLHttpRequest` by default. Pages protected by anti-tamper or bot-detection scripts rejected the wrapped functions, which surfaced in apps as TLS or trust failures. Status codes for web requests now need `webViewOptions = .all`.
- Auto-attach hooks `load(_:)`, `loadHTMLString(_:baseURL:)` and `loadFileURL(_:allowingReadAccessTo:)` instead of swizzling `initWithFrame:configuration:`. The initializer is in the ObjC `init` family and a Swift replacement cannot honour its ownership rules; the `load` methods are ordinary. Web views loaded only through `load(_:mimeType:characterEncodingName:baseURL:)` need a manual `attach(to:)`.

## [0.1.0] - 2026-10-29

### Added
- `APITrace`: debug-only URLSession and WKWebView tracer with UI marks, text report, automatic findings, Perfetto and CSV export, share sheet.
- `APITrace.Record` is `Codable`; `exportJSON()` writes raw records for offline comparison.
- `Findings`: pure functions over `[APITrace.Record]` (serial chains, duplicates, new connections, idle gaps, slowest, errors).
- `TraceExport`: pure builders for the text report, Perfetto JSON and CSV.
- `trace-compare`: compares two exported traces (request count, chain length, per-endpoint medians, added and removed endpoints, network span).
- `DevLens` umbrella module.
- `exportDirectory` to redirect where exports are written.
- Unit tests, CI on macOS and iOS Simulator, MIT license.

### Fixed
Relative to the single-file `APITrace.swift` this package grew out of:
- Requests made with a completion handler could stay open forever when the response arrived before the state observer was registered. Foundation never forwards `didCompleteWithError` for those tasks, so the observer is their only completion signal.
- Cancelled tasks recorded no error because completion was taken from the `canceling` state, before the error exists.
- A delegate class whose name happened to start with `APITrace` was reported as `no-delegate`.
- The probe session used to locate the task class was never invalidated.
