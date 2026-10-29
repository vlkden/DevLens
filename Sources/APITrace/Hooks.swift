//
//  Hooks.swift
//  DevLens / APITrace
//
//  Created by Denys Volkov.
//  MIT License.
//
//  ObjC runtime hooks for URLSession. Installed once, on the first `start()`, never on import.
//

import Foundation
import ObjectiveC.runtime

extension APITrace {

    func installHooksIfNeeded(autoAttachWebViews: Bool) {
        guard !hooksInstalled else { return }
        hooksInstalled = true
        hookTaskResume()
        hookSessionFactory()
        #if canImport(WebKit)
        if autoAttachWebViews { hookWebViewInit() }
        #endif
    }

    /// Hook `-resume` on the concrete task class that actually implements it (`NSURLSessionTask`
    /// itself is abstract; the real implementation lives in a private subclass). We walk the class
    /// chain of a probe task and replace `resume` on every class that has its own implementation.
    private func hookTaskResume() {
        let sel = #selector(URLSessionTask.resume)
        let probeSession = URLSession(configuration: .ephemeral)
        let probe = probeSession.dataTask(with: URL(string: "https://127.0.0.1/apitrace-probe")!)
        var current: AnyClass? = object_getClass(probe)
        var targets: [AnyClass] = []
        while let c = current {
            if let m = class_getInstanceMethod(c, sel) {
                let sup: AnyClass? = class_getSuperclass(c)
                let supM = sup.flatMap { class_getInstanceMethod($0, sel) }
                if supM == nil || supM! != m { targets.append(c) }
            }
            current = class_getSuperclass(c)
        }
        typealias ResumeIMP = @convention(c) (AnyObject, Selector) -> Void
        for cls in targets {
            guard let method = class_getInstanceMethod(cls, sel) else { continue }
            let original = method_getImplementation(method)
            let block: @convention(block) (AnyObject) -> Void = { obj in
                if let task = obj as? URLSessionTask { APITrace.shared.taskWillResume(task) }
                unsafeBitCast(original, to: ResumeIMP.self)(obj, sel)
            }
            class_replaceMethod(cls, sel, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }
        probe.cancel()
        probeSession.invalidateAndCancel()
    }

    /// Hook `+sessionWithConfiguration:delegate:delegateQueue:` so we can (a) hook the delegate's
    /// class for metrics/completion callbacks, keeping the app's delegate object untouched, and
    /// (b) supply an observer delegate when the app passes nil.
    private func hookSessionFactory() {
        let meta: AnyClass = object_getClass(URLSession.self)!
        let pairs: [(String, Selector)] = [
            ("sessionWithConfiguration:delegate:delegateQueue:", #selector(URLSession.apitrace_session(configuration:delegate:delegateQueue:))),
            ("sessionWithConfiguration:", #selector(URLSession.apitrace_session(configuration:)))
        ]
        for (origName, replSel) in pairs {
            guard let orig = class_getClassMethod(meta, NSSelectorFromString(origName)),
                  let repl = class_getClassMethod(meta, replSel) else { continue }
            method_exchangeImplementations(orig, repl)
        }
    }

    /// Replaces the two task-level delegate callbacks we need on the given class. The original
    /// implementation, if any, is called after ours. Classes are hooked at most once.
    func hookDelegateClass(_ cls: AnyClass) {
        let key = ObjectIdentifier(cls)
        guard !hookedDelegateClasses.contains(key) else { return }
        hookedDelegateClasses.insert(key)

        // urlSession(_:task:didFinishCollecting:)
        do {
            let sel = NSSelectorFromString("URLSession:task:didFinishCollectingMetrics:")
            typealias Fn = @convention(c) (AnyObject, Selector, URLSession, URLSessionTask, URLSessionTaskMetrics) -> Void
            let original = class_getInstanceMethod(cls, sel).map(method_getImplementation)
            let block: @convention(block) (AnyObject, URLSession, URLSessionTask, URLSessionTaskMetrics) -> Void = { obj, session, task, metrics in
                APITrace.shared.taskDidCollect(task, metrics: metrics, delegate: obj)
                if let original = original { unsafeBitCast(original, to: Fn.self)(obj, sel, session, task, metrics) }
            }
            class_replaceMethod(cls, sel, imp_implementationWithBlock(block), "v@:@@@")
        }
        // urlSession(_:task:didCompleteWithError:)
        do {
            let sel = NSSelectorFromString("URLSession:task:didCompleteWithError:")
            typealias Fn = @convention(c) (AnyObject, Selector, URLSession, URLSessionTask, NSError?) -> Void
            let original = class_getInstanceMethod(cls, sel).map(method_getImplementation)
            let block: @convention(block) (AnyObject, URLSession, URLSessionTask, NSError?) -> Void = { obj, session, task, error in
                APITrace.shared.taskDidComplete(task, error: error, delegate: obj)
                if let original = original { unsafeBitCast(original, to: Fn.self)(obj, sel, session, task, error) }
            }
            class_replaceMethod(cls, sel, imp_implementationWithBlock(block), "v@:@@@")
        }
    }

    /// Delegate used for sessions the app created with `delegate: nil`, so metrics still arrive.
    final class Observer: NSObject, URLSessionTaskDelegate {
        static let shared = Observer()
        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            APITrace.shared.taskDidCollect(task, metrics: metrics, delegate: nil)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            APITrace.shared.taskDidComplete(task, error: error as NSError?, delegate: nil)
        }
    }

    // MARK: Task lifecycle

    func taskWillResume(_ task: URLSessionTask) {
        guard isRecording else { return }
        let start = now()
        let onMain = Thread.isMainThread
        let qlabel = String(cString: __dispatch_queue_get_label(nil))
        if #available(iOS 15.0, macOS 12.0, *), let d = task.delegate { hookDelegateClass(object_getClass(d)!) }
        queue.async {
            if self.taskMap.object(forKey: task) != nil { return }          // already resumed (retry on same task, or double hook)
            let r = Record(id: self.allocID(), kind: "request", source: "shared/unknown", name: "", start: start)
            r.apply(url: task.originalRequest?.url, method: task.originalRequest?.httpMethod ?? "GET")
            r.startedOnMainThread = onMain
            r.queueLabel = qlabel
            self.taskMap.setObject(r, forKey: task)
            self.records.append(r)
            // KVO on task state is the only completion signal for (a) sessions whose delegate we
            // never saw, e.g. URLSession.shared, and (b) every task created with a completion
            // handler, because Foundation does not forward didCompleteWithError for those.
            // `.initial` catches tasks that already finished before this block ran (fast cached or
            // stubbed responses). Only `.completed` carries the final error; `.canceling` does not.
            r.observation = task.observe(\.state, options: [.initial, .new]) { [weak self] t, _ in
                guard t.state == .completed else { return }
                self?.taskDidComplete(t, error: t.error as NSError?, delegate: nil)
            }
        }
    }

    func taskDidCollect(_ task: URLSessionTask, metrics: URLSessionTaskMetrics, delegate: AnyObject?) {
        guard isRecording else { return }
        let src = delegate.map { classify(NSStringFromClass(object_getClass($0)!)) } ?? "no-delegate"
        queue.async {
            let r = self.record(for: task)
            guard !r.metricsRecorded else { return }
            r.metricsRecorded = true
            r.source = src
            r.redirects = max(0, metrics.transactionMetrics.count - 1)
            guard let t = metrics.transactionMetrics.last else { return }
            func rel(_ d: Date?) -> TimeInterval? { d.map { $0.timeIntervalSince(self.t0) } }
            func span(_ a: Date?, _ b: Date?) -> TimeInterval? { if let a = a, let b = b { return b.timeIntervalSince(a) } else { return nil } }
            r.dns = span(t.domainLookupStartDate, t.domainLookupEndDate)
            r.connect = span(t.connectStartDate, t.connectEndDate)
            r.tls = span(t.secureConnectionStartDate, t.secureConnectionEndDate)
            r.ttfb = span(t.requestEndDate, t.responseStartDate)
            r.download = span(t.responseStartDate, t.responseEndDate)
            r.reusedConnection = t.isReusedConnection
            r.protocolName = t.networkProtocolName
            r.requestBytes = t.countOfRequestHeaderBytesSent + t.countOfRequestBodyBytesSent
            r.responseBytes = t.countOfResponseHeaderBytesReceived + t.countOfResponseBodyBytesReceived
            if let s = rel(t.domainLookupStartDate), let e = rel(t.domainLookupEndDate) { r.phases.append(Phase(name: "dns", start: s, end: e)) }
            if let s = rel(t.connectStartDate), let e = rel(t.secureConnectionStartDate ?? t.connectEndDate) { r.phases.append(Phase(name: "tcp", start: s, end: e)) }
            if let s = rel(t.secureConnectionStartDate), let e = rel(t.secureConnectionEndDate) { r.phases.append(Phase(name: "tls", start: s, end: e)) }
            if let s = rel(t.requestStartDate), let e = rel(t.requestEndDate) { r.phases.append(Phase(name: "send", start: s, end: e)) }
            if let s = rel(t.requestEndDate), let e = rel(t.responseStartDate) { r.phases.append(Phase(name: "wait", start: s, end: e)) }
            if let s = rel(t.responseStartDate), let e = rel(t.responseEndDate) { r.phases.append(Phase(name: "download", start: s, end: e)) }
            if let st = (t.response as? HTTPURLResponse)?.statusCode { r.status = st }
        }
    }

    func taskDidComplete(_ task: URLSessionTask, error: NSError?, delegate: AnyObject?) {
        guard isRecording else { return }
        let end = now()
        let src = delegate.map { classify(NSStringFromClass(object_getClass($0)!)) }
        queue.async {
            // Completion can arrive twice (KVO and delegate). The first caller fixes the end time;
            // later callers only fill in what is still missing.
            let r = self.record(for: task)
            if r.end == nil { r.end = end }
            if let src = src, r.source == "shared/unknown" { r.source = src }
            if r.status == nil, let st = (task.response as? HTTPURLResponse)?.statusCode { r.status = st }
            if r.error == nil, let e = error { r.error = "\(e.domain)#\(e.code)" }
            r.observation?.invalidate()
            r.observation = nil
        }
    }

    // MARK: Helpers

    /// Call on `queue`. Returns the record for a task, creating one if `resume` was never seen.
    func record(for task: URLSessionTask) -> Record {
        if let r = taskMap.object(forKey: task) { return r }
        let r = Record(id: allocID(), kind: "request", source: "shared/unknown", name: "", start: now())
        r.apply(url: task.originalRequest?.url, method: task.originalRequest?.httpMethod ?? "GET")
        taskMap.setObject(r, forKey: task)
        records.append(r)
        return r
    }

    /// Maps a delegate class name to a short source label.
    func classify(_ cls: String) -> String {
        if cls == NSStringFromClass(Observer.self) { return "no-delegate" }
        if cls.hasPrefix("RCT") || cls.contains("ReactNative") { return "react-native" }
        if cls.contains("Alamofire") { return "alamofire" }
        return "native:" + cls
    }
}

// MARK: - Swizzle targets

extension URLSession {
    @objc dynamic class func apitrace_session(configuration: URLSessionConfiguration,
                                              delegate: URLSessionDelegate?,
                                              delegateQueue queue: OperationQueue?) -> URLSession {
        if let d = delegate { APITrace.shared.hookDelegateClass(object_getClass(d)!) }
        let effective: URLSessionDelegate = delegate ?? APITrace.Observer.shared
        // After method_exchangeImplementations this call invokes the original factory.
        return apitrace_session(configuration: configuration, delegate: effective, delegateQueue: queue)
    }

    @objc dynamic class func apitrace_session(configuration: URLSessionConfiguration) -> URLSession {
        // Swift imports `+sessionWithConfiguration:delegate:delegateQueue:` as this initializer, so
        // the call below goes through the (swizzled) three-argument factory, which installs the
        // Observer delegate. Alternative considered: calling the exchanged original directly,
        // but that would bypass delegate injection and lose metrics for delegate-less sessions.
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
    }
}
