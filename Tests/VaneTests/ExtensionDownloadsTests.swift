import AppKit
import WebKit
import XCTest
@testable import vane

/// What an extension may name and how Vane's rows read to it: no WebKit, no window.
@MainActor final class ExtensionDownloadsAPITests: XCTestCase {
    func testFilenamesStayInsideTheDownloadFolder() {
        XCTAssertEqual(ExtensionDownloadsAPI.relativePath("report.pdf"), ["report.pdf"])
        XCTAssertEqual(ExtensionDownloadsAPI.relativePath("Reports/2026/q3.csv"), ["Reports", "2026", "q3.csv"])
        XCTAssertEqual(ExtensionDownloadsAPI.relativePath(".hidden"), [".hidden"])
        for refused in ["", "/etc/hosts", "../escape.txt", "a/../../escape.txt", "./a.txt", "a/./b.txt", "a//b.txt", "a/",
                        "~/escape.txt", "back\\slash.txt", "colon:name.txt", "star*.txt", "line\nbreak.txt", "nul\0.txt",
                        "trailing.", "trailing ", " leading", "invoice\u{202E}fdp.exe", String(repeating: "a", count: 256)] {
            XCTAssertNil(ExtensionDownloadsAPI.relativePath(refused), refused.debugDescription)
        }
    }

    func testRowsReadAsChromesStates() {
        XCTAssertTrue(ExtensionDownloadsAPI.state(.running, reason: "") == ("in_progress", false, nil))
        XCTAssertTrue(ExtensionDownloadsAPI.state(.paused, reason: "Paused") == ("in_progress", true, nil))
        XCTAssertTrue(ExtensionDownloadsAPI.state(.done, reason: "") == ("complete", false, nil))
        XCTAssertTrue(ExtensionDownloadsAPI.state(.missing, reason: Downloads.missingText) == ("complete", false, nil))
        XCTAssertTrue(ExtensionDownloadsAPI.state(.failed, reason: Downloads.cancelledText) == ("interrupted", false, "USER_CANCELED"))
        XCTAssertTrue(ExtensionDownloadsAPI.state(.failed, reason: "The network connection was lost.") == ("interrupted", false, "NETWORK_FAILED"))
    }

    func testUnsafeHeadersAreRefused() {
        for name in ["Cookie", "host", "Origin", "Referer", "Proxy-Authorization", "Sec-Fetch-Site", "Content-Length"] {
            XCTAssertTrue(ExtensionDownloadsAPI.unsafeHeader(name), name)
        }
        for name in ["Authorization", "X-Requested-With", "Accept"] { XCTAssertFalse(ExtensionDownloadsAPI.unsafeHeader(name), name) }
    }

    func testDeclaredOnlyAsARequiredPermission() {
        XCTAssertTrue(ExtensionDownloadsAPI.declared(["permissions": ["downloads"]]))
        XCTAssertFalse(ExtensionDownloadsAPI.declared(["optional_permissions": ["downloads"]]))
        XCTAssertFalse(ExtensionDownloadsAPI.declared(["permissions": ["downloads"]], ExtensionDownloadsAPI.openPermission))
    }

    func testDestinationMakesFoldersButNeverLeavesTheDownloadFolder() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("extension-downloads-\(UUID())")
        let root = base.appendingPathComponent("Downloads"), outside = base.appendingPathComponent("Outside")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let nested = try XCTUnwrap(Downloads.extensionDestination(["a", "b", "file.txt"], in: root, overwrite: false))
        XCTAssertEqual(nested.path, root.appendingPathComponent("a/b/file.txt").path)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("a/b").path))

        try Data("old".utf8).write(to: root.appendingPathComponent("taken.txt"))
        XCTAssertEqual(Downloads.extensionDestination(["taken.txt"], in: root, overwrite: false)?.lastPathComponent, "taken 2.txt")
        XCTAssertEqual(Downloads.extensionDestination(["taken.txt"], in: root, overwrite: true)?.lastPathComponent, "taken.txt")
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("taken.txt").path), "Overwrite replaces the plain file")

        // A folder is never overwritten, only stepped around.
        try fm.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        XCTAssertEqual(Downloads.extensionDestination(["folder"], in: root, overwrite: true)?.lastPathComponent, "folder 2")

        // A symlink inside the folder that leads out of it is refused, and nothing is made there.
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertNil(Downloads.extensionDestination(["link", "escape.txt"], in: root, overwrite: false))
        XCTAssertNil(Downloads.extensionDestination(["link", "deeper", "escape.txt"], in: root, overwrite: false))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside.path), [])
    }
}

/// `chrome.downloads` end to end: a synthetic MV3 extension saves through Vane's own list.
@MainActor final class ExtensionDownloadsTests: XCTestCase {
    private var profile = UUID()
    private var folder: URL!
    private var root: URL!
    private var server: DownloadHTTPFixture!

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        profile = UUID()
        folder = Store.directory.appendingPathComponent("extension-downloads-\(UUID())")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("extension-downloads-root-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"Download Fixture","version":"1.0","permissions":["downloads"],"background":{"service_worker":"worker.js"}}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        try Data("chrome.downloads.onChanged.addListener(() => {});".utf8).write(to: folder.appendingPathComponent("worker.js"))
        try Data("<title>Fixture page</title>".utf8).write(to: folder.appendingPathComponent("page.html"))
        server = try DownloadHTTPFixture()
        try await wait("server") { self.server.port != nil }
    }

    override func tearDown() async throws {
        let manager = Downloads.manager(for: profile)
        manager.items.filter(\.status.isLive).forEach { manager.cancel($0) }
        server.stop()
        ExtensionHost.forget(profile)
        Downloads.forget(profile)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: root)
        try await NativeFixtureProfileCleanup.release([profile])
    }

    private func wait(_ description: String, until ready: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !(try await ready()) {
            guard ContinuousClock.now < deadline else { throw ExtensionHost.Failure("Timed out: " + description) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func run(_ script: String, in page: WKWebView) async throws -> String? {
        try await page.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? String
    }

    private func required(_ script: String, in page: WKWebView) async throws -> String {
        let value = try await run(script, in: page)
        return try XCTUnwrap(value)
    }

    private func item(_ id: String, in page: WKWebView) async throws -> [String: Any] {
        let json = try await run("return JSON.stringify((await chrome.downloads.search({id: \(id)}))[0] ?? null)", in: page)
        return try JSONSerialization.jsonObject(with: Data((json ?? "null").utf8), options: .fragmentsAllowed) as? [String: Any] ?? [:]
    }

    func testAnExtensionDownloadsIntoVanesListAndHearsOfIt() async throws {
        let manager = Downloads.manager(for: profile)
        manager.destinationDirectory = root
        let host = ExtensionHost.host(for: profile)
        _ = try await host.load(folder, installing: true) { _ in true }
        let context = try XCTUnwrap(host.installed.first)
        XCTAssertTrue((host.entries.first?.compatibility ?? []).contains { $0.hasPrefix("downloads: Vane saves") })
        let page = WKWebView(frame: .zero, configuration: try XCTUnwrap(context.webViewConfiguration))
        page.load(URLRequest(url: context.baseURL.appendingPathComponent("page.html")))
        try await wait("extension page") { !page.isLoading && page.title == "Fixture page" }
        defer { page.stopLoading() }

        _ = try await run("""
            window.events = [];
            chrome.downloads.onCreated.addListener(item => events.push('created:' + item.id));
            chrome.downloads.onChanged.addListener(delta => {
              if (delta.state) events.push('state:' + delta.id + ':' + delta.state.current);
              if (delta.paused) events.push('paused:' + delta.id + ':' + delta.paused.current);
            });
            chrome.downloads.onErased.addListener(id => events.push('erased:' + id));
            window.failure = promise => promise.then(() => 'resolved', error => error.message);
            return String(chrome.downloads.State.COMPLETE);
            """, in: page)
        let events = { try await self.run("return events.join(',')", in: page) ?? "" }

        // An http download with the request the extension built, into a folder of its own.
        let url = try server.url()
        let id = try await required("""
            return String(await chrome.downloads.download({url: '\(url)', filename: 'Fixture/fixture.bin', method: 'POST', body: 'x=1',
                                                           headers: [{name: 'X-Fixture', value: 'yes'}]}));
            """, in: page)
        try await wait("complete") { try await self.item(id, in: page)["state"] as? String == "complete" }
        let done = try await item(id, in: page)
        let file = root.appendingPathComponent("Fixture/fixture.bin")
        XCTAssertEqual(done["filename"] as? String, file.path)
        XCTAssertEqual(done["exists"] as? Bool, true)
        XCTAssertEqual(done["url"] as? String, url.absoluteString)
        XCTAssertEqual((done["totalBytes"] as? NSNumber)?.intValue, server.bytes.count)
        XCTAssertEqual(done["byExtensionName"] as? String, "Download Fixture")
        XCTAssertNotNil(done["endTime"])
        XCTAssertEqual(try Data(contentsOf: file), server.bytes)
        XCTAssertTrue(server.requests.contains { $0.hasPrefix("POST /file ") && $0.contains("X-Fixture: yes") })
        // The Library's own row.
        XCTAssertEqual(manager.items.first?.url?.path, file.path)
        try await wait("created and complete events") {
            let heard = try await events()
            return heard.contains("created:\(id)") && heard.contains("state:\(id):complete")
        }

        // data: and the extension's own blob: URLs.
        let pair = try await required("""
            const text = await chrome.downloads.download({url: 'data:text/plain;base64,aGVsbG8=', filename: 'hello.txt'});
            const blob = await chrome.downloads.download({url: URL.createObjectURL(new Blob(['blob body'], {type: 'text/plain'})), filename: 'blob.txt'});
            return text + ',' + blob;
            """, in: page).split(separator: ",").map(String.init)
        for id in pair { try await wait("small file \(id)") { try await self.item(id, in: page)["state"] as? String == "complete" } }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("hello.txt"), encoding: .utf8), "hello")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("blob.txt"), encoding: .utf8), "blob body")
        let found = try await run("""
            const newest = await chrome.downloads.search({orderBy: ['-startTime'], limit: 1});
            const texts = await chrome.downloads.search({filenameRegex: '\\\\.txt$', state: 'complete'});
            return newest.length + ':' + texts.length + ':' + (await chrome.downloads.search({query: ['fixture', '-hello']})).length;
            """, in: page)
        XCTAssertEqual(found, "1:2:1")

        // Refused before anything starts.
        let refusals = try await run("""
            return [await failure(chrome.downloads.download({url: '\(url)', filename: '../escape.bin'})),
                    await failure(chrome.downloads.download({url: '\(url)', filename: '/tmp/escape.bin'})),
                    await failure(chrome.downloads.download({url: 'file:///etc/hosts'})),
                    await failure(chrome.downloads.download({url: 'blob:https://example.com/1'})),
                    await failure(chrome.downloads.download({url: '\(url)', headers: [{name: 'Cookie', value: 'a=b'}]})),
                    await failure(chrome.downloads.open(\(id))),
                    await failure(chrome.downloads.pause(99999))].join('|');
            """, in: page)
        XCTAssertEqual(refusals, #"Invalid filename.|Invalid filename.|Invalid URL.|Invalid URL.|Unsafe request header name.|The "downloads.open" permission is required.|Invalid downloadId."#)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape.bin").path))

        // Pause, then cancel, a transfer the server holds open.
        server.held = true
        let held = try await required("return String(await chrome.downloads.download({url: '\(url)'}))", in: page)
        try await wait("in progress") { try await self.item(held, in: page)["state"] as? String == "in_progress" }
        _ = try await run("await chrome.downloads.pause(\(held)); return 'paused'", in: page)
        try await wait("paused event") { try await events().contains("paused:\(held):true") }
        let paused = try await item(held, in: page)
        XCTAssertEqual(paused["state"] as? String, "in_progress")
        _ = try await run("await chrome.downloads.cancel(\(held)); return 'cancelled'", in: page)
        try await wait("cancelled") { try await self.item(held, in: page)["error"] as? String == "USER_CANCELED" }
        try await wait("interrupted event") { try await events().contains("state:\(held):interrupted") }

        // Erase forgets the row, not the file.
        let erased = try await run("return JSON.stringify(await chrome.downloads.erase({id: \(pair[0])}))", in: page)
        XCTAssertEqual(erased, "[\(pair[0])]")
        try await wait("erased event") { try await events().contains("erased:\(pair[0])") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("hello.txt").path))
        XCTAssertFalse(manager.items.contains { $0.url?.lastPathComponent == "hello.txt" })
        let icon = try await run("return await chrome.downloads.getFileIcon(\(id), {size: 16})", in: page)
        XCTAssertEqual(icon?.hasPrefix("data:image/png;base64,"), true)
    }
}
