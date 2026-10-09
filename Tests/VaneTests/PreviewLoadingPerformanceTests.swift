import AppKit
import Network
import XCTest
import WebKit
@testable import vane

private final class PreviewServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "vane-preview-load-fixture")
    private let lock = NSLock()
    private var hits = 0
    var requests: Int { lock.withLock { hits } }

    init(body: String = "<html><body><h1>A preview</h1><p>Preview content</p></body></html>") throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
                if data?.isEmpty == false {
                    self?.lock.withLock { self?.hits += 1 }
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                } else { connection.cancel() }
            }
        }
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let port = self?.listener.port else { return }
                    self?.listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)")!)
                case .failed(let error):
                    self?.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }
}

@MainActor final class PreviewLoadingPerformanceTests: XCTestCase {
    func testCancellationUnloadsThePreviewDocument() async throws {
        try await checkUnloadsDocument(cachedReplacement: false)
    }

    func testCachedReplacementUnloadsThePreviousPreviewDocument() async throws {
        try await checkUnloadsDocument(cachedReplacement: true)
    }

    func testSourceTeardownUnloadsOnlyItsOwnPreview() async throws {
        try await checkUnloadsDocument(cachedReplacement: false, ownerTeardown: true)
    }

    private func checkUnloadsDocument(cachedReplacement: Bool, ownerTeardown: Bool = false) async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let server = try PreviewServer(body: "<title>Running preview</title><script>window.ticks=0;setInterval(()=>window.ticks++,20)</script>")
        let base = try await server.start()
        let previews = ownerTeardown ? Previews.shared : Previews()
        let tab = Tab(isPrivate: true)
        let enabled = Previews.enabled
        Previews.enabled = true
        var host: NSWindow?
        defer {
            previews.cancel(); tab.tearDown(); server.stop(); Previews.enabled = enabled
            // The singleton keeps its reusable, blank page until this test process exits.
            if !ownerTeardown {
                host?.isReleasedWhenClosed = false
                host?.contentView = nil; host?.close()
            }
        }
        let cachedURL = base.appendingPathComponent("cached")
        var cached = Previews.Preview(url: cachedURL)
        cached.image = NSImage(size: NSSize(width: 10, height: 10))
        previews.publish(cached, for: previews.begin())
        previews.request(base.appendingPathComponent("running"), from: tab)
        let deadline = ContinuousClock.now + .seconds(8)
        var page: WKWebView?
        while ContinuousClock.now < deadline {
            host = NSApp.windows.first { ($0.contentView as? WKWebView)?.url?.port == base.port }
            page = host?.contentView as? WKWebView
            if page?.title == "Running preview", page?.isLoading == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let web = try XCTUnwrap(page)
        XCTAssertEqual(web.title, "Running preview")
        let requestsBeforeReplacement = server.requests
        if cachedReplacement { previews.request(cachedURL, from: tab) }
        else if ownerTeardown {
            let other = Tab(isPrivate: true)
            other.tearDown()
            XCTAssertEqual(previews.current?.url, base.appendingPathComponent("running"), "Another tab's teardown must preserve this preview")
            tab.tearDown()
        } else { previews.cancel() }
        let measure = ProcessInfo.processInfo.environment["VANE_LIFECYCLE_MEASURE"] == "1"
        if measure {
            try await Task.sleep(for: .seconds(30))
            let before = (try await web.evaluateJavaScript("window.ticks || 0")) as? Int ?? 0
            try await Task.sleep(for: .seconds(3))
            let after = (try await web.evaluateJavaScript("window.ticks || 0")) as? Int ?? 0
            print("LIFECYCLE preview cachedReplacement=\(cachedReplacement) ownerTeardown=\(ownerTeardown) timer callbacks after 30s settle, 3s sample: \(after - before)")
        }
        let settle = ContinuousClock.now + .seconds(3)
        while web.url?.absoluteString != "about:blank", ContinuousClock.now < settle {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(web.url?.absoluteString, "about:blank", "Dismissal must unload timers/media, not only stop an in-flight load")
        XCTAssertTrue(host?.contentView === web, "Cancellation should preserve the reusable preview WebView")
        if cachedReplacement {
            XCTAssertEqual(previews.current?.url, cachedURL)
            XCTAssertNotNil(previews.current?.image)
            XCTAssertEqual(server.requests, requestsBeforeReplacement, "The cached card must not reload its destination")
        }
        else { XCTAssertNil(previews.current) }
        let timerType = try await web.evaluateJavaScript("typeof window.ticks") as? String
        XCTAssertEqual(timerType, "undefined")
    }

    func testProfileReplacementReleasesPreviousPreviewViews() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        final class WeakView {
            weak var value: WKWebView?
            init(_ value: WKWebView) { self.value = value }
        }
        let server = try PreviewServer(), base = try await server.start()
        let previews = Previews()
        let enabled = Previews.enabled
        Previews.enabled = true
        var host: NSWindow?
        defer {
            previews.cancel(); server.stop(); Previews.enabled = enabled
            host?.isReleasedWhenClosed = false
            host?.contentView = nil; host?.close()
        }
        let measure = ProcessInfo.processInfo.environment["VANE_LIFECYCLE_MEASURE"] == "1"
        var previous: [WeakView] = []
        for index in 0..<(measure ? 10 : 3) {
            autoreleasepool {
                if let web = host?.contentView as? WKWebView {
                    previous.append(WeakView(web))
                }
            }
            // Private tabs normalize to Profile.incognito.id. Alternate with the
            // isolated default profile so each request really replaces the view.
            let tab = Tab(isPrivate: index.isMultiple(of: 2))
            defer { tab.tearDown() }
            let url = base.appendingPathComponent("profile-\(index)")
            previews.request(url, from: tab)
            let deadline = ContinuousClock.now + .seconds(8)
            while ContinuousClock.now < deadline {
                let loaded = autoreleasepool {
                    host = NSApp.windows.first { ($0.contentView as? WKWebView)?.url == url } ?? host
                    guard let web = host?.contentView as? WKWebView else { return false }
                    return web.url == url && !web.isLoading
                }
                if loaded { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            autoreleasepool {
                let web = host?.contentView as? WKWebView
                XCTAssertEqual(web?.url, url)
                if let previous = previous.last?.value {
                    XCTAssertFalse(web === previous, "This fixture must actually replace the profile's view")
                }
            }
        }
        previews.cancel()
        if measure { try await Task.sleep(for: .seconds(30)) }
        let deadline = ContinuousClock.now + .seconds(3)
        while previous.contains(where: { $0.value != nil }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let retained = previous.filter { $0.value != nil }.count
        print("LIFECYCLE replaced preview WebViews retained: \(retained)/\(previous.count), settling: \(measure ? 30 : 0)s")
        XCTAssertEqual(retained, 0, "Changing profiles must release the previous profile's preview view")
    }

    func testBriefHoverDoesNotVisitDestinationButSettledHoverDoes() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let server = try PreviewServer(), base = try await server.start()
        let previews = Previews(), tab = Tab(isPrivate: true)
        let enabled = Previews.enabled
        Previews.enabled = true
        defer { previews.cancel(); tab.tearDown(); server.stop(); Previews.enabled = enabled }
        // Warm the rendering process so cancellation cannot accidentally win just
        // because WebKit was still launching when the first request was stopped.
        previews.request(base.appendingPathComponent("warm"), from: tab)
        let deadline = Date.now.addingTimeInterval(5)
        while server.requests == 0 && Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(server.requests, 0)
        previews.cancel()
        try await Task.sleep(for: .milliseconds(100))
        let before = server.requests
        previews.request(base.appendingPathComponent("brief"), from: tab)
        try await Task.sleep(for: .milliseconds(70))
        previews.cancel()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(server.requests, before, "Moving past a link must not pay for another full page load")
        previews.request(base.appendingPathComponent("settled"), from: tab)
        let settledDeadline = Date.now.addingTimeInterval(5)
        while server.requests == before && Date.now < settledDeadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(server.requests, before, "A deliberate hover still loads its preview")
    }
}
