//
//  HookIntegrationTests.swift
//  DevLens / APITraceTests
//
//  Created by Denys Volkov.
//  MIT License.
//
//  Integration tests for the URLSession hooks. They run real URLSession machinery against a stub
//  URLProtocol, so no network is touched. Filter them with `--filter HookIntegrationTests` or
//  `--skip HookIntegrationTests` if a platform misbehaves.
//

import XCTest
@testable import APITrace

final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Int(request.url?.lastPathComponent ?? "") ?? 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class RecordingDelegate: NSObject, URLSessionDataDelegate {
    let completed = XCTestExpectation(description: "delegate didComplete")
    var sawMetrics = false
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) { sawMetrics = true }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { completed.fulfill() }
}

/// A delegate that implements neither callback, so the hook has no original IMP to chain to.
final class SilentDelegate: NSObject, URLSessionDataDelegate {}

final class HookIntegrationTests: XCTestCase {

    private func config() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        return c
    }

    override func setUp() {
        super.setUp()
        APITrace.shared.start(label: "hooks", autoAttachWebViews: false)
    }

    override func tearDown() {
        APITrace.shared.stop()
        super.tearDown()
    }

    /// Waits until the single request record has an end time.
    private func waitForCompletion(named name: String, file: StaticString = #filePath, line: UInt = #line) -> APITrace.Record? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let r = APITrace.shared.snapshot().first(where: { $0.name == name && $0.end != nil }) { return r }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let dump = APITrace.shared.snapshot().map { "\($0.id):\($0.name) end=\($0.end.map { "\($0)" } ?? "nil") src=\($0.source)" }.joined(separator: " | ")
        XCTFail("no completed record named \(name). snapshot: \(dump)", file: file, line: line)
        return nil
    }

    func testSessionWithoutDelegateIsTraced() {
        let session = URLSession(configuration: config())
        defer { session.invalidateAndCancel() }
        let done = expectation(description: "completion handler")
        session.dataTask(with: URL(string: "https://api.example.com/v1/items?page=1&token=secret")!) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 5)

        guard let r = waitForCompletion(named: "GET api.example.com/v1/items") else { return }
        XCTAssertEqual(r.kind, "request")
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.host, "api.example.com")
        XCTAssertEqual(r.path, "/v1/items")
        XCTAssertEqual(r.queryKeys, ["page", "token"])
        XCTAssertEqual(r.status, 200)
        XCTAssertNil(r.error)
        XCTAssertNotNil(r.startedOnMainThread)
        XCTAssertNotNil(r.queueLabel)
        XCTAssertGreaterThanOrEqual(r.end ?? -1, r.start)
        // The injected Observer delegate classifies as no-delegate once metrics arrive.
        XCTAssertTrue(["no-delegate", "shared/unknown"].contains(r.source), r.source)
    }

    func testSessionWithDelegateIsTracedAndDelegateStillCalled() {
        let delegate = RecordingDelegate()
        let session = URLSession(configuration: config(), delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.example.com/v1/orders")!)
        request.httpMethod = "POST"
        session.dataTask(with: request).resume()
        wait(for: [delegate.completed], timeout: 5)

        guard let r = waitForCompletion(named: "POST api.example.com/v1/orders") else { return }
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.source, "native:" + NSStringFromClass(RecordingDelegate.self))
        XCTAssertTrue(delegate.sawMetrics, "the delegate's own metrics callback must still run")
    }

    func testDelegateWithoutCallbacksStillYieldsCompletion() {
        let session = URLSession(configuration: config(), delegate: SilentDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: URL(string: "https://api.example.com/status/404")!).resume()
        guard let r = waitForCompletion(named: "GET api.example.com/status/404") else { return }
        XCTAssertEqual(r.status, 404)
    }

    func testCancelledTaskRecordsErrorViaDelegate() {
        let session = URLSession(configuration: config())
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://api.example.com/slow")!)
        task.resume()
        task.cancel()
        guard let r = waitForCompletion(named: "GET api.example.com/slow") else { return }
        // Either the stub finished first (200) or the cancel won (NSURLErrorDomain#-999).
        if let e = r.error {
            XCTAssertEqual(e, "NSURLErrorDomain#-999")
        } else {
            XCTAssertEqual(r.status, 200)
        }
    }

    /// Completion-handler tasks never reach the session delegate's didCompleteWithError, so this
    /// exercises the KVO-only completion path, including the error of a cancelled task.
    func testCancelledCompletionHandlerTaskRecordsError() {
        let session = URLSession(configuration: config())
        defer { session.invalidateAndCancel() }
        let done = expectation(description: "completion handler")
        var handlerError: NSError?
        let task = session.dataTask(with: URL(string: "https://api.example.com/cancel-me")!) { _, _, e in handlerError = e as NSError?; done.fulfill() }
        task.resume()
        task.cancel()
        wait(for: [done], timeout: 5)
        guard let r = waitForCompletion(named: "GET api.example.com/cancel-me") else { return }
        if let e = handlerError {
            XCTAssertEqual(r.error, "\(e.domain)#\(e.code)")
            XCTAssertEqual(r.error, "NSURLErrorDomain#-999")
        } else {
            XCTAssertEqual(r.status, 200)
            XCTAssertNil(r.error)
        }
    }

    func testNothingRecordedWhenStopped() {
        APITrace.shared.stop()
        let session = URLSession(configuration: config())
        defer { session.invalidateAndCancel() }
        let done = expectation(description: "completion handler")
        session.dataTask(with: URL(string: "https://api.example.com/ignored")!) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 5)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(APITrace.shared.snapshot().contains { $0.name.contains("ignored") })
    }

    func testResumeTwiceRecordsOnce() {
        let session = URLSession(configuration: config())
        defer { session.invalidateAndCancel() }
        let done = expectation(description: "completion handler")
        let task = session.dataTask(with: URL(string: "https://api.example.com/once")!) { _, _, _ in done.fulfill() }
        task.resume()
        task.resume()
        wait(for: [done], timeout: 5)
        _ = waitForCompletion(named: "GET api.example.com/once")
        XCTAssertEqual(APITrace.shared.snapshot().filter { $0.name == "GET api.example.com/once" }.count, 1)
    }
}
