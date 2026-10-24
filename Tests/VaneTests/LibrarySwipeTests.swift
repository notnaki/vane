import AppKit
import Combine
import SwiftUI
import XCTest
@testable import vane

@MainActor final class LibrarySwipeTests: XCTestCase {
    private func fixture(withSpaces: Bool = false) -> (TabStore, LibraryScrollWindow, LibrarySwipeMonitor) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let manager = ProfileManager.shared
        let profile = withSpaces ? manager.profiles[0].id : UUID()
        let oldSpaces = withSpaces ? manager.spaces(for: profile) : []
        let first = Space(name: "First", profileID: profile)
        if withSpaces {
            XCTAssertTrue(manager.saveSpaces([first, Space(name: "Second", profileID: profile)], for: profile))
        }
        let store = TabStore(profileID: profile, space: first, session: [])
        let oldLibrary = (Library.shared.section, Library.shared.query,
                          Library.shared.littleArcOnly, Library.shared.completedOnly)
        let window = LibraryScrollWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                         styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        store.libraryOpen = true
        let monitor = store.librarySwipeMonitor
        monitor.install(store)
        addTeardownBlock { @MainActor in
            monitor.remove()
            store.window = nil
            window.close()
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile)
            if withSpaces { XCTAssertTrue(manager.saveSpaces(oldSpaces, for: profile)) }
            Library.open(oldLibrary.0, in: store)
            store.libraryOpen = false
            Library.shared.query = oldLibrary.1
            Library.shared.littleArcOnly = oldLibrary.2
            Library.shared.completedOnly = oldLibrary.3
        }
        return (store, window, monitor)
    }

    private func send(_ window: NSWindow, point: NSPoint = NSPoint(x: 100, y: 350),
                      dx: CGFloat = 0, dy: CGFloat = 0, phase: NSEvent.Phase = .changed,
                      momentum: NSEvent.Phase = [], precise: Bool = true, inverted: Bool = true,
                      time: TimeInterval = 1) {
        NSApplication.shared.sendEvent(LibraryScrollEvent(window: window, point: point,
            dx: dx, dy: dy, phase: phase, momentum: momentum, precise: precise, inverted: inverted, time: time))
    }

    func testOriginalShortLibraryDragsReturnAtAnySpeed() {
        let (store, window, _) = fixture(withSpaces: true)
        for initiallyOpen in [false, true] {
            for (interval, shouldCommit) in [(0.008, false), (0.2, false)] {
                store.libraryOpen = initiallyOpen
                let delta: CGFloat = initiallyOpen ? -20 : 20
                send(window, phase: .began, time: 1)
                send(window, dx: delta, time: 1 + interval)
                send(window, dx: delta, time: 1 + 2 * interval)
                XCTAssertEqual(store.libraryOpen, initiallyOpen)
                send(window, phase: .ended, time: 1 + 2 * interval + 0.001)
                XCTAssertEqual(store.libraryOpen, shouldCommit ? !initiallyOpen : initiallyOpen,
                               "Short flicks must carry their intent in either direction")
            }
        }
    }

    func testSubpixelHorizontalWobbleReleasesLibraryToVerticalScrolling() {
        let (store, window, _) = fixture(withSpaces: true)
        for open in [true, false] {
            store.libraryOpen = open
            let before = window.scrolls
            send(window, phase: .began)
            send(window, dx: open ? -0.2 : 0.2, dy: 0.1)
            XCTAssertNil(store.librarySwipeProgress)
            send(window, dy: 12)
            XCTAssertNil(store.librarySwipeProgress)
            XCTAssertEqual(store.libraryOpen, open)
            XCTAssertEqual(window.scrolls, before + 3)
            send(window, phase: .ended)
        }
    }

    func testOriginalLibraryAxisLockAcceptsHorizontalTravelAfterStartupNoise() {
        let saver = BatterySaver.shared
        let previousMode = saver.mode
        defer { saver.setMode(previousMode) }
        let (store, window, monitor) = fixture(withSpaces: true)
        for mode: BatterySaver.Mode in [.off, .alwaysOn] {
            saver.setMode(mode)
            for open in [false, true] {
                for (dx, dy): (CGFloat, CGFloat) in [(0, 0.5), (0.1, 0.2), (-0.2, 0.1)] {
                    monitor.remove()
                    monitor.install(store)
                    store.libraryOpen = open
                    send(window, phase: .began)
                    send(window, dx: dx, dy: dy)
                    XCTAssertNil(store.librarySwipeProgress)
                    let event = LibraryScrollEvent(window: window, point: NSPoint(x: 100, y: 350),
                        dx: open ? -12 : 12, dy: 0, phase: .changed, momentum: [],
                        precise: true, inverted: true, time: 1)
                    XCTAssertNil(monitor.handle(event, in: store),
                                 "Startup noise must not reject a deliberate horizontal drag")
                    if Motion.reduced {
                        XCTAssertNil(store.librarySwipeProgress)
                    } else {
                        XCTAssertNotNil(store.librarySwipeProgress)
                    }
                }
            }
        }
    }

    func testClosingMountedLibrarySearchReturnsKeyboardToPage() async throws {
        let (store, window, _) = fixture(withSpaces: true)
        let tab = store.newBlankTab(loading: URL(string: "about:blank"))
        store.palette = nil
        let host = NSHostingView(rootView: BrowserWindow().environmentObject(store)
            .environmentObject(ProfileManager.shared))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        Library.open(.downloads, in: store)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        func search(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap { search($0) }.first
        }
        let field = try XCTUnwrap(search(host))
        for _ in 0..<50 where !(window.firstResponder is NSTextView) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(window.firstResponder is NSTextView)
        // A departing panel stays enabled while its native/SwiftUI landing is in flight.
        // Hold that presentation to cover delayed or interrupted completion.
        store.librarySwipeProgress = 0.5
        Library.close(store)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNotNil(field.superview, "The prepared panel remains mounted")
        let responder = window.firstResponder as? NSView
        XCTAssertTrue(responder === tab.web || responder?.isDescendant(of: tab.web) == true,
                      "The invisible search field must release page keyboard input; holder=\(String(describing: window.firstResponder)) page=\(String(describing: store.activePageResponder)) webWindow=\(tab.web.window != nil) palette=\(store.palette != nil)")
    }

    func testOpeningEaselReleasesDepartingLibrarySearchFocus() async throws {
        let (store, window, _) = fixture(withSpaces: true)
        _ = store.newBlankTab(loading: URL(string: "about:blank"))
        store.palette = nil
        let host = NSHostingView(rootView: BrowserWindow().environmentObject(store)
            .environmentObject(ProfileManager.shared))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        Library.open(.easels, in: store)
        host.layoutSubtreeIfNeeded()
        func search(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField,
               field.placeholderString?.contains("Search Easels") == true { return field }
            return view.subviews.lazy.compactMap { search($0) }.first
        }
        let focusDeadline = ProcessInfo.processInfo.systemUptime + 1
        while (search(host)?.currentEditor() == nil), ProcessInfo.processInfo.systemUptime < focusDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let field = try XCTUnwrap(search(host))
        XCTAssertTrue(field.currentEditor() === window.firstResponder,
                      "The real Easel search autofocus must own the field editor first")
        store.librarySwipeProgress = 0.5
        let opened = await store.openEaselAsync(create: true)
        let tab = try XCTUnwrap(opened)
        let boardID = try XCTUnwrap(tab.easelID)
        addTeardownBlock { @MainActor in
            try? await EaselStore.shared(profileID: store.profileID, directory: Store.directory).deleteAsync(boardID)
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(store.libraryOpen)
        XCTAssertNotNil(field.superview, "The departing search remains mounted during landing")
        let page = try XCTUnwrap(store.activePageResponder)
        let responder = window.firstResponder as? NSView
        XCTAssertTrue(responder === page || responder?.isDescendant(of: page) == true,
                      "Opening the board must return keyboard input to its Easel page; holder=\(String(describing: window.firstResponder))")
        let holder = window.firstResponder
        Library.focusSearch()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(window.firstResponder === holder,
                      "A delayed focus token must not refocus the logically closed Easel search")
    }

    func testReopeningMountedDownloadAndMediaPanesRefreshesMissingFiles() async throws {
        let (store, window, _) = fixture(withSpaces: true)
        let downloads = Downloads.manager(for: store.profileID)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = NSHostingView(rootView: LibraryPanel().environmentObject(store))
        window.contentView = host
        defer { window.contentView = nil }
        for section: LibrarySection in [.downloads, .media] {
            let file = directory.appendingPathComponent(UUID().uuidString + ".png")
            try Data([1]).write(to: file)
            let item = downloads.add(.init(name: file.lastPathComponent, destination: file, state: "done"))
            defer { downloads.forget(item) }
            Library.open(section, in: store)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(item.status, .done)
            Library.close(store)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            try FileManager.default.removeItem(at: file)
            Library.open(section, in: store)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(item.status, .missing, "A mounted pane must refresh on logical reopen")
        }
    }

    func testLibraryIsLaidOutBeforeFirstDragSample() async throws {
        let (store, window, monitor) = fixture(withSpaces: true)
        Library.open(.downloads, in: store)
        store.libraryOpen = false
        store.sidebarShown = true
        store.palette = nil
        let host = NSHostingView(rootView: BrowserWindow().environmentObject(store)
            .environmentObject(ProfileManager.shared))
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let prepared = try XCTUnwrap(monitor.presentationView,
                                    "The panel must be mounted before the first input")
        send(window, phase: .began)
        for delta: CGFloat in [12, 3, 3, 3, 3] {
            let start = ProcessInfo.processInfo.systemUptime
            send(window, dx: delta)
            host.layoutSubtreeIfNeeded()
            print("LIBRARY_INITIAL_LAYOUT delta=\(delta) seconds=\(ProcessInfo.processInfo.systemUptime - start)")
            XCTAssertTrue(monitor.presentationView === prepared)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testLibraryDragMovesThePageWithoutResizingWebKitForEachSample() async throws {
        try XCTSkipIf(Motion.reduced, "Requires interactive navigation")
        let (store, window, _) = fixture(withSpaces: true)
        Library.open(.downloads, in: store)
        store.libraryOpen = false
        store.sidebarShown = true
        let tab = store.newBlankTab(loading: URL(string: "about:blank"))
        store.palette = nil
        let host = NSHostingView(rootView: BrowserWindow().environmentObject(store)
            .environmentObject(ProfileManager.shared))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(100))
        let initialWidth = tab.web.bounds.width
        let initialX = tab.web.convert(.zero, to: host).x
        XCTAssertGreaterThan(initialWidth, 100)
        send(window, phase: .began)
        send(window, dx: 40)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(tab.web.bounds.width, initialWidth, accuracy: 1,
                       "Finger tracking must translate the page, without repeated WebKit reflow")
        XCTAssertGreaterThan(tab.web.convert(.zero, to: host).x, initialX + 5,
                             "The stable page must still move with the navigation")
        send(window, dx: 40)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(tab.web.bounds.width, initialWidth, accuracy: 1)
        send(window, phase: .ended)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(store.librarySwipeProgress)
        XCTAssertNil(store.libraryGesture.pageWidth)
        XCTAssertLessThan(tab.web.bounds.width, initialWidth - 50,
                          "Apply the destination page width once the navigation settles")
    }

    func testFloatingSidebarLibraryLandingKeepsInnerWebWidthFixed() async throws {
        try XCTSkipIf(Motion.reduced, "Requires animated navigation")
        let (store, window, _) = fixture(withSpaces: true)
        Library.open(.downloads, in: store)
        store.sidebarShown = false
        let tab = store.newBlankTab(loading: URL(string: "about:blank"))
        store.palette = nil
        let host = NSHostingView(rootView: BrowserWindow().environmentObject(store)
            .environmentObject(ProfileManager.shared))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(100))
        let width = tab.web.bounds.width
        send(window, phase: .began)
        send(window, dx: -80)
        try await Task.sleep(for: .milliseconds(40))
        send(window, phase: .ended)
        XCTAssertFalse(store.libraryOpen)
        var landingSamples = 0
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(30))
            if store.libraryGesture.pageWidth != nil {
                landingSamples += 1
                XCTAssertEqual(tab.web.bounds.width, width, accuracy: 0.5,
                               "The floating card's inner padding must stay fixed through landing")
            }
        }
        XCTAssertGreaterThan(landingSamples, 0, "Inspect the page while its landing is in progress")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(store.libraryGesture.pageWidth)
        XCTAssertNil(store.libraryGesture.pageLeadingInset)
        XCTAssertGreaterThan(tab.web.bounds.width, width + 50)
    }

    func testImmediateLibraryReleaseStillShowsIntermediatePositions() async throws {
        try XCTSkipIf(Motion.reduced, "Requires animated navigation")
        let (store, window, monitor) = fixture(withSpaces: true)
        Library.open(.downloads, in: store)
        store.libraryOpen = false
        store.sidebarShown = true
        store.palette = nil
        let host = NSHostingView(rootView: BrowserWindow().environmentObject(store)
            .environmentObject(ProfileManager.shared))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(80))
        send(window, phase: .began, time: 1)
        send(window, dx: 40, time: 1.008)
        send(window, dx: 40, time: 1.016)
        send(window, phase: .ended, time: 1.017) // No render turn before the fast release.
        try await Task.sleep(for: .milliseconds(60))
        let marker = try XCTUnwrap(monitor.presentationView)
        func x() throws -> CGFloat {
            try XCTUnwrap(marker.layer?.presentation()).convert(.zero,
                to: host.layer?.presentation()).x
        }
        let moving = try x()
        XCTAssertLessThan(moving, -5, "A quick release must not mount directly at the endpoint")
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertGreaterThan(try x(), moving + 5)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(try x(), 0, accuracy: 1)
    }

    func testFingerUpdatesDoNotInvalidateBrowserState() throws {
        try XCTSkipIf(Motion.reduced, "Requires interactive presentation")
        let (store, window, _) = fixture(withSpaces: true)
        var publications = 0
        let observation = store.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        send(window, phase: .began)
        send(window, dx: -15)
        for _ in 0..<20 { send(window, dx: -3) }
        XCTAssertNotNil(store.librarySwipeProgress)
        XCTAssertEqual(publications, 0,
                       "Finger samples should update presentation without invalidating the browser and every tab row")
    }

    /// Run separately with VANE_UI_PERFORMANCE=1. Timings are diagnostic rather than
    /// machine-dependent assertions; the ordinary test above guards the invalidation boundary.
    func testPopulatedArchiveSwipeTiming() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_UI_PERFORMANCE"] == "1")
        let saver = BatterySaver.shared
        let previousMode = saver.mode
        saver.setMode(.off)
        defer { saver.setMode(previousMode) }
        try XCTSkipIf(Motion.reduced, "Requires interactive presentation")
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let (store, originalWindow, monitor) = fixture(withSpaces: true)
        let window = VaneWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        store.window = window
        monitor.remove()
        monitor.install(store)
        defer { store.window = originalWindow; window.close() }
        store.sharingReady = false
        let count = ProcessInfo.processInfo.environment["VANE_LIBRARY_PERF_TABS"].flatMap(Int.init) ?? 300
        store.tabs = (0..<count).map { index in
            let tab = Tab(profileID: store.profileID)
            tab.kind = .today
            tab.park(url: URL(string: "about:blank#swipe-\(index)")!, Parked(title: "Swipe fixture \(index)"))
            return tab
        }
        store.syncShapes()
        let key = ProfileManager.defaultsKey("archivedTabs", store.profileID)
        let oldArchive = UserDefaults.vane.data(forKey: key)
        let archived = (0..<2000).map { Archive.Entry(url: "about:blank#archive-\($0)",
            title: "Archived fixture \($0)", at: Date.now.addingTimeInterval(Double(-$0 * 60))) }
        UserDefaults.vane.set(try JSONEncoder().encode(archived), forKey: key)
        defer {
            Archive.shared(for: store.profileID).clear()
            UserDefaults.vane.set(oldArchive, forKey: key)
            window.contentView = nil
            window.orderOut(nil)
        }
        Library.open(.archived, in: store)
        store.libraryOpen = false
        store.sidebarShown = true
        store.palette = nil
        let host = NSHostingView(rootView: BrowserWindow().environmentObject(store)
            .environmentObject(ProfileManager.shared))
        window.contentView = host
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        print("LIBRARY_SWIPE_WINDOW visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) active=\(NSApp.isActive) frame=\(window.frame) screens=\(NSScreen.screens.map(\.frame))")
        // Force native layout even when this desktop session occludes test windows.
        // These timings measure main-thread update work, not displayed frame rate.
        var lastTick = ProcessInfo.processInfo.systemUptime
        var maxGap = 0.0
        let timer = Timer(timeInterval: 0.001, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = ProcessInfo.processInfo.systemUptime
                maxGap = max(maxGap, now - lastTick)
                lastTick = now
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        for visit in 0..<3 {
            for opening in [true, false] {
                var publications = 0
                let observation = store.objectWillChange.sink { publications += 1 }
                maxGap = 0
                lastTick = ProcessInfo.processInfo.systemUptime
                send(window, phase: .began)
                let start = ProcessInfo.processInfo.systemUptime
                send(window, dx: opening ? 15 : -15)
                host.layoutSubtreeIfNeeded()
                let first = (ProcessInfo.processInfo.systemUptime - start) * 1000
                var times: [Double] = []
                for _ in 0..<30 {
                    let frame = ProcessInfo.processInfo.systemUptime
                    send(window, dx: opening ? 3 : -3)
                    host.layoutSubtreeIfNeeded()
                    times.append((ProcessInfo.processInfo.systemUptime - frame) * 1000)
                    try await Task.sleep(for: .milliseconds(8))
                }
                observation.cancel()
                times.sort()
                print("LIBRARY_SWIPE_PERF tabs=\(count) visit=\(visit) opening=\(opening) first_ms=\(first) median_ms=\(times[15]) p95_ms=\(times[28]) max_ms=\(times.last!) max_gap_ms=\(maxGap * 1000) browser_publications=\(publications)")
                send(window, phase: .ended)
                try await Task.sleep(for: .milliseconds(300))
            }
        }
        XCTAssertEqual(ArchiveLibrary.library(for: store.profileID).entries.count, 2000)
    }

    func testOpeningAndClosingTrackFingersBeforeCommitting() throws {
        try XCTSkipIf(Motion.reduced, "Requires interactive presentation")
        let (store, window, _) = fixture(withSpaces: true)
        store.sidebarShown = true
        store.libraryOpen = false
        send(window, phase: .began)
        send(window, dx: 40)
        let opening = store.librarySwipeProgress
        XCTAssertNotNil(opening)
        XCTAssertGreaterThan(opening ?? 0, 0)
        XCTAssertLessThan(opening ?? 1, 1)
        send(window, dx: 30)
        XCTAssertGreaterThan(store.librarySwipeProgress ?? 0, opening ?? 0)
        XCTAssertFalse(store.libraryOpen)
        send(window, phase: .ended)
        XCTAssertTrue(store.libraryOpen)

        send(window, phase: .began)
        send(window, dx: -40)
        let closing = store.librarySwipeProgress
        XCTAssertNotNil(closing)
        XCTAssertGreaterThan(closing ?? 0, 0)
        XCTAssertLessThan(closing ?? 1, 1)
        send(window, dx: -30)
        XCTAssertLessThan(store.librarySwipeProgress ?? 1, closing ?? 1)
        XCTAssertTrue(store.libraryOpen)
        send(window, phase: .ended)
        XCTAssertFalse(store.libraryOpen)
    }

    func testInterruptedSwipeClearsPresentationWithoutChangingDestination() throws {
        try XCTSkipIf(Motion.reduced, "Requires interactive presentation")
        let (store, window, monitor) = fixture()
        send(window, phase: .began)
        send(window, dx: -40)
        XCTAssertNotNil(store.librarySwipeProgress)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertNil(store.librarySwipeProgress)
        XCTAssertTrue(store.libraryOpen)
        send(window, phase: .began)
        send(window, dx: -40)
        monitor.remove()
        XCTAssertNil(store.librarySwipeProgress)
    }

    func testClickOpeningPresentsIntermediatePanelPositions() async throws {
        try XCTSkipIf(Motion.reduced, "Requires animated navigation")
        let (store, window, monitor) = fixture(withSpaces: true)
        Library.open(.downloads, in: store)
        store.libraryOpen = false
        store.sidebarShown = true
        store.palette = nil
        let host = NSHostingView(rootView: BrowserWindow().environmentObject(store)
            .environmentObject(ProfileManager.shared))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(80))
        Library.open(.downloads, in: store)
        try await Task.sleep(for: .milliseconds(70))
        let marker = try XCTUnwrap(monitor.presentationView)
        func x() throws -> CGFloat {
            try XCTUnwrap(marker.layer?.presentation()).convert(.zero,
                to: host.layer?.presentation()).x
        }
        let moving = try x()
        XCTAssertLessThan(moving, -5, "Opening must show travel rather than the final panel immediately")
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertGreaterThan(try x(), moving + 5)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(try x(), 0, accuracy: 1)
    }

    func testRenderedLibraryTracksDragAndSlidesAtFullWidthOnClose() async throws {
        let saver = BatterySaver.shared
        let previousMode = saver.mode
        saver.setMode(.off)
        defer { saver.setMode(previousMode) }
        try XCTSkipIf(Motion.reduced, "Requires animated presentation")
        let (store, window, _) = fixture(withSpaces: true)
        Library.open(.downloads, in: store)
        store.libraryOpen = false
        store.sidebarShown = true
        store.palette = nil
        let host = NSHostingView(rootView: BrowserWindow().environmentObject(store)
            .environmentObject(ProfileManager.shared))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(80))
        func scroll(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scroll(in: $0) }.first
        }
        let sidebarScroll = try XCTUnwrap(scroll(in: host))
        sidebarScroll.wantsLayer = true
        func sidebarOrigin() throws -> CGFloat {
            try XCTUnwrap(sidebarScroll.layer?.presentation())
                .convert(.zero, to: host.layer?.presentation()).x
        }
        let sidebarStart = try sidebarOrigin()
        send(window, phase: .began)
        send(window, dx: 40)
        try await Task.sleep(for: .milliseconds(40))
        func search(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField,
               field.placeholderString == LibrarySection.downloads.searchPrompt { return field }
            return view.subviews.lazy.compactMap { search($0) }.first
        }
        let field = try XCTUnwrap(search(host))
        field.wantsLayer = true
        func origin() throws -> CGFloat {
            try XCTUnwrap(field.layer?.presentation()).convert(.zero, to: host.layer?.presentation()).x
        }
        let initial = try origin()
        XCTAssertEqual(try sidebarOrigin() - sidebarStart, 40, accuracy: 1,
                       "The sidebar travels with the Library instead of being covered")
        let width = field.bounds.width
        XCTAssertFalse(window.firstResponder is NSTextView, "A preview must not take the keyboard")
        send(window, dx: 40)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(try origin() - initial, 40, accuracy: 1,
                       "The rendered panel follows fingers without an implicit spring")
        XCTAssertEqual(field.bounds.width, width, accuracy: 1)
        XCTAssertEqual(try sidebarOrigin() - sidebarStart, 80, accuracy: 1,
                       "Both neighbors stay connected to the fingers")
        send(window, phase: .ended)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(store.libraryOpen)
        XCTAssertNil(store.librarySwipeProgress)
        let resting = try origin()
        let sidebarResting = try sidebarOrigin()
        send(window, phase: .began)
        send(window, dx: -80)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(try origin(), resting - 80, accuracy: 1)
        XCTAssertEqual(try sidebarOrigin(), sidebarResting - 80, accuracy: 1,
                       "Returning reveals a moving sidebar, not a stationary layer")
        send(window, phase: .ended)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(store.libraryOpen)
        XCTAssertNotNil(field.superview, "Keep the departing panel mounted through its landing")
        XCTAssertLessThan(try origin(), resting - 80)
        XCTAssertEqual(field.bounds.width, width, accuracy: 1,
                       "Closing slides the panel rather than collapsing its contents")
        send(window, point: NSPoint(x: 800, y: 350), phase: .began)
        send(window, point: NSPoint(x: 800, y: 350), dy: 20)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(search(host) === field, "Page scrolling must not cut off the settling panel")
        send(window, point: NSPoint(x: 800, y: 350), phase: .ended)
        let beforeReverse = try origin()
        send(window, phase: .began)
        send(window, dx: 40)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(search(host) === field, "A reverse swipe retains the mounted presentation")
        XCTAssertEqual(try origin(), beforeReverse + 40, accuracy: 3,
                       "Reverse from the visible position, not the closed endpoint")
        send(window, phase: .ended)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(store.librarySwipeProgress)
        XCTAssertTrue(search(host) === field, "Keep the panel ready offscreen for the next gesture")
        XCTAssertFalse(field.isEnabled, "Closed Library fields cannot retain keyboard interaction")

        // A short swipe springs back without committing; the prepared panel stays inactive.
        send(window, phase: .began)
        send(window, dx: 40)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNotNil(search(host))
        send(window, phase: .ended)
        XCTAssertFalse(store.libraryOpen)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(store.librarySwipeProgress)
        XCTAssertTrue(search(host) === field)
        XCTAssertFalse(field.isEnabled)
    }

    func testBatterySaverUsesImmediateDestinationWithoutInteractivePreview() {
        let saver = BatterySaver.shared
        let previousMode = saver.mode
        saver.setMode(.alwaysOn)
        defer { saver.setMode(previousMode) }
        let (store, window, _) = fixture(withSpaces: true)
        store.libraryOpen = false
        send(window, phase: .began)
        send(window, dx: 120)
        XCTAssertNil(store.librarySwipeProgress)
        XCTAssertFalse(store.libraryOpen)
        send(window, phase: .ended)
        XCTAssertTrue(store.libraryOpen)
        XCTAssertNil(store.librarySwipeProgress)
    }

    func testReducingMotionDuringDragClearsPreviewButKeepsGestureOwnership() {
        let saver = BatterySaver.shared
        let previousMode = saver.mode
        saver.setMode(.off)
        defer { saver.setMode(previousMode) }
        let (store, window, monitor) = fixture()
        send(window, phase: .began)
        send(window, dx: -80)
        monitor.finishForReducedMotion()
        XCTAssertNil(store.librarySwipeProgress)
        send(window, phase: .ended)
        XCTAssertFalse(store.libraryOpen)
        let scrolls = window.scrolls
        send(window, dx: -200, phase: [], momentum: .began)
        XCTAssertEqual(window.scrolls, scrolls)
    }

    func testPageSwipesPassThroughWithLibraryOpenOrClosedRegardlessOfMonitorOrder() {
        let (store, window, libraryMonitor) = fixture(withSpaces: true)
        let spaceMonitor = store.spaceGesture.monitor
        defer { spaceMonitor.remove() }
        store.sidebarShown = true
        for libraryFirst in [true, false] {
            libraryMonitor.remove()
            spaceMonitor.remove()
            if libraryFirst { libraryMonitor.install(store); spaceMonitor.install(store) }
            else { spaceMonitor.install(store); libraryMonitor.install(store) }
            for open in [false, true] {
                Library.open(.downloads, in: store)
                store.libraryOpen = open
                for inverted in [true, false] {
                    for delta in [CGFloat(-120), CGFloat(120)] {
                        let before = window.scrolls
                        let point = NSPoint(x: 800, y: 350)
                        send(window, point: point, phase: .began, inverted: inverted)
                        send(window, point: point, dx: delta, inverted: inverted)
                        send(window, point: point, phase: .ended, inverted: inverted)
                        send(window, point: point, dx: delta, phase: [], momentum: .began, inverted: inverted)
                        send(window, point: point, phase: [], momentum: .ended, inverted: inverted)
                        XCTAssertEqual(store.libraryOpen, open)
                        XCTAssertFalse(store.spaceSwiping)
                        XCTAssertEqual(window.scrolls - before, 5, "Content receives the whole gesture")
                    }
                }
            }
        }
    }

    func testScrollingSpaceFooterKeepsWholeGestureAwayFromSidebarNavigation() {
        let (store, window, libraryMonitor) = fixture(withSpaces: true)
        store.libraryOpen = false
        store.sidebarShown = true
        let footer = NSView(frame: NSRect(x: 48, y: 10, width: 132, height: 28))
        window.contentView?.addSubview(footer)
        store.spaceGesture.scrollingFooter = footer
        let spaceMonitor = store.spaceGesture.monitor
        defer { spaceMonitor.remove() }
        for libraryFirst in [true, false] {
            libraryMonitor.remove()
            spaceMonitor.remove()
            if libraryFirst { libraryMonitor.install(store); spaceMonitor.install(store) }
            else { spaceMonitor.install(store); libraryMonitor.install(store) }
            for delta in [CGFloat(-120), CGFloat(120)] {
                let before = window.scrolls
                send(window, point: NSPoint(x: 100, y: 24), phase: .began)
                send(window, point: NSPoint(x: 100, y: 24), dx: delta)
                // Keep the recipient even if the fingers leave the footer mid-gesture.
                send(window, point: NSPoint(x: 100, y: 100), dx: delta)
                send(window, point: NSPoint(x: 100, y: 100), phase: .ended)
                XCTAssertFalse(store.libraryOpen)
                XCTAssertFalse(store.spaceSwiping)
                XCTAssertEqual(window.scrolls - before, 4)
            }
        }
    }

    func testHiddenSidebarDoesNotClaimLibraryOpeningSwipes() {
        let (store, window, _) = fixture(withSpaces: true)
        store.libraryOpen = false
        store.sidebarShown = false
        send(window, phase: .began)
        send(window, dx: 120)
        send(window, phase: .ended)
        XCTAssertFalse(store.libraryOpen)
        XCTAssertEqual(window.scrolls, 3)
    }

    func testFloatingSidebarOpensLibraryButPageAndOuterGapsKeepTheirSwipes() {
        let (store, originalWindow, _) = fixture(withSpaces: true)
        let window = VaneWindow(contentRect: originalWindow.frame, styleMask: .borderless,
                                backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        defer { store.window = originalWindow; window.close() }
        store.sidebarShown = false
        window.peekingSidebar = true
        let width = SidebarWidth.shared.width
        for point in [NSPoint(x: 100, y: 350), NSPoint(x: width + 4, y: 350)] {
            store.libraryOpen = false
            send(window, point: point, phase: .began)
            send(window, point: point, dx: 120)
            send(window, point: point, phase: .ended)
            XCTAssertTrue(store.libraryOpen)
        }
        store.libraryOpen = false
        for point in [NSPoint(x: 4, y: 350), NSPoint(x: width + 20, y: 350),
                      NSPoint(x: 100, y: 4), NSPoint(x: 100, y: 696)] {
            send(window, point: point, phase: .began)
            send(window, point: point, dx: 120)
            send(window, point: point, phase: .ended)
            XCTAssertFalse(store.libraryOpen)
        }
    }

    func testLibraryClosingUsesEachSectionsPanelBoundary() {
        let (store, window, _) = fixture(withSpaces: true)
        for section in [LibrarySection.downloads, .easels, .spaces] {
            Library.open(section, in: store)
            let width = Library.panelWidth(section: section,
                spaces: ProfileManager.shared.allSpaces.count, available: 900)
            for (x, closes) in [(width - 2, true), (width + 2, false)] {
                store.libraryOpen = true
                let point = NSPoint(x: x, y: 350)
                let before = window.scrolls
                send(window, point: point, phase: .began)
                send(window, point: point, dx: -120)
                send(window, point: point, phase: .ended)
                XCTAssertEqual(store.libraryOpen, !closes, "Boundary for \(section)")
                if !closes { XCTAssertEqual(window.scrolls - before, 3) }
            }
        }
    }

    func testRightSwipeOpensLastLibrarySectionFromFirstSpaceSidebar() {
        let (store, window, _) = fixture(withSpaces: true)
        let first = store.currentSpaceID
        Library.open(.downloads, in: store)
        Library.shared.query = "old search"
        store.sidebarShown = true
        for point in [NSPoint(x: 20, y: 350), NSPoint(x: 100, y: 350)] {
            store.libraryOpen = false
            store.findOpen = true
            send(window, point: point, phase: .began)
            send(window, point: point, dx: 120)
            XCTAssertFalse(store.libraryOpen, "Wait for fingers-up")
            send(window, point: point, phase: .ended)
            XCTAssertTrue(store.libraryOpen, "Open from the first Space sidebar: \(point)")
            XCTAssertEqual(store.currentSpaceID, first)
            XCTAssertEqual(Library.shared.section, .downloads)
            XCTAssertEqual(Library.shared.query, "")
            XCTAssertFalse(store.findOpen)
            XCTAssertFalse(store.spaceSwiping)
        }
    }

    func testOpeningLibraryReplacesAnOpenCommandPalette() {
        let (store, window, _) = fixture(withSpaces: true)
        store.libraryOpen = false
        store.palette = .newTab
        send(window, phase: .began)
        send(window, dx: 120)
        send(window, phase: .ended)
        XCTAssertTrue(store.libraryOpen)
        XCTAssertNil(store.palette, "The palette must not obscure the opened Library")
    }

    func testPreviousSpaceSwipeOpensWithEitherNaturalScrollingPreference() {
        let (store, window, _) = fixture(withSpaces: true)
        // Library is before the first Space, so it takes the previous-Space direction,
        // which is a positive `scrollingDeltaX` whatever the scrolling preference.
        for inverted in [true, false] {
            store.libraryOpen = false
            send(window, phase: .began, inverted: inverted)
            send(window, dx: 120, inverted: inverted)
            send(window, phase: .ended, inverted: inverted)
            XCTAssertTrue(store.libraryOpen)
        }
    }

    func testRightSwipeOnLaterSpaceDoesNotOpenLibraryOrConsumePageScrolls() {
        let (store, window, _) = fixture(withSpaces: true)
        store.switchTo(space: store.strip[1])
        store.libraryOpen = false
        send(window, point: NSPoint(x: 800, y: 350), phase: .began)
        send(window, point: NSPoint(x: 800, y: 350), dx: 120)
        send(window, point: NSPoint(x: 800, y: 350), phase: .ended)
        XCTAssertFalse(store.libraryOpen)
        XCTAssertEqual(window.scrolls, 3)
    }

    func testRightSwipeOnLaterSpaceStillSelectsPreviousSpaceInSidebar() async throws {
        let (store, window, _) = fixture(withSpaces: true)
        let first = store.strip[0], second = store.strip[1]
        store.switchTo(space: second)
        store.libraryOpen = false
        store.sidebarShown = true
        let spaceMonitor = store.spaceGesture.monitor
        spaceMonitor.install(store)
        defer { spaceMonitor.remove() }
        send(window, phase: .began)
        send(window, dx: 120)
        send(window, phase: .ended)
        let deadline = Date.now.addingTimeInterval(2)
        while store.currentSpaceID != first.id && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.currentSpaceID, first.id)
        XCTAssertFalse(store.libraryOpen, "A Space gesture must not also open Library")
    }

    func testRejectedOpeningGesturesKeepFirstSpaceAndLibraryClosed() {
        let (store, window, _) = fixture(withSpaces: true)
        store.libraryOpen = false
        for (out, back, end) in [(CGFloat(-120), CGFloat(0), NSEvent.Phase.ended),
                                 (15, 0, .ended), (120, 0, .cancelled),
                                 (120, -115, .ended)] {
            send(window, phase: .began)
            send(window, dx: out)
            send(window, dx: back)
            send(window, phase: end)
            XCTAssertFalse(store.libraryOpen)
        }
        send(window, phase: .began)
        send(window, dx: 1, dy: 20)
        send(window, dx: 200)
        send(window, phase: .ended)
        XCTAssertFalse(store.libraryOpen)
    }

    func testOpeningGestureMomentumCannotCloseLibraryAgain() {
        let (store, window, _) = fixture(withSpaces: true)
        store.libraryOpen = false
        send(window, phase: .began)
        send(window, dx: 120)
        send(window, phase: .ended)
        XCTAssertTrue(store.libraryOpen)
        let scrolls = window.scrolls
        send(window, dx: -300, phase: [], momentum: .began)
        send(window, dx: -300, phase: [], momentum: .changed)
        send(window, phase: [], momentum: .ended)
        XCTAssertTrue(store.libraryOpen)
        XCTAssertEqual(window.scrolls, scrolls)
        send(window, phase: .began)
        send(window, dx: -120)
        send(window, phase: .ended)
        XCTAssertFalse(store.libraryOpen, "A fresh leftward gesture can still close")
    }

    func testFirstSpaceOpeningWinsRegardlessOfMonitorInstallationOrder() {
        let (store, window, libraryMonitor) = fixture(withSpaces: true)
        let spaceMonitor = store.spaceGesture.monitor
        defer { spaceMonitor.remove() }
        store.sidebarShown = true
        for libraryFirst in [true, false] {
            libraryMonitor.remove()
            spaceMonitor.remove()
            if libraryFirst { libraryMonitor.install(store); spaceMonitor.install(store) }
            else { spaceMonitor.install(store); libraryMonitor.install(store) }
            for inverted in [true, false] {
                store.libraryOpen = false
                send(window, phase: .began, inverted: inverted)
                send(window, dx: 120, inverted: inverted)
                XCTAssertFalse(store.spaceSwiping, "The sidebar must not claim Library's gesture")
                send(window, phase: .ended, inverted: inverted)
                XCTAssertTrue(store.libraryOpen)
                XCTAssertEqual(store.spaceDrag, 0)
            }
        }
    }

    func testSmallOpeningSamplesAreNotCountedTwiceByBothMonitors() {
        let (store, window, _) = fixture(withSpaces: true)
        let spaceMonitor = store.spaceGesture.monitor
        spaceMonitor.install(store)
        defer { spaceMonitor.remove() }
        store.sidebarShown = true
        store.libraryOpen = false
        send(window, phase: .began)
        // 54 points is below the 60-point dismissal/opening threshold.
        for _ in 0..<18 { send(window, dx: 3) }
        send(window, phase: .ended)
        XCTAssertFalse(store.libraryOpen)
        XCTAssertFalse(store.spaceSwiping)
        send(window, phase: .began)
        for _ in 0..<22 { send(window, dx: 3) }
        send(window, phase: .ended)
        XCTAssertTrue(store.libraryOpen, "66 points should open it")
    }

    func testSpaceChangeOrCreationDuringOpeningGestureCancelsIt() {
        let (store, window, _) = fixture(withSpaces: true)
        let first = store.strip[0], second = store.strip[1]
        store.libraryOpen = false
        send(window, phase: .began)
        send(window, dx: 120)
        store.switchTo(space: second)
        send(window, phase: .ended)
        XCTAssertFalse(store.libraryOpen)
        store.switchTo(space: first)
        send(window, phase: .began)
        send(window, dx: 120)
        store.creatingSpace = true
        send(window, phase: .ended)
        XCTAssertFalse(store.libraryOpen)
    }

    func testLeftSwipeClosesLibraryWithinPanelWithSidebarHidden() {
        let (store, window, _) = fixture()
        store.sidebarShown = false
        for point in [NSPoint(x: 20, y: 350), NSPoint(x: 250, y: 350)] {
            store.libraryOpen = true
            send(window, point: point, phase: .began)
            send(window, point: point, dx: -120)
            XCTAssertTrue(store.libraryOpen, "Wait for fingers-up")
            send(window, point: point, phase: .ended)
            XCTAssertFalse(store.libraryOpen, "Close from the Library panel: \(point)")
            XCTAssertFalse(store.spaceSwiping)
            XCTAssertEqual(store.spaceDrag, 0)
        }
    }

    func testNextSpaceSwipeClosesWithEitherNaturalScrollingPreference() {
        let (store, window, _) = fixture()
        // The next-Space direction, a negative `scrollingDeltaX`, leaves Library for the
        // first Space; the scrolling preference flips the fingers, not the meaning.
        let leftDelta: CGFloat = -120
        for inverted in [true, false] {
            store.libraryOpen = true
            send(window, phase: .began, inverted: inverted)
            send(window, dx: leftDelta, inverted: inverted)
            send(window, phase: .ended, inverted: inverted)
            XCTAssertFalse(store.libraryOpen, "The next-Space swipe closes regardless of Natural Scrolling")
            store.libraryOpen = true
            send(window, phase: .began, inverted: inverted)
            send(window, dx: -leftDelta, inverted: inverted)
            send(window, phase: .ended, inverted: inverted)
            XCTAssertTrue(store.libraryOpen, "The previous-Space swipe never closes Library")
        }
    }

    func testVerticalScrollLocksOutLaterHorizontalDrift() {
        let (store, window, _) = fixture()
        send(window, phase: .began)
        send(window, dx: -1, dy: 20)
        send(window, dx: -200)
        send(window, phase: .ended)
        XCTAssertTrue(store.libraryOpen)
        XCTAssertEqual(window.scrolls, 4)
    }

    func testReverseShortCancelledAndReturnedSwipesKeepLibraryOpen() {
        let (store, window, _) = fixture()
        for (out, back, end) in [(CGFloat(120), CGFloat(0), NSEvent.Phase.ended),
                                 (-15, 0, .ended), (-120, 0, .cancelled),
                                 (-120, 115, .ended)] {
            send(window, phase: .began)
            send(window, dx: out)
            send(window, dx: back)
            send(window, phase: end)
            XCTAssertTrue(store.libraryOpen)
        }
    }

    func testMomentumCannotDismissReopenedLibraryOrReachThePage() {
        let (store, window, _) = fixture()
        send(window, phase: .began)
        send(window, dx: -120)
        send(window, phase: .ended)
        XCTAssertFalse(store.libraryOpen)
        let scrolls = window.scrolls
        store.libraryOpen = true
        send(window, dx: -300, phase: [], momentum: .began)
        send(window, dx: -300, phase: [], momentum: .changed)
        send(window, phase: [], momentum: .ended)
        XCTAssertTrue(store.libraryOpen)
        XCTAssertEqual(window.scrolls, scrolls, "The claimed gesture's tail must not navigate the page")
    }

    func testClosedLibraryMouseWheelAndOtherWindowKeepTheirEvents() {
        let (store, window, _) = fixture()
        store.libraryOpen = false
        send(window, dx: -120, phase: .began)
        send(window, phase: .ended)
        store.libraryOpen = true
        send(window, dx: -120, phase: [], precise: false)
        send(window, dx: -120, phase: [], precise: true)
        XCTAssertTrue(store.libraryOpen)
        XCTAssertEqual(window.scrolls, 4)
        let other = LibraryScrollWindow(contentRect: window.frame, styleMask: .borderless,
                                        backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        send(other, phase: .began)
        send(other, dx: -120)
        send(other, phase: .ended)
        XCTAssertTrue(store.libraryOpen)
        XCTAssertEqual(other.scrolls, 3)
    }

    func testInterruptedGestureAndRemovedMonitorDoNotDismissLibrary() {
        let (store, window, monitor) = fixture()
        send(window, phase: .began)
        send(window, dx: -120)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        send(window, phase: .ended)
        XCTAssertTrue(store.libraryOpen)
        send(window, phase: .began)
        send(window, dx: -120)
        monitor.remove()
        send(window, phase: .ended)
        XCTAssertTrue(store.libraryOpen)
    }
}

private final class LibraryScrollWindow: NSWindow {
    var scrolls = 0
    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel { scrolls += 1 }
        else { super.sendEvent(event) }
    }
}

private final class LibraryScrollEvent: NSEvent, @unchecked Sendable {
    private let eventTime: TimeInterval
    private let target: NSWindow
    private let targetNumber: Int
    private let point: NSPoint
    private let dx: CGFloat
    private let dy: CGFloat
    private let scrollPhase: NSEvent.Phase
    private let momentum: NSEvent.Phase
    private let precise: Bool
    private let inverted: Bool

    @MainActor init(window: NSWindow, point: NSPoint, dx: CGFloat, dy: CGFloat,
                    phase: NSEvent.Phase, momentum: NSEvent.Phase, precise: Bool, inverted: Bool,
                    time: TimeInterval = 1) {
        eventTime = time
        target = window
        targetNumber = window.windowNumber
        self.point = point
        self.dx = dx
        self.dy = dy
        scrollPhase = phase
        self.momentum = momentum
        self.precise = precise
        self.inverted = inverted
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { target }
    override var windowNumber: Int { targetNumber }
    override var locationInWindow: NSPoint { point }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var isDirectionInvertedFromDevice: Bool { inverted }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { dy }
    override var phase: NSEvent.Phase { scrollPhase }
    override var momentumPhase: NSEvent.Phase { momentum }
    override var timestamp: TimeInterval { eventTime }
}
