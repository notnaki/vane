import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class DraftProtectionTests: XCTestCase {
    private func fixture(_ html: String, isPrivate: Bool = true, profileID: UUID = UUID(), url: URL = URL(string: "https://draft.example.test/editor")!, configure: (WKWebView) -> Void = { _ in }) async throws -> Tab {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        WebKitStartup.prepare()
        let tab = Tab(isPrivate: isPrivate, profileID: profileID)
        addTeardownBlock { @MainActor in tab.tearDown() }
        configure(tab.web)
        tab.web.loadSimulatedRequest(URLRequest(url: url),
                                    responseHTML: "<!doctype html><body>" + html + "</body>")
        try await compatibilityWait { !tab.web.isLoading && tab.web.title == "Draft fixture" }
        return tab
    }

    private func edit(_ tab: Tab, _ js: String) async throws {
        _ = try await tab.web.evaluateJavaScript(js)
    }

    private func expectDraft(_ tab: Tab, _ expected: Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let actual = await tab.hasUnsubmittedInput()
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    func testClearingPrefilledInputIsWorkAndRevertingReleasesIt() async throws {
        let tab = try await fixture("<title>Draft fixture</title><input id=field value=original><textarea id=area>original</textarea>")
        await expectDraft(tab, false)
        try await edit(tab, "field.value=''; field.dispatchEvent(new Event('input',{bubbles:true}))")
        await expectDraft(tab, true)
        try await edit(tab, "field.value='original'; area.value='draft'")
        await expectDraft(tab, true)
        try await edit(tab, "area.value='original'")
        await expectDraft(tab, false)
    }

    func testUntouchedRichEditorCanSleepButEditedEditorCannot() async throws {
        let tab = try await fixture("<title>Draft fixture</title><div id=editor contenteditable=true><b>original</b></div>")
        await expectDraft(tab, false)
        try await edit(tab, "editor.innerHTML='<i>draft</i>'; editor.dispatchEvent(new Event('input',{bubbles:true}))")
        await expectDraft(tab, true)
        try await edit(tab, "editor.innerHTML='<b>original</b>'")
        await expectDraft(tab, false)
    }

    func testDynamicShadowFieldsAndEmbeddedFramesAreProtected() async throws {
        let tab = try await fixture("<title>Draft fixture</title><div id=host></div><iframe id=child srcdoc='<textarea id=area></textarea>'></iframe>")
        try await compatibilityWait {
            (try? await tab.web.evaluateJavaScript("!!child.contentDocument.getElementById('area')")) as? Bool == true
        }
        await expectDraft(tab, false)
        try await edit(tab, "child.contentDocument.getElementById('area').value='draft'")
        await expectDraft(tab, true)
        try await edit(tab, "child.contentDocument.getElementById('area').value=''; host.attachShadow({mode:'open'}).innerHTML='<input id=shadow>'")
        try await edit(tab, "host.shadowRoot.querySelector('input').value='draft'")
        await expectDraft(tab, true)
    }

    func testSubmitEventsDoNotProveSaveSuccessAndResetReleasesProtection() async throws {
        let tab = try await fixture("<title>Draft fixture</title><form id=form><input id=field></form>")
        try await edit(tab, "field.value='draft'; form.addEventListener('submit',e=>e.preventDefault(),{once:true}); form.dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}))")
        await expectDraft(tab, true)
        try await edit(tab, "form.reset()")
        await expectDraft(tab, false)
        try await edit(tab, "field.value='sent'; form.dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}))")
        await expectDraft(tab, true)
        try await edit(tab, "field.value='another draft'")
        await expectDraft(tab, true)
    }

    func testSPAURLChangeKeepsDynamicDraft() async throws {
        let tab = try await fixture("<title>Draft fixture</title><main id=app></main>")
        try await edit(tab, "app.innerHTML='<textarea id=field></textarea>'; history.pushState({},'', '/compose')")
        try await edit(tab, "field.value='draft'")
        await expectDraft(tab, true)
    }
    func testCrossOriginFrameDraftAndRemovedFrameCanBecomeEligibleAgain() async throws {
        let server = try CompatibilityServer()
        defer { server.stop() }
        try await compatibilityWait { server.port != nil }
        server.pages["/child"] = "<textarea id=field></textarea><script>addEventListener('message',e=>{field.value=e.data;field.dispatchEvent(new Event('input',{bubbles:true}));parent.postMessage('ready','*')});parent.postMessage('ready','*')</script>"
        let child = try server.url("/child", host: "localhost")
        let tab = try await fixture("<title>Draft fixture</title><script>window.ready=0;addEventListener('message',()=>window.ready++)</script><iframe id=child src='\(child)'></iframe>", url: try server.url("/parent"))
        try await compatibilityWait { (try? await tab.web.evaluateJavaScript("window.ready>0")) as? Bool == true }
        await expectDraft(tab, false)
        try await edit(tab, "child.contentWindow.postMessage('draft','*')")
        try await compatibilityWait { (try? await tab.web.evaluateJavaScript("window.ready>1")) as? Bool == true }
        await expectDraft(tab, true)
        try await edit(tab, "child.remove()")
        // A detached frame can conservatively defer one pass; it must not pin the page forever.
        try await compatibilityWait { !(await tab.hasUnsubmittedInput()) }
    }

    func testTabStashAndWindowOwnershipKeepTheLiveDraft() async throws {
        let profile = UUID()
        let first = TabStore(profileID: profile, session: [])
        let second = TabStore(profileID: profile, session: [])
        first.sharingReady = false; second.sharingReady = false
        defer {
            TabStore.all.removeAll { $0 === first || $0 === second }
            SharedTabs.release(first.everyTab + second.everyTab)
        }
        let tab = try await fixture("<title>Draft fixture</title><textarea id=field></textarea>", isPrivate: false, profileID: profile)
        let web = tab.web
        first.tabs = [tab]; second.tabs = [tab]
        first.current = tab.id; second.current = tab.id
        try await edit(tab, "field.value='draft'")
        first.current = nil
        let space = UUID()
        first.stashes[space] = Stash(tabs: [tab], pins: Pins(), todayShape: Pins(), splits: [], current: tab.id, fingerprint: "")
        first.tabs = []
        SharedTabs.release([tab], excluding: first)
        XCTAssertTrue(tab.existingWeb === web)
        second.current = nil
        await Suspension.suspendIfEligible(tab, underPressure: true)
        XCTAssertFalse(tab.suspended)
        first.tabs = first.stashes.removeValue(forKey: space)!.tabs
        first.current = tab.id
        XCTAssertTrue(tab.existingWeb === web)
        let value = try await web.evaluateJavaScript("field.value") as? String
        XCTAssertEqual(value, "draft")
        await expectDraft(tab, true)
    }

    private func backgroundFixture() async throws -> (TabStore, Tab) {
        let profile = UUID()
        let store = TabStore(profileID: profile, session: [])
        store.sharingReady = false
        let tab = try await fixture("<title>Draft fixture</title><textarea id=field></textarea>", isPrivate: false, profileID: profile)
        store.tabs = [tab]; store.current = nil
        tab.lastActive = .distantPast
        let previous = Prefs.suspendTabs
        Prefs.suspendTabs = true
        addTeardownBlock { @MainActor in
            Prefs.suspendTabs = previous
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(store.everyTab)
        }
        return (store, tab)
    }

    func testSameURLReplacementWhileCheckPendingCannotSuspendNewDraft() async throws {
        let (_, tab) = try await backgroundFixture()
        let web = tab.web
        await Suspension.suspendIfEligible(tab, underPressure: true, draftCheck: { tab in
            web.loadSimulatedRequest(URLRequest(url: web.url!), responseHTML: "<title>Replacement</title><textarea>new document</textarea>")
            try? await compatibilityWait { !web.isLoading && web.title == "Replacement" }
            return false // the clean result belonged to the old document
        })
        XCTAssertFalse(tab.suspended)
        XCTAssertTrue(tab.existingWeb === web)
    }

    func testTabVisitedAndLeftWhileCheckPendingCannotSuspendUnderPressure() async throws {
        let (store, tab) = try await backgroundFixture()
        await Suspension.suspendIfEligible(tab, underPressure: true, draftCheck: { tab in
            store.current = tab.id
            store.current = nil
            return false
        })
        XCTAssertFalse(tab.suspended)
    }

    func testTabRemovedFromAllOwnersWhileCheckPendingCannotBeParked() async throws {
        let (store, tab) = try await backgroundFixture()
        await Suspension.suspendIfEligible(tab, underPressure: true, draftCheck: { _ in
            store.tabs = []
            return false
        })
        XCTAssertFalse(tab.suspended)
    }

    private func isolated(_ web: WKWebView, _ source: String, frame: WKFrameInfo? = nil) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            web.evaluateJavaScript(source, in: frame, in: DraftProtection.world) { _ in continuation.resume() }
        }
    }

    func testDetectionFailureDefersSuspensionAndNextSuccessfulProbeCanSleep() async throws {
        let (_, tab) = try await backgroundFixture()
        await isolated(tab.web, "globalThis.__fixtureDraft=globalThis.__vaneDraft; globalThis.__vaneDraft=null")
        await Suspension.suspendIfEligible(tab, underPressure: true)
        XCTAssertFalse(tab.suspended)
        await isolated(tab.web, "globalThis.__vaneDraft=globalThis.__fixtureDraft")
        await Suspension.suspendIfEligible(tab, underPressure: true)
        XCTAssertTrue(tab.suspended)
    }

    func testOverlappingPressureAndIdleChecksCannotUseASecondCleanResult() async throws {
        let (_, tab) = try await backgroundFixture()
        var pending: CheckedContinuation<Bool, Never>?
        let first = Task { @MainActor in
            await Suspension.suspendIfEligible(tab, underPressure: true, draftCheck: { _ in
                await withCheckedContinuation { pending = $0 }
            })
        }
        try await compatibilityWait { pending != nil }
        await Suspension.suspendIfEligible(tab, underPressure: false, draftCheck: { _ in false })
        XCTAssertFalse(tab.suspended)
        pending?.resume(returning: true)
        await first.value
        XCTAssertFalse(tab.suspended)
        await Suspension.suspendIfEligible(tab, underPressure: true, draftCheck: { _ in false })
        XCTAssertTrue(tab.suspended, "An uncertain completed check must release its in-flight slot")
    }

    func testSelectionAndDisabledPolicyDuringProbePreventSuspension() async throws {
        let (store, tab) = try await backgroundFixture()
        await Suspension.suspendIfEligible(tab, underPressure: true, draftCheck: { tab in
            store.current = tab.id
            return false
        })
        XCTAssertFalse(tab.suspended)
        store.current = nil
        await Suspension.suspendIfEligible(tab, underPressure: true, draftCheck: { _ in
            Prefs.suspendTabs = false
            return false
        })
        XCTAssertFalse(tab.suspended)
    }

    func testPrivateDraftAndRegularProfileRemainSeparate() async throws {
        let (_, regular) = try await backgroundFixture()
        let privateTab = try await fixture("<title>Draft fixture</title><textarea id=field></textarea>")
        try await edit(privateTab, "field.value='private draft'")
        await expectDraft(privateTab, true)
        await expectDraft(regular, false)
        await Suspension.suspendIfEligible(privateTab, underPressure: true)
        XCTAssertFalse(privateTab.suspended)
        XCTAssertFalse(privateTab.web.configuration.websiteDataStore.isPersistent)
        await Suspension.suspendIfEligible(regular, underPressure: true)
        XCTAssertTrue(regular.suspended)
    }

    func testSuccessfulSubmissionNavigatesToACleanDocument() async throws {
        let server = try CompatibilityServer()
        defer { server.stop() }
        try await compatibilityWait { server.port != nil }
        let url = try server.url("/form")
        let tab = try await fixture("<title>Draft fixture</title><form id=form method=post action='/submitted'><input id=field name=message></form>", url: url)
        try await edit(tab, "field.value='synthetic draft'")
        await expectDraft(tab, true)
        try await edit(tab, "form.requestSubmit()")
        try await compatibilityWait { !tab.web.isLoading && tab.web.title == "Upload received" }
        await expectDraft(tab, false)
        XCTAssertEqual(server.submissions.count, 1)
    }

    func testActualSpaceRoundTripKeepsSameDocumentAndDraft() async throws {
        let profile = ProfileManager.shared.create(name: "Draft Space fixture").id
        let spaces = [Space(name: "Compose", profileID: profile), Space(name: "Browse", profileID: profile)]
        XCTAssertTrue(ProfileManager.shared.saveSpaces(spaces, for: profile))
        let store = TabStore(profileID: profile, space: spaces[0], session: [])
        let tab = try await fixture("<title>Draft fixture</title><textarea id=field></textarea>", isPrivate: false, profileID: profile)
        let web = tab.web
        store.tabs = [tab]; store.current = tab.id
        addTeardownBlock { @MainActor in
            let tabs = store.everyTab
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            ProfileManager.shared.delete(profile)
        }
        try await edit(tab, "field.value='draft'")
        store.switchTo(space: spaces[1])
        XCTAssertTrue(store.stashes[spaces[0].id]?.tabs.contains { $0 === tab } == true)
        await Suspension.suspendIfEligible(tab, underPressure: true)
        XCTAssertFalse(tab.suspended)
        store.switchTo(space: spaces[0])
        XCTAssertTrue(store.active === tab)
        XCTAssertTrue(tab.existingWeb === web)
        let value = try await web.evaluateJavaScript("field.value") as? String
        XCTAssertEqual(value, "draft")
    }

    private final class FixtureWindow: NSWindow {
        var key = false
        override var isKeyWindow: Bool { key }
    }

    func testSharedWindowOwnershipTransferRetainsLiveEditor() async throws {
        let profile = UUID()
        let first = TabStore(profileID: profile, session: [])
        let second = TabStore(profileID: profile, session: [])
        first.sharingReady = false; second.sharingReady = false
        let a = FixtureWindow(contentRect: NSRect(x: -4000, y: -4000, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let b = FixtureWindow(contentRect: a.frame, styleMask: [.titled], backing: .buffered, defer: false)
        a.isReleasedWhenClosed = false; b.isReleasedWhenClosed = false
        first.window = a; second.window = b
        let tab = try await fixture("<title>Draft fixture</title><div id=editor contenteditable=true>original</div>", isPrivate: false, profileID: profile)
        let web = tab.web
        first.tabs = [tab]; second.tabs = [tab]
        first.current = tab.id; second.current = tab.id
        tab.presentationOwner = first.windowID
        let host = WebHost(nil)
        a.contentView = host
        host.show(web)
        a.orderFront(nil); b.orderFront(nil)
        addTeardownBlock { @MainActor in
            first.window = nil; second.window = nil
            a.close(); b.close()
            TabStore.all.removeAll { $0 === first || $0 === second }
            SharedTabs.release([tab])
        }
        try await edit(tab, "editor.dispatchEvent(new InputEvent('beforeinput',{bubbles:true})); editor.textContent='draft'; editor.dispatchEvent(new InputEvent('input',{bubbles:true}))")
        b.key = true
        SharedTabs.refreshPresentation()
        try await compatibilityWait { tab.presentationOwner == second.windowID }
        await Suspension.suspendIfEligible(tab, underPressure: true)
        XCTAssertFalse(tab.suspended)
        XCTAssertTrue(tab.existingWeb === web)
        let value = try await web.evaluateJavaScript("editor.textContent") as? String
        XCTAssertEqual(value, "draft")
        await expectDraft(tab, true)
    }

    func testPinnedSharedPageOnAnotherWindowsStripIsProtectedDespiteStash() async throws {
        let (store, tab) = try await backgroundFixture()
        tab.kind = .pinned
        let peer = TabStore(profileID: store.profileID, session: [])
        peer.sharingReady = false
        peer.stashes[UUID()] = Stash(tabs: [tab], pins: Pins(), todayShape: Pins(), splits: [], current: nil, fingerprint: "")
        addTeardownBlock { @MainActor in TabStore.all.removeAll { $0 === peer } }
        await Suspension.suspendIfEligible(tab, underPressure: true, draftCheck: { _ in false })
        XCTAssertFalse(tab.suspended)
    }

    func testBatterySaverStoppingWhileProbePendingRestoresIdleThreshold() async throws {
        let (_, tab) = try await backgroundFixture()
        let oldMode = BatterySaver.shared.mode
        let oldLimit = Prefs.suspendAfter
        defer { BatterySaver.shared.setMode(oldMode); Prefs.suspendAfter = oldLimit }
        Prefs.suspendAfter = 1800
        tab.lastActive = .now.addingTimeInterval(-301)
        BatterySaver.shared.setMode(.alwaysOn)
        await Suspension.suspendIfEligible(tab, underPressure: false, draftCheck: { _ in
            BatterySaver.shared.setMode(.off)
            return false
        })
        XCTAssertFalse(tab.suspended)
        tab.lastActive = .distantPast
        await Suspension.suspendIfEligible(tab, underPressure: false)
        XCTAssertTrue(tab.suspended)
    }

    func testPageGlobalsCannotForgeCleanDraftResult() async throws {
        let tab = try await fixture("<title>Draft fixture</title><textarea id=field></textarea>")
        try await edit(tab, "field.value='draft'; globalThis.__vaneDraft={check:()=>({dirty:false})}")
        await expectDraft(tab, true)
    }

    func testAsynchronouslyHydratedRichEditorCanSleepUntilUserEdits() async throws {
        let tab = try await fixture("<title>Draft fixture</title><div id=editor contenteditable=true></div>")
        await expectDraft(tab, false)
        try await edit(tab, "editor.innerHTML='<p>saved content</p>'")
        await expectDraft(tab, false)
        try await edit(tab, "editor.dispatchEvent(new InputEvent('beforeinput',{bubbles:true,inputType:'insertText'})); editor.innerHTML='<p>new draft</p>'; editor.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText'}))")
        await expectDraft(tab, true)
        try await edit(tab, "editor.innerHTML='<p>saved content</p>'")
        await expectDraft(tab, false)
    }

    func testSyntheticResetEventCannotAcknowledgeUnchangedDraft() async throws {
        let tab = try await fixture("<title>Draft fixture</title><form id=form><input id=field></form>")
        try await edit(tab, "field.value='draft'; form.dispatchEvent(new Event('reset',{bubbles:true,cancelable:true}))")
        await expectDraft(tab, true)
        try await edit(tab, "form.reset()")
        await expectDraft(tab, false)
    }

    private final class FrameCapture: NSObject, WKScriptMessageHandler {
        var child: WKFrameInfo?
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if !message.frameInfo.isMainFrame { child = message.frameInfo }
        }
    }

    func testTransientChildDetectionFailureDoesNotForgetLiveFrameForever() async throws {
        let capture = FrameCapture()
        let tab = try await fixture("<title>Draft fixture</title><iframe srcdoc='<textarea></textarea>'></iframe>", configure: { web in
            let controller = web.configuration.userContentController
            controller.add(capture, contentWorld: DraftProtection.world, name: "fixtureFrame")
            controller.addUserScript(WKUserScript(source: "webkit.messageHandlers.fixtureFrame.postMessage(true)", injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: DraftProtection.world))
        })
        addTeardownBlock { @MainActor in
            tab.existingWeb?.configuration.userContentController.removeScriptMessageHandler(forName: "fixtureFrame", contentWorld: DraftProtection.world)
        }
        try await compatibilityWait { capture.child != nil }
        let child = try XCTUnwrap(capture.child)
        await expectDraft(tab, false)
        await isolated(tab.web, "globalThis.__fixtureDraft=globalThis.__vaneDraft;globalThis.__vaneDraft=null", frame: child)
        await expectDraft(tab, true)
        await isolated(tab.web, "globalThis.__vaneDraft=globalThis.__fixtureDraft", frame: child)
        await expectDraft(tab, false)
    }

    func testLateOutgoingRootReportCannotForgetCleanIncomingChildren() async throws {
        let tab = try await fixture("<title>Draft fixture</title><iframe srcdoc='<textarea></textarea>'></iframe>")
        try await compatibilityWait { !(await tab.hasUnsubmittedInput()) }
        await isolated(tab.web, "webkit.messageHandlers.vanedraft.postMessage({token:'outgoing-document',dirty:false})")
        try await compatibilityWait { !(await tab.hasUnsubmittedInput()) }
    }

    func testInputOnlyRichEditorKeepsBaselineAcrossMutationMicrotask() async throws {
        let tab = try await fixture("<title>Draft fixture</title><div id=editor contenteditable=true><p>saved</p></div>")
        await expectDraft(tab, false)
        try await edit(tab, "editor.innerHTML='<p>draft</p>';queueMicrotask(()=>editor.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'formatBold'})))")
        await expectDraft(tab, true)
        try await edit(tab, "editor.innerHTML='<p>saved</p>'")
        await expectDraft(tab, false)
    }

    func testChildDraftChangedAfterFirstSampleIsRevalidated() async throws {
        let tab = try await fixture("<title>Draft fixture</title><iframe srcdoc='<textarea id=field></textarea>'></iframe>")
        try await compatibilityWait { !(await tab.hasUnsubmittedInput()) }
        await isolated(tab.web, "let original=__vaneDraft.check;let calls=0;__vaneDraft.check=()=>{if(++calls===2) document.querySelector('iframe').contentDocument.querySelector('textarea').value='draft';return original()}")
        await expectDraft(tab, true)
    }

    func testNestedFrameCountChangesDuringRevalidationDeferSuspension() async throws {
        let capture = FrameCapture()
        let tab = try await fixture("<title>Draft fixture</title><iframe srcdoc='<textarea></textarea>'></iframe>", configure: { web in
            let controller = web.configuration.userContentController
            controller.add(capture, contentWorld: DraftProtection.world, name: "fixtureFrame")
            controller.addUserScript(WKUserScript(source: "webkit.messageHandlers.fixtureFrame.postMessage(true)", injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: DraftProtection.world))
        })
        addTeardownBlock { @MainActor in
            tab.existingWeb?.configuration.userContentController.removeScriptMessageHandler(forName: "fixtureFrame", contentWorld: DraftProtection.world)
        }
        try await compatibilityWait { capture.child != nil }
        let child = try XCTUnwrap(capture.child)
        await expectDraft(tab, false)
        // Model a new descendant whose own detector has not registered yet.
        await isolated(tab.web, "let original=__vaneDraft.check;let calls=0;__vaneDraft.check=()=>{let result=original();if(++calls===2) result.children++;return result}", frame: child)
        await expectDraft(tab, true)
    }

    func testCriticalPressureEntryPointPreservesDraftAndReclaimsCleanPeer() async throws {
        let (_, draft) = try await backgroundFixture()
        let (_, clean) = try await backgroundFixture()
        try await edit(draft, "field.value='draft'")
        Suspension.relieve(critical: true)
        try await compatibilityWait { clean.suspended }
        await expectDraft(draft, true)
        XCTAssertFalse(draft.suspended)
        let value = try await draft.web.evaluateJavaScript("field.value") as? String
        XCTAssertEqual(value, "draft")
    }

}
