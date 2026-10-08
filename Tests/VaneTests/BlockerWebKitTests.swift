import AppKit
import Network
import WebKit
import XCTest
@testable import vane

@MainActor final class BlockerWebKitTests: XCTestCase {
    func testExactSiteExceptionAllowsBlockedRequestsAndCosmeticsOnlyOnThatHost() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let server = try BlockerFixtureServer()
        let base = try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: directory))
        let source = "|\(base.absoluteString)/ad.js|\n##.ad"
        for (host, excepted, expectedLoaded) in [("127.0.0.1", false, false), ("127.0.0.1", true, true), ("localhost", true, false)] {
            let conversion = Blocker.convert(source, excludingHosts: excepted ? ["127.0.0.1"] : [])
            let compiled = try await store.compileContentRuleList(forIdentifier: UUID().uuidString, encodedContentRuleList: conversion.json)
            let rules = try XCTUnwrap(compiled)
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(rules)
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: configuration)
            let delegate = BlockerNavigationFixture()
            web.navigationDelegate = delegate
            let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = web
            defer { web.stopLoading(); web.navigationDelegate = nil; window.close() }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            components.host = host
            web.load(URLRequest(url: components.url!))
            let deadline = Date().addingTimeInterval(10)
            while !delegate.finished, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(delegate.finished)
            let result = try await web.evaluateJavaScript("[window.adLoaded === true, getComputedStyle(document.querySelector('.ad')).display !== 'none']") as? [Bool]
            XCTAssertEqual(result, [expectedLoaded, expectedLoaded], "Host \(host), exception \(excepted)")
            try await store.removeContentRuleList(forIdentifier: rules.identifier)
        }
    }
}

@MainActor private final class BlockerNavigationFixture: NSObject, WKNavigationDelegate {
    var finished = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
}

private final class BlockerFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "vane-blocker-fixture")
    private var base: String = ""
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let script = request.hasPrefix("GET /ad.js ")
                let body = script ? "window.adLoaded = true;" : "<html><body><div class='ad'>Ad</div><script src='\(self.base)/ad.js'></script></body></html>"
                let type = script ? "application/javascript" : "text/html"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self, let port = self.listener.port else { return }
                    self.base = "http://127.0.0.1:\(port.rawValue)"
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: self.base)!)
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }
}
