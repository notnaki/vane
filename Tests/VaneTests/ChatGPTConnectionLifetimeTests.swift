import Darwin
import Network
import XCTest
@testable import vane

// Real loopback sockets exercise receive EOF, oversize rejection, and idle deadlines,
// without running OAuth or opening a browser. Client reads have an independent bound.
private func loopbackRequest(port: UInt16, data: Data, eof: Bool = true) throws -> Data {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { Darwin.close(fd) }
    var deadline = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout.size(ofValue: deadline)))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
    var noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
    try data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
            guard count > 0 else { throw POSIXError(.EIO) }
            offset += count
        }
    }
    if eof { shutdown(fd, SHUT_WR) }
    var response = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = Darwin.recv(fd, &buffer, buffer.count, 0)
        if count == 0 || (count < 0 && errno == ECONNRESET) { return response }
        guard count > 0 else { throw POSIXError(.ETIMEDOUT) }
        response.append(contentsOf: buffer.prefix(count))
    }
}

@MainActor final class ChatGPTConnectionLifetimeTests: XCTestCase {
    func testTerminalReceivePathsReleaseAllEightSlotsForNextRequest() async throws {
        let server = ChatGPTSignIn()
        defer { server.cancel() }
        let port = try await server.start()
        for index in 0..<8 {
            let payload = index.isMultiple(of: 2) ? Data("GET /partial".utf8) : Data(repeating: 65, count: 32768)
            _ = try await Task.detached { try loopbackRequest(port: port, data: payload) }.value
        }
        XCTAssertTrue(server.connections.isEmpty, "EOF and oversized requests must free their slots")
        let response = try await Task.detached { try loopbackRequest(port: port, data: Data("GET /unrelated HTTP/1.1\r\n\r\n".utf8)) }.value
        XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 400"), "The real callback must still be able to connect")
    }

    func testIdleConnectionsExpireBeforeAttemptTimeout() async throws {
        let server = ChatGPTSignIn(readTimeout: .milliseconds(50))
        defer { server.cancel() }
        let port = try await server.start()
        let started = ContinuousClock.now
        _ = try await Task.detached { try loopbackRequest(port: port, data: Data(), eof: false) }.value
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        XCTAssertTrue(server.connections.isEmpty)
    }
}
