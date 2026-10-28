import AppKit
import Combine
import Darwin
import WebKit
import XCTest
@testable import vane

private actor QueuedFaviconPublicationRequests {
    private var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
    func snapshot() -> [URL] { urls }
}

@MainActor private final class FaviconPublicationNavigation: NSObject, WKNavigationDelegate {
    var expected: WKNavigation?
    var finished = false
    var failure: Error?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if navigation === expected { finished = true }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if navigation === expected { failure = error }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if navigation === expected { failure = error }
    }
}

@MainActor final class FaviconPublicationTests: XCTestCase {
    private static let artwork = Data("<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='32' height='32' fill='red'/></svg>".utf8)

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Favicon publication timed out")
                throw NSError(domain: "FaviconPublicationTimeout", code: 1)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testUnchangedDeclaredArtworkKeepsSiblingImageWhileRealChangesPublish() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        for changed in [false, true] {
            let profile = UUID()
            let page = URL(string: "http://127.0.0.1:1/icon-identity")!
            let declaration = URL(string: "http://127.0.0.1:1/new-declaration.svg")!
            let replacement = changed
                ? Data("<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='32' height='32' fill='blue'/></svg>".utf8)
                : Data("<!-- different bytes, identical artwork -->".utf8) + Self.artwork
            let requests = QueuedFaviconPublicationRequests()
            let initial = Self.artwork
            var cache: Favicons? = Favicons(profileID: profile, fetch: { url in
                await requests.record(url)
                return url == declaration ? replacement : initial
            })
            let active = Tab(profileID: profile), sibling = Tab(profileID: profile)
            let directory = ProfileManager.faviconDir(for: profile, in: Store.directory)
            defer {
                active.tearDown(); sibling.tearDown()
                Favicons.forget(profile)
                Store.forget(profile)
                try? FileManager.default.removeItem(at: directory)
            }
            _ = cache?.icon(for: page)
            try await waitUntil {
                cache?.generation == 1 && FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("127.0.0.1").path)
            }
            let original = try XCTUnwrap(cache?.icon(for: page))
            sibling.park(url: page, Parked(title: "An unchanged sibling"))
            try await waitUntil { sibling.favicon != nil }
            cache?.load(for: sibling)
            XCTAssertTrue(sibling.favicon === original)

            let web = active.web
            let navigation = FaviconPublicationNavigation()
            web.navigationDelegate = navigation
            defer { web.navigationDelegate = nil; withExtendedLifetime(navigation) {} }
            navigation.expected = try XCTUnwrap(web.loadHTMLString(
                "<html><head><link rel='icon' href='\(declaration.absoluteString)'></head><body>Icon identity</body></html>",
                baseURL: page))
            try await compatibilityWait { navigation.finished || navigation.failure != nil }
            if let failure = navigation.failure { throw failure }
            try await compatibilityWait { active.currentURL == page && !web.isLoading }
            let declared = Favicons.declared(try await web.evaluateJavaScript(Favicons.linkJS))
            XCTAssertEqual(declared, [declaration])
            var siblingPublications = 0
            let subscription = sibling.$favicon.dropFirst().sink { _ in siblingPublications += 1 }
            defer { withExtendedLifetime(subscription) {} }
            cache?.load(for: active)
            // Admit the actual declaration fetch, then await completion of the cache's
            // real tasks, rather than waiting for the desired absence of publications.
            try await compatibilityWait { await requests.snapshot().contains(declaration) }
            weak var finishing = cache
            cache = nil
            try await waitUntil { finishing == nil }
            if changed {
                XCTAssertFalse(sibling.favicon === original, "Changed artwork must still reach existing tabs")
                XCTAssertEqual(siblingPublications, 1)
            } else {
                XCTAssertTrue(sibling.favicon === original, "Equivalent artwork must not restart every sibling's image transition")
                XCTAssertEqual(siblingPublications, 0)
            }
        }
    }

    /// The writer cannot open a FIFO until its reader exists. A nonblocking reader
    /// also gives failed fixtures a bounded cleanup path rather than stranding a worker.
    private nonisolated static func drain(_ file: URL) async -> Data {
        await Task.detached {
            let descriptor = file.path.withCString { open($0, O_RDONLY | O_NONBLOCK) }
            guard descriptor >= 0 else { return Data() }
            defer { Darwin.close(descriptor) }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
                else if count == 0, !data.isEmpty { return data }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return data
        }.value
    }

    func testFetchedIconPublishesToTabsAndCacheBeforeBlockedPersistenceFinishes() async throws {
        TestEnvironment.prepare()
        let profile = UUID(), data = Self.artwork
        let url = URL(string: "https://publication-\(UUID().uuidString.lowercased()).invalid/")!
        let directory = ProfileManager.faviconDir(for: profile, in: Store.directory)
        let file = directory.appendingPathComponent(url.host!)
        let admission = AsyncStream<Void>.makeStream()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var cache: Favicons? = Favicons(profileID: profile, fetch: { _ in
            defer { admission.continuation.finish() }
            // Install the blocked destination after the initial disk read misses.
            // This exercises the real persistence worker, without mocking publication.
            guard file.path.withCString({ mkfifo($0, S_IRUSR | S_IWUSR) }) == 0 else { return nil }
            admission.continuation.yield(())
            return data
        })
        let tab = Tab(profileID: profile)
        defer { tab.tearDown() }
        tab.park(url: url, Parked(title: "Publication fixture"))
        cache?.load(for: tab)
        var admitted = admission.stream.makeAsyncIterator()
        let began = await admitted.next()
        XCTAssertNotNil(began)
        do {
            try await waitUntil { cache?.icon(for: url) != nil }
            XCTAssertNotNil(tab.favicon, "Tabs must show decoded artwork while its disk write is blocked")
            XCTAssertEqual(cache?.generation, 1, "Cache-only leaves must be notified before persistence finishes")
            XCTAssertTrue(cache?.icon(for: url) === tab.favicon)
        } catch {
            _ = await Self.drain(file)
            throw error
        }
        let persisted = await Self.drain(file)
        XCTAssertEqual(persisted, data, "Publication must not skip the authorized write")
        try await waitUntil { cache?.generation == 1 && tab.favicon != nil }
        weak var completing = cache
        cache = nil
        try await waitUntil { completing == nil }
    }

    func testPrivateOnlyFetchInPublicCacheDoesNotAuthorizePersistence() async throws {
        TestEnvironment.prepare()
        let profile = UUID(), data = Self.artwork
        let url = URL(string: "https://private-public-cache-\(UUID().uuidString.lowercased()).invalid/")!
        let directory = ProfileManager.faviconDir(for: profile, in: Store.directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var cache: Favicons? = Favicons(profileID: profile, fetch: { _ in data })
        let tab = Tab(isPrivate: true, profileID: profile)
        defer { tab.tearDown() }
        tab.park(url: url, Parked(title: "Private fixture"))
        cache?.load(for: tab)
        try await waitUntil { cache?.generation == 1 && tab.favicon != nil }
        // The warm task retains the cache through any authorized disk write and
        // pruning. Check privacy only once even an erroneous write would be finished.
        weak var completing = cache
        cache = nil
        try await waitUntil { completing == nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(url.host!).path),
                       "A fetched private-only URL must not gain persistence authorization")
    }

    func testNewDeclaredIconQueuedDuringPersistenceIsNotDiscarded() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = ProfileManager.shared.create(name: "Queued favicon declaration").id
        let first = Tab(profileID: profile), second = Tab(profileID: profile)
        defer {
            first.tearDown(); second.tearDown()
            _ = ProfileManager.shared.delete(profile)
        }
        let pageA = URL(string: "http://127.0.0.1:1/first-icon-page")!
        let pageB = URL(string: "http://127.0.0.1:1/second-icon-page")!
        let iconA = URL(string: "http://127.0.0.1:1/first-declared.svg")!
        let iconB = URL(string: "http://127.0.0.1:1/second-declared.svg")!
        func loadPage(_ page: URL, icon: URL, in tab: vane.Tab) async throws {
            let web = tab.web
            // Keep Tab.didFinish from starting the unrelated profile cache.
            let navigation = FaviconPublicationNavigation()
            web.navigationDelegate = navigation
            defer {
                web.navigationDelegate = nil
                withExtendedLifetime(navigation) {}
            }
            var stage = "start document navigation"
            do {
                navigation.expected = try XCTUnwrap(web.loadHTMLString(
                    "<html><head><link rel='icon' href='\(icon.absoluteString)'></head><body><p>Actual icon document</p></body></html>",
                    baseURL: page))
                stage = "wait for the actual navigation's didFinish"
                try await compatibilityWait { navigation.finished || navigation.failure != nil }
                if let failure = navigation.failure { throw failure }
                stage = "verify finished document URL and loading state"
                try await compatibilityWait { tab.currentURL == page && !web.isLoading }
                XCTAssertEqual(web.url, page)
                stage = "evaluate the finished document's icon declaration"
                let declared = Favicons.declared(try await web.evaluateJavaScript(Favicons.linkJS))
                XCTAssertEqual(declared, [icon], "The actual loaded document must supply its icon")
            } catch {
                throw NSError(domain: "FaviconPublicationDocumentFixture", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "\(page.absoluteString): \(stage): \(error)",
                    NSUnderlyingErrorKey: error
                ])
            }
        }
        try await loadPage(pageA, icon: iconA, in: first)
        try await loadPage(pageB, icon: iconB, in: second)
        // Observe the cache's real declaration query without inspecting private
        // queue state or replacing the document's links/results.
        _ = try await second.web.evaluateJavaScript("""
        window.faviconDeclarationQueries = 0;
        const originalQuery = document.querySelectorAll.bind(document);
        document.querySelectorAll = function(selector) {
            if (selector.startsWith("link[rel")) window.faviconDeclarationQueries++;
            return originalQuery(selector);
        };
        true;
        """)
        let directory = ProfileManager.faviconDir(for: profile, in: Store.directory)
        let file = directory.appendingPathComponent(try XCTUnwrap(pageA.host))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let requests = QueuedFaviconPublicationRequests()
        let red = Self.artwork
        let blue = Data("<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='32' height='32' fill='blue'/></svg>".utf8)
        var cache: Favicons? = Favicons(profileID: profile, fetch: { url in
            await requests.record(url)
            if url == iconA {
                // The disk read already missed. Block only this authorized write.
                guard file.path.withCString({ mkfifo($0, S_IRUSR | S_IWUSR) }) == 0 else { return nil }
                return red
            }
            if url == iconB {
                // A's writer has completed before this serialized next fetch;
                // replace its drained FIFO so B can persist as a normal file.
                try? FileManager.default.removeItem(at: file)
                return blue
            }
            return nil
        })
        var drained = false
        var stage = "first publication"
        do {
            cache?.load(for: first)
            try await waitUntil { cache?.generation == 1 && first.favicon != nil }
            let firstImage = try XCTUnwrap(first.favicon)
            stage = "second declaration query"
            cache?.load(for: second)
            try await compatibilityWait {
                (try await second.web.evaluateJavaScript("window.faviconDeclarationQueries") as? NSNumber)?.intValue == 1
            }
            // WebKit's queued query completed; let its main-actor continuation
            // enqueue the declared URL before releasing A's persistence worker.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            XCTAssertEqual(cache?.generation, 1)
            let whileBlocked = await requests.snapshot()
            XCTAssertEqual(whileBlocked, [iconA], "One host must serialize fetch and persistence")
            let persistedA = await Self.drain(file)
            drained = true
            XCTAssertEqual(persistedA, red)
            stage = "queued second publication"
            try await waitUntil { cache?.generation == 2 }
            let completedRequests = await requests.snapshot()
            XCTAssertEqual(completedRequests, [iconA, iconB],
                           "New declarations must survive the write await; old fallback alternatives must not fetch")
            XCTAssertFalse(first.favicon === firstImage)
            XCTAssertTrue(first.favicon === second.favicon)
            weak var completing = cache
            cache = nil
            stage = "serialized writer completion"
            try await waitUntil { completing == nil }
            XCTAssertEqual(try Data(contentsOf: file), blue, "The latest authorized artwork must persist last")
        } catch {
            print("FAVICON_QUEUE_FAILURE stage=\(stage) generation=\(cache?.generation ?? 0) requests=\(await requests.snapshot()) drained=\(drained)")
            if !drained { _ = await Self.drain(file) }
            throw error
        }
    }

    func testIncognitoCacheNeverWritesFetchedArtwork() async throws {
        TestEnvironment.prepare()
        let data = Self.artwork
        let url = URL(string: "https://incognito-publication-\(UUID().uuidString.lowercased()).invalid/")!
        let file = ProfileManager.faviconDir(for: Profile.incognito.id, in: Store.directory)
            .appendingPathComponent(url.host!)
        defer { try? FileManager.default.removeItem(at: file) }
        var cache: Favicons? = Favicons(profileID: Profile.incognito.id, fetch: { _ in data })
        // Even an accidentally persist-eligible caller cannot make this cache write.
        let tab = Tab(profileID: Profile.incognito.id)
        defer { tab.tearDown() }
        tab.park(url: url, Parked(title: "Incognito fixture"))
        cache?.load(for: tab)
        try await waitUntil { cache?.generation == 1 && tab.favicon != nil }
        weak var completing = cache
        cache = nil
        try await waitUntil { completing == nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
