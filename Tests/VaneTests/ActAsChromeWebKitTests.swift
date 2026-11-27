import AppKit
import Network
import WebKit
import XCTest
@testable import vane

/// The request header and the page's navigator must tell the same story, on the switched
/// site only, and the switch's reload must already go out as Chrome.
@MainActor final class ActAsChromeWebKitTests: XCTestCase {
    func testSiteSwitchMatchesHeaderAndNavigatorAndStaysOnItsHost() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let saved = UserDefaults.vane.object(forKey: "userAgent")
        UserDefaults.vane.removeObject(forKey: "userAgent")
        defer { UserDefaults.vane.set(saved, forKey: "userAgent") }
        let server = try UserAgentEchoServer()
        let port = try await server.start()
        defer { server.stop() }
        let tab = Tab(isPrivate: true)
        defer {
            ActAsChrome.set("127.0.0.1", on: false, profileID: tab.profileID, isPrivate: true)
            tab.web.stopLoading(); tab.tearDown()
        }

        func page() async throws -> [String: String] {
            let deadline = Date.now.addingTimeInterval(10)
            while Date.now < deadline {
                if let r = try? await tab.web.evaluateJavaScript("window.result") as? [String: String] { return r }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NSError(domain: "ActAsChromeWebKitTests", code: 1)
        }

        tab.navigate(to: URL(string: "http://127.0.0.1:\(port)/")!)
        var r = try await page()
        XCTAssertEqual(r["header"], safariUA, "off by default")
        XCTAssertEqual(r["vendor"], "Apple Computer, Inc.")

        _ = try await tab.web.evaluateJavaScript("window.result = undefined; 0")
        ActAsChrome.toggle(tab)
        r = try await page()
        XCTAssertEqual(r["header"], ActAsChrome.chromeUA, "the switch's reload goes out as Chrome")
        XCTAssertEqual(r["ua"], ActAsChrome.chromeUA)
        XCTAssertEqual(r["vendor"], "Google Inc.")
        XCTAssertEqual(r["brands"], "Not)A;Brand,Chromium,Google Chrome")
        XCTAssertEqual(r["platform"], "macOS")
        let version = ActAsChrome.chromeUA.firstMatch(of: /Chrome\/([\d.]+)/).map { String($0.1) }
        XCTAssertEqual(r["high"], version)
        XCTAssertEqual(r["arch"], ActAsChrome.architecture)

        // Another host: back to the default identity, header and navigator alike.
        _ = try await tab.web.evaluateJavaScript("window.result = undefined; 0")
        tab.navigate(to: URL(string: "http://localhost:\(port)/")!)
        r = try await page()
        XCTAssertEqual(r["header"], safariUA, "leaving the site restores the normal UA")
        XCTAssertEqual(r["ua"], safariUA)
        XCTAssertEqual(r["vendor"], "Apple Computer, Inc.")
        XCTAssertEqual(r["brands"], "none")

        // A server redirect carries the first request's header; the policy re-loads it so
        // header and navigator still agree on the destination's identity.
        func redirect(from: String, to: String) async throws -> [String: String] {
            _ = try await tab.web.evaluateJavaScript("window.result = undefined; 0")
            tab.navigate(to: URL(string: "http://\(from):\(port)/go?http://\(to):\(port)/")!)
            return try await page()
        }
        r = try await redirect(from: "localhost", to: "127.0.0.1")
        XCTAssertEqual(r["header"], ActAsChrome.chromeUA, "a 302 into the switched host goes out as Chrome")
        XCTAssertEqual(r["ua"], ActAsChrome.chromeUA)
        XCTAssertEqual(r["vendor"], "Google Inc.")
        r = try await redirect(from: "127.0.0.1", to: "localhost")
        XCTAssertEqual(r["header"], safariUA, "a 302 out of the switched host goes back to Safari")
        XCTAssertEqual(r["ua"], safariUA)
        XCTAssertEqual(r["vendor"], "Apple Computer, Inc.")

        // A page's own link click is never replayed as a fresh load: the referrer and the
        // history entry survive, and the navigator matches the destination either way.
        func click(to host: String) async throws -> [String: String] {
            let before = Int(try await page()["hist"] ?? "") ?? 0
            _ = try await tab.web.evaluateJavaScript("""
                window.result = undefined; const a = document.createElement('a');
                a.href = 'http://\(host):\(port)/'; document.body.append(a); a.click(); 0
                """)
            let r = try await page()
            XCTAssertEqual(Int(r["hist"] ?? ""), before + 1, "a click to \(host) adds one history entry")
            XCTAssertFalse(r["referer"]?.isEmpty ?? true, "a click to \(host) keeps its referrer, so it wasn't re-loaded")
            print("act as chrome: click to \(host) went out with \(r["header"] ?? "nil")")
            return r
        }
        r = try await click(to: "127.0.0.1")     // from localhost, which is off
        XCTAssertEqual(r["ua"], ActAsChrome.chromeUA)
        XCTAssertEqual(r["vendor"], "Google Inc.")
        r = try await click(to: "localhost")     // from 127.0.0.1, which is on
        XCTAssertEqual(r["ua"], safariUA)
        XCTAssertEqual(r["vendor"], "Apple Computer, Inc.")

        // Smoke check: a same-document Back (to a pushState entry) then a click off the
        // switched site still loads normally.
        _ = try await tab.web.evaluateJavaScript("window.result = undefined; 0")
        tab.navigate(to: URL(string: "http://127.0.0.1:\(port)/")!)
        _ = try await page()
        _ = try await tab.web.evaluateJavaScript("history.pushState(null, '', '/pushed'); 0")
        _ = tab.web.goBack()
        for _ in 0..<250 {
            if try await tab.web.evaluateJavaScript("location.pathname") as? String == "/" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        r = try await click(to: "localhost")
        XCTAssertEqual(r["ua"], safariUA)

        // A 302 loop across the boundary retries a few times, then WebKit's redirect limit
        // ends it instead of every retry starting a fresh 20 redirects.
        server.loopRequests = 0
        tab.navigate(to: URL(string: "http://localhost:\(port)/loop")!)
        var last = -1
        for _ in 0..<40 {      // until the server stops seeing requests
            try await Task.sleep(for: .milliseconds(250))
            if server.loopRequests == last, last > 0 { break }
            last = server.loopRequests
        }
        XCTAssertGreaterThan(server.loopRequests, 10, "the loop ran into WebKit's limit")
        // WebKit's 20-redirect chain plus one request per retry, one spare.
        XCTAssertLessThanOrEqual(server.loopRequests, 22 + ActAsChrome.maxRetries, "the loop ended")

        // A failed load on the switched host shows its error page and stays there: the
        // simulated error page is never re-issued as a real load.
        // A port closed synchronously refuses at once. A cancelled NWListener's cancel is
        // asynchronous: a connect that still finds its socket bound gets no answer and hangs
        // (about 8s before WebKit gives up), past the wait below.
        let closedPort = try Self.closedPort()
        var retries = 0
        var stages: [String] = []
        let began = Date.now
        tab.navigationStageObserver = {
            if $0.stage == "act-as-chrome-retry" { retries += 1 }
            stages.append(String(format: "%.2f ", Date.now.timeIntervalSince(began)) + "\($0.stage) \($0.detail)")
        }
        defer { tab.navigationStageObserver = nil }
        tab.navigate(to: URL(string: "http://127.0.0.1:\(closedPort)/")!)
        var shown = false
        var html: String?
        for _ in 0..<500 where !shown {      // until the error page is up
            try await Task.sleep(for: .milliseconds(20))
            html = try? await tab.web.evaluateJavaScript("document.documentElement.outerHTML") as? String
            shown = tab.web.url?.port == Int(closedPort) && html?.contains("location.reload") == true
        }
        // CI-only so far: say why, so the next failure names its cause.
        XCTAssertTrue(shown, """
            the error page loads; after \(String(format: "%.1f", Date.now.timeIntervalSince(began)))s \
            url=\(tab.web.url?.absoluteString ?? "nil") loading=\(tab.web.isLoading) \
            loopRequests=\(server.loopRequests) html=\(html.map { String($0.prefix(160)) } ?? "nil")
            stages:
            \(stages.joined(separator: "\n"))
            """)
        try await Task.sleep(for: .seconds(1))
        XCTAssertLessThanOrEqual(retries, ActAsChrome.maxRetries, "the error page is never re-issued")
    }

    private static func closedPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        close(fd)
        guard bound else { throw POSIXError(.EADDRNOTAVAIL) }
        return UInt16(bigEndian: address.sin_port)
    }
}

/// Answers every request with a page that reports the User-Agent header it was sent.
private final class UserAgentEchoServer: @unchecked Sendable {
    /// Requests to `/loop`, which 302s to the same path on the other loopback host.
    var loopRequests: Int { get { queue.sync { loops } } set { queue.sync { loops = newValue } } }
    private var loops = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "vane-ua-echo")
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [unowned self, queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                // `GET /go?<url>` answers 302 to <url>.
                let path = request.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? "/"
                if path.hasPrefix("/go?") {
                    let response = "HTTP/1.1 302 Found\r\nLocation: \(path.dropFirst(4))\r\nCache-Control: no-store\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                func field(_ name: String) -> String {
                    request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix(name + ":") }
                        .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) } ?? ""
                }
                if path == "/loop" {
                    self.loops += 1
                    let host = field("host"), other = host.hasPrefix("localhost") ? "127.0.0.1" : "localhost"
                    let port = host.split(separator: ":").last.map(String.init) ?? ""
                    let response = "HTTP/1.1 302 Found\r\nLocation: http://\(other):\(port)/loop\r\nCache-Control: no-store\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                let json = String(decoding: try! JSONEncoder().encode(field("user-agent")), as: UTF8.self)
                let referer = String(decoding: try! JSONEncoder().encode(field("referer")), as: UTF8.self)
                let body = """
                <script>
                const d = navigator.userAgentData;
                (d ? d.getHighEntropyValues(['uaFullVersion', 'architecture']) : Promise.resolve({})).then(h => {
                  window.result = {header: \(json), referer: \(referer), hist: String(history.length),
                    ua: navigator.userAgent, vendor: navigator.vendor,
                    brands: d ? d.brands.map(b => b.brand).join(',') : 'none', platform: d ? d.platform : 'none',
                    high: h.uaFullVersion || 'none', arch: h.architecture || 'none'};
                });
                </script>
                """
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self, let port = self.listener.port else { return }
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: port.rawValue)
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }
}
