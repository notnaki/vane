import AppKit
import Network
import WebKit
import XCTest
@testable import vane

/// Loopback HTTP with complete request-body collection, including binary multipart data.
@MainActor final class NavigationHTTPFixture {
    let listener: NWListener
    var port: UInt16?
    var connections: [NWConnection] = []
    var submissions: [Data] = []
    var pages: [String: String] = [:]
    var redirects: [String: URL] = [:]
    var requests: [String] = []
    var heldPaths: Set<String> = []
    var interruptedPaths: Set<String> = []
    var attachmentPaths: Set<String> = []
    var authPaths: Set<String> = []
    var contentTypes: [String: String] = [:]
    var responseHeaders: [String: [String: String]] = [:]
    private(set) var connectionCallbacks = 0
    private(set) var listenerCancelled = false
    private var stopped = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    if !self.stopped { self.port = self.listener.port?.rawValue }
                case .cancelled: self.listenerCancelled = true
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                self.connectionCallbacks += 1
                guard !self.stopped else { connection.cancel(); return }
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
                guard let self, !self.stopped else { connection.cancel(); return }
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
                self.requests.append(header)
                while self.heldPaths.contains(path) {
                    try? await Task.sleep(for: .milliseconds(10))
                    guard self.connections.contains(where: { $0 === connection }) else { return }
                }
                let responseBody: String
                if header.hasPrefix("POST ") {
                    self.submissions.append(body)
                    responseBody = "<title>Upload received</title><p>\(body.count) bytes</p>"
                } else { responseBody = self.pages[path] ?? "<title>Page \(path)</title><p>\(path)</p>" }
                let destination = self.redirects[path]
                let status = self.authPaths.contains(path) ? "401 Unauthorized" : (destination == nil ? "200 OK" : "302 Found")
                let extras = (self.authPaths.contains(path) ? "WWW-Authenticate: Basic realm=\"Navigation fixture\"\r\n" : "")
                    + (self.attachmentPaths.contains(path) ? "Content-Disposition: attachment; filename=fixture.txt\r\n" : "")
                let customHeaders = (self.responseHeaders[path] ?? [:]).sorted { $0.key < $1.key }
                    .map { "\($0.key): \($0.value)\r\n" }.joined()
                let contentType = self.contentTypes[path] ?? "text/html; charset=utf-8"
                let responseLength = responseBody.utf8.count + (self.interruptedPaths.contains(path) ? 10000 : 0)
                let location = destination.map { "Location: \($0.absoluteString)\r\n" } ?? ""
                let response = "HTTP/1.1 \(status)\r\n\(location)\(extras)\(customHeaders)Content-Type: \(contentType)\r\nContent-Length: \(responseLength)\r\nConnection: close\r\n\r\n" + responseBody
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        // Revoke queued actor work before asking Network to cancel asynchronously.
        stopped = true
        listener.cancel()
        connections.forEach { $0.cancel() }
        connections = []
        heldPaths = []
    }
}
