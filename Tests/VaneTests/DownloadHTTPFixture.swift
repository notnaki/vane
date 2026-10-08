import Foundation
import Network
import XCTest

/// Deterministic binary responses; pause gates and explicit disconnects avoid timing guesses.
@MainActor final class DownloadHTTPFixture {
    let listener: NWListener
    var port: UInt16?
    var connections: [NWConnection] = []
    var requests: [String] = []
    var supportsRanges = true
    var offersValidators = true
    var rejectRanges = false
    var disconnectAfter: Int?
    var held = false
    var holdAllBytes = false
    var holdHeaders = false
    var version = 1
    var variantCount = 262144
    var encodedBody: Data?
    var omitLength = false
    let bytes = Data((0..<262144).map { UInt8($0 % 251) })
    var body: Data { encodedBody ?? (version == 1 ? bytes : Data(repeating: 0xA7, count: variantCount)) }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
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
                self.receive(connection, data: Data())
            }
        }
        listener.start(queue: .main)
    }

    func url(_ path: String = "/file") throws -> URL {
        URL(string: "http://127.0.0.1:\(try XCTUnwrap(port))\(path)")!
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, done, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var data = data
                if let chunk { data.append(chunk) }
                guard data.range(of: Data("\r\n\r\n".utf8)) != nil else {
                    if !done && error == nil { self.receive(connection, data: data) }
                    else { connection.cancel() }
                    return
                }
                let request = String(decoding: data, as: UTF8.self)
                self.requests.append(request)
                while self.holdHeaders && self.connections.contains(where: { $0 === connection }) {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                if request.hasPrefix("GET /page ") {
                    let page = "<title>Download Cookie Fixture</title>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n" + page
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                if request.hasPrefix("GET /redirect ") {
                    connection.send(content: Data("HTTP/1.1 302 Found\r\nLocation: /file\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                        completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                let range = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range:") }
                let validator = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("if-range:") }
                if range != nil && self.rejectRanges {
                    connection.send(content: Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(self.body.count)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                        completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                let offset = range.flatMap { $0.components(separatedBy: "bytes=").last?.split(separator: "-").first }.flatMap { Int($0) } ?? 0
                let ranged = range != nil && self.supportsRanges && (validator == nil || validator!.contains("v\(self.version)"))
                let start = ranged ? min(offset, self.body.count) : 0
                let payload = self.body.subdata(in: start..<self.body.count)
                let contentRange = ranged ? "Content-Range: bytes \(start)-\(self.body.count - 1)/\(self.body.count)\r\n" : ""
                let header = "HTTP/1.1 \(ranged ? "206 Partial Content" : "200 OK")\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=fixture.bin\r\n\(self.omitLength ? "" : "Content-Length: \(payload.count)\r\n")\(self.encodedBody != nil ? "Content-Encoding: gzip\r\n" : "")\(self.offersValidators ? "ETag: \"v\(self.version)\"\r\nLast-Modified: Wed, 07 Oct 2026 10:00:00 GMT\r\n" : "")\(self.supportsRanges ? "Accept-Ranges: bytes\r\n" : "")\(contentRange)Connection: close\r\n\r\n"
                connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
                    Task { @MainActor in
                        guard error == nil else { connection.cancel(); return }
                        self?.send(connection, payload: payload, offset: 0)
                    }
                })
            }
        }
    }

    private func send(_ connection: NWConnection, payload: Data, offset: Int) {
        if let limit = disconnectAfter, offset >= limit { connection.cancel(); return }
        if offset >= payload.count { connection.cancel(); return }
        if (held && offset >= 16384) || holdAllBytes {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(20))
                guard let self, self.connections.contains(where: { $0 === connection }) else { return }
                self.send(connection, payload: payload, offset: offset)
            }
            return
        }
        let end = min(offset + 16384, payload.count)
        connection.send(content: payload.subdata(in: offset..<end), completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard error == nil else { connection.cancel(); return }
                try? await Task.sleep(for: .milliseconds(10))
                self?.send(connection, payload: payload, offset: end)
            }
        })
    }

    func stop() { listener.cancel(); connections.forEach { $0.cancel() }; connections = [] }
}
