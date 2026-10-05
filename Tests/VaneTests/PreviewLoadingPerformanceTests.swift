import AppKit
import Network
import XCTest
@testable import vane

private final class PreviewServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "vane-preview-load-fixture")
    private let lock = NSLock()
    private var hits = 0
    var requests: Int { lock.withLock { hits } }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
                if data?.isEmpty == false {
                    self?.lock.withLock { self?.hits += 1 }
                    let body = "<html><body><h1>A preview</h1><p>Preview content</p></body></html>"
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
