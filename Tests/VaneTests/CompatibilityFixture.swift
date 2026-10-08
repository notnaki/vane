import AppKit
import Network
import WebKit
import XCTest
@testable import vane

/// Loopback HTTP with complete request-body collection, including binary multipart data.
@MainActor final class CompatibilityServer {
    let listener: NWListener
    var port: UInt16?
    var connections: [NWConnection] = []
    var submissions: [Data] = []
    var pages: [String: String] = [:]
    var redirects: [String: URL] = [:]

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .ready = state { self?.port = self?.listener.port?.rawValue }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: .main)
                self.receive(connection, bytes: Data())
            }
        }
        listener.start(queue: .main)
    }

    func url(_ path: String, host: String = "127.0.0.1") throws -> URL {
        URL(string: "http://\(host):\(try XCTUnwrap(port))\(path)")!
    }

    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var accumulated = bytes
                if let data { accumulated.append(data) }
                guard let separator = accumulated.range(of: Data("\r\n\r\n".utf8)) else {
                    if !done && error == nil { self.receive(connection, bytes: accumulated) }
                    else { connection.cancel() }
                    return
                }
                let header = String(decoding: accumulated[..<separator.lowerBound], as: UTF8.self)
                let length = header.components(separatedBy: "\r\n").first {
                    $0.lowercased().hasPrefix("content-length:")
                }.flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = Data(accumulated[separator.upperBound...])
                if body.count < length {
                    if !done && error == nil { self.receive(connection, bytes: accumulated) }
                    else { connection.cancel() }
                    return
                }
                let path = header.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let responseBody: String
                if header.hasPrefix("POST ") {
                    self.submissions.append(body)
                    responseBody = "<title>Upload received</title><p>\(body.count) bytes</p>"
                } else { responseBody = self.pages[path] ?? "<title>Page \(path)</title><p>\(path)</p>" }
                let destination = self.redirects[path]
                let status = destination == nil ? "200 OK" : "302 Found"
                let location = destination.map { "Location: \($0.absoluteString)\r\n" } ?? ""
                let response = "HTTP/1.1 \(status)\r\n\(location)Content-Type: text/html; charset=utf-8\r\nContent-Length: \(responseBody.utf8.count)\r\nConnection: close\r\n\r\n" + responseBody
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    func stop() { listener.cancel(); connections.forEach { $0.cancel() } }
}

@MainActor func compatibilityWait(file: StaticString = #filePath, line: UInt = #line,
                                  _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while try await !condition() {
        if ContinuousClock.now >= deadline {
            XCTFail("Compatibility fixture timed out", file: file, line: line)
            throw NSError(domain: "CompatibilityTimeout", code: 1)
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}
