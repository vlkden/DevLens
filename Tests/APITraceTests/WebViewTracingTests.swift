//
//  WebViewTracingTests.swift
//  DevLens / APITraceTests
//
//  Created by Denys Volkov.
//  MIT License.
//

#if canImport(WebKit)
import XCTest
import WebKit
@testable import APITrace

final class WebViewTracingTests: XCTestCase {

    override func tearDown() {
        APITrace.shared.webViewOptions = .default
        APITrace.shared.stop()
        super.tearDown()
    }

    func testDefaultOptionsAreReadOnly() {
        XCTAssertEqual(APITrace.WebViewOptions.default, [.resourceTiming])
        XCTAssertEqual(APITrace.shared.webViewOptions, .default)
    }

    func testReadOnlyScriptDoesNotTouchPageGlobals() {
        let js = APITrace.webViewScript(options: .resourceTiming)
        XCTAssertTrue(js.contains("PerformanceObserver"))
        XCTAssertTrue(js.contains("getEntriesByType('navigation')"))
        XCTAssertFalse(js.contains("window.fetch ="))
        XCTAssertFalse(js.contains("XMLHttpRequest.prototype"))
        XCTAssertTrue(js.hasPrefix("(function () {"))
        XCTAssertTrue(js.hasSuffix("})();"))
    }

    func testWrapperScriptIsOptIn() {
        let js = APITrace.webViewScript(options: .all)
        XCTAssertTrue(js.contains("PerformanceObserver"))
        XCTAssertTrue(js.contains("window.fetch ="))
        XCTAssertTrue(js.contains("XMLHttpRequest.prototype.send ="))

        let onlyWrappers = APITrace.webViewScript(options: .fetchAndXHRStatus)
        XCTAssertFalse(onlyWrappers.contains("PerformanceObserver"))
        XCTAssertTrue(onlyWrappers.contains("window.fetch ="))
    }

    func testRecordWebEventMapsFields() {
        APITrace.shared.start(label: "web", autoAttachWebViews: false)
        let t0 = APITrace.shared.startDate.timeIntervalSince1970 * 1000
        APITrace.shared.recordWebEvent([
            "kind": "resource", "name": "https://cdn.example.com/app.js", "initiator": "script",
            "start": t0 + 250, "duration": 120.0, "dns": 10.0, "connect": 20.0, "tls": 15.0, "ttfb": 60.0, "size": 4096.0,
        ], pageHost: "www.example.com")
        APITrace.shared.recordWebEvent([
            "kind": "fetch", "name": "https://api.example.com/v1/items", "method": "post",
            "start": t0 + 400, "duration": 80.0, "status": 201,
        ], pageHost: nil)
        let reqs = APITrace.shared.snapshot().filter { $0.isRequest }
        XCTAssertEqual(reqs.count, 2)

        let res = reqs[0]
        XCTAssertEqual(res.kind, "webview-resource")
        XCTAssertEqual(res.source, "webview:www.example.com")
        XCTAssertEqual(res.name, "GET cdn.example.com/app.js (script)")
        XCTAssertEqual(res.start, 0.25, accuracy: 0.01)
        XCTAssertEqual(res.duration ?? 0, 0.12, accuracy: 1e-9)
        XCTAssertEqual(res.dns ?? 0, 0.010, accuracy: 1e-9)
        XCTAssertEqual(res.tls ?? 0, 0.015, accuracy: 1e-9)
        XCTAssertEqual(res.responseBytes, 4096)
        XCTAssertNil(res.status)

        let fetch = reqs[1]
        XCTAssertEqual(fetch.kind, "webview-fetch")
        XCTAssertEqual(fetch.source, "webview")
        XCTAssertEqual(fetch.method, "POST")
        XCTAssertEqual(fetch.status, 201)
    }

    #if canImport(UIKit)
    /// Simulator only: creating a WKWebView needs a UI process.
    func testAutoAttachHappensOnFirstLoad() {
        APITrace.shared.start(label: "web", autoAttachWebViews: true)
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        XCTAssertFalse(APITrace.shared.isAttached(webView), "nothing should happen at init")
        webView.loadHTMLString("<html><body>hi</body></html>", baseURL: nil)
        XCTAssertTrue(APITrace.shared.isAttached(webView))
        let scripts = webView.configuration.userContentController.userScripts
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].source.contains("PerformanceObserver"))
        XCTAssertFalse(scripts[0].source.contains("window.fetch ="))
        XCTAssertEqual(scripts[0].injectionTime, .atDocumentStart)
        XCTAssertFalse(scripts[0].isForMainFrameOnly)

        // Second load, same configuration: still exactly one script.
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        XCTAssertEqual(webView.configuration.userContentController.userScripts.count, 1)
    }

    func testManualAttachIsIdempotent() {
        APITrace.shared.start(label: "web", autoAttachWebViews: false)
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        APITrace.shared.attach(to: webView)
        APITrace.shared.attach(to: webView)
        XCTAssertEqual(webView.configuration.userContentController.userScripts.count, 1)
    }
    #endif
}
#endif
