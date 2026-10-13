import AppKit
import Network
import WebKit
import XCTest
@testable import vane

/// Owns a loopback port without serving a document. The fixture tests store replacement,
/// so no remote site, screenshot timing, or completed navigation is needed.
private final class Feel04WaitingServer: @unchecked Sendable {
    let listener: NWListener
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.newConnectionHandler = { connection in connection.cancel() }
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
    func stop() { listener.cancel() }
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
