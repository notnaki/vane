import AppKit
import Network
import Security
import WebKit

/// Deterministic, real-WebKit smoke checks. Run the packaged app with `browsercheck` and
/// an empty VANE_DATA_DIR. Unlike selfcheck --pure, this needs a logged-in macOS session.
/// Existing SelfCheck owns the keychain/autofill and popup-SPI fixtures; these checks cover
/// navigation, redirects, history, find, form submission, popup creation and private data.
@MainActor enum BrowserChecks {
    private static var runner: Runner?

    static func run() -> Never {
        guard let directory = Store.overrideDirectory,
              FileManager.default.fileExists(atPath: directory),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: directory),
              entries.isEmpty else {
            fail("browsercheck requires VANE_DATA_DIR pointing to an existing empty directory", code: 2)
        }
        guard Bundle.main.bundleURL.pathExtension == "app", sandboxedSignature() else {
            fail("browsercheck must run inside a signed app bundle with App Sandbox enabled", code: 2)
        }
        let check = Runner(directory: directory)
        runner = check
        // Independent of any awaited WebKit callback. An unavailable process or delegate
        // callback must fail CI instead of leaving a task suspended indefinitely.
        DispatchQueue.main.asyncAfter(deadline: .now() + 55) {
            fail("browsercheck exceeded its 55-second deadline", code: 1)
        }
        Task { await check.run() }
        NSApplication.shared.run()
        fail("browsercheck run loop ended before completion", code: 1)
    }

    /// The browser process cannot unregister a store that its WebKit network process still
    /// has open. The smoke script invokes this command in a fresh process after `run` exits.
    static func cleanupStore() -> Never {
        guard let directory = Store.overrideDirectory,
              FileManager.default.fileExists(atPath: directory) else {
            fail("browsercheck cleanup requires an existing VANE_DATA_DIR", code: 2)
        }
        guard Bundle.main.bundleURL.pathExtension == "app", sandboxedSignature() else {
            fail("browsercheck cleanup must run inside a signed sandboxed app", code: 2)
        }
        // The profile-hop checks open a second isolated profile. Compute only identifiers
        // belonging to this test directory; never touch a production/default WebKit store.
        let profileIDs = Set([ProfileManager.defaultID] + ProfileManager.shared.profiles.map(\.id))
        let ids = profileIDs.compactMap {
            ProfileManager.dataStoreIdentifier(for: $0, dataDirectory: directory)
        }.sorted { $0.uuidString < $1.uuidString }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            fail("browsercheck cleanup exceeded its 15-second deadline", code: 1)
        }
        Task {
            // A cold fetchAllDataStoreIdentifiers call crashes WebKit on this macOS release.
            _ = WKProcessPool()
            for id in ids {
                var removed = false
                var lastError: Error?
                for attempt in 0..<20 {
                    let registered = await registeredStoreIdentifiers()
                    if !registered.contains(id) { removed = true; break }
                    lastError = await withCheckedContinuation { continuation in
                        WKWebsiteDataStore.remove(forIdentifier: id) { error in
                            continuation.resume(returning: error)
                        }
                    }
                    if lastError == nil {
                        let remaining = await registeredStoreIdentifiers()
                        if !remaining.contains(id) { removed = true; break }
                    }
                    if attempt < 19 { try? await Task.sleep(for: .milliseconds(250)) }
                }
                if !removed {
                    fail("temporary WebKit store \(id.uuidString) still registered: \(String(describing: lastError))",
                         code: 1)
                }
            }
            print("PASS browsercheck cleanup: \(ids.count) temporary WebKit stores unregistered")
            exit(0)
        }
        NSApplication.shared.run()
        fail("browsercheck cleanup run loop ended before completion", code: 1)
    }

    private static func registeredStoreIdentifiers() async -> [UUID] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.fetchAllDataStoreIdentifiers { ids in
                continuation.resume(returning: ids)
            }
        }
    }

    private static func sandboxedSignature() -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
              let dictionary = info as? [String: Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return false }
        return entitlements["com.apple.security.app-sandbox"] as? Bool == true
    }

    private static func fail(_ text: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("FAIL browsercheck: \(text)\n".utf8))
        exit(code)
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    @MainActor private final class Runner {
        let directory: String
        var server: Server?
        var tabs: [Tab] = []
        var windows: [NSWindow] = []
        var assertions = 0

        init(directory: String) { self.directory = directory }

        func run() async {
            do {
                let server = try Server()
                self.server = server
                try await wait("loopback server starts") { server.port != nil || server.error != nil }
                if let error = server.error { throw Failure(error) }
                guard let port = server.port else { throw Failure("listener has no port") }
                let base = "http://127.0.0.1:\(port)"
                // This defaults suite belongs exclusively to the empty test directory.
                // HTTPS upgrades are tested by SelfCheck; this fixture has no TLS server.
                HTTPSOnly.enabled = false
                let profile = ProfileManager.shared.active.id
                let tab = makeTab(profile: profile)
                let expectedStore = ProfileManager.dataStoreIdentifier(for: profile, dataDirectory: directory)
                try require(expectedStore != nil && tab.web.configuration.websiteDataStore.identifier == expectedStore,
                            "the test data directory has its own named WebKit store")
                try require(tab.web.configuration.websiteDataStore.isPersistent,
                            "the isolated regular store remains persistent")
                try require(expectedStore != profile,
                            "the isolated store cannot collide with an installed profile store")
                let background = TabStore(urls: [URL(string: "\(base)/a")!], profileID: profile)
                let original = background.current
                background.active?.passwordChoice = PasswordChoice(
                    host: "example.test", accounts: ["ada"], anchor: .zero)
                background.openBeside(URL(string: "\(base)/b")!, focus: false)
                try require(background.current == original
                            && background.active?.passwordChoice != nil,
                            "a background link does not interrupt the active tab's password chooser")
                tabs += background.tabs
                let incomingSpace = Space(name: "Incoming", profileID: profile,
                                          tabURLs: [URL(string: "\(base)/a")!])
                let incoming = TabStore(urls: [URL(string: "\(base)/b")!],
                                        profileID: profile, space: incomingSpace)
                try require(incoming.current == incoming.tabs.last?.id,
                            "a URL sent to a new window is selected ahead of existing Space tabs")
                tabs += incoming.tabs
                let pinnedURL = URL(string: "\(base)/pin-home")!
                let pinnedSpace = Space(name: "Pinned", profileID: profile,
                                        pinnedTabURLs: [pinnedURL])
                let requestedPin = TabStore(urls: [pinnedURL], profileID: profile,
                                            space: pinnedSpace)
                try require(requestedPin.active?.homeURL == pinnedURL && requestedPin.palette == nil,
                            "a requested pinned page is shown without opening the New Tab palette")
                tabs += requestedPin.tabs
                TabStore.all.removeAll {
                    $0 === background || $0 === incoming || $0 === requestedPin
                }
                try await load(tab, "\(base)/a", title: "Fixture A")
                try require(tab.history.history().contains { URL(string: $0.url)?.path == "/a" },
                            "normal navigation records a real history visit")

                let hostSource = makeTab(profile: profile)
                try await load(hostSource, "\(base)/host-title", title: "127.0.0.1")
                guard let restoredURL = hostSource.web.url,
                      let restoredState = hostSource.snapshot.state else {
                    throw Failure("host-title page did not expose interaction state")
                }
                let restored = makeTab(profile: profile)
                restored.kind = .pinned
                restored.park(url: restoredURL,
                              Parked(title: "Cached Host Title", state: restoredState))
                restored.resume()
                try await wait("interaction-state page restoration") {
                    restored.web.url == restoredURL && restored.web.title == "127.0.0.1"
                        && !restored.web.isLoading
                }
                try require(restored.title == "Cached Host Title",
                            "interaction-state restoration never publishes its provisional host title")
                try await wait("a final host-shaped title settles") {
                    restored.title == "127.0.0.1"
                }
                try require(restored.title == "127.0.0.1",
                            "a final host-shaped title eventually replaces stale cached text")

                let find = Find()
                await find.run("needle", in: tab, fresh: true)
                try require(find.count == 2 && find.index == 1, "Find selects the first of two visible matches")
                await find.run("needle", in: tab)
                try require(find.count == 2 && find.index == 2, "Find advances to the next real page match")
                await find.run("not-in-this-document", in: tab, fresh: true)
                try require(find.count == 0, "Find reports an actual missing term")

                _ = try await js(tab, "document.getElementById('next').click()")
                try await loaded(tab, path: "/b", title: "Fixture B")
                try require(tab.web.canGoBack, "a clicked link creates a back entry")
                tab.web.goBack()
                try await loaded(tab, path: "/a", title: "Fixture A")
                try require(tab.web.canGoForward, "Back exposes the forward entry")
                tab.web.goForward()
                try await loaded(tab, path: "/b", title: "Fixture B")
                try require(tab.web.url?.path == "/b", "Forward returns to the linked page")

                let beforeReload = server.requests["/b", default: 0]
                tab.web.reload()
                try await wait("reload reaches the server") { server.requests["/b", default: 0] > beforeReload }
                try await loaded(tab, path: "/b", title: "Fixture B")
                try require(server.requests["/b", default: 0] > beforeReload, "Reload fetches a fresh response")

                try await load(tab, "\(base)/redirect", title: "Fixture B", finalPath: "/b")
                try require(server.requests["/redirect", default: 0] == 1 && tab.web.url?.path == "/b",
                            "an HTTP redirect lands on its destination")

                try await load(tab, "\(base)/form", title: "Fixture Form")
                let edited = try await js(tab, """
                    const field = document.getElementById('query');
                    field.value = 'browser smoke';
                    field.dispatchEvent(new Event('input', {bubbles: true}));
                    window.inputState;
                    """)
                try require(edited as? String == "browser smoke", "a form input event reaches page state")
                _ = try await js(tab, "document.getElementById('submit').click()")
                try await loaded(tab, path: "/submitted", title: "Fixture Submitted")
                // HTML GET forms encode spaces as '+'. URLComponents decodes percent
                // escapes but deliberately leaves literal plus signs unchanged.
                let formURL = tab.web.url!.absoluteString.replacingOccurrences(of: "+", with: "%20")
                let submitted = URLComponents(string: formURL)?
                    .queryItems?.first(where: { $0.name == "query" })?.value
                try require(submitted == "browser smoke", "form submission navigates with the edited value")

                // Exercise Tab.createWebViewWith and its real onPopup route, not a stand-in
                // navigation delegate. SelfCheck separately checks gesture SPI/placement.
                tab.web.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
                var popup: Tab?
                tab.onPopup = { [weak self] configuration, _ in
                    guard let self else { return nil }
                    let child = Tab(popup: configuration, isPrivate: false, profileID: profile)
                    popup = child
                    self.host(child)
                    return child.web
                }
                _ = try await js(tab, """
                    window.fixturePopup = window.open('about:blank', '_blank', 'width=451,height=400');
                    if (window.fixturePopup) {
                        window.fixturePopup.document.write('<title>Fixture Popup</title><body>Popup content</body>');
                        window.fixturePopup.document.close();
                    }
                    """)
                try await wait("popup reaches the Tab callback") { popup != nil }
                guard let popup else { throw Failure("popup callback did not produce a tab") }
                try await wait("popup document renders") { popup.web.title == "Fixture Popup" }
                let popupBody = try await js(popup, "document.body.textContent")
                try require((popupBody as? String)?.contains("Popup content") == true,
                            "the opener writes into the returned popup web view")

                try await load(tab, "\(base)/storage", title: "Fixture Storage")
                _ = try await js(tab, "localStorage.setItem('scope', 'regular')")
                let privateTab = makeTab(profile: profile, isPrivate: true)
                try require(!privateTab.web.configuration.websiteDataStore.isPersistent
                            && privateTab.web.configuration.websiteDataStore.identifier == nil,
                            "private browsing uses an unnamed ephemeral WebKit store")
                let historyBefore = tab.history.history().count
                try await load(privateTab, "\(base)/private", title: "Fixture Private")
                let inherited = try await js(privateTab, "localStorage.getItem('scope') === null")
                try require(inherited as? Bool == true, "private browsing cannot read regular local storage")
                _ = try await js(privateTab, "localStorage.setItem('scope', 'private')")
                let regular = try await js(tab, "localStorage.getItem('scope')")
                try require(regular as? String == "regular", "private writes do not change regular storage")
                let secondPrivate = makeTab(profile: profile, isPrivate: true)
                try await load(secondPrivate, "\(base)/private", title: "Fixture Private")
                let separate = try await js(secondPrivate, "localStorage.getItem('scope') === null")
                try require(separate as? Bool == true, "a fresh private tab has a fresh ephemeral data store")
                try require(tab.history.history().count == historyBefore
                            && !tab.history.history().contains { URL(string: $0.url)?.path == "/private" },
                            "private navigations do not add history records")

                let downloads = Downloads.manager(for: profile)
                let destination = URL(fileURLWithPath: directory).appendingPathComponent("download-fixtures")
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                downloads.destinationDirectory = destination
                DownloadLocation.setAskEveryTime(false, for: profile)
                for expected in 1...2 {
                    tab.web.load(URLRequest(url: URL(string: "\(base)/download")!))
                    try await wait("attachment download completes") {
                        downloads.items.filter { $0.status == .done }.count == expected
                    }
                }
                let files = downloads.items.compactMap(\.url)
                try require(files.count == 2 && Set(files).count == 2,
                            "repeated attachment downloads use distinct destinations")
                try require(try files.allSatisfy { try Data(contentsOf: $0) == Data("Vane download fixture\n".utf8) },
                            "real WKDownload writes complete bytes without replacing the earlier file")

                try await multiWindow(base: base)
                try await profileHopCheck(base: base)

                await clean()
                print("PASS browsercheck: \(assertions) real-WebKit assertions")
                print("Coverage excludes live permissions/devices, upload dialogs, printing, DRM and TLS trust.")
                exit(0)
            } catch {
                await clean()
                fail(String(describing: error), code: 1)
            }
        }

        private func makeTab(profile: UUID, isPrivate: Bool = false) -> Tab {
            let tab = Tab(isPrivate: isPrivate, profileID: profile)
            host(tab)
            return tab
        }

        private func host(_ tab: Tab) {
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 720, height: 500),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = tab.web
            window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            window.orderFront(nil)
            windows.append(window)
            tabs.append(tab)
        }

        private func multiWindow(base: String) async throws {
            let profile = ProfileManager.shared.create(name: "Window checks")
            let space = ProfileManager.shared.createSpace(name: "Shared windows", in: profile.id)
            let first = Windows.open(urls: [URL(string: "\(base)/form")!], profile: profile, space: space)
            try await focus(first)
            guard let page = first.active else { throw Failure("first shared window has no page") }
            tabs.append(page)
            try await loaded(page, path: "/form", title: "Fixture Form")
            try await load(page, "\(base)/a", title: "Fixture A")
            try await load(page, "\(base)/form", title: "Fixture Form")
            _ = try await js(page, "document.body.style.height = '3000px'; window.scrollTo(0, 600); document.getElementById('query').value = 'keep this input'")
            let originalWeb = page.web
            first.saveCurrentSpace()
            let second = Windows.open(profile: profile, space: first.currentSpace)
            try await focus(second)
            defer {
                first.window?.close()
                second.window?.close()
            }
            try require(second.active === page,
                        "two windows in one Space share the same tab identity and live page")
            do {
                try await wait("live page transfers to second window") { page.web.window === second.window }
            } catch {
                print("DIAG firstKey=\(first.window?.isKeyWindow ?? false) secondKey=\(second.window?.isKeyWindow ?? false) firstOwn=\(first.ownsPage(page)) secondOwn=\(second.ownsPage(page)) mountedFirst=\(page.web.window === first.window) mountedSecond=\(page.web.window === second.window) snapshot=\(page.windowSnapshot != nil)")
                throw error
            }
            try require(page.windowSnapshot != nil && !first.ownsPage(page) && second.ownsPage(page),
                        "the inactive copy has a snapshot and only the active window owns the page")
            let preservedInput = try await js(page, "document.getElementById('query').value")
            try require(page.web === originalWeb && preservedInput as? String == "keep this input",
                        "window handoff preserves the live view and unsent form input")
            let scroll = try await js(page, "window.scrollY") as? Double
            try require(scroll == 600 && page.web.canGoBack,
                        "window handoff preserves scroll position and back history")
            try await focus(first)
            try await wait("live page transfers back") { page.web.window === first.window }
            try require(first.ownsPage(page) && !second.ownsPage(page),
                        "activating the previous window reverses live and gray presentations")
            page.onOpenBeside?(URL(string: "\(base)/a")!, true)
            try await wait("page callback opens in its current owner") {
                first.tabs.count == 2 && second.tabs.count == 2
            }
            try require(first.current != page.id && second.current == page.id,
                        "page callbacks target the active window while each window keeps its selection")
            guard let duplicate = first.active else { throw Failure("new shared tab was not selected") }
            tabs.append(duplicate)
            first.newTab(URL(string: "\(base)/a")!)
            try await wait("duplicate URL propagates") { second.tabs.count == 3 }
            try require(first.tabs[1].id != first.tabs[2].id && second.tabs[1] === first.tabs[1]
                        && second.tabs[2] === first.tabs[2],
                        "separately opened duplicate URLs remain distinct shared identities")
            first.addPane(page.id, beside: duplicate.id)
            try await wait("shared split propagates") { second.splits.count == 1 }
            try await focus(second)
            try await wait("both live split panes transfer") {
                page.web.window === second.window && duplicate.web.window === second.window
            }
            try require(!first.ownsPage(page) && !first.ownsPage(duplicate),
                        "every shared split pane has a single live owner")
            first.window?.makeKeyAndOrderFront(nil)
            second.window?.makeKeyAndOrderFront(nil)
            first.window?.makeKeyAndOrderFront(nil)
            try await wait("rapid window switches settle in the final owner") {
                page.web.window === first.window && duplicate.web.window === first.window
            }
            try require(first.ownsPage(page) && first.ownsPage(duplicate),
                        "late snapshot callbacks cannot undo the final window activation")
            second.focusPane(duplicate.id)
            second.current = first.tabs.last!.id
            SharedTabs.flush()
            first.focusPane(page.id)
            SharedTabs.flush()
            try require(second.split(containing: duplicate.id)?.activeTab == duplicate.id,
                        "each window remembers its inactive split pane independently")
            first.swapPanes()
            SharedTabs.flush()
            try require(second.split(containing: duplicate.id)?.activeTab == duplicate.id,
                        "swapping shared panes preserves another window's remembered pane focus")
            let extensionAdapter = page.extensions.adapter(for: page, in: first)
            let entries = first.tabs.compactMap { tab -> Session.Entry? in
                guard let url = tab.currentURL else { return nil }
                return Session.Entry(id: tab.id.uuidString, url: url.absoluteString,
                                     title: tab.title, kind: tab.kind)
            }
            let restored = Windows.open(profile: profile, space: first.currentSpace,
                                        session: entries, selected: page.id)
            try require(restored.active === page && restored.tabs.map(\.id) == first.tabs.map(\.id),
                        "restoring another window reuses shared identities including duplicate URLs")
            restored.window?.close()
            second.current = page.id
            try await focus(second)
            try await wait("surviving window keeps the live page") { page.web.window === second.window }
            try require(page.web === originalWeb && page.web.navigationDelegate != nil,
                        "closing another window does not tear down a surviving shared page")
            try require(extensionAdapter.store === second,
                        "a shared tab extension adapter follows the current page owner")
            let beforeBoth = Set(first.tabs.map(\.id))
            first.newTab(URL(string: "\(base)/b")!)
            let openedFirst = first.current
            second.newTab(URL(string: "\(base)/b")!)
            let openedSecond = second.current
            try await wait("back-to-back opens synchronize") { first.tabs.map(\.id) == second.tabs.map(\.id) }
            try require(first.tabs.count == beforeBoth.count + 2
                        && first.tabs.contains { $0.id == openedFirst }
                        && first.tabs.contains { $0.id == openedSecond },
                        "back-to-back opens in different windows keep both new tabs")
            let addedBeforePin = first.newBlankTab(focus: false)
            addedBeforePin.park(url: URL(string: "\(base)/before-pin")!, Parked(title: "Before pin"))
            second.move(duplicate.id, to: .pinned)
            SharedTabs.flush()
            try require(first.tabs.contains { $0 === addedBeforePin }
                        && second.tabs.contains { $0 === addedBeforePin }
                        && first.tabs.first?.kind == .pinned
                        && first.pins.tabs.contains(duplicate.id.uuidString),
                        "opening a tab then pinning in another window keeps the new row and section order")
            let away = ProfileManager.shared.createSpace(name: "Away", in: profile.id)
            first.switchTo(space: away)
            try require(first.space(stashing: page.id) == space.id,
                        "another Space keeps the shared tab stashed")
            second.close(page.id)
            try require(!first.everyTab.contains { $0.id == page.id },
                        "closing a shared tab also removes copies stashed behind another Space")
            first.switchTo(space: second.currentSpace!)
            try require(!first.tabs.contains { $0.id == page.id },
                        "returning to a Space does not resurrect its closed shared tab")
            try require(first.current == openedFirst,
                        "returning to a shared Space restores this window's own selected tab")
            try require(!second.tabs.contains { $0.id == page.id },
                        "closing a shared tab removes it from the other window")
            // Both windows have visited the destination, so both can hold stale stashes.
            var destination = ProfileManager.shared.createSpace(name: "Move destination", in: profile.id)
            destination.tabURLs = [URL(string: "\(base)/b")!]
            ProfileManager.shared.updateSpace(destination)
            first.switchTo(space: destination)
            second.switchTo(space: destination)
            let staleDestinationPage = first.tabs.first!
            first.switchTo(space: second.spaces.first { $0.id == space.id }!)
            second.switchTo(space: first.currentSpace!)
            let movedURL = URL(string: "\(base)/moved")!
            let moving = first.newBlankTab(focus: false)
            moving.park(url: movedURL, Parked(title: "Moved"))
            Spaces.move(moving.id, to: destination.id, as: .today, from: first)
            first.switchTo(space: destination)
            try require(first.tabs.contains { $0.currentURL == movedURL },
                        "entering a shared stashed Space includes tabs moved into it on disk")
            try require(staleDestinationPage.web.navigationDelegate == nil,
                        "replacing stale shared stashes tears down pages no window holds")
            let anotherURL = URL(string: "\(base)/moved-again")!
            let another = second.newBlankTab(focus: false)
            another.park(url: anotherURL, Parked(title: "Moved again"))
            Spaces.move(another.id, to: destination.id, as: .today, from: second)
            try require(first.tabs.contains { $0.currentURL == anotherURL },
                        "moving a tab into a Space already open in another window updates its live strip")
            let pinnedCopy = second.newBlankTab(focus: false)
            pinnedCopy.park(url: anotherURL, Parked(title: "Pinned copy"))
            Spaces.move(pinnedCopy.id, to: destination.id, as: .pinned, from: second)
            try require(first.tabs.contains { $0.kind == .pinned && $0.pinnedURL == anotherURL }
                        && first.tabs.contains { $0.kind == .today && $0.pinnedURL == anotherURL },
                        "moving a pinned copy preserves a Today tab with the same URL")
            second.switchTo(space: first.currentSpace!)
            let splitTabs = first.tabs.prefix(2).map(\.id)
            first.addPane(splitTabs[1], beside: splitTabs[0])
            SharedTabs.flush()
            try await wait("session rows have navigable URLs") { first.tabs.allSatisfy { $0.currentURL != nil } }
            let savedIDs = first.tabs.map(\.id)
            let savedPanes = first.splits.first!.tabs
            try require(Session.save(), "shared-window session saves")
            let sessionFile = ProfileManager.sessionURL(for: profile.id, in: Store.directory)
            let savedSession = try Data(contentsOf: sessionFile)
            first.window?.close()
            second.window?.close()
            // Simulate a process restart with its quit-time snapshot. Explicit window
            // closes save a smaller session, which is a different operation from quitting.
            try savedSession.write(to: sessionFile, options: .atomic)
            try require(Session.restore(profile: profile), "shared-window session restores")
            SharedTabs.flush()
            let restoredWindows = TabStore.all.filter { $0.profileID == profile.id && $0.window != nil }
            defer { restoredWindows.forEach { $0.window?.close() } }
            try require(restoredWindows.count == 2
                        && restoredWindows.allSatisfy { $0.tabs.map(\.id) == savedIDs }
                        && restoredWindows.allSatisfy { $0.splits.first?.tabs == savedPanes },
                        "a disk session restores shared tab identities and splits in both windows")
            try require(restoredWindows[0].tabs.first === restoredWindows[1].tabs.first,
                        "disk session restoration recreates one live object per shared tab")
            let survivor = restoredWindows[0], closing = restoredWindows[1]
            guard let survivingPage = survivor.active else { throw Failure("restored window has no selected page") }
            closing.current = survivingPage.id
            try await focus(closing)
            try await wait("closing window first owns the shared page") { survivingPage.web.window === closing.window }
            let survivingWeb = survivingPage.web
            let adapter = survivingPage.extensions.adapter(for: survivingPage, in: closing)
            closing.window?.close()
            try await focus(survivor)
            try await wait("closing owner hands page to survivor") { survivingPage.web.window === survivor.window }
            try require(survivingPage.web === survivingWeb && survivingWeb.navigationDelegate != nil
                        && adapter.store === survivor,
                        "closing the live owner preserves the page and its extension adapter in the surviving window")
        }

        private func focus(_ store: TabStore) async throws {
            // The fixture is launched by a CLI, so ordering a window alone does not
            // activate its app. Wait for a real key window before asserting handoff.
            NSApp.activate(ignoringOtherApps: true)
            store.window?.makeKeyAndOrderFront(nil)
            try await wait("fixture window becomes key") { store.window?.isKeyWindow == true }
        }

        private func load(_ tab: Tab, _ address: String, title: String, finalPath: String? = nil) async throws {
            guard let url = URL(string: address) else { throw Failure("invalid fixture URL") }
            let requestsBefore = server?.requests[url.path, default: 0] ?? 0
            tab.web.load(URLRequest(url: url))
            try await wait("request \(url.path) reaches the server") {
                (self.server?.requests[url.path, default: 0] ?? 0) > requestsBefore
            }
            try await loaded(tab, path: finalPath ?? url.path, title: title)
        }

        private func loaded(_ tab: Tab, path: String, title: String) async throws {
            try await wait("load \(path)") { tab.web.url?.path == path && tab.web.title == title && !tab.web.isLoading }
            let ready = try await js(tab, "document.readyState")
            guard ready as? String == "complete" else { throw Failure("\(path) did not finish loading") }
        }

        private func js(_ tab: Tab, _ source: String) async throws -> Any? {
            // WebKit returns Any, which cannot cross a continuation's sending boundary.
            // Move only serialized data between callbacks and the suspended task.
            let data: Data? = try await withCheckedThrowingContinuation { continuation in
                tab.web.evaluateJavaScript(source) { value, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let value else { continuation.resume(returning: nil); return }
                    do {
                        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
                        continuation.resume(returning: data)
                    } catch { continuation.resume(throwing: error) }
                }
            }
            return try data.map { try JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        }

        private func wait(_ label: String, until predicate: () -> Bool) async throws {
            let deadline = Date.now.addingTimeInterval(8)
            while !predicate() {
                guard Date.now < deadline else { throw Failure("timed out waiting for \(label)") }
                try await Task.sleep(for: .milliseconds(25))
            }
        }

        private func require(_ condition: Bool, _ label: String) throws {
            guard condition else { throw Failure(label) }
            assertions += 1
            print("  ok  \(label)")
        }

        /// A parked profile still belongs to the same window. Exercise both routes back to
        /// it: the Profiles menu and the command bar's open-tab row. The former must write
        /// the outgoing Space before parking it; the latter must actually show the tab.
        private func profileHopCheck(base: String) async throws {
            let manager = ProfileManager.shared
            let first = manager.active
            let second = manager.create(name: "Browsercheck Other")
            guard let firstSpace = manager.ensureSpaces(for: first).first,
                  let secondSpace = manager.ensureSpaces(for: second).first,
                  let firstURL = URL(string: "\(base)/a"),
                  let secondURL = URL(string: "\(base)/b") else {
                throw Failure("profile hop fixture could not create its Spaces")
            }
            let firstStore = Windows.open(profile: first, space: firstSpace)
            guard let window = firstStore.window else { throw Failure("profile hop has no window") }
            let revision = firstStore.spaceRevision
            let imported = manager.createSpace(name: "Imported Work", in: second.id)
            ArcImport.refreshSpaces(afterImporting: [second.id])
            try require(firstStore.spaceRevision > revision
                        && firstStore.strip.contains(where: { $0.id == imported.id }),
                        "a foreign Arc import refreshes the open window's global selector")
            let importedRevision = firstStore.spaceRevision
            ArcImport.refreshSpaces(afterImporting: [])
            try require(firstStore.spaceRevision == importedRevision,
                        "an import with no new Spaces leaves selectors unchanged")
            manager.deleteSpace(imported.id, in: second.id)
            firstStore.newTab(firstURL)
            firstStore.palette = nil
            let extensionDirectory = Store.directory.appendingPathComponent("extension-window-fixture")
            try FileManager.default.createDirectory(at: extensionDirectory, withIntermediateDirectories: true)
            try Data(#"{"manifest_version":3,"name":"Window fixture","version":"1"}"#.utf8)
                .write(to: extensionDirectory.appendingPathComponent("manifest.json"))
            let windowExtension = try await WKWebExtension(resourceBaseURL: extensionDirectory)
            let windowContext = WKWebExtensionContext(for: windowExtension)
            let firstHost = firstStore.extensions
            func extensionWindows(_ host: ExtensionHost) -> [ExtWindow] {
                host.webExtensionController(host.controller, openWindowsFor: windowContext)
                    .compactMap { $0 as? ExtWindow }
            }
            try require(extensionWindows(firstHost).contains(where: { $0.store === firstStore }),
                        "extensions list the profile's visible window")
            firstStore.switchTo(space: secondSpace)
            guard let secondStore = Windows.current(in: second.id),
                  secondStore.window === window else {
                throw Failure("cross-profile Space switch did not keep the same window")
            }
            try require(!extensionWindows(firstHost).contains(where: { $0.store === firstStore })
                        && extensionWindows(secondStore.extensions).contains(where: { $0.store === secondStore }),
                        "extensions exclude a profile parked behind another profile's window")
            secondStore.newTab(secondURL)
            secondStore.palette = nil
            guard let secondTab = secondStore.tabs.last else { throw Failure("second profile has no tab") }
            try await loaded(secondTab, path: "/b", title: "Fixture B")

            _ = Windows.switchTo(profile: first)
            try require(extensionWindows(firstHost).contains(where: { $0.store === firstStore })
                        && !extensionWindows(secondStore.extensions).contains(where: { $0.store === secondStore }),
                        "extensions list the returning profile's window again")
            try require(firstStore.window === window && secondStore.isParked,
                        "Profiles menu returns to a parked profile in the same window")
            try require(manager.spaces(for: second.id).first?.tabURLs.contains(secondURL) == true,
                        "Profiles menu saves the outgoing Space before parking it")

            NSApp.activate(ignoringOtherApps: true)
            try require(Windows.reveal(secondTab, in: secondStore),
                        "an open-tab result can reveal a tab in a parked profile")
            try require(secondStore.window === window && secondStore.current == secondTab.id,
                        "revealing a parked tab shows its profile and selects it")
            do {
                try await wait("keyboard focus returns to the revealed page") {
                    window.firstResponder === secondTab.web
                }
            } catch {
                let responder = window.firstResponder
                throw Failure("keyboard focus stayed on \(String(describing: responder)) "
                              + "(key=\(window.isKeyWindow), pageWindow=\(secondTab.web.window === window), "
                              + "palette=\(String(describing: secondStore.palette)))")
            }
            try require(window.firstResponder === secondTab.web,
                        "revealing a parked tab leaves the page ready for typing")

            _ = Windows.switchTo(profile: first)
            renameSpace(secondSpace, in: firstStore)
            try require(secondStore.window === window && secondStore.renamingSpace == secondSpace.id,
                        "a foreign Space dot opens its inline rename field")
            secondStore.renamingSpace = nil

            _ = Windows.switchTo(profile: first)
            guard let folderOwner = spaceMenuTarget(secondSpace, from: firstStore),
                  let foreignFolder = folderOwner.newFolder() else {
                throw Failure("foreign Space dot did not make its folder in the target Space")
            }
            try require(folderOwner === secondStore && secondStore.currentSpaceID == secondSpace.id
                        && secondStore.pins.folder(foreignFolder.id) != nil
                        && firstStore.pins.folder(foreignFolder.id) == nil,
                        "New Folder on a foreign dot belongs to that Space")
            _ = Windows.switchTo(profile: first)
            guard let liveOwner = spaceMenuTarget(secondSpace, from: firstStore),
                  let foreignLive = liveOwner.newLiveFolder(named: "Smoke live folder",
                                                              source: .github(LiveFolders.defaultQuery)) else {
                throw Failure("foreign Space dot did not make its live folder in the target Space")
            }
            try require(liveOwner === secondStore && secondStore.currentSpaceID == secondSpace.id
                        && secondStore.pins.folder(foreignLive.id)?.live != nil
                        && firstStore.pins.folder(foreignLive.id) == nil,
                        "New Live Folder on a foreign dot belongs to that Space")
            _ = Windows.switchTo(profile: first)
            let spare = manager.createSpace(name: "Browsercheck Spare", in: second.id)
            _ = Windows.switchTo(profile: second)
            guard let todayFolder = secondStore.newFolder(from: secondTab.id, in: \.todayShape) else {
                throw Failure("moving Space could not make its Today folder fixture")
            }
            try require(Session.save(), "the source session records the Space before it moves")
            let sourceSession = ProfileManager.sessionURL(for: second.id, in: Store.directory)
            try require((try? Data(contentsOf: sourceSession)).map {
                Session.decodeSpaces($0).contains(secondSpace.id)
            } == true, "the source session has a row for the Space before it moves")
            secondStore.switchTo(space: spare)
            _ = Windows.switchTo(profile: first)
            guard let formURL = URL(string: "\(base)/form") else {
                throw Failure("profile hop fixture has no form URL")
            }
            // This navigation happens in a live stash behind the source profile's current
            // Space after its last disk save. The target has no store currently showing it.
            secondTab.web.load(URLRequest(url: formURL))
            try await loaded(secondTab, path: "/form", title: "Fixture Form")
            moveSpace(secondSpace, to: first, from: firstStore)
            try require((try? Data(contentsOf: sourceSession)).map {
                !Session.decodeSpaces($0).contains(secondSpace.id)
                    && Session.decode($0).flatMap { $0 }.allSatisfy {
                        $0.url != formURL.absoluteString && $0.url != secondURL.absoluteString
                    }
            } == true, "moving a Space clears its stale source session before autosave")
            try require(manager.spaces(for: first.id).first(where: { $0.id == secondSpace.id })?
                            .tabURLs.contains(formURL) == true,
                        "moving a foreign Space preserves navigation in its parked profile")
            try require(secondStore.currentSpaceID == spare.id,
                        "moving a foreign Space resolves its parked owner to a surviving Space")
            let movedState = Suspension.SpaceState.load(space: secondSpace.id, profileID: first.id,
                                                         in: Store.directory)
            try require(movedState[formURL.absoluteString] != nil,
                        "moving a foreign Space carries its saved page state")
            let movedPinned = TabStore.savedShape(space: secondSpace.id, profileID: first.id)
            let movedToday = TabStore.savedShape(.today, space: secondSpace.id, profileID: first.id)
            try require(movedPinned?.folder(foreignFolder.id) != nil
                        && movedPinned?.folder(foreignLive.id)?.live != nil
                        && movedToday?.folder(todayFolder.id) != nil,
                        "moving a foreign Space carries Pinned and Today folders")
            guard let movedSpace = manager.spaces(for: first.id).first(where: { $0.id == secondSpace.id })
            else { throw Failure("the moved Space is absent from its destination profile") }
            firstStore.switchTo(space: movedSpace)
            try require(firstStore.pins.folder(foreignFolder.id) != nil
                        && firstStore.pins.folder(foreignLive.id)?.live != nil
                        && firstStore.todayShape.folder(todayFolder.id) != nil,
                        "the moved Space rebuilds both folder sections in its new profile")

            let keep = manager.createSpace(name: "Browsercheck Keep", in: second.id)
            guard let submittedURL = URL(string: "\(base)/submitted") else {
                throw Failure("profile hop fixture has no submitted URL")
            }
            secondStore.newTab(firstURL)
            guard let parkedTab = secondStore.tabs.last else {
                throw Failure("parked profile has no deletion fixture tab")
            }
            try await loaded(parkedTab, path: "/a", title: "Fixture A")
            try require(secondStore.saveCurrentSpace(),
                        "the deletion fixture has a stale parked Space snapshot")
            parkedTab.web.load(URLRequest(url: submittedURL))
            try await loaded(parkedTab, path: "/submitted", title: "Fixture Submitted")
            try require(deleteSpaceConfirmed(spare, in: firstStore),
                        "a foreign Space dot can delete a parked profile's Space")
            try require(Archive.shared(for: second.id).entries.contains {
                            $0.url == submittedURL.absoluteString
                        }, "deleting a foreign Space archives its live parked URL")
            try require(secondStore.currentSpaceID == keep.id,
                        "deleting a foreign Space resolves its parked owner to a surviving Space")

            let stashedDelete = manager.createSpace(name: "Delete hidden Space", in: second.id)
            secondStore.switchTo(space: stashedDelete)
            secondStore.newTab(firstURL)
            guard let stashedTab = secondStore.tabs.last else { throw Failure("hidden deletion has no tab") }
            try await loaded(stashedTab, path: "/a", title: "Fixture A")
            try require(secondStore.saveCurrentSpace(), "the hidden deletion fixture is saved")
            secondStore.switchTo(space: keep)
            stashedTab.web.load(URLRequest(url: formURL))
            try await loaded(stashedTab, path: "/form", title: "Fixture Form")
            try require(deleteSpaceConfirmed(stashedDelete, in: firstStore)
                        && Archive.shared(for: second.id).entries.contains {
                            $0.url == formURL.absoluteString
                        }, "deleting a foreign Space archives navigation in its live stash")

            // This profile has no open store at all. Session.save() skips such profiles, so
            // the move must remove an old row naming its Space from that profile's file.
            let closedProfile = manager.create(name: "Browsercheck Closed")
            let closedSpace = manager.createSpace(name: "From closed profile", in: closedProfile.id)
            let closedSpare = manager.createSpace(name: "Closed spare", in: closedProfile.id)
            let closedSession = ProfileManager.sessionURL(for: closedProfile.id, in: Store.directory)
            let staleEntry = Session.Entry(url: secondURL.absoluteString, kind: .today)
            let keptEntry = Session.Entry(url: firstURL.absoluteString, kind: .today)
            let selectedAfter = UUID()
            guard let staleData = Session.encode([[staleEntry], [keptEntry]],
                                                 spaces: [closedSpace.id.uuidString,
                                                          closedSpare.id.uuidString],
                                                 selected: [UUID().uuidString,
                                                            selectedAfter.uuidString])
            else { throw Failure("closed profile session fixture could not encode") }
            try staleData.write(to: closedSession)
            moveSpace(closedSpace, to: first, from: firstStore)
            try require((try? Data(contentsOf: closedSession)).map {
                Session.decodeSpaces($0) == [closedSpare.id]
                    && Session.decode($0).map { $0.map(\.url) } == [[firstURL.absoluteString]]
                    && Session.decodeSelected($0) == [selectedAfter]
            } == true, "moving from a closed profile clears only its Space's session row")

            // Delete must prune a closed profile's snapshot too, or restoring it would
            // reopen archived tabs in the surviving Space.
            var closedDelete = manager.createSpace(name: "Delete from closed profile", in: closedProfile.id)
            closedDelete.tabURLs = [secondURL]
            try require(manager.updateSpace(closedDelete), "the closed deletion fixture is saved")
            guard let deleteData = Session.encode([[staleEntry], [keptEntry]],
                                                  spaces: [closedDelete.id.uuidString,
                                                           closedSpare.id.uuidString],
                                                  selected: [UUID().uuidString,
                                                             selectedAfter.uuidString])
            else { throw Failure("closed deletion session fixture could not encode") }
            try deleteData.write(to: closedSession)
            try require(deleteSpaceConfirmed(closedDelete, in: firstStore),
                        "a foreign Space can be deleted while its profile has no open store")
            try require((try? Data(contentsOf: closedSession)).map {
                Session.decodeSpaces($0) == [closedSpare.id]
                    && Session.decode($0).map { $0.map(\.url) } == [[firstURL.absoluteString]]
                    && Session.decodeSelected($0) == [selectedAfter]
            } == true, "deleting from a closed profile clears only its Space's session row")

            let survivingSession = try Data(contentsOf: closedSession)
            try require(!deleteSpaceConfirmed(closedSpare, in: firstStore)
                        && (try? Data(contentsOf: closedSession)) == survivingSession,
                        "refusing a profile's last Space preserves its saved session")
            let blockedDelete = manager.createSpace(name: "Blocked deletion", in: closedProfile.id)
            let malformedSession = Data("unreadable session fixture".utf8)
            try malformedSession.write(to: closedSession)
            let archiveCount = Archive.shared(for: closedProfile.id).entries.count
            try require(!deleteSpaceConfirmed(blockedDelete, in: firstStore)
                        && manager.spaces(for: closedProfile.id).contains(where: { $0.id == blockedDelete.id })
                        && Archive.shared(for: closedProfile.id).entries.count == archiveCount
                        && (try? Data(contentsOf: closedSession)) == malformedSession,
                        "a session prune failure keeps the Space and archive unchanged")
            try survivingSession.write(to: closedSession)

            // The other move path starts on the Space being moved and hops the window into
            // its new profile. Its immediate session write must keep the rebuilt Today tab.
            guard let returning = manager.spaces(for: first.id).first(where: { $0.id == secondSpace.id })
            else { throw Failure("the moved Space is absent before its return move") }
            moveSpace(returning, to: second, from: firstStore)
            let destinationSession = ProfileManager.sessionURL(for: second.id, in: Store.directory)
            try require(manager.spaces(for: second.id).first(where: { $0.id == returning.id })?
                            .tabURLs.contains(formURL) == true
                        && secondStore.window === window && secondStore.currentSpaceID == returning.id,
                        "moving the shown Space keeps its pages through the profile hop")
            try require((try? Data(contentsOf: destinationSession)).map {
                Session.decodeSpaces($0).contains(returning.id)
                    && Session.decode($0).flatMap { $0 }.contains { $0.url == formURL.absoluteString }
            } == true, "moving the shown Space saves its destination session immediately")
            let oldSession = ProfileManager.sessionURL(for: first.id, in: Store.directory)
            try require((try? Data(contentsOf: oldSession)).map {
                !Session.decodeSpaces($0).contains(returning.id)
                    && !Session.decode($0).flatMap { $0 }.contains { $0.url == formURL.absoluteString }
            } == true, "moving the shown Space clears its former profile's session")

            window.performClose(nil)
            try require(!extensionWindows(firstHost).contains(where: { $0.store === firstStore })
                        && !extensionWindows(secondStore.extensions).contains(where: { $0.store === secondStore }),
                        "extensions no longer list either profile after the hopped window closes")
            try require(!TabStore.all.contains(where: { $0 === firstStore || $0 === secondStore }),
                        "closing a hopped window removes both of its profile stores")
            window.contentView = nil
            window.delegate = nil
            // tearDown() replaces each closed page with a fresh unloaded WKWebView. Release
            // those fixture tabs before the separate cleanup process unregisters the stores.
            firstStore.tabs.removeAll()
            secondStore.tabs.removeAll()
            ExtensionHost.forget(second.id)
            ProfileManager.releaseDataStore(for: second.id)
        }

        private func clean() async {
            server?.stop()
            defer { UserDefaults.dropScratchSuite(UserDefaults.suiteName(forDataDir: directory)) }
            let profileID = tabs.first(where: { !$0.isPrivate })?.profileID
            var isolatedStore: WKWebsiteDataStore?
            // Defense in depth: clean only the exact named store derived from this empty
            // test directory. Never clean .default() or a profile's production identifier.
            if let regular = tabs.first(where: { !$0.isPrivate }),
               let expected = ProfileManager.dataStoreIdentifier(for: regular.profileID, dataDirectory: directory),
               regular.web.configuration.websiteDataStore.identifier == expected {
                isolatedStore = regular.web.configuration.websiteDataStore
                await isolatedStore?.removeData(
                    ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            }
            tabs.forEach { $0.tearDown() }
            windows.forEach { $0.orderOut(nil) }
            tabs.removeAll()
            windows.removeAll()
            if let profileID {
                ExtensionHost.forget(profileID)
                ProfileManager.releaseDataStore(for: profileID)
            }
            isolatedStore = nil
        }
    }

    /// A loopback-only, GET-only HTTP fixture. A real HTTP 302 is necessary here: replacing
    /// a navigation with loadSimulatedRequest would not test WebKit's redirect/reload path.
    @MainActor private final class Server {
        let listener: NWListener
        var port: UInt16?
        var error: String?
        var requests: [String: Int] = [:]
        var connections: [NWConnection] = []

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    if case .ready = state { self?.port = self?.listener.port?.rawValue }
                    if case .failed(let error) = state { self?.error = error.localizedDescription }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated {
                    guard let self else { connection.cancel(); return }
                    self.connections.append(connection)
                    connection.start(queue: .main)
                    self.receive(connection, buffer: Data())
                }
            }
            listener.start(queue: .main)
        }

        func stop() { listener.cancel(); connections.forEach { $0.cancel() } }

        private func receive(_ connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
                MainActor.assumeIsolated {
                    guard let self, error == nil else { connection.cancel(); return }
                    var buffer = buffer
                    if let data { buffer.append(data) }
                    guard buffer.count < 32768 else { connection.cancel(); return }
                    guard let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") else {
                        if complete { connection.cancel() }
                        else { self.receive(connection, buffer: buffer) }
                        return
                    }
                    let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                    let path = String(target.split(separator: "?", maxSplits: 1)[0])
                    self.requests[path, default: 0] += 1
                    let attachment = path == "/download"
                    let body = attachment ? "Vane download fixture\n" : self.html(path)
                    let redirect = path == "/redirect"
                    let status = redirect ? "302 Found" : "200 OK"
                    let location = redirect ? "Location: /b\r\n" : ""
                    let contentType = attachment ? "application/octet-stream" : "text/html; charset=utf-8"
                    let disposition = attachment ? "Content-Disposition: attachment; filename=fixture.txt\r\n" : ""
                    let response = "HTTP/1.1 \(status)\r\n\(location)\(disposition)Content-Type: \(contentType)\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }

        private func html(_ path: String) -> String {
            let title: String
            let content: String
            switch path {
            case "/a": title = "A"; content = "<p>needle one</p><p>needle two</p><a id=next href=/b>Next</a>"
            case "/b": title = "B"; content = "<p>Second page</p>"
            case "/form":
                title = "Form"
                content = """
                    <form action=/submitted method=get><input id=query name=query><button id=submit>Submit</button></form>
                    <script>window.inputState='';document.getElementById('query').addEventListener('input',e=>window.inputState=e.target.value);</script>
                    """
            case "/submitted": title = "Submitted"; content = "<p>Form received</p>"
            case "/host-title":
                return "<!doctype html><meta charset=utf-8><title>127.0.0.1</title><body>Host title</body>"
            case "/storage": title = "Storage"; content = "<p>Regular storage</p>"
            case "/private": title = "Private"; content = "<p>Private storage</p>"
            default: title = "Empty"; content = ""
            }
            return "<!doctype html><meta charset=utf-8><title>Fixture \(title)</title><body>\(content)</body>"
        }
    }
}
