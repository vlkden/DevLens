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

    private static let attachedKey = malloc(1)!

    /// Injects the timing script and message handler into a web view. Called automatically for
    /// every `WKWebView` when `autoAttachWebViews` is true; call manually for web views created
    /// before `start()`. Attaching twice to the same configuration is a no-op.
    public func attach(to webView: WKWebView) {
        let ucc = webView.configuration.userContentController
        guard objc_getAssociatedObject(ucc, APITrace.attachedKey) == nil else { return }
        objc_setAssociatedObject(ucc, APITrace.attachedKey, true, .OBJC_ASSOCIATION_RETAIN)
        ucc.add(WebBridge(), name: "apitrace")
        ucc.addUserScript(WKUserScript(source: APITrace.webViewScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
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

    func hookWebViewInit() {
        guard let orig = class_getInstanceMethod(WKWebView.self, NSSelectorFromString("initWithFrame:configuration:")),
              let repl = class_getInstanceMethod(WKWebView.self, #selector(WKWebView.apitrace_init(frame:configuration:))) else { return }
        method_exchangeImplementations(orig, repl)
    }

    /// Resource timing gives the breakdown; fetch/XHR wrappers give status codes. Expect each web
    /// request to appear as one "resource" entry and one "fetch"/"xhr" entry: same URL, same start.
    static let webViewScript = """
    (function () {
      if (window.__apitrace) { return; } window.__apitrace = true;
      var post = function (e) { try { window.webkit.messageHandlers.apitrace.postMessage(e); } catch (_) {} };
      var origin = performance.timeOrigin || (Date.now() - performance.now());
      var nowEpoch = function () { return origin + performance.now(); };
      var strip = function (u) { try { var x = new URL(u, location.href); return x.origin + x.pathname; } catch (_) { return String(u).split('?')[0]; } };
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
    })();
    """
}

extension WKWebView {
    @objc dynamic func apitrace_init(frame: CGRect, configuration: WKWebViewConfiguration) -> WKWebView {
        let wv = apitrace_init(frame: frame, configuration: configuration)   // original init
        APITrace.shared.attach(to: wv)
        return wv
    }
}
#endif
