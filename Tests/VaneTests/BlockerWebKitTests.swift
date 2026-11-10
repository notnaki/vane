import AppKit
import Network
import WebKit
import XCTest
@testable import vane

@MainActor final class BlockerWebKitTests: XCTestCase {
    func testCaseAndNarrowedResourceOptionsActuallyControlScriptLoading() async throws {
        WebKitPretargetDiagnostics.emit("blocker.prepare.begin")
        TestEnvironment.prepare()
        WebKitPretargetDiagnostics.emit("blocker.prepare.end app.begin")
        _ = NSApplication.shared
        WebKitPretargetDiagnostics.emit("blocker.app.end")
        let server = try BlockerFixtureServer()
        WebKitPretargetDiagnostics.emit("blocker.server.start.begin")
        let base = try await server.start()
        WebKitPretargetDiagnostics.emit("blocker.server.start.end")
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: directory))
        for (source, expectedLoaded) in [("/ad.js$match-case,script,image,~image", false),
                                          ("/Ad.js$match-case", true), ("/Ad.js", false),
                                          (#"/\/ad[a-z]*\.js$/$script"#, false),
                                          (#"/\/Ad[a-z]*\.js$/$script,match-case"#, true),
                                          (#"/\/ad[0-9]+\.js$/$script"#, true),
                                          (#"/^http:\/\/127\.0\.0\.1:[0-9]+\/ad\.js$/$script"#, false),
                                          (#"/\/a[d]?\.js$/$script"#, false),
                                          (#"/\/a[^x]+\.js$/$script"#, false),
                                          (#"/\/a[^d]+\.js$/$script"#, true),
                                          ("/ad.js$script\n/ad.js$script,badfilter", true),
                                          ("/ad.js$script\n/ad.js$image,badfilter", false),
                                          ("/ad.js$script\n@@/ad.js$script\n@@/ad.js$script,badfilter", false),
                                          ("/ad.js$script\n@@/ad.js$script,1p\n@@/ad.js$script,~third-party,badfilter", false),
                                          ("/ad.js$script\n@@/ad.js$script\n/ad.js$script,badfilter", true),
                                          ("/ad.js$script\n/ad.js$script,badfilter\n.js$script", false)] {
            WebKitPretargetDiagnostics.emit("blocker.variant.begin rule=\(source)")
            defer { WebKitPretargetDiagnostics.emit("blocker.variant.end") }
            let conversion = Blocker.convert(source + "\n||unused.invalid^")
            WebKitPretargetDiagnostics.emit("blocker.convert.end")
            XCTAssertGreaterThan(conversion.rules, 0)
            XCTAssertEqual(conversion.skipped, 0)
            WebKitPretargetDiagnostics.emit("blocker.compile.begin")
            let compiled = try await store.compileContentRuleList(
                forIdentifier: UUID().uuidString, encodedContentRuleList: conversion.json)
            WebKitPretargetDiagnostics.emit("blocker.compile.reply")
            let rules = try XCTUnwrap(compiled)
            WebKitPretargetDiagnostics.emit("blocker.config.begin")
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(rules)
            WebKitPretargetDiagnostics.emit("blocker.config.end web-init.begin")
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: configuration)
            WebKitPretargetDiagnostics.emit("blocker.web-init.end delegate.begin")
            let delegate = BlockerNavigationFixture()
            web.navigationDelegate = delegate
            WebKitPretargetDiagnostics.emit("blocker.delegate.end")
            defer {
                WebKitPretargetDiagnostics.emit("blocker.stop.begin")
                web.stopLoading()
                WebKitPretargetDiagnostics.emit("blocker.stop.end delegate-clear.begin")
                web.navigationDelegate = nil
                WebKitPretargetDiagnostics.emit("blocker.delegate-clear.end")
            }
            WebKitPretargetDiagnostics.emit("blocker.load.begin")
            web.load(URLRequest(url: base))
            WebKitPretargetDiagnostics.emit("blocker.load.end navigation-wait.begin")
            let deadline = Date().addingTimeInterval(10)
            while !delegate.finished, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            WebKitPretargetDiagnostics.emit("blocker.navigation-wait.end")
            XCTAssertTrue(delegate.finished, source)
            WebKitPretargetDiagnostics.emit("blocker.evaluate.begin")
            let loaded = try await web.evaluateJavaScript("window.adLoaded === true") as? Bool
            WebKitPretargetDiagnostics.emit("blocker.evaluate.reply")
            XCTAssertEqual(loaded, expectedLoaded, source)
            WebKitPretargetDiagnostics.emit("blocker.rule-remove.begin")
            try await store.removeContentRuleList(forIdentifier: rules.identifier)
            WebKitPretargetDiagnostics.emit("blocker.rule-remove.reply")
        }
    }

    func testExactSiteExceptionAllowsBlockedRequestsAndCosmeticsOnlyOnThatHost() async throws {
        WebKitPretargetDiagnostics.emit("blocker.prepare.begin")
        TestEnvironment.prepare()
        WebKitPretargetDiagnostics.emit("blocker.prepare.end app.begin")
        _ = NSApplication.shared
        WebKitPretargetDiagnostics.emit("blocker.app.end")
        let server = try BlockerFixtureServer()
        WebKitPretargetDiagnostics.emit("blocker.server.start.begin")
        let base = try await server.start()
        WebKitPretargetDiagnostics.emit("blocker.server.start.end")
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: directory))
        let source = "|\(base.absoluteString)/ad.js|\n##.ad"
        for (host, excepted, expectedLoaded) in [("127.0.0.1", false, false), ("127.0.0.1", true, true), ("localhost", true, false)] {
            WebKitPretargetDiagnostics.emit("blocker.exact.begin host=\(host) excepted=\(excepted)")
            defer { WebKitPretargetDiagnostics.emit("blocker.exact.end") }
            let conversion = Blocker.convert(source, excludingHosts: excepted ? ["127.0.0.1"] : [])
            WebKitPretargetDiagnostics.emit("blocker.compile.begin")
            let compiled = try await store.compileContentRuleList(forIdentifier: UUID().uuidString, encodedContentRuleList: conversion.json)
            WebKitPretargetDiagnostics.emit("blocker.compile.reply")
            let rules = try XCTUnwrap(compiled)
            WebKitPretargetDiagnostics.emit("blocker.config.begin")
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(rules)
            WebKitPretargetDiagnostics.emit("blocker.config.end web-init.begin")
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: configuration)
            WebKitPretargetDiagnostics.emit("blocker.web-init.end delegate.begin")
            let delegate = BlockerNavigationFixture()
            web.navigationDelegate = delegate
            WebKitPretargetDiagnostics.emit("blocker.delegate.end")
            WebKitPretargetDiagnostics.emit("blocker.window.begin")
            let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = web
            WebKitPretargetDiagnostics.emit("blocker.window.end")
            defer {
                WebKitPretargetDiagnostics.emit("blocker.stop.begin")
                web.stopLoading()
                WebKitPretargetDiagnostics.emit("blocker.stop.end delegate-clear.begin")
                web.navigationDelegate = nil
                WebKitPretargetDiagnostics.emit("blocker.delegate-clear.end window-close.begin")
                window.close()
                WebKitPretargetDiagnostics.emit("blocker.window-close.end")
            }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            components.host = host
            WebKitPretargetDiagnostics.emit("blocker.load.begin")
            web.load(URLRequest(url: components.url!))
            WebKitPretargetDiagnostics.emit("blocker.load.end navigation-wait.begin")
            let deadline = Date().addingTimeInterval(10)
            while !delegate.finished, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            WebKitPretargetDiagnostics.emit("blocker.navigation-wait.end")
            XCTAssertTrue(delegate.finished)
            WebKitPretargetDiagnostics.emit("blocker.evaluate.begin")
            let result = try await web.evaluateJavaScript("[window.adLoaded === true, getComputedStyle(document.querySelector('.ad')).display !== 'none']") as? [Bool]
            WebKitPretargetDiagnostics.emit("blocker.evaluate.reply")
            XCTAssertEqual(result, [expectedLoaded, expectedLoaded], "Host \(host), exception \(excepted)")
            WebKitPretargetDiagnostics.emit("blocker.rule-remove.begin")
            try await store.removeContentRuleList(forIdentifier: rules.identifier)
            WebKitPretargetDiagnostics.emit("blocker.rule-remove.reply")
        }
    }
}

@MainActor private final class BlockerNavigationFixture: NSObject, WKNavigationDelegate {
    var finished = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        WebKitPretargetDiagnostics.emit("blocker.navigation.didFinish")
        finished = true
    }
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

extension BlockerWebKitTests {
    func testLinkedSettingsOperationsPublishPersistedSnapshotsIntoActualWebKitLoads() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let defaults = UserDefaults.vane
        let saved = defaults.object(forKey: LocalFilterSources.snapshotsKey)
        func restore() {
            if let saved { defaults.set(saved, forKey: LocalFilterSources.snapshotsKey) }
            else { defaults.removeObject(forKey: LocalFilterSources.snapshotsKey) }
        }
        defer { restore() }
        defaults.removeObject(forKey: LocalFilterSources.snapshotsKey)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("filters.txt")
        try Data("/ad.js$script".utf8).write(to: file)
        let manager = LocalFilterSources(defaults: defaults, directory: root.appendingPathComponent("grants"),
            transaction: { try await Blocker.commitLinkedSources($0) })
        try await manager.link(file)
        let id = manager.items[0].id
        let server = try BlockerFixtureServer()
        let base = try await server.start()
        defer { server.stop() }
        for operation in 0..<4 {
            if operation == 1 {
                // An atomic source replacement must reach the installed WebKit list.
                try Data("/different.js$script".utf8).write(to: file, options: .atomic)
                await manager.refresh(id)
            } else if operation == 2 {
                try Data("/ad.js$script".utf8).write(to: file, options: .atomic)
                await manager.refresh(id)
                await manager.setEnabled(id, enabled: false)
            } else if operation == 3 { await manager.remove(id) }
            await withCheckedContinuation { continuation in Blocker.refresh(completion: { continuation.resume() }) }
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            Blocker.apply(to: config)
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: config)
            let navigation = BlockerNavigationFixture()
            web.navigationDelegate = navigation
            web.load(URLRequest(url: base))
            let deadline = Date().addingTimeInterval(10)
            while !navigation.finished, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(navigation.finished)
            let loaded = try await web.evaluateJavaScript("window.adLoaded === true") as? Bool
            XCTAssertEqual(loaded, operation != 0, "Linked operation \(operation)")
            web.stopLoading(); web.navigationDelegate = nil
        }
        XCTAssertTrue(manager.items.isEmpty)
        restore()
        await withCheckedContinuation { continuation in Blocker.refresh(completion: { continuation.resume() }) }
    }
}
