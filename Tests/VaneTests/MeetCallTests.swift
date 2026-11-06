import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class MeetCallTests: XCTestCase {
    private var fixtures: [(Tab, NSWindow)] = []
    private var stores: [TabStore] = []

    private func withLoop(_ body: @MainActor () async throws -> Void) async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let preference = UserDefaults.standard.object(forKey: PictureInPicture.prefKey)
        PictureInPicture.autoEnabled = true
        defer { UserDefaults.standard.set(preference, forKey: PictureInPicture.prefKey) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .regular)
        var failure: (any Error)?
        do { try await body() } catch { failure = error }
        for (tab, window) in fixtures {
            if let web = tab.existingWeb {
                _ = try? await web.evaluateJavaScript("if (typeof cleanup === 'function') cleanup(); true")
            }
            tab.tearDown(); window.close()
        }
        fixtures.removeAll()
        for store in stores {
            let tabs = store.everyTab
            store.window = nil
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
        }
        stores.removeAll()
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Meet fixture loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func owner(_ tab: Tab, window: NSWindow) -> TabStore {
        let store = TabStore(isPrivate: true, session: [])
        store.tabs = [tab]
        store.window = window
        store.current = tab.id
        stores.append(store)
        return store
    }

    private func fixture(_ html: String, host: String = "meet.google.com", privateCall: Bool = true) async throws -> (Tab, NSWindow, WebHost) {
        TestEnvironment.prepare()
        let tab = privateCall ? Tab(isPrivate: true) : Tab(profileID: UUID())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let source = WebHost(tab.web)
        window.contentView = source
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        fixtures.append((tab, window))
        tab.web.loadHTMLString(html, baseURL: URL(string: "https://\(host)/abc-defg-hij"))
        try await compatibilityWait { !tab.web.isLoading && tab.web.title == "Call fixture" }
        do {
            try await compatibilityWait {
                // A previous loop's activation-policy transition can settle after
                // the first request. Re-admit the actual foreground owner.
                if !NSApp.isActive || !window.isKeyWindow {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
                return NSApp.isRunning && NSApp.isActive && window.isKeyWindow && tab.web.window === window && source.bounds.width > 400
            }
        } catch {
            print("MEET_ADMISSION running=\(NSApp.isRunning) active=\(NSApp.isActive) key=\(window.isKeyWindow) visible=\(window.isVisible) pageOwned=\(tab.web.window === window) bounds=\(source.bounds) policy=\(NSApp.activationPolicy().rawValue) appKey=\(String(describing: NSApp.keyWindow))")
            throw error
        }
        return (tab, window, source)
    }

    func testLobbyDoesNotPopOutAndSPAJoinLeaveUpdatesCallState() async throws {
        try await withLoop {
            let (tab, _, _) = try await fixture("<title>Call fixture</title><button id='leave' hidden><span>call_end</span></button>")
            XCTAssertFalse(tab.inMeetCall)
            PictureInPicture.enterIfPlaying(tab)
            XCTAssertNil(CallPopout.window(for: tab))
            _ = try await tab.web.evaluateJavaScript("leave.hidden=false; true")
            try await compatibilityWait { tab.inMeetCall && CallPopout.window(for: tab) != nil }
            _ = try await tab.web.evaluateJavaScript("leave.remove(); true")
            try await compatibilityWait { !tab.inMeetCall }
        }
    }

    func testUnrelatedOriginCannotAdvertiseAMeetCall() async throws {
        try await withLoop {
            let (tab, _, _) = try await fixture("<title>Call fixture</title><button><span>call_end</span></button>", host: "unrelated.example.test")
            XCTAssertFalse(tab.inMeetCall)
            PictureInPicture.enterIfPlaying(tab)
            XCTAssertNil(CallPopout.window(for: tab))
        }
    }

    func testCallStateIsClearedOnNavigation() async throws {
        try await withLoop {
            let (tab, _, _) = try await fixture("<title>Call fixture</title><button><span>call_end</span></button>")
            try await compatibilityWait { tab.inMeetCall }
            PictureInPicture.enterIfPlaying(tab)
            let panel = try XCTUnwrap(CallPopout.window(for: tab))
            tab.web.loadHTMLString("<title>Replacement</title>", baseURL: URL(string: "https://meet.google.com/"))
            try await compatibilityWait { !tab.web.isLoading && tab.web.title == "Replacement" }
            XCTAssertFalse(tab.inMeetCall)
            XCTAssertNil(CallPopout.window(for: tab))
            XCTAssertFalse(panel.isVisible)
        }
    }

    func testPopoutKeepsDocumentAndControlsAndReturnsWithoutHostTheft() async throws {
        try await withLoop {
            let (tab, sourceWindow, source) = try await fixture("""
            <title>Call fixture</title><button><span>call_end</span></button>
            <button id="control" onclick="this.textContent=String(++clicks)">0</button><script>let clicks=0;</script>
            """)
            try await compatibilityWait { tab.inMeetCall }
            let web = tab.web
            PictureInPicture.enterIfPlaying(tab)
            let panel = try XCTUnwrap(CallPopout.window(for: tab))
            try await compatibilityWait { panel.isVisible && web.window === panel }
            XCTAssertFalse(panel.isKeyWindow, "Automatic pop-out must not steal focus")
            source.show(web)
            XCTAssertTrue(web.window === panel, "A stale browser render must not take the call out of its floating window")
            _ = try await web.evaluateJavaScript("control.click(); true")
            let clicks = try await web.evaluateJavaScript("clicks") as? Int
            XCTAssertEqual(clicks, 1)
            PictureInPicture.exitIfAuto(tab)
            XCTAssertNil(CallPopout.window(for: tab))
            XCTAssertTrue(web === tab.existingWeb)
            XCTAssertTrue(web.window === sourceWindow)
            XCTAssertFalse(web.isHiddenOrHasHiddenAncestor)
            XCTAssertFalse(panel.isVisible)
        }
    }

    func testClosingPopoutKeepsCallAndSuppressesReentryUntilTabReturn() async throws {
        try await withLoop {
            let (tab, _, _) = try await fixture("<title>Call fixture</title><button><span>call_end</span></button>")
            try await compatibilityWait { tab.inMeetCall }
            PictureInPicture.enterIfPlaying(tab)
            let panel = try XCTUnwrap(CallPopout.window(for: tab))
            panel.performClose(nil)
            XCTAssertNil(CallPopout.window(for: tab))
            XCTAssertTrue(tab.inMeetCall, "Closing the pop-out must not hang up")
            PictureInPicture.enterIfPlaying(tab)
            XCTAssertNil(CallPopout.window(for: tab))
            PictureInPicture.exitIfAuto(tab)
            PictureInPicture.enterIfPlaying(tab)
            XCTAssertNotNil(CallPopout.window(for: tab))
            _ = try await tab.web.evaluateJavaScript("document.querySelector('button').remove(); true")
            try await compatibilityWait { !tab.inMeetCall && CallPopout.window(for: tab) == nil }
        }
    }

    func testPreferenceOffAndTeardownReleaseCallWindow() async throws {
        try await withLoop {
            let (tab, _, _) = try await fixture("<title>Call fixture</title><button><span>call_end</span></button>")
            try await compatibilityWait { tab.inMeetCall }
            let enabled = PictureInPicture.autoEnabled
            defer { PictureInPicture.autoEnabled = enabled }
            PictureInPicture.autoEnabled = false
            PictureInPicture.enterIfPlaying(tab)
            XCTAssertNil(CallPopout.window(for: tab))
            PictureInPicture.autoEnabled = true
            PictureInPicture.enterIfPlaying(tab)
            let panel = try XCTUnwrap(CallPopout.window(for: tab))
            tab.tearDown()
            XCTAssertNil(CallPopout.window(for: tab))
            XCTAssertFalse(panel.isVisible)
            XCTAssertFalse(tab.inMeetCall)
        }
    }

    func testHiddenAncestorAndAttributeOnlyJoinAreDetected() async throws {
        try await withLoop {
            let (tab, _, _) = try await fixture("<title>Call fixture</title><div id='controls' style='display:none'><button><span>call_end</span></button></div>")
            XCTAssertFalse(tab.inMeetCall)
            _ = try await tab.web.evaluateJavaScript("controls.style.display='block'; true")
            try await compatibilityWait { tab.inMeetCall }
            PictureInPicture.enterIfPlaying(tab)
            XCTAssertNotNil(CallPopout.window(for: tab))
            _ = try await tab.web.evaluateJavaScript("controls.style.visibility='hidden'; true")
            try await compatibilityWait { !tab.inMeetCall && CallPopout.window(for: tab) == nil }
        }
    }

    func testRealRTCFramesContinueAcrossPopoutAndReturn() async throws {
        try await withLoop {
            let (tab, _, _) = try await fixture("<title>Call fixture</title><button><span>call_end</span></button>" + CallCompatibilityTests.page)
            _ = try await tab.web.evaluateJavaScript("connect().catch(e=>failure=String(e)); true")
            try await compatibilityWait { try await tab.web.evaluateJavaScript("right && right.connectionState==='connected' && remote.videoWidth===320") as? Bool == true }
            try await compatibilityWait { tab.inMeetCall }
            let web = tab.web
            @MainActor func decoded() async throws -> Int {
                let value = try await web.callAsyncJavaScript("const stats=await right.getStats(); let frames=0; stats.forEach(s=>{if(s.type==='inbound-rtp' && s.kind==='video') frames+=s.framesDecoded||0}); return frames;",
                                                            arguments: [:], in: nil, contentWorld: .page)
                return try XCTUnwrap(value as? Int)
        }
        let before = try await decoded()
        PictureInPicture.enterIfPlaying(tab)
        let panel = try XCTUnwrap(CallPopout.window(for: tab))
        try await compatibilityWait { web.window === panel && panel.isVisible }
        try await compatibilityWait { try await decoded() > before + 3 }
        let floating = try await decoded()
        PictureInPicture.exitIfAuto(tab)
        try await compatibilityWait { try await decoded() > floating + 3 }
        let error = try await web.evaluateJavaScript("failure") as? String
        XCTAssertEqual(error, "")
        XCTAssertTrue(web === tab.existingWeb)
        }
    }

    func testVisibleSplitAndOtherWindowPreventAutomaticPopout() async throws {
        try await withLoop {
            let (tab, window, _) = try await fixture("<title>Call fixture</title><button><span>call_end</span></button>")
            try await compatibilityWait { tab.inMeetCall }
            let first = owner(tab, window: window)
            let other = Tab(isPrivate: true)
            first.tabs.append(other)
            let secondWindow = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 300),
                                        styleMask: [.titled], backing: .buffered, defer: false)
            secondWindow.isReleasedWhenClosed = false
            defer { secondWindow.close() }
            let second = owner(tab, window: secondWindow)
            secondWindow.orderFront(nil)
            first.current = other.id
            XCTAssertNil(CallPopout.window(for: tab), "A call still selected in another visible window must stay there")
            PictureInPicture.enterIfPlaying(tab, minimizingWindow: window)
            XCTAssertNil(CallPopout.window(for: tab), "Minimizing one shared window must not steal another window's selected call")
            second.window = nil
            first.splits = [try XCTUnwrap(Split(tabs: [tab.id, other.id]))]
            PictureInPicture.enterIfPlaying(tab)
            XCTAssertNil(CallPopout.window(for: tab), "Changing focus inside a visible split must not detach the call")
            first.splits = []
            PictureInPicture.enterIfPlaying(tab)
            XCTAssertNotNil(CallPopout.window(for: tab))
        }
    }

    func testTabSwitchAndBackToTabButtonUseOriginalCall() async throws {
        try await withLoop {
            let (tab, window, source) = try await fixture("<title>Call fixture</title><button><span>call_end</span></button>")
            try await compatibilityWait { tab.inMeetCall }
            let store = owner(tab, window: window)
            let other = Tab(isPrivate: true)
            store.tabs.append(other)
            store.current = other.id
            let panel = try XCTUnwrap(CallPopout.window(for: tab))
            source.show(other.web, keeping: [tab.web, other.web])
            panel.setContentSize(NSSize(width: 550, height: 400))
            panel.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(tab.web.bounds.width, 550, accuracy: 1)
            @MainActor func buttons(_ view: NSView) -> [NSButton] {
                if let button = view as? NSButton { return [button] }
                return view.subviews.flatMap(buttons)
            }
            let back = try XCTUnwrap(panel.contentView.flatMap { buttons($0).first { $0.identifier?.rawValue == "vane.call.restore" } })
            back.performClick(nil)
            XCTAssertEqual(store.current, tab.id)
            XCTAssertNil(CallPopout.window(for: tab))
            XCTAssertTrue(tab.inMeetCall)
            source.show(tab.web, keeping: [tab.web, other.web])
            XCTAssertTrue(tab.web.window === window)
            XCTAssertFalse(tab.web.isHiddenOrHasHiddenAncestor)
        }
    }

    func testMinimizedWindowAndReplacedSourceHostRetainLivePage() async throws {
        try await withLoop {
            let (tab, window, _) = try await fixture("<title>Call fixture</title><button><span>call_end</span></button>")
            try await compatibilityWait { tab.inMeetCall }
            _ = owner(tab, window: window)
            PictureInPicture.enterIfPlaying(tab, minimizingWindow: window)
            XCTAssertNotNil(CallPopout.window(for: tab))
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            PictureInPicture.exitIfAuto(tab)
            XCTAssertTrue(tab.web.window === window, "A replaced Space/profile host must not strand the live page in a closed panel")
            XCTAssertTrue(MediaState.shared.keepsRunning(tab))
            PictureInPicture.toggle(tab)
            XCTAssertNotNil(CallPopout.window(for: tab))
            PictureInPicture.toggle(tab)
            XCTAssertNil(CallPopout.window(for: tab))
            XCTAssertTrue(tab.inMeetCall)
        }
    }

    func testClosingDetachedTabReleasesOriginalHostCache() async throws {
        try await withLoop {
            let (tab, _, source) = try await fixture("<title>Call fixture</title><button><span>call_end</span></button>")
            try await compatibilityWait { tab.inMeetCall }
            PictureInPicture.enterIfPlaying(tab)
            XCTAssertNotNil(CallPopout.window(for: tab))
            tab.tearDown()
            XCTAssertNil(source.web, "A closed detached page must not survive in the original browser host's cache")
        }
    }

    func testSilentCallSurvivesSuspensionUntilItEnds() async throws {
        try await withLoop {
            let (tab, window, _) = try await fixture("<title>Call fixture</title><button><span>call_end</span></button>", privateCall: false)
            try await compatibilityWait { tab.inMeetCall }
            let store = owner(tab, window: window)
            let other = Tab(isPrivate: true)
            store.tabs.append(other)
            store.current = other.id
            CallPopout.dismiss(tab, suppress: true)
            tab.lastActive = .distantPast
            let pref = Prefs.suspendTabs
            Prefs.suspendTabs = true
            defer { Prefs.suspendTabs = pref; Store.forget(tab.profileID) }
            XCTAssertFalse(TabAudio.isPlaying(tab))
            XCTAssertTrue(MediaState.shared.keepsRunning(tab))
            await Suspension.suspendIfEligible(tab, underPressure: true, draftCheck: { _ in false })
            XCTAssertFalse(tab.suspended, "A silent call with both devices off still needs its document")
            _ = try await tab.web.evaluateJavaScript("document.querySelector('button').remove(); true")
            try await compatibilityWait { !tab.inMeetCall }
            await Suspension.suspendIfEligible(tab, underPressure: true, draftCheck: { _ in false })
            XCTAssertTrue(tab.suspended, "Ending the call must release the suspension exemption")
        }
    }

    func testCanceledOrDownloadedNavigationKeepsTheOriginalCall() async throws {
        try await withLoop {
            let (tab, _, _) = try await fixture("<title>Call fixture</title><button><span>call_end</span></button>")
            try await compatibilityWait { tab.inMeetCall }
            PictureInPicture.enterIfPlaying(tab)
            let panel = try XCTUnwrap(CallPopout.window(for: tab))
            let carrier = WKWebView()
            for error in [URLError(.cancelled) as NSError, NSError(domain: "WebKitErrorDomain", code: 102)] {
                // Real WebKit navigation identities, replayed without replacing the
                // source document: the canceled/download navigation never commits.
                let navigation = try XCTUnwrap(carrier.loadHTMLString("<title>Provisional</title>", baseURL: nil))
                carrier.stopLoading()
                tab.webView(tab.web, didStartProvisionalNavigation: navigation)
                XCTAssertTrue(tab.inMeetCall, "A pending load has not replaced the live call")
                tab.webView(tab.web, didFailProvisionalNavigation: navigation, withError: error)
                XCTAssertTrue(tab.inMeetCall)
                XCTAssertTrue(MediaState.shared.keepsRunning(tab))
                XCTAssertTrue(CallPopout.window(for: tab) === panel)
            }
        }
    }

    func testLeavingSplitPopsOutCallFromUnfocusedPane() async throws {
        try await withLoop {
            let (tab, window, _) = try await fixture("<title>Call fixture</title><button><span>call_end</span></button>")
            try await compatibilityWait { tab.inMeetCall }
            let store = owner(tab, window: window)
            let second = Tab(isPrivate: true), unrelated = Tab(isPrivate: true)
            store.tabs += [second, unrelated]
            store.splits = [try XCTUnwrap(Split(tabs: [tab.id, second.id]))]
            store.current = second.id
            XCTAssertNil(CallPopout.window(for: tab))
            store.current = unrelated.id
            XCTAssertNotNil(CallPopout.window(for: tab), "Every departing pane must be considered, not just the focused tab")
            store.current = second.id
            XCTAssertNil(CallPopout.window(for: tab), "Returning to either pane reveals the whole split and returns its call")
        }
    }

    func testCallFollowsSpaceAndProfileChanges() async throws {
        try await withLoop {
            let manager = ProfileManager.shared
            let previous = manager.active
            let profile = manager.create(name: "Call source"), otherProfile = manager.create(name: "Call destination")
            let source = manager.createSpace(name: "Call", in: profile.id)
            let second = manager.createSpace(name: "Other", in: profile.id)
            let destination = manager.createSpace(name: "Destination", in: otherProfile.id)
            let store = Windows.open(profile: profile, space: source, focus: true)
            let window = try XCTUnwrap(store.window)
            defer {
                window.close()
                _ = manager.delete(profile.id); _ = manager.delete(otherProfile.id)
                manager.active = previous
            }
            let tab = store.newBlankTab(focus: true)
            tab.web.loadHTMLString("<title>Call fixture</title><button><span>call_end</span></button>", baseURL: URL(string: "https://meet.google.com/abc-defg-hij"))
            try await compatibilityWait { tab.inMeetCall && tab.web.window === window && !tab.web.isHiddenOrHasHiddenAncestor }
            store.switchTo(space: second)
            XCTAssertNotNil(CallPopout.window(for: tab))
            store.switchTo(space: source)
            XCTAssertNil(CallPopout.window(for: tab))
            let arriving = try XCTUnwrap(Windows.hop(store, to: destination))
            XCTAssertNotNil(CallPopout.window(for: tab))
            XCTAssertTrue(Windows.hop(arriving, to: source) === store)
            XCTAssertNil(CallPopout.window(for: tab))
            XCTAssertTrue(tab.inMeetCall)
        }
    }
}
