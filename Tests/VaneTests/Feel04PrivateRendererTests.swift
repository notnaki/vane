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
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    init(body: String? = nil, hold: Bool = false) throws {
        self.body = body; self.hold = hold
        listener = try NWListener(using: .tcp, on: .any)
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let body = body
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
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
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
