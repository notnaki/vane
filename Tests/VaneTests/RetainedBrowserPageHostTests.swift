import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class RetainedBrowserPageHostTests: XCTestCase {
    private func withPage(_ body: (TabStore, NSWindow, NSView) async throws -> Void) async throws {
        TestEnvironment.prepare()
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        let store = TabStore(isPrivate: true)
        store.palette = nil
        let window = PageDisplayCountingWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = root
        store.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        var failure: (any Error)?
        do {
            try await compatibilityWait {
                NSApp.isRunning && NSApp.isActive && window.isKeyWindow
                    && window.occlusionState.contains(.visible)
            }
            try await body(store, window, root)
        } catch { failure = error }
        store.spaceGesture.monitor.remove()
        store.librarySwipeMonitor.remove()
        window.makeFirstResponder(nil)
        window.contentView = nil
        window.close()
        store.window = nil
        store.dropStashes()
        TabStore.all.removeAll { $0 === store }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Retained page loop cleanup: \(error)") }
        }
        if let failure { throw failure }
    }

    func testReplacingTheNativeSlotCannotBeUndoneByAnObsoleteSlot() async throws {
        try await withPage { store, _, root in
            let owner = RetainedBrowserPageHost(store: store, presentation: BrowserProfilePresentation())
            defer { owner.retire() }
            let first = NativeBrowserPageSlot(owner: owner)
            first.frame = NSRect(x: 40, y: 20, width: 480, height: 320)
            root.addSubview(first)
            first.configure(environment: PagePublicEnvironment(EnvironmentValues()),
                            envelope: WebCardEnvelopeSpec(topGap: 8, edgeToEdge: false, leading: 0),
                            transaction: Transaction())
            XCTAssertTrue(owner.hostingView.superview === first)
            let replacement = NativeBrowserPageSlot(owner: owner)
            replacement.frame = NSRect(x: 30, y: 15, width: 500, height: 340)
            root.addSubview(replacement)
            replacement.configure(environment: PagePublicEnvironment(EnvironmentValues()),
                                  envelope: WebCardEnvelopeSpec(topGap: 8, edgeToEdge: false, leading: 0),
                                  transaction: Transaction())
            XCTAssertTrue(owner.hostingView.superview === replacement)
            first.setFrameSize(NSSize(width: 100, height: 100))
            first.dismantle()
            XCTAssertTrue(owner.hostingView.superview === replacement,
                          "A stale slot cannot steal or dismantle a replacement page")
            XCTAssertEqual(owner.hostingView.frame, replacement.bounds)
            let newParent = NSView(frame: root.bounds)
            root.addSubview(newParent)
            newParent.addSubview(replacement)
            XCTAssertTrue(owner.hostingView.superview === replacement,
                          "The current slot must recover its own host when reparented without configure")
            owner.retire()
            replacement.setFrameSize(NSSize(width: 510, height: 350))
            XCTAssertNil(owner.hostingView.superview, "Late native geometry cannot revive a retired page")
        }
    }

    func testUnknownLibraryAdmissionUsesTheOriginalLayoutFallback() async throws {
        try await withPage { store, window, root in
            let owner = RetainedBrowserPageHost(store: store, presentation: BrowserProfilePresentation())
            defer { owner.retire() }
            let slot = NativeBrowserPageSlot(owner: owner)
            slot.frame = NSRect(x: 40, y: 20, width: 480, height: 320)
            root.addSubview(slot)
            slot.configure(environment: PagePublicEnvironment(EnvironmentValues()),
                           envelope: WebCardEnvelopeSpec(topGap: 8, edgeToEdge: false, leading: 0),
                           transaction: Transaction())
            slot.layoutSubtreeIfNeeded()
            XCTAssertFalse(owner.layoutForProfileHandoff(in: window),
                           "A mounted page with no actual Library owner proof is not an eligible fast path")
        }
    }

    func testRetainedAndInlineCardsKeepTheSamePageEnvelopeAndPixels() async throws {
        try await withPage { store, window, root in
            let presentation = BrowserProfilePresentation()
            let owner = RetainedBrowserPageHost(store: store, presentation: presentation)
            defer { owner.retire() }
            var pageBounds: CGRect?
            @MainActor func card(retained: Bool) -> AnyView {
                AnyView(WebCard(retainedPage: retained ? owner : nil, topGap: 12)
                    .environmentObject(store).environmentObject(ProfileManager.shared)
                    .environmentObject(presentation.downloads)
                    .overlayPreferenceValue(PeekContentBounds.self) { anchor in
                        GeometryReader { geometry in
                            Color.clear.onChange(of: anchor.map { geometry[$0] }, initial: true) { _, value in
                                pageBounds = value
                            }
                        }
                    })
            }
            let host = NSHostingView(rootView: card(retained: false))
            host.frame = root.bounds
            root.addSubview(host)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await compatibilityWait { pageBounds != nil }
            let inlineBounds = try XCTUnwrap(pageBounds)
            let inlinePixels = try SidebarSnapshot.pixels(in: host)
            pageBounds = nil
            host.rootView = card(retained: true)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await compatibilityWait { pageBounds != nil && owner.hostingView.window === window }
            XCTAssertEqual(try XCTUnwrap(pageBounds), inlineBounds,
                           "The retained page must use the original pre-padding Peek rectangle")
            XCTAssertEqual(try SidebarSnapshot.pixels(in: host), inlinePixels,
                           "Extracting the page must not duplicate its padding, clip, rim or empty surface")
            host.removeFromSuperview()
        }
    }

    func testPageOnlyDisplayProofIsConsumedAndLiveGestureInvalidatesIt() async throws {
        try await withPage { store, window, root in
            let presentation = BrowserProfilePresentation()
            let owner = RetainedBrowserPageHost(store: store, presentation: presentation)
            defer { owner.retire() }
            let parent = NSHostingView(rootView: BrowserWindow(pageHost: owner, presentation: presentation)
                .environmentObject(store).environmentObject(ProfileManager.shared))
            parent.frame = root.bounds
            root.addSubview(parent)
            try await compatibilityWait {
                parent.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                return owner.layoutForProfileHandoff(in: window)
            }
            XCTAssertTrue(owner.displayForProfileHandoff(in: window),
                          "An exact current page/Library receipt must authorize its one immediate display")
            XCTAssertFalse(owner.displayForProfileHandoff(in: window),
                           "A second display cannot reuse the consumed layout proof")
            try await compatibilityWait {
                parent.layoutSubtreeIfNeeded()
                return owner.layoutForProfileHandoff(in: window)
            }
            store.libraryGesture.progress = 0
            XCTAssertFalse(owner.displayForProfileHandoff(in: window),
                           "Held-at-zero logical gesture invalidates display even before another layout")
            store.libraryGesture.progress = nil
            parent.removeFromSuperview()
        }
    }

    private func admitPage(_ store: TabStore, window: NSWindow, root: NSView)
        async throws -> (RetainedBrowserPageHost, NSHostingView<some View>) {
        let presentation = BrowserProfilePresentation()
        let owner = RetainedBrowserPageHost(store: store, presentation: presentation)
        let parent = NSHostingView(rootView: BrowserWindow(pageHost: owner, presentation: presentation)
            .environmentObject(store).environmentObject(ProfileManager.shared))
        parent.frame = root.bounds
        root.addSubview(parent)
        do {
            try await compatibilityWait {
                parent.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                return owner.layoutForProfileHandoff(in: window)
            }
        } catch { owner.retire(); parent.removeFromSuperview(); throw error }
        return (owner, parent)
    }

    func testOutOfBandRootResizeCannotRestampAnUnchangedOldNativeSlot() async throws {
        try await withPage { store, window, root in
            let (owner, parent) = try await admitPage(store, window: window, root: root)
            defer { owner.retire(); parent.removeFromSuperview() }
            let before = root.frame.size
            let slotFrame = owner.hostingView.superview?.frame
            root.setFrameSize(NSSize(width: before.width + 80, height: before.height + 40))
            XCTAssertEqual(owner.hostingView.superview?.frame, slotFrame,
                           "The fixture must leave the old positive-size page slot unchanged")
            XCTAssertFalse(owner.layoutForProfileHandoff(in: window),
                           "Admission cannot mint new root bounds around stale page geometry")
            root.setFrameSize(before)
            XCTAssertFalse(owner.layoutForProfileHandoff(in: window),
                           "Returning to old bounds cannot revive proof without a normal parent commit")
        }
    }

    func testNativeGeometryOutAndBackPermanentlyRevokesTheDisplayProof() async throws {
        try await withPage { store, window, root in
            let (owner, parent) = try await admitPage(store, window: window, root: root)
            defer { owner.retire(); parent.removeFromSuperview() }
            let slot = try XCTUnwrap(owner.hostingView.superview as? NativeBrowserPageSlot)
            let before = slot.frame.size
            slot.setFrameSize(NSSize(width: before.width - 20, height: before.height))
            slot.setFrameSize(before)
            XCTAssertFalse(owner.displayForProfileHandoff(in: window),
                           "Equal final coordinates cannot restore a geometry epoch consumed by intervening changes")
        }
    }

    func testPendingPresentationAndAttachedSheetRejectBothLayoutAndDisplay() async throws {
        try await withPage { store, window, root in
            let (owner, parent) = try await admitPage(store, window: window, root: root)
            defer { owner.retire(); parent.removeFromSuperview() }
            store.liveFolderSheet = true
            XCTAssertFalse(owner.displayForProfileHandoff(in: window),
                           "A presentation opened after layout must consume the old proof and fall back")
            XCTAssertFalse(owner.layoutForProfileHandoff(in: window))
            store.liveFolderSheet = false
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            sheet.isReleasedWhenClosed = false
            window.beginSheet(sheet)
            defer { window.endSheet(sheet); sheet.close() }
            XCTAssertFalse(owner.layoutForProfileHandoff(in: window),
                           "An actual attached native sheet cannot use the page-only layout path")
            XCTAssertFalse(owner.displayForProfileHandoff(in: window))
        }
    }

    func testWindowDisplayWithoutAnAuthorizedProfileCoverUsesTheOriginalFallback() async throws {
        try await withPage { store, window, _ in
            let host = BrowserWindowHost(shown: ShownStore(store))
            window.contentView = host
            host.layoutDisplayedProfile()
            let counter = try XCTUnwrap(window as? PageDisplayCountingWindow)
            counter.displayAttempts = 0
            host.displayDisplayedProfile()
            XCTAssertEqual(counter.displayAttempts, 1,
                           "Unsupported profile display must call the original NSWindow display")
            host.displayDisplayedProfile()
            XCTAssertEqual(counter.displayAttempts, 2,
                           "A reentrant/repeated call without proof must still take the native fallback")
            window.contentView = nil
        }
    }

    func testInjectedFeedbackReceivesIntoTheEagerOwnerAndRemovalCancelsIt() async throws {
        try await withPage { store, window, root in
            let presentation = BrowserProfilePresentation()
            let host = NSHostingView(rootView: AnyView(Color.gray
                .modifier(DownloadFeedbackAnchor(target: .page))
                .modifier(DownloadFeedbackPresentation(store: store, chrome: false,
                                                       feedback: presentation.downloads))))
            host.frame = root.bounds
            root.addSubview(host)
            host.layoutSubtreeIfNeeded()
            let start = DownloadFeedback.Start(name: "owned.pdf", profileID: Profile.incognito.id, window: window)
            NotificationCenter.default.post(name: DownloadFeedback.started, object: start)
            try await compatibilityWait { presentation.downloads.start === start }
            host.rootView = AnyView(Color.clear)
            host.layoutSubtreeIfNeeded()
            try await compatibilityWait { presentation.downloads.start == nil }
            NotificationCenter.default.post(name: DownloadFeedback.started, object: start)
            XCTAssertNil(presentation.downloads.start,
                         "A removed parent must not leave a second page-root notification receiver")
            host.removeFromSuperview()
        }
    }
}

@MainActor private final class PageDisplayCountingWindow: NSWindow {
    var displayAttempts = 0
    override func displayIfNeeded() {
        displayAttempts += 1
        super.displayIfNeeded()
    }
}
