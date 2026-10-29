//
//  WebViewTracing.swift
//  DevLens / APITrace
//
//  Created by Denys Volkov.
//  MIT License.
//
//  WKWebView networking runs in a separate process, so URLSession hooks never see it. We inject a
//  script that reports Resource Timing entries plus fetch/XHR wrappers through a message handler.
//

#if canImport(WebKit)
import Foundation
import ObjectiveC.runtime
import WebKit

extension APITrace {

    /// What the injected script does inside web pages.
    public struct WebViewOptions: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Report Resource Timing and Navigation Timing entries through a `PerformanceObserver`.
        /// Read-only: does not modify any page global, so anti-tamper and bot-detection scripts
        /// on login or payment pages are not affected. Gives start, duration, DNS/TLS/TTFB and size,
        /// but no HTTP status.
        public static let resourceTiming = WebViewOptions(rawValue: 1 << 0)

        /// Wrap `window.fetch` and `XMLHttpRequest` to also capture HTTP status codes and errors.
        /// Pages that check whether those functions are native (common in security layers used by
        /// banks and payment providers) may reject the session. Off by default.
        public static let fetchAndXHRStatus = WebViewOptions(rawValue: 1 << 1)

        public static let `default`: WebViewOptions = [.resourceTiming]
        public static let all: WebViewOptions = [.resourceTiming, .fetchAndXHRStatus]
    }

    private static let attachedKey = malloc(1)!
    private static var _webViewOptions = WebViewOptions.default
    private static let optionsLock = NSLock()

    /// Controls the script injected by `attach(to:)`. Set it before web views are attached;
    /// already-attached web views keep the script they got. Defaults to `.resourceTiming` only.
    public var webViewOptions: WebViewOptions {
        get { APITrace.optionsLock.lock(); defer { APITrace.optionsLock.unlock() }; return APITrace._webViewOptions }
        set { APITrace.optionsLock.lock(); APITrace._webViewOptions = newValue; APITrace.optionsLock.unlock() }
    }

    /// Injects the timing script and message handler into a web view. Called automatically on the
    /// first `load` of every `WKWebView` when `autoAttachWebViews` is true; call manually for web
    /// views created before `start()` or loaded through `load(_:mimeType:characterEncodingName:baseURL:)`.
    /// Attaching twice to the same configuration is a no-op. Scripts added here apply to the next
    /// navigation, so attach before calling `load`.
    public func attach(to webView: WKWebView) {
        let ucc = webView.configuration.userContentController
        guard objc_getAssociatedObject(ucc, APITrace.attachedKey) == nil else { return }
        objc_setAssociatedObject(ucc, APITrace.attachedKey, true, .OBJC_ASSOCIATION_RETAIN)
        ucc.add(WebBridge(), name: "apitrace")
        ucc.addUserScript(WKUserScript(source: APITrace.webViewScript(options: webViewOptions), injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    /// `true` once `attach(to:)` has run for this web view's configuration.
    public func isAttached(_ webView: WKWebView) -> Bool {
        objc_getAssociatedObject(webView.configuration.userContentController, APITrace.attachedKey) != nil
    }

    final class WebBridge: NSObject, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            APITrace.shared.recordWebEvent(body, pageHost: message.frameInfo.request.url?.host)
        }
    }

    func recordWebEvent(_ e: [String: Any], pageHost: String?) {
        guard isRecording else { return }
        let kind = "webview-" + ((e["kind"] as? String) ?? "resource")
        let epochMs = (e["start"] as? Double) ?? Date().timeIntervalSince1970 * 1000
        let start = Date(timeIntervalSince1970: epochMs / 1000).timeIntervalSince(t0)
        let durMs = (e["duration"] as? Double) ?? 0
        let url = (e["name"] as? String).flatMap(URL.init(string:))
        let method = (e["method"] as? String)?.uppercased() ?? (kind == "webview-navigation" ? "NAV" : "GET")
        let r = Record(id: 0, kind: kind, source: "webview" + (pageHost.map { ":\($0)" } ?? ""), name: "", start: start)
        r.apply(url: url, method: method)
        if kind == "webview-resource", let init_ = e["initiator"] as? String { r.name += " (\(init_))" }
        r.end = start + durMs / 1000
        r.status = e["status"] as? Int
        r.error = e["error"] as? String
        func ms(_ k: String) -> TimeInterval? { (e[k] as? Double).map { $0 / 1000 } }
        r.dns = ms("dns"); r.connect = ms("connect"); r.tls = ms("tls"); r.ttfb = ms("ttfb")
        r.responseBytes = (e["size"] as? Double).map(Int64.init)
        queue.async { r.id = self.allocID(); self.records.append(r) }
    }

    /// Hooks the `load` entry points of `WKWebView` so `attach(to:)` runs before the first
    /// navigation. These are ordinary methods, unlike `initWithFrame:configuration:`, whose
    /// `init`-family ownership rules a Swift replacement cannot honour. User scripts added at
    /// this point still apply to the navigation that follows.
    func hookWebViewLoad() {
        let cls: AnyClass = WKWebView.self
        typealias Load1 = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
        typealias Load2 = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> AnyObject?

        for name in ["loadRequest:"] {
            let sel = NSSelectorFromString(name)
            guard let m = class_getInstanceMethod(cls, sel) else { continue }
            let original = method_getImplementation(m)
            let block: @convention(block) (AnyObject, AnyObject?) -> AnyObject? = { obj, a in
                if let wv = obj as? WKWebView { APITrace.shared.attach(to: wv) }
                return unsafeBitCast(original, to: Load1.self)(obj, sel, a)
            }
            class_replaceMethod(cls, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m))
        }
        for name in ["loadHTMLString:baseURL:", "loadFileURL:allowingReadAccessToURL:"] {
            let sel = NSSelectorFromString(name)
            guard let m = class_getInstanceMethod(cls, sel) else { continue }
            let original = method_getImplementation(m)
            let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> AnyObject? = { obj, a, b in
                if let wv = obj as? WKWebView { APITrace.shared.attach(to: wv) }
                return unsafeBitCast(original, to: Load2.self)(obj, sel, a, b)
            }
            class_replaceMethod(cls, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m))
        }
    }

    /// Builds the injected script. Resource timing gives the breakdown; the optional fetch/XHR
    /// wrappers give status codes. With both enabled, expect each web request to appear as one
    /// "resource" entry and one "fetch"/"xhr" entry: same URL, same start.
    static func webViewScript(options: WebViewOptions) -> String {
        var body = """
          if (window.__apitrace) { return; } window.__apitrace = true;
          var post = function (e) { try { window.webkit.messageHandlers.apitrace.postMessage(e); } catch (_) {} };
          var origin = performance.timeOrigin || (Date.now() - performance.now());
          var nowEpoch = function () { return origin + performance.now(); };
          var strip = function (u) { try { var x = new URL(u, location.href); return x.origin + x.pathname; } catch (_) { return String(u).split('?')[0]; } };
        """
        if options.contains(.resourceTiming) {
            body += """
          try {
            var obs = new PerformanceObserver(function (list) {
              list.getEntries().forEach(function (r) {
                post({ kind: 'resource', name: strip(r.name), initiator: r.initiatorType, start: origin + r.startTime, duration: r.duration,
                       dns: (r.domainLookupEnd - r.domainLookupStart) || 0, connect: (r.connectEnd - r.connectStart) || 0,
                       tls: r.secureConnectionStart ? (r.connectEnd - r.secureConnectionStart) : 0,
                       ttfb: (r.responseStart && r.requestStart) ? (r.responseStart - r.requestStart) : 0, size: r.transferSize || 0 });
              });
            });
            obs.observe({ type: 'resource', buffered: true });
          } catch (_) {}
          window.addEventListener('load', function () {
            try {
              var n = performance.getEntriesByType('navigation')[0];
              if (n) { post({ kind: 'navigation', name: strip(location.href), start: origin + n.startTime, duration: n.loadEventEnd || n.duration,
                              dns: (n.domainLookupEnd - n.domainLookupStart) || 0, tls: n.secureConnectionStart ? (n.connectEnd - n.secureConnectionStart) : 0,
                              ttfb: n.responseStart || 0, size: n.transferSize || 0, status: n.responseStatus || 0 }); }
            } catch (_) {}
          });
        """
        }
        if options.contains(.fetchAndXHRStatus) {
            body += """
          if (window.fetch) {
            var of = window.fetch;
            window.fetch = function (input, init) {
              var u = (typeof input === 'string') ? input : (input && input.url); var m = (init && init.method) || (input && input.method) || 'GET'; var s = nowEpoch();
              return of.apply(this, arguments).then(function (res) { post({ kind: 'fetch', name: strip(u), method: m, start: s, duration: nowEpoch() - s, status: res.status }); return res; },
                                                    function (err) { post({ kind: 'fetch', name: strip(u), method: m, start: s, duration: nowEpoch() - s, error: String(err) }); throw err; });
            };
          }
          var oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function (m, u) { this.__apitrace = { m: m, u: u }; return oo.apply(this, arguments); };
          XMLHttpRequest.prototype.send = function () {
            var x = this, s = nowEpoch();
            x.addEventListener('loadend', function () { var i = x.__apitrace || {}; post({ kind: 'xhr', name: strip(i.u), method: i.m, start: s, duration: nowEpoch() - s, status: x.status }); });
            return os.apply(this, arguments);
          };
        """
        }
        return "(function () {\n" + body + "\n})();"
    }
}

#endif
