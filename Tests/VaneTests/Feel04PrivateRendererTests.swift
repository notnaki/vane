import AppKit
import Network
import WebKit
import XCTest
@testable import vane

/// Owned loopback fixtures can serve a page, withhold a response, or refuse a connection.
/// No remote website or screenshot timing is needed for renderer lifecycle assertions.
private final class Feel04WaitingServer: @unchecked Sendable {
    let listener: NWListener
    private let body: String?
    private let hold: Bool
    private let cookie: Bool
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    init(body: String? = nil, hold: Bool = false, cookie: Bool = false) throws {
        self.body = body; self.hold = hold; self.cookie = cookie
        listener = try NWListener(using: .tcp, on: .any)
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let body = body, cookie = cookie
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                if hold {
                    lock.withLock { connections.append(connection) }
                    connection.start(queue: DispatchQueue(label: "feel04-held-response"))
                    return
                }
                guard let body else { connection.cancel(); return }
                connection.start(queue: DispatchQueue(label: "feel04-loopback-response"))
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                    guard data?.isEmpty == false else { connection.cancel(); return }
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\(cookie ? "Set-Cookie: feel04=preview; Path=/\r\n" : "")Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self, let port = listener.port else { return }
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)")!)
                case .failed(let error):
                    self?.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "feel04-private-renderer"))
        }
    }
    func stop() {
        listener.cancel()
        let pending = lock.withLock { let pending = connections; connections = []; return pending }
        pending.forEach { $0.cancel() }
    }
}

@MainActor final class Feel04PrivateRendererTests: XCTestCase {
    func testPrivateTabsCannotReuseEachOthersRendererStore() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let server = try Feel04WaitingServer(), url = try await server.start()
        let clock = Feel04DebounceFixture(), previews = Previews(debounceSleep: clock.sleep)
        let first = Tab(isPrivate: true), second = Tab(isPrivate: true)
        let enabled = Previews.enabled, mode = BatterySaver.shared.mode
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        Previews.enabled = true; BatterySaver.shared.setMode(.off)
        var host: NSWindow?
        defer {
            previews.cancel(); clock.finish(); first.tearDown(); second.tearDown(); server.stop()
            host?.contentView = nil; host?.close()
            Previews.enabled = enabled; BatterySaver.shared.setMode(mode)
        }
        previews.request(url.appendingPathComponent("first"), from: first)
        try await clock.waitUntil { clock.count == 1 }
        clock.release(0)
        try await clock.waitUntil {
            host = NSApp.windows.first { $0 is PreviewHostWindow && !existing.contains(ObjectIdentifier($0)) }
            return host?.contentView is WKWebView
        }
        let original = try XCTUnwrap(host?.contentView as? WKWebView)
        previews.request(url.appendingPathComponent("second"), from: second)
        try await clock.waitUntil { clock.count == 2 }
        clock.release(1)
        try await clock.waitUntil { clock.completed.contains(1) }
        let replacement = try XCTUnwrap(host?.contentView as? WKWebView)
        XCTAssertFalse(original === replacement)
        XCTAssertFalse(original.configuration.websiteDataStore === replacement.configuration.websiteDataStore)
        XCTAssertFalse(replacement.configuration.websiteDataStore.isPersistent)
    }
}

@MainActor final class Feel04SkippedLoadTests: XCTestCase {
    func testBusySourceReplacementUnloadsTheRetiredDocument() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let server = try Feel04WaitingServer(body: "<title>Running preview</title><script>window.ticks=0;setInterval(()=>window.ticks++,20)</script>")
        let base = try await server.start(), clock = Feel04DebounceFixture()
        let blocker = try Feel04WaitingServer(hold: true), busyURL = try await blocker.start()
        let previews = Previews(debounceSleep: clock.sleep), first = Tab(isPrivate: true), busy = Tab(isPrivate: true)
        let enabled = Previews.enabled, mode = BatterySaver.shared.mode
        Previews.enabled = true; BatterySaver.shared.setMode(.off)
        var host: NSWindow?
        defer {
            previews.cancel(); clock.finish(); first.tearDown(); busy.tearDown(); server.stop(); blocker.stop()
            host?.contentView = nil; host?.close()
            Previews.enabled = enabled; BatterySaver.shared.setMode(mode)
        }
        previews.request(base.appendingPathComponent("first"), from: first)
        try await clock.waitUntil { clock.count == 1 }
        clock.release(0)
        try await clock.waitUntil {
            host = NSApp.windows.first { ($0.contentView as? WKWebView)?.url?.port == base.port }
            return (host?.contentView as? WKWebView)?.title == "Running preview"
                && (host?.contentView as? WKWebView)?.isLoading == false
        }
        let web = try XCTUnwrap(host?.contentView as? WKWebView)
        let source = busy.web
        previews.request(base.appendingPathComponent("skipped"), from: busy)
        try await clock.waitUntil { clock.count == 2 }
        // The owned server withholds its response until cleanup, keeping active browsing
        // busy without racing a timer against document completion.
        source.load(URLRequest(url: busyURL))
        XCTAssertTrue(source.isLoading)
        clock.release(1)
        try await clock.waitUntil { clock.completed.contains(1) }
        XCTAssertEqual(previews.current?.loading, false)
        let deadline = ContinuousClock.now + .seconds(5)
        while (web.url?.absoluteString != "about:blank" || web.isLoading), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(web.url?.absoluteString, "about:blank", "The skipped replacement must unload its predecessor")
        guard web.url?.absoluteString == "about:blank", !web.isLoading else { return }
        let timerType = try await web.evaluateJavaScript("typeof window.ticks") as? String
        XCTAssertEqual(timerType, "undefined", "Skipping the new load must still retire the previous document")
    }
}

@MainActor private final class Feel04CookieSetupObserver: NSObject, WKHTTPCookieStoreObserver {
    private(set) var changes = 0
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in self?.changes += 1 }
    }
}

@MainActor final class Feel04CookieRendererTests: XCTestCase {
    func testDestinationCookieDoesNotCancelPreviewButProfileCookieChangeDoes() async throws {
        try await checkSession(observerEnabled: true)
    }

    func testSourceSessionCheckRetiresPreviewWhenCookieCallbacksAreUnavailable() async throws {
        try await checkSession(observerEnabled: false)
    }

    func testCachedPixelsRevalidateAfterAnUnobservedInactiveSessionChange() async throws {
        try await checkSession(observerEnabled: false, inactiveChange: true)
    }

    func testCachedPixelsRejectSameSitePolicyChangesWithoutCookieCallbacks() async throws {
        try await checkSession(observerEnabled: false, inactiveChange: true, policyChange: true)
    }

    private func checkSession(observerEnabled: Bool, inactiveChange: Bool = false,
                              policyChange: Bool = false) async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let server = try Feel04WaitingServer(body: "<title>Cookie preview</title><body style='margin:0'><div style='height:240px;background:#1976d2'>Preview</div><div style='height:240px;background:#e53935'></div><div style='height:240px;background:#43a047'></div></body>", cookie: true)
        let url = try await server.start(), clock = Feel04DebounceFixture()
        let previews = Previews(sessionObserverFactory: { profile, changed in
            observerEnabled ? Feel04PreviewSessionObserver(profileID: profile, changed: changed) : nil
        }, debounceSleep: clock.sleep), tab = Tab(profileID: UUID())
        let enabled = Previews.enabled, mode = BatterySaver.shared.mode
        Previews.enabled = true; BatterySaver.shared.setMode(.off)
        // A page-originated preview always has a live persistent source WebView.
        // Keep that persistent context alive, and exercise a page-originated logout
        // rather than relying on observation of native edits to an otherwise unused store.
        let sourceServer = try Feel04WaitingServer(body: "<title>Source page</title>")
        var host: NSWindow?
        defer {
            previews.cancel(); clock.finish(); tab.tearDown(); server.stop(); sourceServer.stop()
            host?.contentView = nil; host?.close()
            Previews.enabled = enabled; BatterySaver.shared.setMode(mode)
        }
        let sourceURL = try await sourceServer.start(), source = tab.web
        source.load(URLRequest(url: sourceURL))
        let sourceDeadline = ContinuousClock.now + .seconds(8)
        while source.isLoading || source.title != "Source page" {
            guard ContinuousClock.now < sourceDeadline else { return XCTFail("Source page did not load") }
            try await Task.sleep(for: .milliseconds(20))
        }
        let cookies = source.configuration.websiteDataStore.httpCookieStore
        var properties: [HTTPCookiePropertyKey: Any] = [.domain: "127.0.0.1", .path: "/", .name: "source", .value: "signed-in"]
        if policyChange { properties[.sameSitePolicy] = "Strict" }
        let cookie = try XCTUnwrap(HTTPCookie(properties: properties))
        let setupObserver = Feel04CookieSetupObserver()
        cookies.add(setupObserver)
        defer { cookies.remove(setupObserver) }
        await cookies.setCookie(cookie)
        // setCookie's completion and its observer delivery are separate WebKit events.
        // Drain this deliberate setup mutation before attaching the production observer;
        // a late setup notification is not the logout under test.
        let setupDeadline = ContinuousClock.now + .seconds(8)
        while setupObserver.changes == 0 {
            guard ContinuousClock.now < setupDeadline else { return XCTFail("Initial source cookie change was not observed") }
            try await Task.sleep(for: .milliseconds(20))
        }
        // Keep the source subscription alive across the production observer's handoff.
        // The unique profile also excludes cookie-store teardown from earlier fixtures.
        let beforeRequest = setupObserver.changes
        previews.request(url, from: tab)
        try await clock.waitUntil { clock.count == 1 }; clock.release(0)
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            host = NSApp.windows.first { ($0.contentView as? WKWebView)?.url?.port == url.port } ?? host
            if previews.current?.title == "Cookie preview", previews.current?.image != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(previews.current?.title, "Cookie preview")
        XCTAssertNotNil(previews.current?.image)
        let web = try XCTUnwrap(host?.contentView as? WKWebView)
        let pageCookies = try await web.evaluateJavaScript("document.cookie") as? String
        XCTAssertTrue(pageCookies?.contains("source=signed-in") == true)
        XCTAssertTrue(pageCookies?.contains("feel04=preview") == true)
        let persisted = await cookies.allCookies()
        XCTAssertFalse(persisted.contains { $0.name == "feel04" }, "Speculative destination writes must stay in the renderer")
        if inactiveChange { previews.cancel() }
        if policyChange {
            properties[.sameSitePolicy] = "Lax"
            await cookies.setCookie(try XCTUnwrap(HTTPCookie(properties: properties)))
        } else {
            _ = try await source.evaluateJavaScript("document.cookie = 'source=; Max-Age=0; Path=/'")
        }
        let sourceCookies = await cookies.allCookies()
        if policyChange {
            let replaced = try XCTUnwrap(sourceCookies.first { $0.name == "source" })
            XCTAssertEqual(replaced.value, "signed-in")
            XCTAssertEqual(replaced.sameSitePolicy?.rawValue.lowercased(), "lax")
        } else {
            XCTAssertFalse(sourceCookies.contains { $0.name == "source" }, "Verify the source mutation before awaiting its observation")
        }
        if inactiveChange {
            previews.request(url, from: tab)
            XCTAssertNil(previews.current?.image, "Unvalidated cached pixels must never be promoted")
            let gateDeadline = ContinuousClock.now + .seconds(5)
            while clock.count < 2, previews.current?.image == nil, ContinuousClock.now < gateDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNil(previews.current?.image, "Changed session policy must not promote the old pixels")
            XCTAssertEqual(clock.count, 2, "A changed session must reach a fresh load gate")
            guard clock.count == 2 else { return }
            clock.release(1)
            let reloadDeadline = ContinuousClock.now + .seconds(8)
            while ContinuousClock.now < reloadDeadline {
                if let replacement = host?.contentView as? WKWebView,
                   replacement.title == "Cookie preview", !replacement.isLoading,
                   previews.current?.image != nil {
                    let copied = try await replacement.evaluateJavaScript("document.cookie") as? String
                    XCTAssertEqual(copied?.contains("source=signed-in") == true, policyChange)
                    XCTAssertFalse(replacement === web, "A changed source session must discard the old renderer")
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            return XCTFail("The revalidated preview did not reload")
        }
        let invalidationDeadline = ContinuousClock.now + .seconds(5)
        while previews.current != nil, ContinuousClock.now < invalidationDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        print("FEEL04_COOKIE_OBSERVATION profile=\(tab.profileID) sourceStoreMatches=\(source.configuration.websiteDataStore === ProfileManager.dataStore(for: tab.profileID)) setup=\(beforeRequest) afterLogout=\(setupObserver.changes) private=\(tab.isPrivate)")
        // Observer delivery is diagnostic; the application must retire pixels even
        // when WebKit omits that event. The final assertion is the consumer contract.
        XCTAssertNil(previews.current, "A real source-session change must retire authenticated pixels")
    }
}
