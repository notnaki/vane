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
    }
}

/// Answers every request with a page that reports the User-Agent header it was sent.
private final class UserAgentEchoServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "vane-ua-echo")
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [queue] connection in
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
                let header = request.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("user-agent:") }
                    .map { String($0.dropFirst("user-agent:".count)).trimmingCharacters(in: .whitespaces) } ?? ""
                let json = String(decoding: try! JSONEncoder().encode(header), as: UTF8.self)
                let body = """
                <script>
                const d = navigator.userAgentData;
                (d ? d.getHighEntropyValues(['uaFullVersion', 'architecture']) : Promise.resolve({})).then(h => {
                  window.result = {header: \(json), ua: navigator.userAgent, vendor: navigator.vendor,
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
