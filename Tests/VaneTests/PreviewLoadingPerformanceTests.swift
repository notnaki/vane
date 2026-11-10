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
    private var paths: [String] = []
    var requests: Int { lock.withLock { hits } }
    var requestedPaths: [String] { lock.withLock { paths } }

    init(body: String = "<html><body><h1>A preview</h1><p>Preview content</p></body></html>") throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receiveRequest(on: connection, body: body)
        }
    }

    private func receiveRequest(on connection: NWConnection, body: String, buffered: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self, let data, !data.isEmpty, error == nil else { connection.cancel(); return }
            let received = buffered + data
            // TCP may split even the request line across receives. Record only a
            // complete line so packet boundaries cannot change the asserted path.
            guard let lineEnd = received.range(of: Data("\r\n".utf8)) else {
                if done { connection.cancel() }
                else { self.receiveRequest(on: connection, body: body, buffered: received) }
                return
            }
            let line = String(decoding: received[..<lineEnd.lowerBound], as: UTF8.self)
            let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            self.lock.withLock {
                self.hits += 1
                self.paths.append(path)
            }
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
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

/// Observes real callbacks without changing their order, policy, or owner. Installed
/// only in synthetic replacement fixtures; the production bridge still handles all work.
@MainActor private final class PreviewTrace: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let downstream: WKNavigationDelegate
    weak var previews: Previews?
    private(set) var events: [String] = []
    init(web: WKWebView, previews: Previews) throws {
        downstream = try XCTUnwrap(web.navigationDelegate)
        self.previews = previews
        super.init()
        web.navigationDelegate = self
        let controller = web.configuration.userContentController
        let world = WKContentWorld.world(name: "VanePreviewMetadata")
        controller.removeScriptMessageHandler(forName: "vanepreviewmeta", contentWorld: world)
        controller.add(self, contentWorld: world, name: "vanepreviewmeta")
        record("installed", web)
    }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || MainActor.assumeIsolated { (downstream as? NSObject)?.responds(to: selector) == true }
    }
    override func forwardingTarget(for selector: Selector!) -> Any? { MainActor.assumeIsolated { downstream } }
    private func identity(_ navigation: WKNavigation?) -> String {
        navigation.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
    }
    func record(_ event: String, _ web: WKWebView, navigation: WKNavigation? = nil) {
        guard events.count < 96 else { return }
        let fields = previews.map { Mirror(reflecting: $0).children }
        let state = fields?.compactMap { field -> String? in
            guard let key = field.label, ["latest", "committed", "navigation", "metadataDocument", "showing"].contains(key) else { return nil }
            if let nav = field.value as? WKNavigation { return "\(key)=\(identity(nav))" }
            return "\(key)=\(String(describing: field.value))"
        }.joined(separator: " ") ?? "owner=nil"
        events.append("\(event) callback=\(identity(navigation)) url=\(web.url?.absoluteString ?? "nil") loading=\(web.isLoading) title=\(previews?.current?.title ?? "nil") \(state)")
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let web = message.webView { record("metadata before frame=\(message.frameInfo.request.url?.absoluteString ?? "nil") main=\(message.frameInfo.isMainFrame)", web) }
        (downstream as? WKScriptMessageHandler)?.userContentController(controller, didReceive: message)
        if let web = message.webView { record("metadata after", web) }
    }
    func webView(_ web: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        record("start before", web, navigation: navigation)
        downstream.webView?(web, didStartProvisionalNavigation: navigation)
        record("start after", web, navigation: navigation)
    }
    func webView(_ web: WKWebView, didCommit navigation: WKNavigation!) {
        downstream.webView?(web, didCommit: navigation)
        record("commit after", web, navigation: navigation)
    }
    func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
        downstream.webView?(web, didFinish: navigation)
        record("finish after", web, navigation: navigation)
    }
    func webView(_ web: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        downstream.webView?(web, didFail: navigation, withError: error)
        record("fail \((error as NSError).code)", web, navigation: navigation)
    }
    func webView(_ web: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        downstream.webView?(web, didFailProvisionalNavigation: navigation, withError: error)
        record("provisional fail \((error as NSError).code)", web, navigation: navigation)
    }
}

@MainActor final class PreviewLoadingPerformanceTests: XCTestCase {
    private var previousBatteryMode: BatterySaver.Mode?
    override func setUp() async throws {
        TestEnvironment.prepare()
        previousBatteryMode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
    }
    override func tearDown() async throws {
        if let previousBatteryMode { BatterySaver.shared.setMode(previousBatteryMode) }
    }

    func testPreviewHostCannotAppearOrInterceptClicksWhenMovedOntoScreen() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let server = try PreviewServer(body: """
        <title>Hidden preview</title><body style='margin:0'>
        <div style='height:240px;background:#1976d2'>Preview content</div>
        <div style='height:240px;background:#e53935'></div>
        <div style='height:240px;background:#43a047'></div></body>
        """)
        let base = try await server.start(), previews = Previews(), tab = Tab(isPrivate: true)
        let enabled = Previews.enabled
        Previews.enabled = true
        var host: NSWindow?
        defer {
            previews.cancel(); tab.tearDown(); server.stop(); Previews.enabled = enabled
            host?.isReleasedWhenClosed = false
            host?.contentView = nil; host?.close()
        }
        previews.request(base, from: tab)
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            host = NSApp.windows.first { ($0.contentView as? WKWebView)?.url?.port == base.port }
            if previews.current?.image != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let window = try XCTUnwrap(host)
        XCTAssertNotNil(previews.current?.image, "An invisible host must still produce page snapshots")
        let screen = try XCTUnwrap(NSScreen.main)
        // Model macOS relocating an offscreen window after a display/Space change.
        window.setFrameOrigin(screen.visibleFrame.origin)
        window.orderFront(nil)
        XCTAssertTrue(window.isVisible, "WebKit retains an ordered host")
        XCTAssertEqual(window.alphaValue, 0, "Relocation must never reveal a white window")
        XCTAssertTrue(window.ignoresMouseEvents, "The renderer must never intercept desktop clicks")
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertTrue(window.isExcludedFromWindowsMenu)
        XCTAssertTrue(window.collectionBehavior.contains(.ignoresCycle))
        XCTAssertFalse(window.isRestorable)

        previews.cancel()
        let blankDeadline = ContinuousClock.now + .seconds(5)
        let web = try XCTUnwrap(window.contentView as? WKWebView)
        while (web.url?.absoluteString != "about:blank" || web.isLoading), ContinuousClock.now < blankDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(web.url?.absoluteString, "about:blank")
        XCTAssertEqual(window.alphaValue, 0, "The reusable blank host must also remain invisible")
        XCTAssertTrue(window.ignoresMouseEvents)
    }

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
        // URL changes before the old JavaScript context has necessarily gone away.
        // Wait for the replacement document, rather than treating URL KVO as completion.
        let settle = ContinuousClock.now + .seconds(8)
        var timerType: String?
        while ContinuousClock.now < settle {
            if web.url?.absoluteString == "about:blank", !web.isLoading {
                timerType = try await web.evaluateJavaScript("typeof window.ticks") as? String
                if timerType == "undefined" { break }
            }
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
        XCTAssertEqual(timerType, "undefined")
    }

    func testRetiredBlankNavigationAndFrameCannotMutateNewPreview() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let server = try PreviewServer(body: "<title>Current preview</title><body>Fixture<script>if(location.pathname==='/next')location.replace('/final')</script></body>")
        let base = try await server.start(), previews = Previews(), tab = Tab(isPrivate: true)
        let enabled = Previews.enabled
        Previews.enabled = true
        var host: NSWindow?
        defer {
            previews.cancel(); tab.tearDown(); server.stop(); Previews.enabled = enabled
            host?.isReleasedWhenClosed = false
            host?.contentView = nil; host?.close()
        }
        previews.request(base.appendingPathComponent("first"), from: tab)
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            host = NSApp.windows.first { ($0.contentView as? WKWebView)?.url?.port == base.port }
            if (host?.contentView as? WKWebView)?.isLoading == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let web = try XCTUnwrap(host?.contentView as? WKWebView)
        let trace = try PreviewTrace(web: web, previews: previews)
        let blank = try XCTUnwrap(web.load(URLRequest(url: URL(string: "about:blank")!)))
        trace.record("issued external blank", web, navigation: blank)
        let next = base.appendingPathComponent("next")
        previews.request(next, from: tab)
        let nextDeadline = ContinuousClock.now + .seconds(8)
        trace.record("requested replacement", web)
        while web.url != base.appendingPathComponent("final") || web.isLoading
                || previews.current?.title != "Current preview" {
            guard ContinuousClock.now < nextDeadline else {
                trace.record("timeout appRunning=\(NSApp.isRunning) launched=\(NSRunningApplication.current.isFinishedLaunching) paths=\(server.requestedPaths)", web)
                print(trace.events.joined(separator: "\n"))
                return XCTFail("Replacement preview did not load: url=\(web.url?.absoluteString ?? "nil") loading=\(web.isLoading) nativeTitle=\(previews.current?.title ?? "nil") webTitle=\(web.title ?? "nil")")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        trace.record("replacement completed appRunning=\(NSApp.isRunning) launched=\(NSRunningApplication.current.isFinishedLaunching)", web)
        print("Preview replacement trace:\n" + trace.events.joined(separator: "\n"))
        let pageHandler = try await web.evaluateJavaScript("typeof window.webkit?.messageHandlers?.vanepreviewmeta") as? String
        XCTAssertEqual(pageHandler, "undefined", "Previewed pages must not be able to fabricate native metadata")
        // An about:blank child provides an actual WKScriptMessage with a blank
        // originating frame while the containing WebView already has a new URL.
        // The handler exists only in the metadata producer's isolated world.
        web.callAsyncJavaScript("""
        var f = document.createElement('iframe'); document.body.appendChild(f);
        f.contentWindow.webkit.messageHandlers.vanepreviewmeta.postMessage('<title>Stale blank</title>'); return true;
        """, arguments: [:], in: nil, in: WKContentWorld.world(name: "VanePreviewMetadata"), completionHandler: nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotEqual(previews.current?.title, "Stale blank")
        var pending = Previews.Preview(url: next)
        pending.title = "Current preview"
        previews.publish(pending, for: previews.begin())
        web.navigationDelegate?.webView?(web, didFail: blank, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        XCTAssertEqual(previews.current?.loading, true, "A retired unload must not finish the new request")
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
        let debounce = DebounceFixture()
        let previews = Previews(debounceSleep: debounce.sleep), tab = Tab(isPrivate: true)
        let enabled = Previews.enabled
        let batteryMode = BatterySaver.shared.mode
        Previews.enabled = true
        BatterySaver.shared.setMode(.off)
        var host: NSWindow?
        defer {
            previews.cancel(); debounce.finish(); tab.tearDown(); server.stop()
            Previews.enabled = enabled; BatterySaver.shared.setMode(batteryMode)
            host?.isReleasedWhenClosed = false
            host?.contentView = nil; host?.close()
        }
        previews.request(base.appendingPathComponent("brief"), from: tab)
        try await debounce.waitUntil { debounce.count == 1 }
        previews.cancel()
        debounce.release(0)
        try await debounce.waitUntil { debounce.completed.contains(0) }
        XCTAssertEqual(server.requestedPaths, [], "Moving past a link must not start a page load")

        let settled = base.appendingPathComponent("settled")
        previews.request(settled, from: tab)
        try await debounce.waitUntil { debounce.count == 2 }
        XCTAssertEqual(server.requestedPaths, [], "A pending hover must stay behind the debounce gate")
        debounce.release(1)
        try await debounce.waitUntil {
            host = NSApp.windows.first { ($0.contentView as? WKWebView)?.url?.port == base.port }
            return server.requestedPaths.contains("/settled")
        }
        XCTAssertFalse(server.requestedPaths.contains("/brief"), "Canceled hovers must never reach the server")
        XCTAssertTrue(server.requestedPaths.contains("/settled"), "A deliberate hover still loads its preview")
    }
}
