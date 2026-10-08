import Foundation
import Network
import XCTest
@testable import vane

@MainActor private final class ReadingImageServer {
    let listener: NWListener
    var port: UInt16?
    var connections: [NWConnection] = []
    var requests: [String] = []
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in Task { @MainActor in
            if case .ready = state { self?.port = self?.listener.port?.rawValue }
        } }
        listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection); connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in Task { @MainActor in
                guard let self, let data else { connection.cancel(); return }
                let header = String(decoding: data, as: UTF8.self)
                self.requests.append(header)
                let path = header.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let response: Data
                var stall = false
                if path == "/large" {
                    response = Data("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n".utf8) + Data(repeating: 7, count: ReadingArticleCodec.imageLimit + 1)
                } else if path == "/stall" {
                    response = Data("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nx".utf8); stall = true
                } else if path == "/loop" {
                    response = Data("HTTP/1.1 302 Found\r\nLocation: /loop\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                } else {
                    response = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8)
                }
                let keepOpen = stall
                connection.send(content: response, completion: .contentProcessed { _ in if !keepOpen { connection.cancel() } })
            } }
        } }
        listener.start(queue: .main)
    }
    func url(_ path: String) throws -> URL { URL(string: "http://127.0.0.1:\(try XCTUnwrap(port))\(path)")! }
    func stop() { listener.cancel(); connections.forEach { $0.cancel() } }
}

@MainActor final class ReadingQueueNetworkTests: XCTestCase {
    func testHeaderlessOversizedResponseIsBoundedAndRedirectLoopStops() async throws {
        let server = try ReadingImageServer(); defer { server.stop() }
        try await compatibilityWait { server.port != nil }
        do { _ = try await ReadingQueueImages.download(server.url("/large")); XCTFail("Oversized stream accepted") }
        catch ReadingQueueFailure.tooLarge {}
        do { _ = try await ReadingQueueImages.download(server.url("/loop")); XCTFail("Redirect loop accepted") }
        catch {}
        XCTAssertEqual(server.requests.filter { $0.hasPrefix("GET /loop ") }.count, 6)
        XCTAssertFalse(server.requests.contains { $0.lowercased().contains("\r\ncookie:") || $0.lowercased().contains("\r\nauthorization:") })
    }
    func testStalledResponseTimesOutAndCancellationFinishesPromptly() async throws {
        let server = try ReadingImageServer(); defer { server.stop() }
        try await compatibilityWait { server.port != nil }
        let start = ContinuousClock.now
        do { _ = try await ReadingQueueImages.download(server.url("/stall"), timeout: 0.2); XCTFail("Stalled download completed") }
        catch {}
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        let url = try server.url("/stall")
        let pending = Task { try await ReadingQueueImages.download(url, timeout: 10) }
        try await compatibilityWait { server.requests.filter { $0.hasPrefix("GET /stall ") }.count == 2 }
        let cancelStart = ContinuousClock.now
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled download completed") } catch {}
        XCTAssertLessThan(cancelStart.duration(to: .now), .seconds(2))
    }
}
