import AppKit
import CoreMedia
import CoreVideo
@preconcurrency import ScreenCaptureKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SpaceNativeRenderingTests: XCTestCase {
    private func fixture(floatingWindow: Bool = false, coloured: Bool = false, defaultColours: Bool = false, activateWindow: Bool = true, registerTeardown: Bool = true) throws -> (TabStore, [Space], NSWindow, SwipeMonitor) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        if registerTeardown { addTeardownBlock { @MainActor in NSApp.setActivationPolicy(activationPolicy) } }
        try XCTSkipIf(Motion.spaceReduced, "Animated interruption requires motion")
        let profile = fixtureProfile(named: "Continuity fixture").id
        let spaces = ["First", "Second", "Third", "Fourth"].enumerated().map { index, name in
            coloured ? Space(name: name, profileID: profile,
                             colorHex: index == 0 ? "#FF0000" : "#0000FF", appearance: "dark", tint: 1)
                : Space(name: name, profileID: profile, colorHex: defaultColours ? ["#6E7DD2", "#678575", "#B08068", "#6E7DD2"][index] : nil)
        }
        XCTAssertTrue(ProfileManager.shared.saveSpaces(spaces, for: profile))
        let store = TabStore(profileID: profile, space: spaces[0], session: [])
        // Empty windows initially offer search. These fixtures exercise the sidebar;
        // search-specific tests opt back into its presentation explicitly.
        store.palette = nil
        let frame = NSRect(x: 100, y: 100, width: 300, height: 400)
        let window: NSWindow = floatingWindow
            ? VaneWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            : NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Admit the fixture independently of WindowServer's window-show effect.
        // Sidebar and profile movement keep their own production animations.
        window.animationBehavior = .none
        store.window = window
        window.contentView = BrowserWindowHost(shown: ShownStore(store))
        window.contentView?.layoutSubtreeIfNeeded()
        // Presentation-layer frame assertions require a visible active test window.
        // A user's running Vane copy can otherwise keep this fixture occluded.
        if activateWindow {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        let monitor = store.spaceGesture.monitor
        monitor.install(store)
        if registerTeardown {
            addTeardownBlock { @MainActor in self.retireFixture(store, window: window, monitor: monitor) }
        }
        return (store, spaces, window, monitor)
    }

    private func retireFixture(_ store: TabStore, window: NSWindow, monitor: SwipeMonitor) {
        monitor.remove()
        window.orderOut(nil)
        window.contentView = nil
        store.window = nil
        store.dropStashes()
        let tabs = store.tabs
        TabStore.all.removeAll { $0 === store }
        SharedTabs.release(tabs)
        Store.forget(store.profileID)
        ProfileManager.shared.delete(store.profileID)
        try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: store.profileID, in: Store.directory))
    }

    /// A closed, retained NSWindow still owns its content tree. Retire native
    /// travel and both visible and parked roots before deleting fixture profiles.
    private func retireProfileWindow(_ window: NSWindow) {
        let held = TabStore.all.filter { $0.window === window || $0.parkedIn === window }
        for store in held {
            store.spaceGesture.monitor.interruptLanding()
            store.spaceGesture.monitor.remove()
            store.librarySwipeMonitor.remove()
        }
        (window.contentView as? BrowserWindowHost)?.cancelSpaceSlide()
        window.close()
        window.contentView = nil
        for store in held {
            store.window = nil
            store.parkedIn = nil
            store.profileVisible = false
            store.dropStashes()
        }
    }

    private func withFixtureApplicationLoop(_ body: () async throws -> Void) async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do { try await body() } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Rendering fixture AppKit cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func fixtureProfile(named name: String) -> Profile {
        let profile = ProfileManager.shared.create(name: name)
        // Register before the fixture's teardown so its windows/tabs retire first.
        // The wrapper then verifies this exact backend after the host has exited.
        addTeardownBlock { @MainActor in try await NativeFixtureProfileCleanup.release([profile.id]) }
        return profile
    }

    private func fixtureSidebarWidth(in store: TabStore) -> CGFloat {
        // The 300pt fixture fits its sidebar to 164pt, independently of the
        // saved preference. Parked source stores still belong to that window.
        let window = store.window ?? store.parkedIn
        return SidebarWidth.fitting(SidebarWidth.shared.width,
                                    in: window?.contentView?.bounds.width ?? .infinity)
    }

    private func admitFixtureSidebar(_ store: TabStore, window: NSWindow) async throws {
        try await compatibilityWait {
            window.contentView?.layoutSubtreeIfNeeded()
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            if NSApp.keyWindow !== window { window.makeKeyAndOrderFront(nil) }
            guard NSApp.isRunning, NSApp.isActive, NSApp.keyWindow === window,
                  window.isVisible, window.occlusionState.contains(.visible),
                  store.window === window, let host = window.contentView,
                  let root = host.layer, let presentedRoot = root.presentation(),
                  let anchor = store.spaceGesture.sectionsView, anchor.window === window,
                  let layer = anchor.layer, let presented = layer.presentation(),
                  SidebarNativeReadinessCoordinator.shared.isReady(
                    SidebarNativeReadinessScope(store: store, spaceID: store.currentSpaceID),
                    allowingUnregistered: !NativeCachedSidebarBatchesExperiment.enabled) else { return false }
            return abs(presented.convert(.zero, to: presentedRoot).x - layer.convert(.zero, to: root).x) < 0.125
        }
    }

    func testCompactWindowReusesPreparedSurfaceAtItsFittedSidebarWidth() async throws {
        try await withFixtureApplicationLoop {
            let (store, spaces, window, monitor) = try self.fixture()
            let width = self.fixtureSidebarWidth(in: store)
            XCTAssertEqual(width, SidebarWidth.inWindow(store))
            XCTAssertLessThan(try XCTUnwrap(window.contentView).bounds.width,
                              SidebarWidth.shared.width + 200)
            try await self.waitForPreparation(monitor, target: spaces[1].id)
            let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
            let originX = prepared.outgoing.frame.minX
            monitor.track(-30, width: width, in: store)
            XCTAssertTrue((window.contentView as? BrowserWindowHost)?.spaceSlide === prepared,
                          "Compact input must claim its already prepared native geometry")
            XCTAssertEqual(prepared.outgoing.frame.minX - originX, -30, accuracy: 0.001)
            monitor.abort()
        }
    }

    private func colourSurface(in view: NSView) -> ThemeWashSurface? {
        if let surface = view as? ThemeWashSurface { return surface }
        return view.subviews.lazy.compactMap { self.colourSurface(in: $0) }.first
    }

    private func firstColour(of surface: ThemeWashSurface, presented: Bool = false) throws -> NSColor {
        let layer = presented ? surface.base.presentation() ?? surface.base : surface.base
        let colours = try XCTUnwrap(layer.colors as? [CGColor])
        return try XCTUnwrap(NSColor(cgColor: XCTUnwrap(colours.first))?.usingColorSpace(.deviceRGB))
    }

    private func warmOwnerReports(in view: NSView) -> [any NativeCachedSidebarBatchesReporting] {
        let own = (view as? any NativeCachedSidebarBatchesReporting).map { [$0] } ?? []
        return own + view.subviews.flatMap { warmOwnerReports(in: $0) }
    }

    private func warmOwnerFixture(pinnedRows: Int = 0, todayRows: Int = 32, windowHeight: CGFloat = 800, registerTeardown: Bool = true) async throws -> (TabStore, [Space], NSWindow, SwipeMonitor, BrowserWindowHost) {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VANE_RETAIN_INACTIVE_SPACE_ROW_OWNERS"] == "0")
        let (store, spaces, window, monitor) = try fixture(registerTeardown: registerTeardown)
        window.setContentSize(NSSize(width: 1100, height: windowHeight))
        for space in spaces {
            store.switchTo(space: space)
            store.tabs = (0..<(todayRows + pinnedRows)).map { index in
                let tab = Tab(profileID: store.profileID)
                if index < pinnedRows { tab.kind = .pinned }
                tab.park(url: URL(string: "about:blank#warm-authority-\(space.id)-\(index)")!,
                         Parked(title: "Warm owner \(index)"))
                return tab
            }
            store.syncShapes()
        }
        store.switchTo(space: spaces[0]); store.palette = nil
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        try await compatibilityWait { self.warmOwnerReports(in: host).contains { $0.attachedLogicalRows >= 24 } }
        return (store, spaces, window, monitor, host)
    }

    private func visitWarmSpace(_ target: Space, store: TabStore, monitor: SwipeMonitor,
                                host: BrowserWindowHost) async throws {
        let direction = try XCTUnwrap(store.beginSpaceSelection(target))
        monitor.land(direction, to: target, width: fixtureSidebarWidth(in: store), store: store, duration: 0.05)
        try await compatibilityWait { store.currentSpaceID == target.id && !store.spaceSwiping && host.spaceSlide == nil }
    }

    func testInactiveWarmOwnerBudgetAppliesAcrossPinnedAndTodaySections() async throws {
        let (store, spaces, _, monitor, host) = try await warmOwnerFixture(pinnedRows: 32)
        for target in spaces.dropFirst() {
            try await visitWarmSpace(target, store: store, monitor: monitor, host: host)
            let reports = warmOwnerReports(in: host)
            XCTAssertGreaterThanOrEqual(reports.filter { $0.cachedLogicalRows > 0 }.count, 2,
                                        "Both real sections must participate in this budget")
            XCTAssertLessThanOrEqual(reports.reduce(0) { $0 + $1.inactiveGraphCount }, 16,
                                     "One store must share its inactive graph budget across both sections")
            XCTAssertGreaterThan(reports.reduce(0) { $0 + $1.inactiveGraphCount }, 0,
                                 "The budget must retain owners, not pass by disabling reuse")
        }
    }

    func testWarmReturnAtStoreBudgetReusesSurvivingSectionOwners() async throws {
        try await warmReturnAtStoreBudget(windowHeight: 800)
    }

    func testWarmReturnAtStoreBudgetWithTallViewportReusesBothSections() async throws {
        try await warmReturnAtStoreBudget(windowHeight: 2600)
    }

    private func warmReturnAtStoreBudget(windowHeight: CGFloat) async throws {
        // Three pinned graphs plus two Today graphs per Space fit three complete
        // visits in the shared 16-graph budget, even when every row is visible.
        // The former 32 Today rows relied on offscreen geometry mounting only two
        // of four graphs; transient/tall geometry could legitimately evict First.
        let (store, spaces, _, monitor, host) = try await warmOwnerFixture(
            pinnedRows: 24, todayRows: 16, windowHeight: windowHeight)
        func admitPopulation() async throws {
            try await compatibilityWait {
                self.warmOwnerReports(in: host).map(\.attachedLogicalRows).sorted() == [16, 24]
            }
        }
        try await admitPopulation()
        for target in spaces.dropFirst() {
            try await visitWarmSpace(target, store: store, monitor: monitor, host: host)
            try await admitPopulation()
        }
        let reports = warmOwnerReports(in: host)
        let expected = Dictionary(uniqueKeysWithValues: reports.filter {
            $0.attachedGraphCount > 0 && $0.inactiveGraphCount == 3 * $0.attachedGraphCount
        }.map { (ObjectIdentifier($0), $0.batchCounts.inactiveScopeHits) })
        XCTAssertEqual(expected.count, 2, "Both sections' three inactive visits must fit before the return reservation")
        XCTAssertEqual(reports.reduce(0) { $0 + $1.inactiveGraphCount }, 15)
        XCTAssertEqual(reports.reduce(0) { $0 + $1.batchCounts.inactiveScopeEvictions }, 0)
        try await visitWarmSpace(spaces[0], store: store, monitor: monitor, host: host)
        try await admitPopulation()
        let returned = warmOwnerReports(in: host)
        XCTAssertEqual(Set(returned.map(ObjectIdentifier.init)), Set(expected.keys),
                       "Both supplying section owners must survive the return")
        for report in returned {
            if let before = expected[ObjectIdentifier(report)] {
                XCTAssertEqual(report.batchCounts.inactiveScopeHits, before + 1,
                               "Every surviving arriving section must be reused before outgoing budget reservations")
            }
        }
        XCTAssertLessThanOrEqual(returned.reduce(0) { $0 + $1.inactiveGraphCount }, 16)
    }


    func testProtectionRevocationSynchronouslyDropsInactiveWarmOwners() async throws {
        let (store, spaces, _, monitor, host) = try await warmOwnerFixture()
        try await visitWarmSpace(spaces[1], store: store, monitor: monitor, host: host)
        XCTAssertGreaterThan(warmOwnerReports(in: host).reduce(0) { $0 + $1.inactiveGraphCount }, 0)
        store.folderAuthentication.lock(UUID(), profile: store.profileID)
        XCTAssertEqual(warmOwnerReports(in: host).reduce(0) { $0 + $1.inactiveGraphCount }, 0,
                       "Protection revocation must withdraw inactive owners before returning to its caller")
    }

    func testRelockingAWarmSpacePurgesItsGraphAndNeverRemountsItsPrivateRows() async throws {
        let (store, spaces, _, monitor, host) = try await warmOwnerFixture()
        var folder = Folder(name: "Warm private folder")
        folder.requiresAuthentication = true
        folder.collapsed = false
        let secret = try XCTUnwrap(store.tabs.dropFirst(3).first)
        store.todayShape = Pins(entries: [.init(row: .folder(folder), parent: nil)] + store.tabs.map {
            .init(row: .tab($0.id.uuidString), parent: folder.id)
        })
        store.folderAuthentication.unlock(folder.id, profile: store.profileID, reason: "Native fixture",
            using: { _, reply in reply(true); return nil }) { XCTAssertTrue($0) }
        func attachedRows(_ view: NSView) -> Set<String> {
            let own = (view as? NativeSidebarRowLayoutView).map { Set([$0.rowID]) } ?? []
            return view.subviews.reduce(own) { $0.union(attachedRows($1)) }
        }
        func liveRows() -> Set<String> {
            warmOwnerReports(in: host).compactMap { $0 as? NSView }.reduce([]) { $0.union(attachedRows($1)) }
        }
        try await compatibilityWait { liveRows().contains(secret.id.uuidString) }
        try await visitWarmSpace(spaces[1], store: store, monitor: monitor, host: host)
        // The grant change revoked the original visit. A fresh visit is allowed
        // to become warm; ordinary same-scope updates cannot reauthorize it.
        try await visitWarmSpace(spaces[0], store: store, monitor: monitor, host: host)
        XCTAssertTrue(liveRows().contains(secret.id.uuidString))
        try await visitWarmSpace(spaces[1], store: store, monitor: monitor, host: host)
        XCTAssertGreaterThan(warmOwnerReports(in: host).reduce(0) { $0 + $1.inactiveGraphCount }, 0)
        store.folderAuthentication.lock(folder.id, profile: store.profileID)
        XCTAssertEqual(warmOwnerReports(in: host).reduce(0) { $0 + $1.inactiveGraphCount }, 0)
        try await visitWarmSpace(spaces[0], store: store, monitor: monitor, host: host)
        XCTAssertTrue(store.isTabLocked(secret.id))
        XCTAssertFalse(liveRows().contains(secret.id.uuidString), "A revoked private control must never return to the live hierarchy")
    }

    func testRevokedCurrentVisitCannotBeArchivedByLaterSameScopeUpdates() async throws {
        let (store, spaces, _, monitor, host) = try await warmOwnerFixture()
        let updates = warmOwnerReports(in: host).reduce(0) { $0 + $1.batchCounts.rootUpdates }
        store.folderAuthentication.lock(UUID(), profile: store.profileID)
        try await compatibilityWait {
            self.warmOwnerReports(in: host).reduce(0) { $0 + $1.batchCounts.rootUpdates } > updates
        }
        try await visitWarmSpace(spaces[1], store: store, monitor: monitor, host: host)
        XCTAssertEqual(warmOwnerReports(in: host).reduce(0) { $0 + $1.inactiveGraphCount }, 0,
                       "An ordinary configure must not reauthorize a critically revoked visit for archiving")
    }

    func testMemoryPressureDropsWarmOwnersWithTabSuspensionDisabled() async throws {
        try await withFixtureApplicationLoop { try await checkMemoryPressureDropsWarmOwners() }
    }

    private func checkMemoryPressureDropsWarmOwners() async throws {
        let (store, spaces, window, monitor, host) = try await warmOwnerFixture(registerTeardown: false)
        defer { retireFixture(store, window: window, monitor: monitor) }
        try await visitWarmSpace(spaces[1], store: store, monitor: monitor, host: host)
        // Pressure relief is the action under test. Admit an actual warm owner
        // before applying it, rather than treating an unfinished warm-up as zero.
        try await compatibilityWait {
            self.warmOwnerReports(in: host).reduce(0) { $0 + $1.inactiveGraphCount } > 0
        }
        XCTAssertGreaterThan(warmOwnerReports(in: host).reduce(0) { $0 + $1.inactiveGraphCount }, 0)
        let previous = Prefs.suspendTabs
        Prefs.suspendTabs = false
        defer { Prefs.suspendTabs = previous }
        Suspension.relieve(critical: false)
        XCTAssertEqual(warmOwnerReports(in: host).reduce(0) { $0 + $1.inactiveGraphCount }, 0,
                       "UI graph pressure relief must work independently of the tab suspension preference")
    }

    func testHiddenProfileSynchronouslyDropsWarmOwnersDuringLanding() async throws {
        let (store, spaces, _, monitor, host) = try await warmOwnerFixture()
        try await visitWarmSpace(spaces[1], store: store, monitor: monitor, host: host)
        monitor.track(-80, width: fixtureSidebarWidth(in: store), in: store)
        monitor.land(1, to: spaces[2], width: fixtureSidebarWidth(in: store), store: store, duration: 2)
        try await compatibilityWait { store.currentSpaceID == spaces[2].id && host.spaceSlide?.isActive == true }
        XCTAssertGreaterThan(warmOwnerReports(in: host).reduce(0) { $0 + $1.inactiveGraphCount }, 0)
        store.profileVisible = false
        XCTAssertEqual(warmOwnerReports(in: host).reduce(0) { $0 + $1.inactiveGraphCount }, 0,
                       "The emitted hide value must revoke archives synchronously")
    }

    func testBatterySaverFooterFollowsFractionalNativeSpaceTravel() async throws {
        let (store, spaces, window, monitor) = try fixture()
        let previous = BatterySaver.shared.mode
        defer { BatterySaver.shared.setMode(previous) }
        BatterySaver.shared.setMode(.alwaysOn)
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        func markers(in view: NSView) -> [NativeSpaceFooterMarkerView] {
            (view as? NativeSpaceFooterMarkerView).map { [$0] } ?? view.subviews.flatMap { markers(in: $0) }
        }
        let target = try XCTUnwrap(markers(in: host).first { $0.configuration?.id == spaces[1].id }?.marker)
        XCTAssertTrue(target.layout.showsAllIcons)
        XCTAssertTrue(BatterySaver.shared.isActive)
        monitor.track(-fixtureSidebarWidth(in: store) * 0.25, width: fixtureSidebarWidth(in: store), in: store)
        XCTAssertNotNil(host.spaceSlide, "Battery Saver keeps Space travel continuous")
        XCTAssertEqual(target.symbol.transform.m11, 0.85, accuracy: 0.001,
                       "The footer must follow the same fractional travel in Battery Saver")
        XCTAssertEqual(target.symbol.opacity, 0.7, accuracy: 0.001)
        monitor.track(-fixtureSidebarWidth(in: store) * 0.75, width: fixtureSidebarWidth(in: store), in: store)
        XCTAssertEqual(target.symbol.transform.m11, 0.95, accuracy: 0.001)
        XCTAssertEqual(target.symbol.opacity, 0.9, accuracy: 0.001)
    }


    func testZeroOffsetKeepsTheIncomingBackgroundColourPrepared() async throws {
        let (store, spaces, window, _) = try fixture(coloured: true)
        _ = store.beginSpaceSelection(spaces[1])
        store.spaceGesture.nativeDrag = 0
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let surface = try XCTUnwrap(colourSurface(in: XCTUnwrap(window.contentView)))
        let start = try firstColour(of: surface)
        XCTAssertGreaterThan(start.redComponent, 0.9)
        let track = try XCTUnwrap(store.spaceGesture.trackGround)
        track(1)
        let end = try firstColour(of: surface)
        track(0.5)
        let middle = try firstColour(of: surface)
        XCTAssertLessThan(middle.redComponent, start.redComponent - 0.1)
        XCTAssertGreaterThan(middle.redComponent, end.redComponent + 0.1)
        XCTAssertGreaterThan(middle.blueComponent, start.blueComponent + 0.1)
        XCTAssertLessThan(middle.blueComponent, end.blueComponent - 0.1,
                          "A zero-offset click must retain the incoming colour for native tracking")
    }

    func testNativeSpaceClickBlendsBackgroundDuringSidebarTravel() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do { try await checkNativeSpaceClickBlendsBackground() } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Click tint AppKit loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func checkNativeSpaceClickBlendsBackground() async throws {
        let (store, spaces, window, monitor) = try fixture(coloured: true, registerTeardown: false)
        defer { retireFixture(store, window: window, monitor: monitor) }
        // Search's first presentation can occupy the main actor longer than the
        // landing tail. This fixture samples tint; empty-Space/search handoff has
        // its own coverage in SpaceSwipeLandingTests.
        store.switchTo(space: spaces[1])
        let tab = store.newBlankTab(focus: false)
        tab.park(url: URL(string: "https://example.test/tint")!, Parked(title: "Tint fixture"))
        store.current = tab.id
        store.switchTo(space: spaces[0])
        store.palette = nil
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let surface = try XCTUnwrap(colourSurface(in: XCTUnwrap(window.contentView)))
        // Admit the exact visible source and its row population before the
        // action. A guessed startup delay can miss the spring's entire early travel.
        var admission = "starting"
        defer { print("NATIVE_CLICK_ADMISSION \(admission)") }
        do { try await compatibilityWait {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            let population = SidebarNativeReadinessCoordinator.shared.isReady(
                SidebarNativeReadinessScope(store: store, spaceID: spaces[0].id),
                allowingUnregistered: !NativeCachedSidebarBatchesExperiment.enabled)
            let presented = try? self.firstColour(of: surface, presented: true).redComponent
            let model = try? self.firstColour(of: surface).redComponent
            admission = "running=\(NSApp.isRunning) active=\(NSApp.isActive) hidden=\(NSApp.isHidden) "
                + "key=\(NSApp.keyWindow === window) visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) "
                + "population=\(population) presented=\(String(describing: presented)) model=\(String(describing: model))"
            if !NSApp.isActive || NSApp.keyWindow !== window {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return false
            }
            guard NSApp.isRunning, NSApp.isActive, NSApp.keyWindow === window,
                  window.isVisible, window.occlusionState.contains(.visible),
                  NSApp.modalWindow == nil, window.attachedSheet == nil,
                  population,
                  surface.base.presentation() != nil,
                  let presented, let model else { return false }
            return abs(presented - model) < 0.001
        } } catch {
            print("CLICK_TINT_ADMISSION running=\(NSApp.isRunning) active=\(NSApp.isActive) key=\(NSApp.keyWindow === window) visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) modal=\(NSApp.modalWindow != nil) sheet=\(window.attachedSheet != nil) ready=\(SidebarNativeReadinessCoordinator.shared.isReady(SidebarNativeReadinessScope(store: store, spaceID: spaces[0].id), allowingUnregistered: !NativeCachedSidebarBatchesExperiment.enabled)) presentation=\(surface.base.presentation() != nil) model=\(try? firstColour(of: surface).redComponent) presented=\(try? firstColour(of: surface, presented: true).redComponent)")
            throw error
        }
        let start = try firstColour(of: surface, presented: true).redComponent
        let selectionStart = ContinuousClock.now
        monitor.select(spaces[1], in: store)
        let selectionTime = selectionStart.duration(to: .now)
        var samples = [start]
        var positions: [CGFloat] = [0]
        var sampleTimes = [selectionStart.duration(to: .now)]
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        repeat {
            try await Task.sleep(for: .milliseconds(16))
            samples.append(try firstColour(of: surface, presented: true).redComponent)
            positions.append(host.spaceSlide.map { min(1, abs($0.offset / fixtureSidebarWidth(in: store))) } ?? 1)
            sampleTimes.append(selectionStart.duration(to: .now))
        } while store.spaceSwiping && ProcessInfo.processInfo.systemUptime < deadline
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
        try await Task.sleep(for: .milliseconds(60))
        let end = try firstColour(of: surface, presented: true).redComponent
        samples.append(end)
        positions.append(1)
        XCTAssertGreaterThan(abs(start - end), 0.5)
        XCTAssertTrue(samples.contains { abs($0 - start) > 0.05 && abs($0 - end) > 0.05 },
                      "The actual BrowserWindowHost must show intermediate background colours")
        print("NATIVE_CLICK_TINT select=\(selectionTime) times=\(sampleTimes) reds=\(samples)")
        for (red, position) in zip(samples, positions) {
            // Main-actor samples can be separated by a page-restore stall. Compare
            // the two compositor presentations, not the size of that missing interval.
            XCTAssertEqual((red - start) / (end - start), Double(position), accuracy: 0.05,
                           "The background must follow native travel instead of cutting at handoff")
        }
    }

    func testProfileClickDoesNotRestoreItsDepartureColour() async throws {
        try await checkProfileColourReturn(swipe: false)
    }

    func testProfileSwipeDoesNotRestoreItsDepartureColour() async throws {
        try await checkProfileColourReturn(swipe: true)
    }

    private func checkProfileColourReturn(swipe: Bool) async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "Requires animated profile navigation")
        let manager = ProfileManager.shared
        let previous = manager.active
        let blackProfile = fixtureProfile(named: "Black profile")
        let blueProfile = fixtureProfile(named: "Blue profile")
        var black = manager.createSpace(name: "Black", in: blackProfile.id)
        black.colorHex = "#000000"; black.tint = 1; black.appearance = "dark"
        manager.updateSpace(black)
        var blue = manager.createSpace(name: "Blue", in: blueProfile.id)
        blue.colorHex = "#0000FF"; blue.tint = 1; blue.appearance = "dark"
        manager.updateSpace(blue)
        let source = Windows.open(profile: blackProfile, space: black, focus: false)
        let window = try XCTUnwrap(source.window)
        window.animationBehavior = .none
        defer {
            retireProfileWindow(window)
            _ = manager.delete(blackProfile.id)
            _ = manager.delete(blueProfile.id)
            manager.active = previous
        }
        try await Task.sleep(for: .milliseconds(150))
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let blackSurface = try XCTUnwrap(colourSurface(in: host))
        XCTAssertEqual(try firstColour(of: blackSurface).blueComponent, 0, accuracy: 0.001)
        source.spaceGesture.monitor.select(blue, in: source)
        try await Task.sleep(for: .milliseconds(500))
        let destination = try XCTUnwrap(TabStore.all.first { $0.window === window })
        XCTAssertEqual(destination.profileID, blueProfile.id)
        XCTAssertTrue(blackSurface.window === window && blackSurface.isHiddenOrHasHiddenAncestor,
                      "Parked profiles keep their backing frames mounted outside input and accessibility")
        XCTAssertEqual(try firstColour(of: blackSurface).blueComponent, 0, accuracy: 0.001,
                       "A cached profile must retain its own black wash, ready for the return handoff")
        if swipe {
            NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .began))
            for _ in 0..<10 {
                NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: 12))
                try await Task.sleep(for: .milliseconds(8))
            }
            NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .ended))
        } else {
            destination.spaceGesture.monitor.select(black, in: destination)
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(source.window === window)
        XCTAssertTrue(blackSurface.window === window)
        XCTAssertEqual(try firstColour(of: blackSurface, presented: true).blueComponent, 0, accuracy: 0.001)
    }

    func testRealShortSwipeRestoresLiveSidebarAfterCancellation() async throws {
        try await withFixtureApplicationLoop { try await checkRealShortSwipeRestoresLiveSidebarAfterCancellation() }
    }

    private func checkRealShortSwipeRestoresLiveSidebarAfterCancellation() async throws {
        let (store, spaces, window, monitor) = try fixture(registerTeardown: false)
        defer { retireFixture(store, window: window, monitor: monitor) }
        let tab = store.newBlankTab(focus: false)
        tab.park(url: URL(string: "https://example.test/source")!, Parked(title: "Visible source row"))
        store.palette = nil
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let surface = try XCTUnwrap(colourSurface(in: host))
        // Native completion and its visibility publication require the exact
        // foreground owner, not merely a constructed window or a startup delay.
        try await compatibilityWait {
            host.layoutSubtreeIfNeeded()
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            if NSApp.keyWindow !== window { window.makeKeyAndOrderFront(nil) }
            guard NSApp.isRunning, NSApp.isActive, NSApp.keyWindow === window,
                  window.isVisible, window.occlusionState.contains(.visible),
                  NSApp.modalWindow == nil, window.attachedSheet == nil,
                  let anchor = store.spaceGesture.sectionsView, anchor.window === window,
                  let layer = anchor.layer, let presented = layer.presentation(),
                  let root = host.layer, let presentedRoot = root.presentation(),
                  SidebarNativeReadinessCoordinator.shared.isReady(
                    SidebarNativeReadinessScope(store: store, spaceID: store.currentSpaceID),
                    allowingUnregistered: !NativeCachedSidebarBatchesExperiment.enabled) else { return false }
            return abs(presented.convert(.zero, to: presentedRoot).x - layer.convert(.zero, to: root).x) < 0.125
        }
        func capture() throws -> NSBitmapImageRep {
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            return image
        }
        let baseline = try capture()
        let originalAnchor = try XCTUnwrap(store.spaceGesture.sectionsView)
        let region = originalAnchor.convert(originalAnchor.bounds, to: host)
        func edges(_ image: NSBitmapImageRep) -> Double {
            let scale = Double(image.pixelsWide) / host.bounds.width
            let x0 = max(0, Int(region.minX * scale)), x1 = min(image.pixelsWide - 2, Int(region.maxX * scale))
            let y0 = max(0, Int(region.minY * scale)), y1 = min(image.pixelsHigh - 2, Int(region.maxY * scale))
            var total: Double = 0
            for y in stride(from: y0, to: y1, by: 2) {
                for x in stride(from: x0, to: x1, by: 2) {
                    if let a = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       let b = image.colorAt(x: x + 1, y: y)?.usingColorSpace(.deviceRGB) {
                        total += abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
                    }
                }
            }
            return total
        }
        let beforeEdges = edges(baseline)
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .began))
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -12))
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -8))
        XCTAssertNotNil(host.spaceSlide, "The real monitor must mount its native finger track")
        let originalCover = try XCTUnwrap(host.spaceSlide)
        XCTAssertTrue(host.spaceSlide === originalCover && store.spaceGesture.profileSliding)
        var observedNativeCover = false
        var queuedRepeat = false
        let observer = store.spaceGesture.$presentation.map(\.profileSliding).removeDuplicates().sink { hidden in
            print("SHORT_SWIPE_VISIBILITY hidden=\(hidden) cover=\(host.spaceSlide != nil) running=\(NSApp.isRunning) active=\(NSApp.isActive) key=\(window.isKeyWindow)")
            if hidden, host.spaceSlide != nil { observedNativeCover = true }
            // Presentation publishes one coherent state after native retirement.
            // Witness the covered state first; its cover may already be detached
            // when the matching live-visibility notification is delivered.
            guard !hidden, observedNativeCover, !queuedRepeat else { return }
            queuedRepeat = true
            DispatchQueue.main.async {
                // The acknowledged cover can already be retired. A new zero-travel
                // gesture at this boundary must still release its swiping ownership.
                NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -12, phase: .began))
                NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .ended))
            }
        }
        defer { observer.cancel() }
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .ended))
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(observedNativeCover, "Replay must follow a real native-covered gesture")
        XCTAssertTrue(queuedRepeat)
        XCTAssertFalse(surface.nativeAnimating)
        XCTAssertNil(surface.base.animation(forKey: "colors"))
        XCTAssertEqual(store.currentSpaceID, spaces[0].id)
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertFalse(store.spaceGesture.profileSliding)
        XCTAssertEqual(store.spaceGesture.drag, 0)
        XCTAssertNil(store.spaceGesture.nativeDrag)
        XCTAssertNil(host.spaceSlide)
        let anchor = try XCTUnwrap(store.spaceGesture.sectionsView)
        XCTAssertTrue(anchor.window === window)
        XCTAssertFalse(anchor.isHiddenOrHasHiddenAncestor)
        let afterEdges = edges(try capture())
        XCTAssertGreaterThan(beforeEdges, 1, "The pre-gesture fixture must render sidebar content")
        XCTAssertGreaterThan(afterEdges, beforeEdges * 0.7,
                             "Canceled swipe must restore visible text and rows instead of a blank sidebar")
    }

    func testRealSwipePresentedColourFollowsNativeLandingPosition() async throws {
        let (store, spaces, window, _) = try fixture(defaultColours: true)
        store.palette = nil
        try await Task.sleep(for: .milliseconds(250))
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let surface = try XCTUnwrap(colourSurface(in: host))
        let start = try firstColour(of: surface, presented: true)
        let sampler = SwipeColourSampler(host: host, surface: surface)
        sampler.start(on: try XCTUnwrap(window.screen))
        defer { sampler.stop() }
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .began))
        for _ in 0..<10 {
            NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -12))
            try await Task.sleep(for: .milliseconds(8))
        }
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .ended))
        // Page activation measured a 147ms main-turn stall in the original regression.
        // Commit first, then model a bounded synchronous restore while CA keeps rendering.
        DispatchQueue.main.async {
            CATransaction.flush()
            Thread.sleep(forTimeInterval: 0.08)
        }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
        let end = try firstColour(of: surface, presented: true)
        let vector = [end.redComponent-start.redComponent, end.greenComponent-start.greenComponent, end.blueComponent-start.blueComponent]
        let length = vector.reduce(0) { $0 + $1*$1 }
        XCTAssertGreaterThan(length, 0.001)
        var worst: Double = 0
        for sample in sampler.samples {
            let delta = [sample.colour.redComponent-start.redComponent, sample.colour.greenComponent-start.greenComponent, sample.colour.blueComponent-start.blueComponent]
            let fraction = zip(vector, delta).reduce(0) { $0 + $1.0*$1.1 } / length
            let expected = min(1, abs(sample.offset / fixtureSidebarWidth(in: store)))
            worst = max(worst, abs(fraction-expected))
        }
        XCTAssertGreaterThan(sampler.samples.count, 5)
        XCTAssertLessThan(worst, 0.16, "Presented colour must follow the compositor's sidebar position through release")
    }

    func testNativeWashUsesLandingCurveAndReleasesOwnershipForReducedMotion() async throws {
        let (store, spaces, window, monitor) = try fixture(defaultColours: true)
        store.palette = nil
        try await Task.sleep(for: .milliseconds(250))
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let surface = try XCTUnwrap(colourSurface(in: host))
        monitor.track(-40, width: fixtureSidebarWidth(in: store), in: store)
        try await Task.sleep(for: .milliseconds(20))
        monitor.track(-60, width: fixtureSidebarWidth(in: store), in: store)
        monitor.land(1, to: spaces[1], width: fixtureSidebarWidth(in: store), store: store)
        let position = try XCTUnwrap(host.spaceSlide?.outgoing.layer?.animation(forKey: "space-position") as? CABasicAnimation)
        let colour = try XCTUnwrap(surface.base.animation(forKey: "colors") as? CABasicAnimation)
        XCTAssertEqual(position.duration, colour.duration)
        for index in 1...2 {
            var a: [Float] = [0, 0], b: [Float] = [0, 0]
            position.timingFunction?.getControlPoint(at: index, values: &a)
            colour.timingFunction?.getControlPoint(at: index, values: &b)
            XCTAssertEqual(a, b)
        }
        XCTAssertTrue(surface.nativeAnimating)
        monitor.finishForReducedMotion()
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(surface.nativeAnimating)
        XCTAssertNil(surface.base.animation(forKey: "colors"))
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
    }

    func testNativeWashCancellationCopiesSpringAndCanRestoreOriginImmediately() throws {
        let surface = ThemeWashSurface()
        let from = ThemeWash(colors: [ThemeColor(hex: "#6E7DD2")!], strength: 1, opacity: 1, grain: 0)
        let to = ThemeWash(colors: [ThemeColor(hex: "#678575")!], strength: 1, opacity: 1, grain: 0)
        let animation = CASpringAnimation(keyPath: "position")
        animation.mass = 1
        animation.stiffness = 1542
        animation.damping = 70
        animation.initialVelocity = 2
        animation.duration = animation.settlingDuration
        let token = surface.animateNative(from: from, to: to, animation: animation)
        let colour = try XCTUnwrap(surface.base.animation(forKey: "colors") as? CASpringAnimation)
        XCTAssertEqual(colour.mass, animation.mass)
        XCTAssertEqual(colour.stiffness, animation.stiffness)
        XCTAssertEqual(colour.damping, animation.damping)
        XCTAssertEqual(colour.initialVelocity, animation.initialVelocity)
        surface.finishNative(token: token, wash: from)
        XCTAssertFalse(surface.nativeAnimating)
        XCTAssertNil(surface.base.animation(forKey: "colors"))
        XCTAssertEqual(try firstColour(of: surface).redComponent,
                       try XCTUnwrap(from.colors[0].nsColor.usingColorSpace(.deviceRGB)).redComponent, accuracy: 0.001)
    }

    func testOldNativeWashCompletionCannotCancelReplacementAnimation() throws {
        let surface = ThemeWashSurface()
        let from = ThemeWash(colors: [ThemeColor(hex: "#6E7DD2")!], strength: 1, opacity: 1, grain: 0)
        let to = ThemeWash(colors: [ThemeColor(hex: "#678575")!], strength: 1, opacity: 1, grain: 0)
        let animation = CABasicAnimation(keyPath: "position")
        animation.duration = 0.18
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let old = surface.animateNative(from: from, to: to, animation: animation)
        let replacement = surface.animateNative(from: to, to: from, animation: animation)
        surface.finishNative(token: old, wash: to)
        XCTAssertTrue(surface.nativeAnimating)
        XCTAssertNotNil(surface.base.animation(forKey: "colors"))
        surface.finishNative(token: replacement, wash: from)
        XCTAssertFalse(surface.nativeAnimating)
        XCTAssertNil(surface.base.animation(forKey: "colors"))
        let colour = try firstColour(of: surface)
        XCTAssertEqual(colour.redComponent, try XCTUnwrap(from.colors[0].nsColor.usingColorSpace(.deviceRGB)).redComponent, accuracy: 0.001)
    }

    func testRetargetedLandingPreservesPresentedWashForReversalAndNewDestination() async throws {
        for targetIndex in [0, 2] {
            let (store, spaces, window, monitor) = try fixture(defaultColours: true)
            store.palette = nil
            try await Task.sleep(for: .milliseconds(250))
            let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
            let surface = try XCTUnwrap(colourSurface(in: host))
            // Give a loaded CI runner a deterministic mid-flight interruption point;
            // the replacement still uses the production click/return timing.
            XCTAssertNotNil(store.beginSpaceSelection(spaces[1]))
            monitor.land(1, to: spaces[1], width: fixtureSidebarWidth(in: store), store: store, duration: 0.8)
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while (store.currentSpaceID != spaces[1].id || abs(host.spaceSlide?.offset ?? 0) / fixtureSidebarWidth(in: store) < 0.35),
                  ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(store.currentSpaceID, spaces[1].id)
            let previous = try XCTUnwrap(host.spaceSlide)
            XCTAssertTrue(previous.isActive)
            let before = try firstColour(of: surface, presented: true)
            monitor.select(spaces[targetIndex], in: store)
            if targetIndex == 0 {
                XCTAssertTrue(host.spaceSlide === previous, "A reversal must keep the native surface under the fingers")
                XCTAssertTrue(previous.outgoing.layer?.animation(forKey: "space-position") is CASpringAnimation)
            }
            let animation = try XCTUnwrap(surface.base.animation(forKey: "colors") as? CABasicAnimation)
            let values = try XCTUnwrap(animation.fromValue as? [CGColor])
            let from = try XCTUnwrap(NSColor(cgColor: XCTUnwrap(values.first))?.usingColorSpace(.deviceRGB))
            if targetIndex == 0 {
                let delta = abs(from.redComponent-before.redComponent)
                    + abs(from.greenComponent-before.greenComponent) + abs(from.blueComponent-before.blueComponent)
                XCTAssertLessThan(delta, 0.02, "A reversal must begin at the actual presented wash")
            } else {
                XCTAssertTrue(host.spaceSlide === previous, "A new destination waits for the exposed leg")
            }
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(8))
            XCTAssertTrue(try XCTUnwrap(host.spaceSlide).isActive, "The superseded animation must not finish its replacement")
            if let slide = host.spaceSlide,
               let position = slide.outgoing.layer?.animation(forKey: "space-position") as? CABasicAnimation,
               let start = (position.fromValue as? NSValue)?.pointValue.x,
               let end = (position.toValue as? NSValue)?.pointValue.x,
               let x = slide.outgoing.layer?.presentation()?.position.x, end != start {
                let fraction = max(0, min(1, (x-start)/(end-start)))
                let colors = try XCTUnwrap(animation.toValue as? [CGColor])
                let to = try XCTUnwrap(NSColor(cgColor: XCTUnwrap(colors.first))?.usingColorSpace(.deviceRGB))
                let actual = try firstColour(of: surface, presented: true)
                let expected = [from.redComponent+(to.redComponent-from.redComponent)*fraction,
                                from.greenComponent+(to.greenComponent-from.greenComponent)*fraction,
                                from.blueComponent+(to.blueComponent-from.blueComponent)*fraction]
                let renderedError = abs(actual.redComponent-expected[0])+abs(actual.greenComponent-expected[1])+abs(actual.blueComponent-expected[2])
                XCTAssertLessThan(renderedError, 0.02, "Retargeted presented colour must remain on the native sidebar's actual curve")
            }
            let finalDeadline = ProcessInfo.processInfo.systemUptime + 3
            while (store.currentSpaceID != spaces[targetIndex].id || store.spaceSwiping || host.spaceSlide != nil),
                  ProcessInfo.processInfo.systemUptime < finalDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(store.currentSpaceID, spaces[targetIndex].id)
            XCTAssertFalse(surface.nativeAnimating)
        }
    }

    func testQueuedDestinationDoesNotReplaceAlreadyVisibleIncomingRows() async throws {
        let (store, spaces, window, monitor) = try fixture(defaultColours: true)
        store.palette = nil
        try await Task.sleep(for: .milliseconds(250))
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        XCTAssertNotNil(store.beginSpaceSelection(spaces[1]))
        monitor.land(1, to: spaces[1], width: fixtureSidebarWidth(in: store), store: store, duration: 0.8)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while abs(host.spaceSlide?.offset ?? 0) / fixtureSidebarWidth(in: store) < 0.35,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let original = try XCTUnwrap(host.spaceSlide)
        let incoming = try XCTUnwrap(original.subviews.last)
        func pixels(_ view: NSView) throws -> Data {
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            return try XCTUnwrap(image.tiffRepresentation)
        }
        let before = try pixels(incoming)
        monitor.select(spaces[2], in: store)
        XCTAssertTrue(host.spaceSlide === original, "Already visible B rows must remain on their native surface")
        let after = try XCTUnwrap(host.spaceSlide?.subviews.last)
        XCTAssertTrue(after === incoming)
        XCTAssertEqual(try pixels(after), before, "Requesting C must not swap the exposed B pixels")
        let finalDeadline = ProcessInfo.processInfo.systemUptime + 3
        while (store.currentSpaceID != spaces[2].id || store.spaceSwiping || host.spaceSlide != nil),
              ProcessInfo.processInfo.systemUptime < finalDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.currentSpaceID, spaces[2].id)
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertNil(host.spaceSlide)
    }

    func testQueuedDestinationHonorsLatestClickAndClearsForVisibleOrOriginClicks() async throws {
        for requestedIndex in [3, 1, 0] {
            let (store, spaces, window, monitor) = try fixture()
            store.palette = nil
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertNotNil(store.beginSpaceSelection(spaces[1]))
            monitor.land(1, to: spaces[1], width: fixtureSidebarWidth(in: store), store: store, duration: 0.5)
            try await Task.sleep(for: .milliseconds(60))
            let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
            let original = try XCTUnwrap(host.spaceSlide)
            monitor.select(spaces[2], in: store)
            monitor.select(spaces[requestedIndex], in: store)
            XCTAssertTrue(host.spaceSlide === original)
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while (store.currentSpaceID != spaces[requestedIndex].id || store.spaceSwiping || host.spaceSlide != nil),
                  ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(store.currentSpaceID, spaces[requestedIndex].id)
            XCTAssertNil(host.spaceSlide)
        }
    }

    func testQueuedDestinationKeepsVisibleIncomingDuringNativeReturnSpring() async throws {
        let (store, spaces, window, monitor) = try fixture()
        store.palette = nil
        try await Task.sleep(for: .milliseconds(150))
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        XCTAssertNotNil(store.beginSpaceSelection(spaces[1]))
        monitor.land(1, to: spaces[1], width: fixtureSidebarWidth(in: store), store: store, duration: 0.8)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while (store.currentSpaceID != spaces[1].id || abs(host.spaceSlide?.offset ?? 0) / fixtureSidebarWidth(in: store) < 0.35),
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let original = try XCTUnwrap(host.spaceSlide)
        monitor.select(spaces[0], in: store)
        monitor.select(spaces[2], in: store)
        XCTAssertTrue(host.spaceSlide === original)
        XCTAssertTrue(original.outgoing.layer?.animation(forKey: "space-position") is CASpringAnimation)
        let finalDeadline = ProcessInfo.processInfo.systemUptime + 3
        while (store.currentSpaceID != spaces[2].id || store.spaceSwiping || host.spaceSlide != nil),
              ProcessInfo.processInfo.systemUptime < finalDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.currentSpaceID, spaces[2].id)
        XCTAssertNil(host.spaceSlide)
    }

    func testQueuedDestinationResolvesReducedMotionAndDoesNotSurviveAbortOrHide() async throws {
        for action in ["reduce", "abort", "hide"] {
            let (store, spaces, window, monitor) = try fixture()
            store.palette = nil
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertNotNil(store.beginSpaceSelection(spaces[1]))
            monitor.land(1, to: spaces[1], width: fixtureSidebarWidth(in: store), store: store, duration: 0.5)
            try await Task.sleep(for: .milliseconds(60))
            let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
            monitor.select(spaces[2], in: store)
            switch action {
            case "reduce": monitor.finishForReducedMotion()
            case "abort": monitor.abort()
            default:
                store.sidebarShown = false
                host.spaceSlide?.sidebarDidDisappear(store)
            }
            try await Task.sleep(for: .milliseconds(800))
            XCTAssertEqual(store.currentSpaceID, spaces[action == "reduce" ? 2 : 1].id, action)
            XCTAssertFalse(store.spaceSwiping, action)
            XCTAssertNil(host.spaceSlide, action)
        }
    }

    func testQueuedDestinationRevalidatesDeletionAndExternalSelection() async throws {
        for action in ["delete", "external"] {
            let (store, spaces, window, monitor) = try fixture()
            store.palette = nil
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertNotNil(store.beginSpaceSelection(spaces[1]))
            monitor.land(1, to: spaces[1], width: fixtureSidebarWidth(in: store), store: store, duration: 0.5)
            try await Task.sleep(for: .milliseconds(60))
            monitor.select(spaces[2], in: store)
            if action == "delete" {
                XCTAssertTrue(ProfileManager.shared.deleteSpace(spaces[2].id, in: store.profileID))
            } else {
                Motion.spaceHandoff { store.switchTo(space: spaces[3]) }
            }
            try await Task.sleep(for: .milliseconds(1000))
            XCTAssertEqual(store.currentSpaceID, spaces[action == "delete" ? 1 : 3].id)
            XCTAssertFalse(store.spaceSwiping)
            XCTAssertNil((window.contentView as? BrowserWindowHost)?.spaceSlide)
        }
    }

    func testFirstProfileVisitChangesPageAtStartOfNativeLanding() async throws {
        try await withFixtureApplicationLoop { try await checkEarlyProfilePageSelection(cached: false) }
    }

    func testReverseSwipeTakesOverThePresentedLandingWithoutFinishingIt() async throws {
        try await withFixtureApplicationLoop { try await checkReverseSwipeTakesOverLanding() }
    }

    private func checkReverseSwipeTakesOverLanding() async throws {
        for direction in [1, -1] {
            let (store, spaces, window, monitor) = try fixture(registerTeardown: false)
            defer { retireFixture(store, window: window, monitor: monitor) }
            let origin = spaces[direction > 0 ? 0 : 1]
            let target = spaces[direction > 0 ? 1 : 0]
            store.switchTo(space: origin)
            try await checkReverseLanding(store: store, origin: origin, target: target,
                                          window: window, monitor: monitor, direction: direction)
        }
    }

    func testReverseProfileSwipeTakesOverTheSamePresentedNativeRows() async throws {
        try await withFixtureApplicationLoop { try await checkReverseProfileSwipeTakesOverRows() }
    }

    private func checkReverseProfileSwipeTakesOverRows() async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "Requires animated profile navigation")
        let manager = ProfileManager.shared
        let previous = manager.active
        let profiles = [fixtureProfile(named: "Catch origin"), fixtureProfile(named: "Catch arrival")]
        let spaces = profiles.map { manager.createSpace(name: "Catch", in: $0.id) }
        let store = Windows.open(profile: profiles[0], space: spaces[0], focus: false)
        let window = try XCTUnwrap(store.window)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        defer {
            retireProfileWindow(window)
            profiles.forEach { _ = manager.delete($0.id) }
            manager.active = previous
        }
        try await checkReverseLanding(store: store, origin: spaces[0], target: spaces[1],
                                      window: window, monitor: store.spaceGesture.monitor, direction: 1)
    }

    func testTargetClickInterruptsTheSameProfileReturnSpring() async throws {
        try await withFixtureApplicationLoop { try await checkTargetClickInterruptsTheSameProfileReturnSpring() }
    }

    private func checkTargetClickInterruptsTheSameProfileReturnSpring() async throws {
        let (store, spaces, window, monitor) = try fixture(registerTeardown: false)
        defer { retireFixture(store, window: window, monitor: monitor) }
        // This fixture interrupts native row travel. Admit a populated endpoint
        // so search's first mount does not consume the middle-frame setup leg;
        // empty-Space/search handoff is exercised in SpaceSwipeLandingTests.
        store.switchTo(space: spaces[1])
        let tab = store.newBlankTab(focus: false)
        tab.park(url: URL(string: "https://example.test/return-spring")!, Parked(title: "Return spring endpoint"))
        store.current = tab.id
        store.switchTo(space: spaces[0])
        store.palette = nil
        try await admitFixtureSidebar(store, window: window)
        try await waitForPreparation(monitor, target: spaces[1].id)
        XCTAssertNotNil(store.beginSpaceSelection(spaces[1]))
        // Slow the setup leg to admit a middle frame on a loaded desktop. Both
        // interrupted clicks below still use their production spring timing.
        let setupStart = CACurrentMediaTime()
        monitor.land(1, to: spaces[1], width: fixtureSidebarWidth(in: store), store: store, duration: 2)
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let slide = try XCTUnwrap(host.spaceSlide)
        var middleState = "not sampled"
        defer { print("RETURN_TARGET_MIDDLE \(middleState)") }
        try await compatibilityWait {
            middleState = "elapsed=\(CACurrentMediaTime() - setupStart) active=\(slide.isActive) offset=\(slide.offset) width=\(fixtureSidebarWidth(in: store)) appActive=\(NSApp.isActive) key=\(window.isKeyWindow)"
            return slide.isActive && abs(slide.offset) > fixtureSidebarWidth(in: store) * 0.4
                && abs(slide.offset) < fixtureSidebarWidth(in: store) * 0.65
        }
        monitor.select(spaces[0], in: store)
        XCTAssertTrue(slide.outgoing.layer?.animation(forKey: "space-position") is CASpringAnimation)
        monitor.select(spaces[1], in: store)
        XCTAssertTrue(host.spaceSlide === slide && slide.follows(spaces[1], direction: 1),
                      "The exposed target must interrupt the return spring immediately")
        try await compatibilityWait { store.currentSpaceID == spaces[1].id }
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
        XCTAssertNil(host.spaceSlide)
    }

    func testProfileOriginClickReversesBeforeTheCurrentLandingFinishes() async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "Requires animated profile navigation")
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do { try await checkProfileOriginClickReversal() } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Profile reversal AppKit loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func checkProfileOriginClickReversal() async throws {
        let manager = ProfileManager.shared
        let previous = manager.active
        let profiles = [fixtureProfile(named: "Click origin"), fixtureProfile(named: "Click arrival")]
        let spaces = profiles.map { manager.createSpace(name: "Click", in: $0.id) }
        let source = Windows.open(profile: profiles[0], space: spaces[0], focus: false)
        let window = try XCTUnwrap(source.window)
        window.animationBehavior = .none
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        defer {
            retireProfileWindow(window)
            profiles.forEach { _ = manager.delete($0.id) }
            manager.active = previous
        }
        source.palette = nil
        try await Task.sleep(for: .milliseconds(150))
        func markers(in view: NSView) -> [NativeSpaceFooterMarkerView] {
            (view as? NativeSpaceFooterMarkerView).map { [$0] }
                ?? view.subviews.flatMap { markers(in: $0) }
        }
        let originalGlyph = try XCTUnwrap(markers(in: try XCTUnwrap(window.contentView))
            .first { $0.owner === source && $0.configuration?.id == spaces[1].id }?.marker?.symbol)
        let width = fixtureSidebarWidth(in: source)
        source.spaceGesture.monitor.track(-60, width: width, in: source)
        // A critical spring covers its middle early. Slow only this setup leg so
        // a cold profile can mount before the midpoint reversal; the click below
        // still uses production timing and its original 100 ms outcome bound.
        source.spaceGesture.monitor.land(1, to: spaces[1], width: width, store: source, duration: 2)
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let slide = try XCTUnwrap(host.spaceSlide)
        try await compatibilityWait {
            slide.isActive && abs(slide.offset) > width * 0.4 && abs(slide.offset) < width * 0.65
        }
        let arriving = try XCTUnwrap(TabStore.all.first { $0.window === window })
        XCTAssertEqual(arriving.currentSpaceID, spaces[1].id)
        let activeMarker = try XCTUnwrap(markers(in: host).first {
            $0.owner === arriving && $0.configuration?.id == spaces[1].id && $0.marker?.view === $0
        })
        XCTAssertTrue(activeMarker.marker?.symbol === originalGlyph,
                      "The actual footer must carry its glyph across profile hosting roots")
        let originalRows = slide.outgoing
        let before = try XCTUnwrap(originalRows.layer?.presentation()).frame.minX
        arriving.spaceGesture.monitor.select(spaces[0], in: arriving)
        XCTAssertTrue(host.spaceSlide === slide, "Reverse the existing presented rows rather than replace them")
        XCTAssertTrue(slide.follows(spaces[0], direction: -1), "Retarget before returning from the click")
        let from = (originalRows.layer?.animation(forKey: "space-position") as? CABasicAnimation)?.fromValue as? NSValue
        let anchor = try XCTUnwrap(originalRows.layer).anchorPoint.x
        XCTAssertEqual(try XCTUnwrap(from).pointValue.x - originalRows.bounds.width * anchor, before, accuracy: 5)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(TabStore.all.first { $0.window === window }?.currentSpaceID, spaces[0].id,
                       "The origin click must take effect before the old landing finishes")
        for (index, direction) in [(1, 1), (0, -1)] {
            let showing = try XCTUnwrap(TabStore.all.first { $0.window === window })
            showing.spaceGesture.monitor.select(spaces[index], in: showing)
            XCTAssertTrue(host.spaceSlide === slide && slide.follows(spaces[index], direction: direction),
                          "Another reversal must interrupt the return instead of queueing")
            try await compatibilityWait {
                TabStore.all.first { $0.window === window }?.currentSpaceID == spaces[index].id
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(TabStore.all.first { $0.window === window }?.currentSpaceID, spaces[0].id)
        XCTAssertNil(host.spaceSlide)
    }

    private func checkReverseLanding(store: TabStore, origin: Space, target: Space,
                                     window: NSWindow, monitor: SwipeMonitor, direction: Int) async throws {
        store.palette = nil
        let width = fixtureSidebarWidth(in: store)
        let sign = CGFloat(direction)
        let callbackProbe = ProfileLandingCallbackProbe(window: window, targetID: target.id)
        callbackProbe.start(on: try XCTUnwrap(window.screen))
        defer { callbackProbe.stopAndDump(label: "reverse") }
        try await compatibilityWait {
            if !NSApp.isActive || NSApp.keyWindow !== window {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return false
            }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            return NSApp.isRunning && window.isKeyWindow && window.isVisible
                && window.occlusionState.contains(.visible) && store.window === window
                && store.currentSpaceID == origin.id
                && store.spaceGesture.sectionsView?.window === window
        }
        let heldDrag = -sign * width * 0.6
        monitor.track(heldDrag, width: width, in: store)
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let slide = try XCTUnwrap(host.spaceSlide)
        // Admit a genuinely presented middle finger position before release.
        // Starting below the sampled interval made cold layout consume it.
        try await compatibilityWait {
            abs(slide.offset - heldDrag) < 0.125 && slide.outgoing.layer?.presentation() != nil
        }
        callbackProbe.begin(slide: slide)
        monitor.land(direction, to: target, width: width, store: store, duration: 0.8)
        // Admit a real middle frame with room to move in either direction. Fixed sleeps
        // can sample the insertion frame or an endpoint on a loaded desktop.
        let middleStart = CACurrentMediaTime()
        var middleState = "not sampled"
        // Temporary public-only discriminator: retain the first admitted values,
        // not just the final timeout frame, without printing in the sample path.
        var middleSamples: [(TimeInterval, CGFloat, CGFloat, Bool, Bool)] = []
        defer {
            print("REVERSE_LANDING_MIDDLE \(middleState)")
            for (elapsed, offset, model, active, targetActive) in middleSamples {
                print("REVERSE_LANDING_FIRST elapsed=\(elapsed) offset=\(offset) model=\(model) active=\(active) targetActive=\(targetActive)")
            }
        }
        try await compatibilityWait {
            if middleSamples.count < 8 {
                callbackProbe.noteTask("middle")
                middleSamples.append((CACurrentMediaTime() - middleStart, slide.offset,
                                      slide.outgoing.frame.minX, slide.isActive,
                                      TabStore.all.first { $0.window === window }?.currentSpaceID == target.id))
            }
            middleState = "elapsed=\(CACurrentMediaTime() - middleStart) active=\(slide.isActive) offset=\(slide.offset) width=\(width) source=\(store.currentSpaceID == origin.id) target=\(store.currentSpaceID == target.id) app=\(NSApp.isActive) key=\(window.isKeyWindow) animation=\(String(describing: slide.outgoing.layer?.animation(forKey: "space-position")))"
            return slide.isActive && abs(slide.offset) > width * 0.45 && abs(slide.offset) < width * 0.8
                && TabStore.all.first { $0.window === window }?.currentSpaceID == target.id
                && slide.outgoing.layer?.animation(forKey: "space-position") != nil
        }
        XCTAssertEqual(TabStore.all.first { $0.window === window }?.currentSpaceID, target.id)
        let originalRows = slide.outgoing
        let presentedX = try XCTUnwrap(originalRows.layer?.presentation()).frame.minX

        NSApp.sendEvent(ScrollEvent(window: window, phase: .began))
        NSApp.sendEvent(ScrollEvent(window: window, dx: sign * 12))
        XCTAssertTrue(host.spaceSlide === slide, "Reversing must retain both captured native surfaces")
        XCTAssertTrue(slide.isActive, "The next swipe must own the still-unfinished transition")
        XCTAssertNil(originalRows.layer?.animation(forKey: "space-position"))
        XCTAssertEqual(originalRows.frame.minX, presentedX + sign * 12, accuracy: 5,
                       "Take over at the visible position, without snapping to the old endpoint")
        let held = originalRows.frame.minX
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertTrue(host.spaceSlide === slide && slide.isActive,
                      "The previous animation completion must not retire the new gesture")
        XCTAssertEqual(originalRows.frame.minX, held, accuracy: 1)
        NSApp.sendEvent(ScrollEvent(window: window, dx: sign * 40))
        XCTAssertEqual(originalRows.frame.minX, held + sign * 40, accuracy: 1)
        NSApp.sendEvent(ScrollEvent(window: window, phase: .ended))
        try await Task.sleep(for: .milliseconds(400))
        let showing = try XCTUnwrap(TabStore.all.first { $0.window === window })
        XCTAssertEqual(showing.currentSpaceID, origin.id)
        XCTAssertFalse(showing.spaceSwiping)
        XCTAssertNil(host.spaceSlide)
    }

    func testRapidBackToBackSwipesDoNotWaitForThePreviousLanding() async throws {
        for direction: CGFloat in [-1, 1] {
            let (store, spaces, window, _) = try fixture()
            store.switchTo(space: direction < 0 ? spaces[0] : spaces[3])
            store.palette = nil
            try await Task.sleep(for: .milliseconds(150))
            for _ in 0..<2 {
                NSApp.sendEvent(ScrollEvent(window: window, phase: .began))
                NSApp.sendEvent(ScrollEvent(window: window, dx: direction * 100))
                NSApp.sendEvent(ScrollEvent(window: window, phase: .ended))
                try await Task.sleep(for: .milliseconds(40))
            }
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(store.currentSpaceID, spaces[direction < 0 ? 2 : 1].id,
                           "Two distinct quick gestures must each change Space, in either direction")
        }
    }

    /// Diagnose the populated path separately from the empty-Space correctness fixture.
    func testPopulatedRapidSwipeInputTiming() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_UI_PERFORMANCE"] == "1")
        let (store, spaces, window, _) = try fixture()
        for space in spaces {
            store.switchTo(space: space)
            store.tabs = (0..<32).map { index in
                let tab = Tab(profileID: store.profileID)
                tab.park(url: URL(string: "about:blank#\(space.name)-\(index)")!,
                         Parked(title: "\(space.name) document \(index)"))
                return tab
            }
            store.syncShapes()
        }
        store.switchTo(space: spaces[0])
        store.palette = nil
        try await Task.sleep(for: .milliseconds(700))
        print("POPULATED_SWIPE_READY pid=\(ProcessInfo.processInfo.processIdentifier)")
        for leg in 0..<12 {
            let direction: CGFloat = leg % 6 < 3 ? -1 : 1
            let start = ProcessInfo.processInfo.systemUptime
            NSApp.sendEvent(ScrollEvent(window: window, phase: .began))
            NSApp.sendEvent(ScrollEvent(window: window, dx: direction * 100))
            let claimed = ProcessInfo.processInfo.systemUptime
            NSApp.sendEvent(ScrollEvent(window: window, phase: .ended))
            print("POPULATED_SWIPE leg=\(leg) claim_ms=\((claimed - start) * 1000) release_ms=\((ProcessInfo.processInfo.systemUptime - claimed) * 1000)")
            try await Task.sleep(for: .milliseconds(70))
        }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(store.currentSpaceID, spaces[0].id)
    }

    func testNativeSwipePreparationKeepsOneLiveSidebarUntilItsOverlayIsMounted() async throws {
        let (store, _, window, _) = try fixture()
        try await Task.sleep(for: .milliseconds(120))
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let live = try XCTUnwrap(host.subviews.first { !($0 is ProfileSpaceSlide) })
        XCTAssertNotNil(SidebarSectionsViewport.scrollView(in: live))
        // Native claim publishes its direction before inserting the compositor overlay.
        // That interval must not build additional fallback SwiftUI sidebar trees.
        store.spaceSwiping = true
        store.spaceDrag = -60
        live.layoutSubtreeIfNeeded()
        XCTAssertNotNil(SidebarSectionsViewport.scrollView(in: live),
                        "Native preparation must retain one live viewport, without mounting duplicate ghost lists")
    }

    func testNativeFingerSamplePublishesOneCoherentGestureChange() async throws {
        let (store, _, window, monitor) = try fixture()
        try await Task.sleep(for: .milliseconds(150))
        var changes = 0
        let observation = store.spaceGesture.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        monitor.track(-50, width: fixtureSidebarWidth(in: store), in: store)
        XCTAssertNotNil((window.contentView as? BrowserWindowHost)?.spaceSlide)
        XCTAssertTrue(store.spaceSwiping)
        XCTAssertTrue(store.spaceGesture.profileSliding)
        XCTAssertEqual(changes, 1,
                       "One native input must not flush several intermediate browser presentation states")
    }

    func testNativeLandingRetainsTheLiveScrollShellAndResetsItsOffset() async throws {
        let (store, spaces, window, monitor) = try fixture()
        for space in spaces.prefix(2) {
            store.switchTo(space: space)
            store.tabs = (0..<32).map { index in
                let tab = Tab(profileID: store.profileID)
                tab.park(url: URL(string: "about:blank#shell-\(space.id)-\(index)")!, Parked(title: "Row \(index)"))
                return tab
            }
            store.syncShapes()
        }
        store.switchTo(space: spaces[0])
        store.palette = nil
        try await Task.sleep(for: .milliseconds(200))
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let live = try XCTUnwrap(host.subviews.first { !($0 is ProfileSpaceSlide) })
        let viewport = try XCTUnwrap(SidebarSectionsViewport.scrollView(in: live))
        viewport.contentView.scroll(to: CGPoint(x: 0, y: 100))
        viewport.reflectScrolledClipView(viewport.contentView)
        try await Task.sleep(for: .milliseconds(80))
        monitor.track(-80, width: fixtureSidebarWidth(in: store), in: store)
        monitor.land(1, to: spaces[1], width: fixtureSidebarWidth(in: store), store: store, duration: 0.8)
        try await compatibilityWait { store.currentSpaceID == spaces[1].id }
        live.layoutSubtreeIfNeeded()
        XCTAssertTrue(SidebarSectionsViewport.scrollView(in: live) === viewport,
                      "A covering native slide must not rebuild the live scroll/layout/focus shell")
        try await compatibilityWait { abs(viewport.documentVisibleRect.minY) < 1 }
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertNil(host.spaceSlide)
        store.switchTo(space: spaces[0])
        try await compatibilityWait {
            guard let next = SidebarSectionsViewport.scrollView(in: live) else { return false }
            return next !== viewport
        }
    }

    func testLandingDoesNotRebuildTheMenuAfterSelectionHasUpdatedIt() async throws {
        let (store, spaces, _, monitor) = try fixture()
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        try await Task.sleep(for: .milliseconds(150))
        monitor.track(-80, width: fixtureSidebarWidth(in: store), in: store)
        monitor.land(1, to: spaces[1], width: fixtureSidebarWidth(in: store), store: store, duration: 0.8)
        try await compatibilityWait { store.currentSpaceID == spaces[1].id }
        let menu = try XCTUnwrap(NSApp.mainMenu)
        try await compatibilityWait { !store.spaceSwiping }
        XCTAssertTrue(NSApp.mainMenu === menu,
                      "Finishing a covered animation must not synchronously rebuild the already updated menu")
    }

    func testDestinationVisibilityNotificationCannotAbortTheSourceLanding() async throws {
        try await withFixtureApplicationLoop {
            let (source, spaces, window, monitor) = try self.fixture(registerTeardown: false)
            let arriving = TabStore(profileID: source.profileID, space: spaces[1], session: [])
            defer {
                arriving.spaceGesture.monitor.remove()
                arriving.window = nil
                arriving.dropStashes()
                TabStore.all.removeAll { $0 === arriving }
                self.retireFixture(source, window: window, monitor: monitor)
            }
            let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
            let slide = ProfileSpaceSlide(frame: NSRect(x: 0, y: 0, width: 228, height: 300),
                outgoing: source.swipePreview(in: spaces[0]), incoming: source.swipePreview(in: spaces[1]),
                drag: -70, direction: 1, source: source, includesFavorites: true, travelWidth: 228)
            host.beginSpaceSlide(slide, preservingGround: true)
            slide.start(duration: 2) {}
            arriving.profileVisible = false
            arriving.window = window
            arriving.spaceGesture.monitor.install(arriving)
            slide.attach(arriving)
            var removals = 0
            let visibility = arriving.$profileVisible.dropFirst().sink { visible in
                guard visible else { return }
                XCTAssertFalse(arriving.profileVisible, "@Published delivers the incoming value before assignment")
                removals += 1
                arriving.spaceGesture.monitor.remove()
            }
            defer { visibility.cancel() }
            arriving.profileVisible = true
            XCTAssertEqual(removals, 1)
            XCTAssertTrue(slide.isActive, "Removing destination input must preserve the source's committed cover")
            XCTAssertTrue(host.spaceSlide === slide)
            XCTAssertTrue(arriving.spaceSwiping)
            arriving.spaceGesture.monitor.install(arriving)
            arriving.spaceGesture.monitor.abort()
            XCTAssertFalse(slide.isActive, "An explicit abort must still cancel an attached landing")
        }
    }


    func testProfileClickStartsCapturedTravelBeforePreparingTheDestination() async throws {
        try await withFixtureApplicationLoop {
            try XCTSkipIf(Motion.spaceReduced, "Requires animated profile navigation")
            let manager = ProfileManager.shared
            let previous = manager.active
            let profiles = [fixtureProfile(named: "Responsive source"), fixtureProfile(named: "Responsive arrival")]
            let first = manager.createSpace(name: "Source", in: profiles[0].id)
            var second = manager.createSpace(name: "Arrival", in: profiles[1].id)
            second.tabURLs = [URL(string: "about:blank")!]
            XCTAssertTrue(manager.updateSpace(second))
            let source = Windows.open(profile: profiles[0], space: first, focus: false)
            let window = try XCTUnwrap(source.window)
            window.animationBehavior = .none
            defer {
                self.retireProfileWindow(window)
                profiles.forEach { _ = manager.delete($0.id) }
                manager.active = previous
            }
            source.palette = nil
            try await self.admitFixtureSidebar(source, window: window)
            let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
            source.spaceGesture.monitor.select(second, in: source)
            let slide = try XCTUnwrap(host.spaceSlide)
            XCTAssertTrue(slide.hasStartedLanding,
                          "Captured travel must start in the input action, before live profile restoration")
            XCTAssertNotNil(slide.outgoing.layer?.animation(forKey: "space-position"))
            XCTAssertFalse(TabStore.all.contains { $0.profileID == profiles[1].id && $0.parkedIn === window },
                           "Do not construct and lay out a hidden destination browser in the input action")
            XCTAssertTrue(source.window === window, "Page activation stays on the queued handoff")
            try await compatibilityWait {
                TabStore.all.contains { $0.window === window && $0.currentSpaceID == second.id }
                    && host.spaceSlide == nil
            }
        }
    }

    func testPreparedProfileKeepsWindowAuthorityWithSourceUntilHop() async throws {
        try await withFixtureApplicationLoop {
            let manager = ProfileManager.shared
            let previous = manager.active
            let profiles = [fixtureProfile(named: "Prepared source"), fixtureProfile(named: "Prepared arrival")]
            let first = manager.createSpace(name: "Source", in: profiles[0].id)
            var second = manager.createSpace(name: "Arrival", in: profiles[1].id)
            second.tabURLs = [URL(string: "about:blank")!]
            XCTAssertTrue(manager.updateSpace(second))
            let source = Windows.open(profile: profiles[0], space: first, focus: false)
            let window = try XCTUnwrap(source.window)
            window.animationBehavior = .none
            defer {
                self.retireProfileWindow(window)
                profiles.forEach { _ = manager.delete($0.id) }
                manager.active = previous
            }
            source.palette = nil
            try await compatibilityWait {
                if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
                if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
                return NSApp.isRunning && NSApp.isActive && NSApp.keyWindow === window
                    && source.window === window && source.profileVisible
            }
            let activeBeforePreparation = manager.active.id
            XCTAssertTrue(window.makeFirstResponder(window), "Admit a stable source responder before preparing a hidden root")
            let responderBeforePreparation = window.firstResponder
            let arriving = try XCTUnwrap(Windows.prepareHop(source, to: second))
            XCTAssertTrue(source.window === window && source.profileVisible)
            XCTAssertEqual(manager.active.id, activeBeforePreparation)
            XCTAssertTrue(window.firstResponder === responderBeforePreparation,
                          "A hidden prepared profile must not take keyboard authority")
            XCTAssertNil(arriving.window)
            XCTAssertTrue(arriving.parkedIn === window)
            XCTAssertFalse(arriving.profileVisible)
            let surface = try XCTUnwrap(arriving.spaceGesture.groundSurface)
            XCTAssertTrue(surface.window === window && surface.isHiddenOrHasHiddenAncestor,
                          "Preparing the committed chrome must not expose another profile")
            let tab = try XCTUnwrap(arriving.active)
            XCTAssertFalse(arriving.ownsPage(tab),
                           "Preparing chrome must not bypass SharedTabs page ownership")
            let page = try XCTUnwrap(tab.existingWeb)
            XCTAssertNil(page.window)
            source.switchTo(space: second)
            XCTAssertTrue(arriving.ownsPage(tab))
            XCTAssertTrue(TabStore.all.first { $0.window === window } === arriving,
                          "Activation must reuse the prepared profile's backend and native host")
            XCTAssertTrue(source.parkedIn === window && !source.profileVisible)
        }
    }


    func testAttachedArrivalSharesTheSourceWashClockWithoutPointUpdates() async throws {
        try await withFixtureApplicationLoop {
            let (source, spaces, window, monitor) = try self.fixture(coloured: true, registerTeardown: false)
            defer { self.retireFixture(source, window: window, monitor: monitor) }
            let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
            let sourceSurface = try XCTUnwrap(self.colourSurface(in: host))
            let arriving = TabStore(profileID: source.profileID, space: spaces[1], session: [])
            let target = ThemeWash.space(spaces[1], fallback: source.profile,
                profiles: ProfileManager.shared.profiles, systemDark: true)
            let cached = NSHostingView(rootView: NativeThemeWash(wash: target, reduced: false,
                gesture: arriving.spaceGesture, origin: target, destination: target,
                fallback: source.profile, profiles: ProfileManager.shared.profiles, systemDark: true))
            cached.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
            host.addSubview(cached)
            defer {
                cached.removeFromSuperview()
                arriving.dropStashes()
                TabStore.all.removeAll { $0 === arriving }
            }
            try await compatibilityWait {
                cached.layoutSubtreeIfNeeded()
                return arriving.spaceGesture.trackGround != nil && sourceSurface.base.presentation() != nil
                    && self.colourSurface(in: cached)?.base.presentation() != nil
            }
            let arrivingSurface = try XCTUnwrap(self.colourSurface(in: cached))
            let slide = ProfileSpaceSlide(frame: cached.frame,
                outgoing: source.swipePreview(in: spaces[0]), incoming: source.swipePreview(in: spaces[1]),
                drag: -70, direction: 1, source: source, includesFavorites: true, travelWidth: 228)
            host.beginSpaceSlide(slide, preservingGround: true)
            defer { slide.cancel() }
            slide.start(duration: 0.8) {}
            try await Task.sleep(for: .milliseconds(200))
            slide.attach(arriving)
            // A parked destination receives no publishProgress callback. Its own
            // compositor must join the curve already running on the source.
            XCTAssertNil(arriving.window)
            try await Task.sleep(for: .milliseconds(80))
            let sourceRed = try self.firstColour(of: sourceSurface, presented: true).redComponent
            let arrivingRed = try self.firstColour(of: arrivingSurface, presented: true).redComponent
            XCTAssertEqual(arrivingRed, sourceRed, accuracy: 0.03,
                           "A late-mounted profile must share the existing wash clock without point updates")
        }
    }

    func testProfileWashTravelGateRejectsStationaryAndSnappedFrames() {
        XCTAssertTrue(ProfileWashSampler.travelValues(in: [0.8, 0.8, 0.8, 0.8], held: 0.8).isEmpty)
        XCTAssertTrue(ProfileWashSampler.travelValues(in: [0.8, 0.2, 0.2, 0.2, 0.2], held: 0.8).isEmpty)
        XCTAssertTrue(ProfileWashSampler.travelValues(in: [0.2, 0.8, 0.8, 0.8, 0.8], held: 0.2).isEmpty)
        XCTAssertEqual(ProfileWashSampler.travelValues(in: [0.8, 0.5, 0.5, 0.5, 0.2], held: 0.8), [0.5])
        XCTAssertEqual(ProfileWashSampler.travelValues(in: [0.8, 0.65, 0.5, 0.35, 0.25, 0.2], held: 0.8).count, 4)
    }

    func testCachedProfileColourStaysContinuousAcrossRepeatedSwipes() async throws {
        try await withFixtureApplicationLoop {
            for mixedThemes in [false, true] {
                try await checkRepeatedProfileSwipes(mixedThemes: mixedThemes)
            }
        }
    }

    func testCachedArrivingWashIsPrimedBeforeItsNextSwiftUIUpdate() async throws {
        let (source, spaces, window, _) = try fixture(coloured: true)
        let container = try XCTUnwrap(window.contentView)
        let arriving = TabStore(profileID: source.profileID, space: spaces[1], session: [])
        let target = ThemeWash.space(spaces[1], fallback: source.profile,
                                     profiles: ProfileManager.shared.profiles, systemDark: true)
        // A parked host last rendered its settled destination, so its installed
        // callback still captures two identical blue endpoints when attach runs.
        let cached = NSHostingView(rootView: NativeThemeWash(wash: target, reduced: false,
            gesture: arriving.spaceGesture, origin: target, destination: target,
            fallback: source.profile, profiles: ProfileManager.shared.profiles, systemDark: true))
        cached.frame = NSRect(x: 0, y: 0, width: 200, height: 300)
        container.addSubview(cached)
        defer {
            cached.removeFromSuperview()
            arriving.window = nil
            TabStore.all.removeAll { $0 === arriving }
        }
        cached.layoutSubtreeIfNeeded()
        try await compatibilityWait { arriving.spaceGesture.trackGround != nil }
        let surface = try XCTUnwrap(colourSurface(in: cached))
        let origin = ThemeWash.space(spaces[0], fallback: source.profile,
            profiles: ProfileManager.shared.profiles, systemDark: true)
        // Interpolate in the wash's color space before converting for the native
        // layer read; device-RGB conversion is not itself a linear interpolation.
        func expectedRed(at fraction: Double) throws -> CGFloat {
            try XCTUnwrap(origin.mixed(towards: target, fraction: fraction)
                .colors[0].nsColor.usingColorSpace(.deviceRGB)).redComponent
        }
        cached.isHidden = true
        let slide = ProfileSpaceSlide(frame: cached.frame,
            outgoing: source.swipePreview(in: spaces[0]), incoming: source.swipePreview(in: spaces[1]),
            drag: -70, direction: 1, source: source, includesFavorites: true, travelWidth: 228)
        container.addSubview(slide)
        defer { slide.cancel() }
        slide.prepare()
        slide.start(duration: 1) {}
        slide.attach(arriving)
        XCTAssertEqual(try XCTUnwrap(arriving.spaceGesture.nativeDrag), -70, accuracy: 0.001,
                       "SwiftUI must receive the same published progress as the primed native wash")
        // No await/layout occurs between attachment and this read. The pixels must
        // be ready before the cached host is exposed, even before CA presents the
        // new position animation (whose model position already holds its endpoint).
        XCTAssertEqual(try firstColour(of: surface).redComponent,
                       try expectedRed(at: 70.0 / 228.0), accuracy: 0.001,
                       "A cached host must not expose its settled target color before tracking catches up")
        arriving.spaceGesture.trackGround?(0.5)
        XCTAssertEqual(try firstColour(of: surface).redComponent, try expectedRed(at: 0.5), accuracy: 0.001,
                       "The installed callback must resolve the new gesture endpoints before SwiftUI renders again")
    }

    private func withProfileWashSampler(host: BrowserWindowHost, screen: NSScreen,
                                        _ body: (ProfileWashSampler) async throws -> Void) async throws {
        let sampler = ProfileWashSampler(host: host)
        sampler.start(on: screen)
        do { try await body(sampler) }
        catch {
            let primary = error
            do { try await sampler.close() }
            catch { XCTFail("Profile sampler cleanup also failed: \(error)") }
            throw primary
        }
        try await sampler.close()
    }

    private func withProfilePixelCharacterization(source: TabStore, host: BrowserWindowHost, window: NSWindow,
                                                  _ body: (ProfilePixelCharacterization) async throws -> Void) async throws {
        let pixels = ProfilePixelCharacterization()
        do {
            try await pixels.start(source: source, host: host, window: window)
            try await body(pixels)
        } catch {
            let primary = error
            do { try await pixels.stop() }
            catch { XCTFail("Profile pixel characterization cleanup also failed: \(error)") }
            pixels.dump()
            throw primary
        }
        do { try await pixels.stop() }
        catch { pixels.dump(); throw error }
        pixels.dump()
    }

    private func checkRepeatedProfileSwipes(mixedThemes: Bool) async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "Requires animated profile navigation")
        let manager = ProfileManager.shared
        let previous = manager.active
        let profiles = [fixtureProfile(named: "Repeated red"), fixtureProfile(named: "Repeated blue")]
        let spaces = profiles.enumerated().map { index, profile in
            Space(name: "Repeated \(index)", profileID: profile.id,
                  colorHex: mixedThemes ? (index == 0 ? "#000000" : "#26456B") : (index == 0 ? "#FF0000" : "#0000FF"),
                  appearance: mixedThemes ? nil : "dark", tint: mixedThemes ? (index == 0 ? 0.8953 : 0.6246) : 1)
        }
        for (profile, space) in zip(profiles, spaces) {
            XCTAssertTrue(manager.saveSpaces([space], for: profile.id))
        }
        let source = Windows.open(profile: profiles[0], space: spaces[0], focus: false)
        let window = try XCTUnwrap(source.window)
        window.animationBehavior = .none
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            retireProfileWindow(window)
            profiles.forEach { _ = manager.delete($0.id) }
            manager.active = previous
        }
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        for (index, space) in spaces.enumerated() {
            let showing = try XCTUnwrap(TabStore.all.first { $0.window === window })
            showing.switchTo(space: space)
            let owner = try XCTUnwrap(TabStore.all.first { $0.window === window })
            for row in 0..<20 {
                let tab = owner.newBlankTab(focus: false)
                tab.park(url: URL(string: "about:blank#\(row)")!, Parked(title: "Profile \(index) document \(row)"))
            }
            owner.palette = nil
        }
        TabStore.all.first { $0.window === window }?.switchTo(space: spaces[0])
        try await Task.sleep(for: .milliseconds(150))
        try await withProfilePixelCharacterization(source: source, host: host, window: window) { pixels in
        // Alternate twelve times with both saturated themes and mixed default themes.
        for leg in 0..<12 {
            let index = (leg + 1) % 2
            let showing = try XCTUnwrap(TabStore.all.first { $0.window === window })
            let direction = index == 1 ? 1 : -1
            let monitor = showing.spaceGesture.monitor
            try await withProfileWashSampler(host: host, screen: XCTUnwrap(window.screen)) { sampler in
                // A new display link and a freshly restored hosting tree may not have
                // presented yet. Establish actual source-color samples before asking
                // this sampler to verify the subsequent transition's continuity.
                try await compatibilityWait {
                    if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
                    if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
                    return NSApp.isRunning && NSApp.isActive && window.isKeyWindow && NSApp.keyWindow === window
                        && host.window === window && showing.window === window && showing.profileVisible
                        && sampler.reds.count >= 3
                }
                sampler.beginTransitionSampling()
                let observers = [
                    NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
                        MainActor.assumeIsolated { sampler.foregroundInterrupted = true }
                    },
                    NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { _ in
                        MainActor.assumeIsolated { sampler.foregroundInterrupted = true }
                    }
                ]
                defer { observers.forEach(NotificationCenter.default.removeObserver) }
                let actionBegan = CACurrentMediaTime()
                XCTAssertNotNil(showing.beginSpaceSelection(spaces[index]))
                monitor.track(-CGFloat(direction) * 70, width: fixtureSidebarWidth(in: source), in: showing)
                try await sampler.admitTransitionLayers()
                pixels.beginLeg(label: "mixed=\(mixedThemes) leg=\(leg) direction=\(direction)")
                monitor.land(direction, to: spaces[index], width: fixtureSidebarWidth(in: source),
                             store: showing, duration: 0.3)
                print("PROFILE_ACTION mixed=\(mixedThemes) leg=\(leg) actionMS=\((CACurrentMediaTime() - actionBegan) * 1000) active=\(NSApp.isActive) key=\(window.isKeyWindow)")
                // Hosting/layout can defer CA's first commit beyond the nominal
                // duration. Sample the entire handoff, including its actual endpoint,
                // rather than stopping at an assumed 450 ms wall-clock deadline.
                let retirementDeadline = ContinuousClock.now + .seconds(2)
                while host.spaceSlide != nil, ContinuousClock.now < retirementDeadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                pixels.endLeg()
                try await sampler.close()
                sampler.dumpLayerCharacterization(label: "mixed=\(mixedThemes) leg=\(leg) direction=\(direction)")
                try sampler.validateTransitionLayers()
                XCTAssertEqual(TabStore.all.first { $0.window === window }?.currentSpaceID, spaces[index].id)
                XCTAssertFalse(sampler.foregroundInterrupted, "Profile sampling must retain actual foreground ownership")
                XCTAssertGreaterThan(sampler.reds.count, 3)
                XCTAssertGreaterThan(sampler.travelReds.count, 3,
                                     "Observe distinct travel frames, excluding the held position and settled endpoint")
                XCTAssertEqual(sampler.unadmittedTransitionCallbacks, 0,
                               "Every transition callback must identify exactly one presented wash; missing samples cannot pass continuity")
                let reversals = zip(sampler.reds, sampler.reds.dropFirst()).map { previous, next in
                    (direction == 1) != mixedThemes ? next - previous : previous - next
                }
                print("PROFILE_WASH_SAMPLE mixed=\(mixedThemes) leg=\(leg) direction=\(direction) frames=\(sampler.reds.count) max_reverse=\(reversals.max() ?? 0) max_gap_ms=\(sampler.maxGap * 1000) first_callback_ms=\((sampler.firstCallbackLatency ?? 0) * 1000)")
                if (reversals.max() ?? 0) >= 0.08 || sampler.unadmittedTransitionCallbacks > 0 {
                    sampler.dumpDiagnostics(label: "mixed=\(mixedThemes) leg=\(leg) direction=\(direction)")
                }
                XCTAssertLessThan(reversals.max() ?? 0, 0.08,
                                  "The displayed background must not flash back toward its source after profile activation")
                XCTAssertNil(host.spaceSlide)
                XCTAssertEqual(showing.spaceDrag, 0, "Parked profile progress must be released at every landing")
                try await pixels.completeLegObservation()
            }
        }
        }
    }

    func testCachedProfileChangesPageAtStartOfNativeLanding() async throws {
        try await withFixtureApplicationLoop { try await checkEarlyProfilePageSelection(cached: true) }
    }

    func testCachedProfileReturnInstallsInputBeforeTheNextRender() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let manager = ProfileManager.shared
        let previous = manager.active
        let profiles = [fixtureProfile(named: "Input origin"), fixtureProfile(named: "Input arrival")]
        let spaces = profiles.map { manager.createSpace(name: "Input", in: $0.id) }
        let source = Windows.open(profile: profiles[0], space: spaces[0], focus: false)
        let window = try XCTUnwrap(source.window)
        window.animationBehavior = .none
        defer {
            retireProfileWindow(window)
            profiles.forEach { _ = manager.delete($0.id) }
            manager.active = previous
        }
        source.palette = nil
        try await compatibilityWait { source.spaceGesture.monitor.isInstalled }
        let arriving = try XCTUnwrap(Windows.hop(source, to: spaces[1]))
        try await compatibilityWait {
            !source.spaceGesture.monitor.isInstalled && arriving.spaceGesture.monitor.isInstalled
        }
        XCTAssertTrue(Windows.hop(arriving, to: spaces[0]) === source)
        XCTAssertTrue(source.spaceGesture.monitor.isInstalled,
                      "Cached profiles must accept the next gesture before SwiftUI renders their visibility change")
    }

    func testRapidProfileBoundarySwipesCanImmediatelyReverse() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do { try await checkRapidProfileBoundarySwipesCanImmediatelyReverse() }
        catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Rapid profile AppKit loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func checkRapidProfileBoundarySwipesCanImmediatelyReverse() async throws {
        try XCTSkipIf(Motion.spaceReduced, "Requires animated profile navigation")
        let manager = ProfileManager.shared
        let previous = manager.active
        let profiles = [fixtureProfile(named: "Rapid origin"), fixtureProfile(named: "Rapid arrival")]
        let spaces = profiles.map { manager.createSpace(name: "Rapid", in: $0.id) }
        let source = Windows.open(profile: profiles[0], space: spaces[0], focus: false)
        let window = try XCTUnwrap(source.window)
        window.animationBehavior = .none
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        defer {
            retireProfileWindow(window)
            profiles.forEach { _ = manager.delete($0.id) }
            manager.active = previous
        }
        source.palette = nil
        try await compatibilityWait {
            if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            return NSApp.isRunning && NSApp.isActive && NSApp.keyWindow === window
                && window.isVisible && window.occlusionState.contains(.visible)
                && NSApp.modalWindow == nil && window.attachedSheet == nil
                && source.window === window && source.profileVisible
                && source.spaceGesture.sectionsView?.window === window
                && source.spaceGesture.monitor.isInstalled
        }
        for leg in 0..<8 {
            let direction: CGFloat = leg.isMultiple(of: 2) ? -1 : 1
            NSApp.sendEvent(ScrollEvent(window: window, phase: .began))
            NSApp.sendEvent(ScrollEvent(window: window, dx: direction * 100))
            NSApp.sendEvent(ScrollEvent(window: window, phase: .ended))
            try await Task.sleep(for: .milliseconds(40))
            let showing = TabStore.all.first { $0.window === window }
            print("RAPID_PROFILE leg=\(leg) actual=\(showing?.profileID == profiles[0].id ? 0 : 1) installed=\(showing?.spaceGesture.monitor.isInstalled == true) swiping=\(showing?.spaceSwiping == true) anchor=\(showing?.spaceGesture.stripView?.window === window)")
            XCTAssertEqual(TabStore.all.first { $0.window === window }?.currentSpaceID,
                           spaces[leg.isMultiple(of: 2) ? 1 : 0].id,
                           "Every fast boundary crossing and reversal must be accepted")
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(source.window === window)
        XCTAssertNil((window.contentView as? BrowserWindowHost)?.spaceSlide)
    }

    private func checkEarlyProfilePageSelection(cached: Bool) async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "Native landing requires animation")
        let manager = ProfileManager.shared
        let previous = manager.active
        let firstProfile = fixtureProfile(named: "Early page origin")
        let secondProfile = fixtureProfile(named: "Early page arrival")
        var first = manager.createSpace(name: "A", in: firstProfile.id)
        first.colorHex = "#FF0000"; first.tint = 1; first.appearance = "dark"
        XCTAssertTrue(manager.updateSpace(first))
        var second = manager.createSpace(name: "B", in: secondProfile.id)
        second.colorHex = "#0000FF"; second.tint = 1; second.appearance = "dark"
        second.tabURLs = [URL(string: "about:blank")!]
        XCTAssertTrue(manager.updateSpace(second))
        let other = manager.createSpace(name: "Other parked Space", in: secondProfile.id)
        let source = Windows.open(profile: firstProfile, space: first, focus: false)
        let window = try XCTUnwrap(source.window)
        window.animationBehavior = .none
        window.orderFrontRegardless()
        defer {
            retireProfileWindow(window)
            _ = manager.delete(firstProfile.id)
            _ = manager.delete(secondProfile.id)
            manager.active = previous
        }
        let callbackProbe = ProfileLandingCallbackProbe(window: window, targetID: second.id)
        callbackProbe.start(on: try XCTUnwrap(window.screen))
        defer { callbackProbe.stopAndDump(label: "early cached=\(cached)") }
        if cached {
            source.switchTo(space: second)
            let arriving = try XCTUnwrap(TabStore.all.first { $0.window === window })
            try await compatibilityWait {
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                CATransaction.flush()
                return arriving.window === window && arriving.profileVisible
                    && arriving.active?.web.window === window
                    && arriving.active?.web.isLoading == false
            }
            arriving.switchTo(space: other)
            try await compatibilityWait {
                window.contentView?.layoutSubtreeIfNeeded()
                return arriving.currentSpaceID == other.id
                    && SidebarNativeReadinessCoordinator.shared.isReady(
                        SidebarNativeReadinessScope(store: arriving, spaceID: other.id),
                        allowingUnregistered: !NativeCachedSidebarBatchesExperiment.enabled)
            }
            arriving.switchTo(space: first)
        }
        source.newTab(URL(string: "about:blank")!)
        source.palette = nil
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await compatibilityWait {
            if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            return NSApp.isRunning && NSApp.isActive && window.isKeyWindow && NSApp.keyWindow === window
                && window.isVisible && window.occlusionState.contains(.visible)
                && source.window === window && source.profileVisible
                && source.active?.web.window === window
                && source.spaceGesture.sectionsView?.window === window
                && source.spaceGesture.monitor.isInstalled
        }
        let sourcePage = try XCTUnwrap(source.active?.web)
        try await compatibilityWait {
            window.contentView?.layoutSubtreeIfNeeded()
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            if NSApp.keyWindow !== window { window.makeKeyAndOrderFront(nil) }
            guard NSApp.isRunning, NSApp.isActive, NSApp.keyWindow === window,
                  window.isVisible, window.occlusionState.contains(.visible),
                  NSApp.modalWindow == nil, window.attachedSheet == nil,
                  sourcePage.window === window, !sourcePage.isHiddenOrHasHiddenAncestor,
                  let anchor = source.spaceGesture.stripView, anchor.window === window,
                  let surface = self.colourSurface(in: try XCTUnwrap(window.contentView)),
                  surface.base.presentation() != nil,
                  let presented = try? self.firstColour(of: surface, presented: true),
                  let model = try? self.firstColour(of: surface),
                  SidebarNativeReadinessCoordinator.shared.isReady(
                    SidebarNativeReadinessScope(store: source, spaceID: first.id),
                    allowingUnregistered: !NativeCachedSidebarBatchesExperiment.enabled) else { return false }
            return abs(presented.redComponent - model.redComponent) < 0.001
        }
        var observedCachedSelection = false
        let selection = TabStore.all.first { $0.parkedIn === window && $0.profileID == secondProfile.id }?
            .$currentSpaceID.sink { id in
                guard id == second.id else { return }
                observedCachedSelection = true
                XCTAssertTrue(sourcePage.window === window && !sourcePage.isHiddenOrHasHiddenAncestor,
                              "Select the requested cached Space before uncovering its profile host")
            }
        defer { selection?.cancel() }
        let monitor = source.spaceGesture.monitor
        XCTAssertNotNil(source.beginSpaceSelection(second))
        monitor.track(-60, width: fixtureSidebarWidth(in: source), in: source)
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let slide = try XCTUnwrap(host.spaceSlide)
        XCTAssertTrue(source.window === window, "Finger tracking must keep the outgoing page")
        callbackProbe.begin(slide: slide)
        monitor.land(1, to: second, width: fixtureSidebarWidth(in: source), store: source, duration: 0.8)
        try await Task.sleep(for: .milliseconds(100))
        callbackProbe.noteTask("early100")
        let arriving = try XCTUnwrap(TabStore.all.first { $0.window === window })
        XCTAssertEqual(arriving.profileID, secondProfile.id,
                       "Profile activation must not wait for the sidebar animation to finish")
        XCTAssertEqual(arriving.currentSpaceID, second.id)
        if cached { XCTAssertTrue(observedCachedSelection) }
        let pageMounted = arriving.active?.web.window === window
        if !pageMounted {
            print("EARLY_PROFILE_PAGE cached=\(cached) tabs=\(arriving.tabs.count) active=\(String(describing: arriving.active?.id)) superview=\(String(describing: arriving.active?.web.superview)) profileVisible=\(arriving.profileVisible) activeApp=\(NSApp.isActive) key=\(window.isKeyWindow)")
        }
        XCTAssertTrue(pageMounted,
                      "The destination web content must be mounted during landing")
        let surface = try XCTUnwrap(colourSurface(in: host))
        let colour = try firstColour(of: surface, presented: true)
        XCTAssertGreaterThan(colour.redComponent, 0.1,
                             "The background must continue blending after the early profile handoff")
        XCTAssertTrue(host.spaceSlide === slide && slide.isActive,
                      "The original captured sidebar must continue travelling over the new profile")
        XCTAssertTrue(arriving.spaceGesture.profileSliding,
                      "Live incoming rows must stay hidden underneath the moving sidebar")
        XCTAssertFalse(source.profileVisible)
        XCTAssertTrue(arriving.profileVisible)
        XCTAssertTrue(source.spaceGesture.monitor.preparedSlides.isEmpty,
                      "Parked roots must release their gesture preparation and observers")
        source.liveFolderSheet = true
        source.externalApp = ExternalApps.Prompt(url: URL(string: "example-app://background")!,
            scope: nil, tabID: source.active!.id, documentID: UUID(), scheme: "example-app", app: nil, name: nil)
        try await Task.sleep(for: .milliseconds(40))
        callbackProbe.noteTask("early40")
        XCTAssertNil(window.attachedSheet,
                     "A late result from a parked root must not present over the arriving profile")
        source.liveFolderSheet = false
        source.externalApp = nil
        let arrivingMonitor = arriving.spaceGesture.monitor
        XCTAssertFalse(arrivingMonitor.mine(ScrollEvent(window: window, phase: .began, x: 900), arriving))
        XCTAssertFalse(arrivingMonitor.mine(ScrollEvent(window: window, dy: 20, x: 900), arriving))
        XCTAssertTrue(host.spaceSlide === slide && slide.isActive,
                      "Scrolling over the page must not cut the sidebar landing short")
        XCTAssertFalse(arrivingMonitor.mine(ScrollEvent(window: window, phase: .began), arriving))
        XCTAssertFalse(arrivingMonitor.mine(ScrollEvent(window: window, dy: 20), arriving))
        XCTAssertTrue(host.spaceSlide === slide && slide.isActive,
                      "Vertical sidebar scrolling must not cut the landing short")
        XCTAssertEqual(arriving.spaceGesture.outgoing?.space.id, first.id,
                       "The arriving footer must keep the gesture's original Space")
        XCTAssertNotNil(arriving.spaceGesture.footer.drag)
        var footerFrames = 0
        let observation = arriving.spaceGesture.footer.$drag.dropFirst().sink { drag in
            guard let drag else { return }
            footerFrames += 1
            XCTAssertEqual(drag, slide.offset, accuracy: 2,
                           "Each arriving footer frame must follow the same native presentation")
        }
        defer { observation.cancel() }
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertGreaterThan(footerFrames, 2)
        if let retained = host.spaceSlide {
            print("EARLY_PROFILE_RETIREMENT cached=\(cached) sameSlide=\(retained === slide) \(retained.retirementDiagnosticString)")
        }
        XCTAssertNil(host.spaceSlide)
        XCTAssertFalse(arriving.spaceGesture.profileSliding)
        XCTAssertFalse(source.spaceSwiping)
        XCTAssertFalse(source.spaceGesture.profileSliding)
        XCTAssertEqual(source.spaceDrag, 0, "A parked source must not retain stale native travel")
    }

    func testQueuedDestinationStartsFromActualArrivingProfileStore() async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "Native queue requires animation")
        let manager = ProfileManager.shared
        let previous = manager.active
        let firstProfile = fixtureProfile(named: "Queued origin")
        let secondProfile = fixtureProfile(named: "Queued arrival")
        let first = manager.createSpace(name: "A", in: firstProfile.id)
        let second = manager.createSpace(name: "B", in: secondProfile.id)
        let third = manager.createSpace(name: "C", in: secondProfile.id)
        let source = Windows.open(profile: firstProfile, space: first, focus: false)
        let window = try XCTUnwrap(source.window)
        window.animationBehavior = .none
        defer {
            retireProfileWindow(window)
            _ = manager.delete(firstProfile.id)
            _ = manager.delete(secondProfile.id)
            manager.active = previous
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(source.beginSpaceSelection(second))
        source.spaceGesture.monitor.land(1, to: second, width: fixtureSidebarWidth(in: source), store: source, duration: 0.5)
        try await Task.sleep(for: .milliseconds(60))
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let original = try XCTUnwrap(host.spaceSlide)
        let showing = try XCTUnwrap(TabStore.all.first { $0.window === window })
        showing.spaceGesture.monitor.select(third, in: showing)
        XCTAssertTrue(host.spaceSlide === original)
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while (TabStore.all.first { $0.window === window }?.currentSpaceID != third.id || host.spaceSlide != nil),
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let arriving = try XCTUnwrap(TabStore.all.first { $0.window === window })
        XCTAssertEqual(arriving.profileID, secondProfile.id)
        XCTAssertEqual(arriving.currentSpaceID, third.id)
        XCTAssertFalse(arriving.spaceSwiping)
        XCTAssertNil(source.window)
        XCTAssertNil(host.spaceSlide)
    }

    func testFirstNativeDragReusesSurfacesPreparedWhileIdle() async throws {
        let (store, spaces, window, monitor) = try fixture()
        for space in spaces.prefix(2) {
            store.switchTo(space: space)
            for index in 0..<10 {
                let tab = store.newBlankTab(focus: false)
                tab.park(url: URL(string: "https://example.test/\(index)")!, Parked(title: "Document \(index)"))
            }
        }
        store.switchTo(space: spaces[0])
        store.palette = nil
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        for _ in 0..<50 where monitor.preparedSlides[spaces[1].id] == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id],
                                    "Adjacent surfaces must be laid out before finger movement")
        let originX = prepared.outgoing.frame.minX
        for offset: CGFloat in [-0.25, -0.5, -1, -2, -4] {
            let start = ProcessInfo.processInfo.systemUptime
            monitor.track(offset, width: fixtureSidebarWidth(in: store), in: store)
            print("INITIAL_NATIVE_DRAG offset=\(offset) seconds=\(ProcessInfo.processInfo.systemUptime - start)")
            let slide = try XCTUnwrap((window.contentView as? BrowserWindowHost)?.spaceSlide)
            XCTAssertTrue(slide === prepared, "The first sample must not construct a new hosting tree")
            XCTAssertEqual(slide.outgoing.frame.minX - originX, offset, accuracy: 0.001)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testPreparedSurfaceStaysAttachedToCompositorAtFirstDrag() async throws {
        try await withFixtureApplicationLoop { try await assertPreparedCompositorHandoff(selecting: false) }
    }

    func testPreparedSurfaceStaysAttachedToCompositorAtButtonSelection() async throws {
        try await withFixtureApplicationLoop { try await assertPreparedCompositorHandoff(selecting: true) }
    }

    private func assertPreparedCompositorHandoff(selecting: Bool) async throws {
        let (store, spaces, window, monitor) = try fixture(floatingWindow: true, registerTeardown: false)
        defer { retireFixture(store, window: window, monitor: monitor) }
        window.setContentSize(NSSize(width: 1280, height: 840))
        window.contentView?.wantsLayer = true
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while monitor.preparedSlides[spaces[1].id]?.layer?.superlayer !== host.layer,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        let layer = try XCTUnwrap(prepared.layer)
        let searchLayer = try XCTUnwrap(host.subviews.last?.layer)
        XCTAssertFalse(searchLayer === layer, "Search must remain above the captured sidebar")
        XCTAssertTrue(layer.superlayer === host.layer, "Idle preparation must already reach the compositor")
        XCTAssertTrue(prepared.isHidden, "Idle surfaces must not paint over the live sidebar")
        var content: NSView = try XCTUnwrap(store.spaceGesture.sectionsView)
        while let parent = content.superview, parent !== host { content = parent }
        XCTAssertTrue(content.superview === host)
        let contentLayer = try XCTUnwrap(content.layer)
        if selecting { monitor.select(spaces[1], in: store) }
        else { monitor.track(-10, width: fixtureSidebarWidth(in: store), in: store) }
        XCTAssertTrue(host.spaceSlide === prepared)
        XCTAssertTrue(store.spaceGesture.profileSliding)
        XCTAssertFalse(prepared.isHidden)
        XCTAssertFalse(layer.isHidden)
        XCTAssertTrue(layer.superlayer === host.layer,
                      "Hiding live sections must not detach their replacement until a later AppKit turn")
        let layers = try XCTUnwrap(host.layer?.sublayers)
        let replacementIndex = try XCTUnwrap(layers.firstIndex { $0 === layer })
        let contentIndex = try XCTUnwrap(layers.firstIndex { $0 === contentLayer })
        XCTAssertGreaterThan(replacementIndex, contentIndex,
                             "The already attached replacement must paint above the live hosting tree")
        XCTAssertTrue(layers.last === searchLayer, "Search must retain its compositor position above the preview")
        XCTAssertTrue(layers.dropLast().last === layer,
                      "The already attached replacement must paint immediately above live content and below search")
    }

    func testFreshSurfaceReachesCompositorBeforeCoveringLiveSidebar() async throws {
        let (store, spaces, window, monitor) = try fixture(floatingWindow: true)
        for space in spaces.prefix(2) {
            store.switchTo(space: space)
            for index in 0..<10 {
                let tab = store.newBlankTab(focus: false)
                tab.park(url: URL(string: "about:blank")!, Parked(title: "Document \(index)"))
            }
        }
        store.switchTo(space: spaces[0])
        store.palette = nil
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        host.wantsLayer = true
        try await Task.sleep(for: .milliseconds(250))
        monitor.remove()
        monitor.install(store)
        XCTAssertTrue(monitor.preparedSlides.isEmpty)
        let start = ProcessInfo.processInfo.systemUptime
        monitor.track(-10, width: fixtureSidebarWidth(in: store), in: store)
        print("COLD_NATIVE_COMPOSITOR_CLAIM seconds=\(ProcessInfo.processInfo.systemUptime - start)")
        let slide = try XCTUnwrap(host.spaceSlide)
        XCTAssertTrue(store.spaceGesture.profileSliding)
        XCTAssertTrue(slide.layer?.superlayer === host.layer,
                      "A cold claim must attach its surface before covering live content too")
    }

    func testAdjacentButtonSelectionReusesPreparedPopulatedNativeSurfaceWithoutChangingTiming() async throws {
        let (store, spaces, window, monitor) = try fixture()
        for space in spaces.prefix(2) {
            store.switchTo(space: space)
            for index in 0..<10 {
                let tab = store.newBlankTab(focus: false)
                tab.park(url: URL(string: "https://example.test/\(index)")!, Parked(title: "Document \(index)"))
            }
        }
        store.switchTo(space: spaces[0])
        store.palette = nil
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while monitor.preparedSlides[spaces[1].id] == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        monitor.select(spaces[1], in: store)
        XCTAssertTrue((window.contentView as? BrowserWindowHost)?.spaceSlide === prepared,
                      "An adjacent button click must reuse the hosting trees prepared while idle")
        XCTAssertNil(monitor.preparedSlides[spaces[1].id], "The active surface must leave the idle cache")
        XCTAssertFalse(prepared.isHidden)
        let animation = try XCTUnwrap(prepared.outgoing.layer?.animation(forKey: "space-position") as? CASpringAnimation)
        XCTAssertEqual(animation.duration, 0.3, accuracy: 0.001,
                       "Default Space travel should settle in the reference's short landing tail")
        XCTAssertEqual(animation.damping, 2 * sqrt(animation.mass * animation.stiffness), accuracy: 0.001,
                       "Space travel must settle without oscillating past the destination")
        XCTAssertEqual(animation.initialVelocity, 0, "An idle click must not manufacture finger velocity")
        try await Task.sleep(for: .milliseconds(500))
    }

    func testCrossProfileButtonSelectionReusesPreparedNativeSurface() async throws {
        let (store, spaces, window, monitor) = try fixture()
        let (profile, target) = adjacentProfile(to: store, after: spaces.last!)
        let peer = TabStore(profileID: profile, space: target, session: [])
        _ = peer.newBlankTab(focus: false)
        window.contentView?.layoutSubtreeIfNeeded()
        monitor.schedulePreparation(in: store)
        try await waitForPreparation(monitor, target: target.id)
        let prepared = try XCTUnwrap(monitor.preparedSlides[target.id])
        monitor.select(target, in: store)
        XCTAssertTrue((window.contentView as? BrowserWindowHost)?.spaceSlide === prepared,
                      "Profile-boundary buttons must reuse the prepared favorites and sections")
        XCTAssertNil(monitor.preparedSlides[target.id])
        try await Task.sleep(for: .milliseconds(500))
    }

    func testButtonSelectionRejectsCaptureFromBeforeANewPreviewSupplier() async throws {
        let (store, spaces, window, monitor) = try fixture()
        let (profile, target) = adjacentProfile(to: store, after: spaces.last!)
        window.contentView?.layoutSubtreeIfNeeded()
        monitor.schedulePreparation(in: store)
        try await waitForPreparation(monitor, target: target.id)
        let stale = try XCTUnwrap(monitor.preparedSlides[target.id])
        let peer = TabStore(profileID: profile, space: target, session: [])
        _ = peer.newBlankTab(focus: false)
        monitor.select(target, in: store)
        let active = try XCTUnwrap((window.contentView as? BrowserWindowHost)?.spaceSlide)
        XCTAssertFalse(active === stale, "Button claims must validate newly live snapshot suppliers too")
        XCTAssertNil(stale.superview)
        try await Task.sleep(for: .milliseconds(500))
    }

    func testPeekingSidebarPreparesAndReusesItsNativeSurface() async throws {
        let (store, spaces, window, monitor) = try fixture(floatingWindow: true)
        // Separate the docked sidebar's disappearance from the floating mount. Instant
        // fixture setup leaves native Space motion enabled, with stable peek geometry.
        Motion.instant { store.sidebarShown = false }
        try await Task.sleep(for: .milliseconds(100))
        Motion.instant { store.sidebarPeeking = true; store.palette = nil }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue((window as? VaneWindow)?.peekingSidebar == true)
        XCTAssertTrue(store.spaceGesture.sectionsView?.window === window,
                      "The floating sidebar must have its actual rendered geometry")
        XCTAssertGreaterThan(store.spaceGesture.sectionsView?.bounds.width ?? 0, 0)
        XCTAssertGreaterThan(store.spaceGesture.sectionsView?.bounds.height ?? 0, 0)
        monitor.install(store)
        monitor.schedulePreparation(in: store)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while monitor.preparedSlides[spaces[1].id] == nil,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id],
                                    "A visible floating sidebar must prepare before finger input")
        monitor.track(-0.5, width: fixtureSidebarWidth(in: store), in: store)
        XCTAssertTrue((window.contentView as? BrowserWindowHost)?.spaceSlide === prepared,
                      "The first floating-sidebar drag must reuse its laid-out hosting trees")
    }

    func testHiddenSidebarDoesNotPrepareNativeSurfaces() async throws {
        let (store, _, window, monitor) = try fixture(floatingWindow: true)
        store.sidebarShown = false
        store.sidebarPeeking = false
        store.palette = nil
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse((window as? VaneWindow)?.peekingSidebar ?? true)
        // Keep a valid native anchor as an outgoing sidebar could during its removal.
        // The hidden-state guard, rather than missing geometry, must prevent preparation.
        let anchor = NSView(frame: NSRect(x: Look.floatingSidebarGap, y: Look.floatingSidebarGap,
                                         width: fixtureSidebarWidth(in: store), height: 300))
        window.contentView?.addSubview(anchor)
        store.spaceGesture.sectionsView = anchor
        store.spaceGesture.stripView = anchor
        monitor.install(store)
        monitor.schedulePreparation(in: store)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(monitor.preparedSlides.isEmpty,
                      "No hidden sidebar should allocate prepared native lists")
    }

    func testNativeSurfaceCoversTheLiveSidebarUpdateTurn() async throws {
        let (store, spaces, window, monitor) = try fixture()
        monitor.track(-60, width: fixtureSidebarWidth(in: store), in: store)
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let slide = try XCTUnwrap(host.spaceSlide)
        var coveredUpdate = false
        slide.start(duration: 0.02) {
            // Match the production completion: selection and gesture reset share a
            // handoff transaction so SpaceSlide cannot begin an independent transition.
            Motion.spaceHandoff {
                store.switchTo(space: spaces[1])
                store.spaceDrag = 0
                store.spaceSwiping = false
            }
            coveredUpdate = slide.superview === host
        }
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(coveredUpdate, "Keep the native rows through publication until the live update acknowledges them")
        XCTAssertNil(host.spaceSlide)
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
    }

    func testHidingSidebarRetiresCommittedNativeLandingWithoutCoveringThePage() async throws {
        let (store, spaces, window, monitor) = try fixture()
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        monitor.track(-80, width: fixtureSidebarWidth(in: store), in: store)
        let departing = try XCTUnwrap(host.spaceSlide)
        monitor.land(1, to: spaces[1], width: fixtureSidebarWidth(in: store), store: store, duration: 1)
        try await Task.sleep(for: .milliseconds(30))
        Motion.instant { store.sidebarShown = false; store.sidebarPeeking = false }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(host.spaceSlide, "A closed sidebar must not leave its native lists over the page")
        XCTAssertNil(departing.superview)
        XCTAssertEqual(store.currentSpaceID, spaces[1].id, "Closing the sidebar preserves the committed selection")
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertFalse(store.spaceGesture.profileSliding)

        Motion.instant { store.sidebarShown = true }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        monitor.select(spaces[2], in: store)
        let replacement = try XCTUnwrap(host.spaceSlide)
        XCTAssertFalse(replacement === departing)
        departing.finish() // An old compositor callback must not remove the replacement.
        XCTAssertTrue(host.spaceSlide === replacement)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while host.spaceSlide != nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.currentSpaceID, spaces[2].id)
        XCTAssertNil(host.spaceSlide)
    }

    func testAnotherWindowLosingFocusDoesNotCancelThisWindowsSpaceGesture() throws {
        let (store, _, window, monitor) = try fixture()
        monitor.track(-40, width: fixtureSidebarWidth(in: store), in: store)
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let slide = try XCTUnwrap(host.spaceSlide)
        let unrelated = NSWindow(contentRect: .zero, styleMask: .borderless,
                                 backing: .buffered, defer: false)
        unrelated.isReleasedWhenClosed = false
        defer { unrelated.close() }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: unrelated)
        XCTAssertTrue(store.spaceSwiping, "Focus notifications belong to their own browser window")
        XCTAssertTrue(host.spaceSlide === slide)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(store.spaceSwiping, "This window losing focus must still cancel an uncommitted drag")
        XCTAssertNil(host.spaceSlide)
    }

    func testDisappearingSourceDoesNotUncoverAVisibleArrivingSidebarBeforeAcknowledgement() async throws {
        let (source, spaces, window, _) = try fixture()
        let (profile, target) = adjacentProfile(to: source, after: spaces.last!)
        let arriving = TabStore(profileID: profile, space: target, session: [])
        let population = try EmptyNativeSidebarPopulationFixture(store: arriving, spaceID: target.id)
        defer { population.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        window.contentView = container
        let slide = ProfileSpaceSlide(frame: container.bounds,
            outgoing: source.swipePreview(in: spaces.last!), incoming: source.swipePreview(in: target),
            drag: -80, direction: 1, source: source, includesFavorites: true, travelWidth: 250)
        container.addSubview(slide)
        defer { slide.cancel(); arriving.window = nil }
        source.sidebarShown = false
        source.sidebarPeeking = false
        slide.start(duration: 1) {
            source.window = nil
            arriving.window = window
            arriving.sidebarShown = true
            slide.attach(arriving)
        }
        slide.sidebarDidDisappear(source)
        XCTAssertTrue(slide.isDestination(arriving))
        XCTAssertTrue(slide.superview === container,
                      "Completion must recheck the arriving visibility instead of unconditionally retiring")
        population.complete()
        slide.sidebarDidUpdate(arriving, renderedSpaceID: target.id, atRest: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(slide.superview, "A visible arrival retires after its real rendered acknowledgement")
    }

    func testSlowNativeSpaceLandingNeverReversesItsPresentation() async throws {
        try await withFixtureApplicationLoop { try await checkSlowNativeSpaceLanding() }
    }

    private func checkSlowNativeSpaceLanding() async throws {
        let (store, spaces, window, monitor) = try fixture(registerTeardown: false)
        defer { retireFixture(store, window: window, monitor: monitor) }
        store.palette = nil
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        try await waitForPreparation(monitor, target: spaces[1].id)
        try await compatibilityWait {
            if !NSApp.isActive || NSApp.keyWindow !== window {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return false
            }
            return NSApp.isRunning && window.isKeyWindow
                && window.isVisible && window.occlusionState.contains(.visible)
                && host.window === window && host.layer?.presentation() != nil
        }
        var samples: [CGFloat] = []
        for index in 1...40 {
            monitor.track(-CGFloat(index) * 3, width: fixtureSidebarWidth(in: store), in: store)
            try await Task.sleep(for: .milliseconds(10))
            samples.append(try XCTUnwrap(host.spaceSlide).offset)
        }
        // This case samples 35 x 8 ms and then checks completion. Give that
        // fixed window a known 200 ms landing; the 300 ms product default can
        // legitimately still be running at its 280 ms minimum observation.
        monitor.land(1, to: spaces[1], width: fixtureSidebarWidth(in: store), store: store, duration: 0.2)
        for _ in 0..<35 {
            try await Task.sleep(for: .milliseconds(8))
            samples.append(host.spaceSlide?.offset ?? -fixtureSidebarWidth(in: store))
        }
        print("SLOW_SPACE_PRESENTATION: \(samples)")
        for (previous, next) in zip(samples, samples.dropFirst()) {
            XCTAssertLessThanOrEqual(next, previous + 0.5,
                                     "A forward slide must never expose the origin again")
        }
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
        XCTAssertFalse(store.spaceSwiping)
    }

    func testIdleSurfacesRefreshWithSidebarContentAndLeaveWithMonitor() async throws {
        let (store, spaces, _, monitor) = try fixture()
        try await Task.sleep(for: .milliseconds(250))
        let previous = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        _ = store.newBlankTab(focus: false)
        try await waitForPreparation(monitor, target: spaces[1].id)
        let refreshed = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        XCTAssertFalse(previous === refreshed, "Changed sidebar content must invalidate the prepared capture")
        XCTAssertNil(previous.superview)
        let remaining = Array(monitor.preparedSlides.values)
        monitor.remove()
        XCTAssertTrue(monitor.preparedSlides.isEmpty)
        XCTAssertTrue(remaining.allSatisfy { $0.superview == nil })
    }

    func testUnchangedAnchorUpdatesKeepPreparedSidebars() async throws {
        let (store, spaces, window, monitor) = try fixture()
        try await waitForPreparation(monitor, target: spaces[1].id)
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        for _ in 0..<5 { monitor.schedulePreparation(in: store) }
        XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === prepared,
                      "Repeated layout acknowledgements must not rebuild identical hidden trees")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === prepared)
        window.setContentSize(NSSize(width: 340, height: 500))
        window.contentView?.layoutSubtreeIfNeeded()
        monitor.schedulePreparation(in: store)
        try await waitForPreparation(monitor, target: spaces[1].id)
        XCTAssertFalse(monitor.preparedSlides[spaces[1].id] === prepared,
                       "Changed viewport geometry still needs a fresh capture")
    }

    func testUnchangedSpaceSavesAndAbsentWarningsKeepPreparedCaptureClaimable() async throws {
        let (store, spaces, window, monitor) = try fixture(activateWindow: false)
        try await waitForPreparation(monitor, target: spaces[1].id)
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        let manager = ProfileManager.shared
        let committed = manager.spaces(for: store.profileID)
        XCTAssertTrue(committed.contains { $0.id == store.currentSpaceID })
        XCTAssertFalse(manager.saveFailures.contains { $0.id == .spaces(store.profileID) })
        let revision = manager.spacesRevision
        // Model the same durable metadata save made by periodic session capture.
        // Keep a delayed preparation queued, as ordinary scrolling does.
        monitor.postponePreparation(in: store, by: 0.35, preservingSurfaces: true)
        for _ in 0..<3 {
            XCTAssertTrue(manager.saveSpaces(committed, for: store.profileID))
            manager.dismissSaveFailure(.spaces(store.profileID))
        }
        XCTAssertEqual(manager.spacesRevision, revision)
        XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === prepared,
                      "Unchanged saves and absent warning dismissal must not revoke a ready native capture")
        // This is a negative lifetime assertion through the existing quiet deadline,
        // not a readiness sleep: a capture was positively admitted above.
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === prepared,
                      "Idle scheduling after an unchanged save must retain the same laid-out trees")
        XCTAssertTrue(prepared.superview === window.contentView)
        monitor.track(-30, width: fixtureSidebarWidth(in: store), in: store)
        XCTAssertTrue((window.contentView as? BrowserWindowHost)?.spaceSlide === prepared,
                      "The first directional claim must consume the same warm capture")
        XCTAssertNil(monitor.preparedSlides[spaces[1].id])
        monitor.abort()
    }

    func testActualMetadataContentAndFolderProtectionStillRevokePreparedCaptures() async throws {
        let (store, spaces, window, monitor) = try fixture(activateWindow: false)
        store.sharingReady = false
        store.folderAuthentication = FolderAuthentication()
        let child = store.newBlankTab(focus: false)
        let folder = Folder(name: "Protected fixture folder")
        store.todayShape = Pins(entries: [.init(row: .folder(folder)),
            .init(row: .tab(child.id.uuidString), parent: folder.id)])
        store.palette = nil
        window.contentView?.layoutSubtreeIfNeeded()
        try await waitForPreparation(monitor, target: spaces[1].id)
        let original = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        let manager = ProfileManager.shared
        var renamed = try XCTUnwrap(manager.spaces(for: store.profileID).first { $0.id == spaces[1].id })
        renamed.name += " renamed"
        XCTAssertTrue(manager.updateSpace(renamed))
        XCTAssertNil(monitor.preparedSlides[spaces[1].id], "Real adjacent metadata changes must revoke on the sending turn")
        XCTAssertNil(original.superview)
        try await waitForPreparation(monitor, target: spaces[1].id)
        let afterMetadata = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        XCTAssertFalse(afterMetadata === original)

        _ = store.newBlankTab(focus: false)
        XCTAssertNil(monitor.preparedSlides[spaces[1].id], "Real sidebar content changes must still revoke synchronously")
        XCTAssertNil(afterMetadata.superview)
        try await waitForPreparation(monitor, target: spaces[1].id)
        let afterContent = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        XCTAssertFalse(afterContent === afterMetadata)

        store.lockFolder(folder.id)
        XCTAssertTrue(store.isFolderLocked(folder.id))
        XCTAssertTrue(store.todayShape.folder(folder.id)?.requiresAuthentication == true)
        XCTAssertNil(monitor.preparedSlides[spaces[1].id], "Actual folder protection must revoke before any following claim")
        XCTAssertNil(afterContent.superview)
        try await waitForPreparation(monitor, target: spaces[1].id)
        let afterProtection = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        XCTAssertFalse(afterProtection === afterContent)
        monitor.track(-30, width: fixtureSidebarWidth(in: store), in: store)
        XCTAssertTrue((window.contentView as? BrowserWindowHost)?.spaceSlide === afterProtection,
                      "Fresh protected content must remain ready for Space navigation")
        monitor.abort()
    }

    func testCancelledSwipeRepreparesBothNeighbours() async throws {
        try await cancelledSwipeRepreparesBothNeighbours(withPendingPreparation: false)
    }

    func testCancelledSwipeWhilePreparationPendingRepreparesBothNeighbours() async throws {
        try await cancelledSwipeRepreparesBothNeighbours(withPendingPreparation: true)
    }

    private func cancelledSwipeRepreparesBothNeighbours(withPendingPreparation pending: Bool) async throws {
        let (store, spaces, window, monitor) = try fixture()
        store.switchTo(space: spaces[1])
        store.palette = nil
        window.contentView?.layoutSubtreeIfNeeded()
        try await waitForPreparation(monitor, target: spaces[0].id)
        try await waitForPreparation(monitor, target: spaces[2].id)
        let left = try XCTUnwrap(monitor.preparedSlides[spaces[0].id])
        let right = try XCTUnwrap(monitor.preparedSlides[spaces[2].id])
        if pending {
            // Vertical scrolling keeps the warm surfaces but schedules delayed work.
            // The next horizontal claim must cancel that work without wedging the queue.
            monitor.postponePreparation(in: store, by: 0.6, preservingSurfaces: true)
        }
        monitor.track(-30, width: fixtureSidebarWidth(in: store), in: store)
        XCTAssertTrue((window.contentView as? BrowserWindowHost)?.spaceSlide === right,
                      "The claim must consume the existing right-hand capture")
        XCTAssertTrue(monitor.preparedSlides[spaces[0].id] === left)
        XCTAssertNil(monitor.preparedSlides[spaces[2].id])
        monitor.abort()
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
        monitor.schedulePreparation(in: store)
        try await waitForPreparation(monitor, target: spaces[2].id)
        XCTAssertEqual(Set(monitor.preparedSlides.keys), Set([spaces[0].id, spaces[2].id]),
                       "Returning to the middle Space must warm both directions again")
        let restored = try XCTUnwrap(monitor.preparedSlides[spaces[2].id])
        monitor.track(-30, width: fixtureSidebarWidth(in: store), in: store)
        XCTAssertTrue((window.contentView as? BrowserWindowHost)?.spaceSlide === restored,
                      "The following swipe must reuse the replacement, rather than build cold")
        monitor.abort()
    }

    func testSearchPresentationAndSuggestionsKeepPreparedSidebars() async throws {
        let (store, spaces, _, monitor) = try fixture()
        try await waitForPreparation(monitor, target: spaces[1].id)
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        store.palette = .newTab
        store.suggestions = [Suggestion(url: "https://example.com", title: "Example", bookmarked: false)]
        store.clearSuggestions()
        XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === prepared,
                      "Search state must not discard unchanged hidden sidebars")
        store.palette = nil
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === prepared,
                      "Search dismissal must reuse the same trees, without another expensive layout")
    }

    func testSidebarHideAndRevealReusePreparedSurfaces() async throws {
        let (store, spaces, window, monitor) = try fixture()
        try await waitForPreparation(monitor, target: spaces[1].id)
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        for _ in 0..<2 {
            Motion.instant { store.sidebarShown = false }
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === prepared,
                          "Hiding chrome must retain unchanged, hidden Space surfaces")
            XCTAssertFalse(monitor.mine(ScrollEvent(window: window, phase: .began), store),
                           "A hidden sidebar cannot claim gestures")
            Motion.instant { store.sidebarShown = true }
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(450))
            XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === prepared,
                          "Cmd-S must not rebuild the entire neighboring sidebar graph")
        }
        monitor.track(-40, width: fixtureSidebarWidth(in: store), in: store)
        XCTAssertTrue((window.contentView as? BrowserWindowHost)?.spaceSlide === prepared,
                      "The reused surface must still be claimable for a real Space switch")
    }

    func testHiddenSidebarStillRevokesStructurallyInvalidPreparedSurfaces() async throws {
        let (store, spaces, window, monitor) = try fixture()
        try await waitForPreparation(monitor, target: spaces[1].id)
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        Motion.instant { store.sidebarShown = false }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === prepared)
        store.sidebarPreviewInvalidated.send()
        XCTAssertTrue(monitor.preparedSlides.isEmpty,
                      "Protection changes must revoke hidden captures synchronously")
        XCTAssertNil(prepared.superview)
        Motion.instant { store.sidebarShown = true }
        window.contentView?.layoutSubtreeIfNeeded()
        try await waitForPreparation(monitor, target: spaces[1].id)
        XCTAssertFalse(monitor.preparedSlides[spaces[1].id] === prepared)
        let ready = Array(monitor.preparedSlides.values)
        monitor.remove()
        XCTAssertTrue(monitor.preparedSlides.isEmpty)
        XCTAssertTrue(ready.allSatisfy { $0.superview == nil },
                      "Full profile/window teardown must still release retained surfaces")
    }

    func testSearchDefersDestructionOfStructurallyInvalidatedHostingTrees() async throws {
        let (store, spaces, _, monitor) = try fixture()
        try await waitForPreparation(monitor, target: spaces[1].id)
        #if compiler(>=6.3)
        weak let retiredCapture = monitor.preparedSlides[spaces[1].id]
        weak let outgoing = monitor.preparedSlides[spaces[1].id]?.outgoing
        #else
        weak var retiredCapture = monitor.preparedSlides[spaces[1].id]
        weak var outgoing = monitor.preparedSlides[spaces[1].id]?.outgoing
        #endif
        XCTAssertNotNil(outgoing)
        store.palette = .newTab
        store.todayShape = Pins(entries: [.init(row: .folder(Folder(name: "Changed during search")))])
        XCTAssertTrue(monitor.preparedSlides.isEmpty)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNotNil(outgoing, "Opening search must retire eligibility without destroying whole SwiftUI trees on the key event")
        store.palette = nil
        try await waitForPreparation(monitor, target: spaces[1].id)
        XCTAssertNil(retiredCapture, "Idle cleanup must release Vane's retired capture ownership")
        // AppKit can retain a detached hosting view until its pending display work
        // drains. Require eventual idle release, rather than same-turn deallocation.
        try await compatibilityWait { outgoing == nil }
        XCTAssertNil(outgoing, "The retired tree must be released once search dismissal settles")
    }

    private func waitForPreparation(_ monitor: SwipeMonitor, target: UUID) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while monitor.preparedSlides[target] == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func adjacentProfile(to store: TabStore, after space: Space) -> (UUID, Space) {
        let profile = fixtureProfile(named: "Prepared destination").id
        let target = Space(name: "Remote", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([target], for: profile))
        store.switchTo(space: space)
        store.palette = nil // The empty destination offers search; this fixture tests swipes.
        XCTAssertEqual(store.swipeNeighbour(for: -1)?.id, target.id)
        addTeardownBlock { @MainActor in
            for peer in TabStore.all.filter({ $0.profileID == profile }) {
                peer.spaceGesture.monitor.remove()
                let tabs = peer.everyTab
                peer.dropStashes()
                TabStore.all.removeAll { $0 === peer }
                SharedTabs.release(tabs)
            }
            Store.forget(profile)
            ProfileManager.shared.delete(profile)
            try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: profile, in: Store.directory))
        }
        return (profile, target)
    }

    func testPreparedDestinationInvalidatesBeforeAnotherProfileMutatesItsTabs() async throws {
        let (store, spaces, window, monitor) = try fixture()
        let (profile, target) = adjacentProfile(to: store, after: spaces.last!)
        let peer = TabStore(profileID: profile, space: target, session: [])
        _ = peer.newBlankTab(focus: false)
        window.contentView?.layoutSubtreeIfNeeded()
        monitor.schedulePreparation(in: store)
        try await waitForPreparation(monitor, target: target.id)
        let stale = try XCTUnwrap(monitor.preparedSlides[target.id])
        _ = peer.newBlankTab(focus: false)
        XCTAssertNil(monitor.preparedSlides[target.id],
                     "A peer mutation must invalidate before a same-turn gesture can claim the capture")
        XCTAssertNil(stale.superview)
        try await waitForPreparation(monitor, target: target.id)
        let refreshed = try XCTUnwrap(monitor.preparedSlides[target.id])
        XCTAssertFalse(refreshed === stale)
        monitor.track(-30, width: fixtureSidebarWidth(in: store), in: store)
        XCTAssertTrue((window.contentView as? BrowserWindowHost)?.spaceSlide === refreshed)
    }

    func testNewPreviewSupplyingStoreCannotReuseAnOlderPreparedDestination() async throws {
        let (store, spaces, window, monitor) = try fixture()
        let (profile, target) = adjacentProfile(to: store, after: spaces.last!)
        window.contentView?.layoutSubtreeIfNeeded()
        monitor.schedulePreparation(in: store)
        try await waitForPreparation(monitor, target: target.id)
        let stale = try XCTUnwrap(monitor.preparedSlides[target.id])
        let peer = TabStore(profileID: profile, space: target, session: [])
        _ = peer.newBlankTab(focus: false)
        // No run-loop turn for preparation/registry observation before the gesture.
        monitor.track(-30, width: fixtureSidebarWidth(in: store), in: store)
        let slide = try XCTUnwrap((window.contentView as? BrowserWindowHost)?.spaceSlide)
        XCTAssertFalse(slide === stale, "A newly live preview supplier changes the frozen row structure")
        XCTAssertNil(stale.superview)
    }

    func testSearchDefersAdjacentPreparationUntilDismissalFinishes() async throws {
        let (store, _, window, monitor) = try fixture()
        store.palette = nil
        window.contentView?.layoutSubtreeIfNeeded()
        monitor.remove()
        monitor.install(store)
        // Opening can race an already queued idle capture. Both scheduling and
        // execution must respect search, including later suggestion publications.
        store.palette = .newTab
        try await Task.sleep(for: .milliseconds(600))
        monitor.schedulePreparation(in: store)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(monitor.preparedSlides.isEmpty,
                      "Hidden Space lists must not be built during search opening")
        SearchSuggestions.enabled = false
        store.suggest("fixture")
        monitor.schedulePreparation(in: store)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(monitor.preparedSlides.isEmpty,
                      "Suggestion updates must not start hidden layout during typing")
        let dismissed = ContinuousClock.now
        store.palette = nil
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        if !Motion.reduced, ContinuousClock.now < dismissed + .seconds(Look.appearDuration) {
            XCTAssertTrue(monitor.preparedSlides.isEmpty,
                          "Search's dismissal fade must finish before hidden layout resumes")
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while monitor.preparedSlides.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(monitor.preparedSlides.isEmpty,
                       "Adjacent Space swipes must be ready again after search closes")
    }

    func testSidebarPreparationWaitsUntilLibraryDragIsIdle() async throws {
        let (store, spaces, _, monitor) = try fixture()
        store.librarySwipeProgress = 0.2
        monitor.schedulePreparation(in: store)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(monitor.preparedSlides.isEmpty,
                      "Background sidebar layout must not interrupt an active Library drag")
        store.librarySwipeProgress = nil
        monitor.schedulePreparation(in: store)
        try await waitForPreparation(monitor, target: spaces[1].id)
        XCTAssertFalse(monitor.preparedSlides.isEmpty)
    }

    func testHidingTheRetainedSidebarEndsAnUncommittedSwipe() async throws {
        let (store, _, window, monitor) = try fixture()
        monitor.track(-30, width: fixtureSidebarWidth(in: store), in: store)
        XCTAssertTrue(store.spaceSwiping)
        store.sidebarShown = false
        try await Task.sleep(for: .milliseconds(350))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(store.spaceSwiping, "A hidden retained sidebar must release its gesture")
        XCTAssertEqual(store.spaceDrag, 0)
        XCTAssertNil((window.contentView as? BrowserWindowHost)?.spaceSlide)
    }

    func testFloatingRevealDefersAdjacentSurfacePreparationUntilAfterTravel() async throws {
        let (store, _, window, monitor) = try fixture(floatingWindow: true)
        store.sidebarShown = false
        try await Task.sleep(for: .milliseconds(350))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(monitor.preparedSlides.isEmpty)
        store.sidebarPeeking = true
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(monitor.preparedSlides.isEmpty,
                      "Laying out adjacent Spaces must not interrupt the floating reveal")
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while monitor.preparedSlides.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(monitor.preparedSlides.isEmpty,
                       "The settled floating sidebar must still prepare the next swipe")
    }

    func testDockedRevealDefersAdjacentSurfacePreparationUntilAfterTravel() async throws {
        let (store, _, window, monitor) = try fixture(floatingWindow: true)
        store.sidebarShown = false
        try await Task.sleep(for: .milliseconds(350))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(monitor.preparedSlides.isEmpty)
        store.sidebarShown = true
        window.contentView?.layoutSubtreeIfNeeded()
        let start = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .milliseconds(120))
        print("SIDEBAR_DOCK_PREPARATION wait_ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000) prepared=\(monitor.preparedSlides.count)")
        XCTAssertTrue(monitor.preparedSlides.isEmpty,
                      "Adjacent hosting trees must not interrupt the docked opening animation")
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while monitor.preparedSlides.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(monitor.preparedSlides.isEmpty)
    }

    func testSnapshotBurstWaitsForQuietThenWarmsBothNeighbours() async throws {
        let (store, spaces, window, monitor) = try fixture()
        store.switchTo(space: spaces[1])
        store.palette = nil
        window.contentView?.layoutSubtreeIfNeeded()
        try await waitForPreparation(monitor, target: spaces[0].id)
        try await waitForPreparation(monitor, target: spaces[2].id)
        let old = Array(monitor.preparedSlides.values)
        // These are real snapshot-revision publications, not a test-only timer API.
        // Every publication must revoke reuse immediately, but a burst should not
        // repeatedly create and destroy complete neighboring hosting trees.
        var prematureCaptures: Set<ObjectIdentifier> = []
        for _ in 0..<4 {
            store.spacesChanged()
            XCTAssertTrue(monitor.preparedSlides.isEmpty)
            try await Task.sleep(for: .milliseconds(130))
            prematureCaptures.formUnion(monitor.preparedSlides.values.map(ObjectIdentifier.init))
        }
        XCTAssertTrue(prematureCaptures.isEmpty, "A continuing mutation burst must produce zero replacement captures")
        try await waitForPreparation(monitor, target: spaces[0].id)
        try await waitForPreparation(monitor, target: spaces[2].id)
        XCTAssertEqual(Set(monitor.preparedSlides.keys), Set([spaces[0].id, spaces[2].id]))
        XCTAssertTrue(old.allSatisfy { $0.superview == nil })
        let right = try XCTUnwrap(monitor.preparedSlides[spaces[2].id])
        monitor.track(-30, width: fixtureSidebarWidth(in: store), in: store)
        XCTAssertTrue((window.contentView as? BrowserWindowHost)?.spaceSlide === right,
                      "Quiet-time rebuilding must still supply the first directional claim")
        monitor.abort()
    }

    func testPageInputExtendsPendingPreparationWithoutDiscardingWarmSurfaces() async throws {
        let (store, spaces, window, monitor) = try fixture()
        try await waitForPreparation(monitor, target: spaces[1].id)
        let warm = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dy: 10, phase: .began, x: 290))
        XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === warm,
                      "Input must preserve valid warm first-swipe surfaces")
        store.spacesChanged()
        for index in 0..<4 {
            NSApplication.shared.sendEvent(ScrollEvent(window: window, dy: 10,
                phase: index == 0 ? .began : .changed, x: 290))
            try await Task.sleep(for: .milliseconds(130))
            XCTAssertTrue(monitor.preparedSlides.isEmpty,
                          "Pending hidden trees must not rebuild during continuing page/Library input")
        }
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .ended, x: 290))
        try await waitForPreparation(monitor, target: spaces[1].id)
        XCTAssertFalse(monitor.preparedSlides[spaces[1].id] === warm)
    }

    func testCreateFormDefersReplacementPreparationUntilDismissed() async throws {
        let (store, spaces, _, monitor) = try fixture()
        try await waitForPreparation(monitor, target: spaces[1].id)
        store.creatingSpace = true
        store.spacesChanged()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(monitor.preparedSlides.isEmpty,
                      "The Create Space form must not compete with replacement preview layout")
        store.creatingSpace = false
        try await waitForPreparation(monitor, target: spaces[1].id)
        XCTAssertFalse(monitor.preparedSlides.isEmpty)
    }

    func testVerticalScrollingDefersAdjacentSurfacePreparationUntilIdle() async throws {
        let (store, _, window, monitor) = try fixture()
        store.sharingReady = false
        store.tabs = (0..<300).map { index in
            let tab = Tab(profileID: store.profileID)
            tab.park(url: URL(string: "about:blank#scroll-\(index)")!, Parked(title: "Document \(index)"))
            return tab
        }
        store.syncShapes()
        store.palette = nil
        window.contentView?.layoutSubtreeIfNeeded()
        monitor.schedulePreparation(in: store)
        var gaps: [Double] = []
        for index in 0..<20 {
            let start = ProcessInfo.processInfo.systemUptime
            if index == 10 {
                NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .ended))
            }
            NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: 0, dy: 20,
                phase: index < 10 ? (index == 0 ? .began : .changed) : [],
                momentum: index < 10 ? [] : (index == 10 ? .began : .changed)))
            try await Task.sleep(for: .milliseconds(20))
            gaps.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            XCTAssertTrue(monitor.preparedSlides.isEmpty,
                          "Vertical scrolling must not compete with hidden neighboring hosting trees")
        }
        XCTAssertFalse(store.spaceSwiping, "Vertical scrolling must keep its normal recipient")
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: [], momentum: .ended))
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while monitor.preparedSlides.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(monitor.preparedSlides.isEmpty,
                       "Preparation must resume after scrolling so the next swipe stays ready")
        print("SIDEBAR_SCROLL_PREPARATION max_gap_ms=\(gaps.max() ?? 0)")
    }

    func testMouseWheelScrollingAlsoPostponesHiddenPreparation() async throws {
        let (store, _, window, monitor) = try fixture()
        monitor.schedulePreparation(in: store)
        for _ in 0..<8 {
            NSApplication.shared.sendEvent(ScrollEvent(window: window, dy: 10, phase: [], precise: false))
            try await Task.sleep(for: .milliseconds(25))
            XCTAssertTrue(monitor.preparedSlides.isEmpty)
        }
        XCTAssertFalse(store.spaceSwiping)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while monitor.preparedSlides.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(monitor.preparedSlides.isEmpty)
    }

    func testFolderDisclosureDefersHiddenSpacePreparationAndDisposal() async throws {
        try await checkFolderDisclosurePreparation(authenticating: false)
    }

    func testSuccessfulFolderUnlockDefersPreviewDisposalBeforeGrantPublication() async throws {
        try await checkFolderDisclosurePreparation(authenticating: true)
    }

    private func checkFolderDisclosurePreparation(authenticating: Bool) async throws {
        let (store, spaces, window, monitor) = try fixture()
        var authenticationReply: FolderAuthentication.Reply?
        store.folderAuthentication = FolderAuthentication { _, reply in
            authenticationReply = reply
            return nil
        }
        try XCTSkipIf(Motion.reduced, "Requires the folder's animated disclosure interval")
        store.sharingReady = false
        // Match the reported outline: four favourites, four loose pins, seven folder
        // children, and eleven Today rows, inside the production native browser host.
        let tabs = (0..<26).map { index in
            let tab = Tab(profileID: store.profileID)
            tab.kind = index < 4 ? .favourite : (index < 15 ? .pinned : .today)
            tab.park(url: URL(string: "about:blank#folder-\(index)")!, Parked(title: "Document \(index)"))
            return tab
        }
        store.tabs = tabs
        let folder = Folder(name: "Documents", collapsed: true,
                            requiresAuthentication: authenticating ? true : nil)
        store.pins = Pins(entries: tabs[4..<8].map { .init(row: .tab($0.id.uuidString)) }
            + [.init(row: .folder(folder))]
            + tabs[8..<15].map { .init(row: .tab($0.id.uuidString), parent: folder.id) })
        store.todayShape = Pins(entries: tabs[15...].map { .init(row: .tab($0.id.uuidString)) })
        store.palette = nil
        window.contentView?.layoutSubtreeIfNeeded()
        try await waitForPreparation(monitor, target: spaces[1].id)
        for _ in 0..<2 {
            let stale = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
            store.toggleFolder(folder.id)
            if let reply = authenticationReply {
                authenticationReply = nil
                reply(true)
            }
            XCTAssertFalse(store.isFolderLocked(folder.id))
            XCTAssertTrue(monitor.preparedSlides.isEmpty, "Old disclosure geometry cannot be reused")
            XCTAssertNotNil(stale.superview,
                            "Disposing hidden hosting trees must not block the disclosure input")
            try await Task.sleep(for: .milliseconds(120))
            XCTAssertTrue(monitor.preparedSlides.isEmpty,
                          "Hidden neighbouring lists must not be built in the folder's middle frames")
            XCTAssertNotNil(stale.superview)
            try await waitForPreparation(monitor, target: spaces[1].id)
            XCTAssertNotNil(monitor.preparedSlides[spaces[1].id], "Preparation resumes after disclosure settles")
            XCTAssertNil(stale.superview, "Idle preparation must drain the old hosting trees")
        }
        XCTAssertTrue(tabs.allSatisfy { $0.existingWeb == nil })
    }

    func testMissingSectionsViewportRejectsPreparedReuse() async throws {
        try await assertMalformedSectionsViewportRejectsPreparedReuse(duplicate: false)
    }

    func testDuplicateSectionsViewportsRejectPreparedReuse() async throws {
        try await assertMalformedSectionsViewportRejectsPreparedReuse(duplicate: true)
    }

    private func assertMalformedSectionsViewportRejectsPreparedReuse(duplicate: Bool) async throws {
        let (store, spaces, window, monitor) = try fixture()
        try await waitForPreparation(monitor, target: spaces[1].id)
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        func markers(in view: NSView) -> [SidebarSectionsViewport.Marker] {
            (view as? SidebarSectionsViewport.Marker).map { [$0] }
                ?? view.subviews.flatMap { markers(in: $0) }
        }
        let readyMarkers = markers(in: prepared.outgoing)
        XCTAssertEqual(readyMarkers.count, 1, "The real hosted preview must identify one sections viewport")
        let marker = try XCTUnwrap(readyMarkers.first)
        let scroll = try XCTUnwrap(marker.enclosingScrollView)
        let before = scroll.documentVisibleRect.minY
        if duplicate {
            marker.addSubview(SidebarSectionsViewport.Marker(frame: .zero))
        } else {
            marker.removeFromSuperview()
        }
        XCTAssertFalse(prepared.updatePreparedScrollOffset(180),
                       "Missing or ambiguous viewport identity must reject cached reuse")
        XCTAssertEqual(scroll.documentVisibleRect.minY, before, accuracy: 0.5,
                       "An invalid marker set must not scroll an arbitrary native view")

        monitor.track(-30, width: fixtureSidebarWidth(in: store), in: store)
        let replacement = try XCTUnwrap((window.contentView as? BrowserWindowHost)?.spaceSlide)
        XCTAssertFalse(replacement === prepared, "The gesture must fall back to a fresh native cover")
        XCTAssertTrue(replacement.isActive)
        XCTAssertNil(prepared.superview, "The invalid cached cover must be revoked")
        monitor.abort()
    }

    func testScrollingReusesPreparedSurfacesAndRefreshesNativeOffset() async throws {
        let (store, spaces, window, monitor) = try fixture()
        store.sharingReady = false
        store.tabs = (0..<60).map { index in
            let tab = Tab(profileID: store.profileID)
            tab.park(url: URL(string: "about:blank#scroll-reuse-\(index)")!, Parked(title: "Document \(index)"))
            return tab
        }
        store.syncShapes()
        window.contentView?.layoutSubtreeIfNeeded()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while monitor.preparedSlides[spaces[1].id] == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dy: 20, phase: .began))
        XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === prepared)
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(25))
            NSApplication.shared.sendEvent(ScrollEvent(window: window, dy: 20))
        }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === prepared,
                      "Scrolling must not reconstruct two whole hidden hosting trees after every pause")
        func scrollView(in view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        let scroll = try XCTUnwrap(scrollView(in: prepared.outgoing))
        // An unrelated native scroller can precede the sections viewport in a
        // hosted sidebar. Keep the real target before inserting that decoy.
        let decoy = NSScrollView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        decoy.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 1000))
        decoy.contentView.scroll(to: NSPoint(x: 0, y: 40))
        decoy.reflectScrolledClipView(decoy.contentView)
        decoy.isHidden = true
        let nativeContainer = try XCTUnwrap(scroll.superview)
        nativeContainer.addSubview(decoy, positioned: .below, relativeTo: scroll)
        defer { decoy.removeFromSuperview() }
        XCTAssertTrue(scrollView(in: prepared.outgoing) === decoy,
                      "The decoy must precede the real sections viewport in native traversal")
        XCTAssertEqual(decoy.documentVisibleRect.minY, 40, accuracy: 1)

        store.spaceGesture.sidebarOffset = 180
        monitor.track(-30, width: fixtureSidebarWidth(in: store), in: store)
        XCTAssertTrue((window.contentView as? BrowserWindowHost)?.spaceSlide === prepared)
        XCTAssertEqual(scroll.documentVisibleRect.minY, 180, accuracy: 1,
                       "The reused outgoing sidebar must start at the live scroll position")
        XCTAssertEqual(decoy.documentVisibleRect.minY, 40, accuracy: 1,
                       "Refreshing a reused sidebar must not scroll an unrelated native view")
        monitor.remove()
        XCTAssertNil(prepared.superview)
    }

    func testPageScrollingKeepsThePreparedSidebarReady() async throws {
        let (store, spaces, _, monitor) = try fixture()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while monitor.preparedSlides[spaces[1].id] == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let prepared = try XCTUnwrap(monitor.preparedSlides[spaces[1].id])
        // The fixture is 300pt wide; this point is beyond the default sidebar.
        NSApplication.shared.sendEvent(ScrollEvent(window: try XCTUnwrap(store.window), dy: 20,
                                                   phase: .began, x: 290))
        XCTAssertTrue(monitor.preparedSlides[spaces[1].id] === prepared,
                      "Page scrolling must not discard an unrelated ready-to-use sidebar")
    }

    func testFingerTrackingReusesNativeSurfaceThroughCommit() async throws {
        let (store, spaces, window, monitor) = try fixture()
        monitor.track(-30, width: 250, in: store)
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let slide = try XCTUnwrap(host.spaceSlide)
        XCTAssertEqual(slide.offset, -30, accuracy: 1)
        var publications = 0
        let observer = store.spaceGesture.objectWillChange.sink { publications += 1 }
        monitor.track(-80, width: 250, in: store)
        XCTAssertEqual(publications, 0, "Finger tracking must not invalidate SwiftUI on each event")
        XCTAssertEqual(store.spaceDrag, -80)
        XCTAssertEqual(store.spaceGesture.footer.drag, -80,
                       "The isolated footer must follow every native finger update")
        withExtendedLifetime(observer) {}
        XCTAssertTrue(host.spaceSlide === slide, "Scroll events must retain the mounted lists")
        XCTAssertEqual(slide.offset, -80, accuracy: 1)
        XCTAssertEqual(store.currentSpaceID, spaces[0].id, "Dragging must not activate the page")
        monitor.land(1, to: spaces[1], width: 250, store: store,
                     duration: 0.4)
        XCTAssertTrue(host.spaceSlide === slide, "Release must animate the surface already under the fingers")
        // A newly ordered window may submit its first compositor frame after start().
        // Observe native completion before measuring the separate live-tree handoff.
        let animationDeadline = ProcessInfo.processInfo.systemUptime + 1
        while (store.spaceSwiping || store.spaceGesture.profileSliding),
              ProcessInfo.processInfo.systemUptime < animationDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(store.spaceSwiping, "The native landing must complete")
        XCTAssertFalse(store.spaceGesture.profileSliding)
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
        let handoffDeadline = ProcessInfo.processInfo.systemUptime + 0.18
        while host.spaceSlide != nil, ProcessInfo.processInfo.systemUptime < handoffDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(host.spaceSlide, "After native completion, retire through the live acknowledgement, not the one-second safeguard")
    }

    func testLandingKeepsOneContinuousNativeProgressSource() async throws {
        let (store, spaces, window, monitor) = try fixture()
        monitor.track(-20, width: 250, in: store)
        monitor.track(-80, width: 250, in: store)
        let slide = try XCTUnwrap((window.contentView as? BrowserWindowHost)?.spaceSlide)
        var samples: [CGFloat] = []
        let observation = store.spaceGesture.footer.$drag.sink { value in
            guard let value else { return }
            samples.append(value)
            XCTAssertEqual(value, slide.offset, accuracy: 1,
                           "Each footer publication must come from the same native presentation")
        }
        defer { observation.cancel() }
        monitor.land(1, to: spaces[1], width: 250, store: store, duration: 0.4)
        XCTAssertEqual(store.spaceGesture.footer.drag, -80,
                       "Release must not fall back to the first drag sample")
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(store.currentSpaceID, spaces[1].id,
                       "The page should change under the covering native sidebar, not wait for its endpoint")
        XCTAssertEqual(store.spaceGesture.outgoing?.space.id, spaces[0].id,
                       "Footer and tint must keep their captured origin after page selection")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertGreaterThan(samples.count, 2, "Landing must publish intermediate presentation progress")
        for (previous, next) in zip(samples, samples.dropFirst()) {
            XCTAssertLessThanOrEqual(next, previous + 0.5, "A committed footer must never reverse")
        }
        XCTAssertNil((window.contentView as? BrowserWindowHost)?.spaceSlide)
        XCTAssertNil(store.spaceGesture.footer.drag)
    }

    func testCompletedCoverKeepsLiveRowsHiddenUntilPopulationIsReady() throws {
        let (store, spaces, window, _) = try fixture()
        let population = try EmptyNativeSidebarPopulationFixture(store: store, spaceID: spaces[1].id)
        defer { population.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        window.contentView = container
        let slide = ProfileSpaceSlide(frame: container.bounds,
            outgoing: store.swipePreview(in: spaces[0]), incoming: store.swipePreview(in: spaces[1]),
            drag: -80, direction: 1, source: store, includesFavorites: false, travelWidth: 250)
        container.addSubview(slide)
        defer { slide.cancel() }
        slide.start(duration: 0.02) { store.switchTo(space: spaces[1]) }
        slide.finish()
        XCTAssertFalse(slide.isActive, "The animation has finished independently of live population")
        XCTAssertTrue(store.spaceGesture.profileSliding,
                      "A retained native cover must still hide the live rows beneath its translucent text")
        slide.sidebarDidUpdate(store, renderedSpaceID: spaces[1].id, atRest: false)
        XCTAssertTrue(slide.superview === container, "Live population still owns its readiness prerequisite")
        population.complete()
        XCTAssertFalse(store.spaceGesture.profileSliding, "Ready population can request the live visibility update")
        XCTAssertTrue(slide.superview === container, "Population alone must not bypass the visibility acknowledgement")
        slide.sidebarDidUpdate(store, renderedSpaceID: spaces[1].id, atRest: true)
        XCTAssertNil(slide.superview)
        XCTAssertFalse(store.spaceGesture.profileSliding, "Retirement releases live-row visibility")
    }

    func testNativeCoverWaitsForTheLiveSidebarAcknowledgement() async throws {
        let (store, spaces, window, _) = try fixture()
        let population = try EmptyNativeSidebarPopulationFixture(store: store, spaceID: spaces[1].id)
        defer { population.close() }
        // A host that has not rendered its new live sidebar cannot acknowledge handoff.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        window.contentView = container
        let slide = ProfileSpaceSlide(frame: container.bounds,
            outgoing: store.swipePreview(in: spaces[0]), incoming: store.swipePreview(in: spaces[1]),
            drag: -80, direction: 1, source: store, includesFavorites: false, travelWidth: 250)
        container.addSubview(slide)
        defer { slide.cancel() }
        slide.start(duration: 0.02) { store.switchTo(space: spaces[1]) }
        slide.sidebarDidUpdate(store, renderedSpaceID: spaces[1].id, atRest: true)
        // This state-machine case owns an NSView-only destination. Deliver the
        // completion after that premature acknowledgement, then test the final one.
        slide.finish()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(slide.superview === container,
                      "One display tick alone does not prove the destination live sidebar exists")
        slide.sidebarDidUpdate(store, renderedSpaceID: spaces[0].id, atRest: true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(slide.superview === container, "A stale identity must not uncover the old sidebar")
        slide.sidebarDidUpdate(store, renderedSpaceID: spaces[1].id, atRest: false)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(slide.superview === container, "The hidden tree still offset by the drag is not ready")
        population.complete()
        XCTAssertTrue(slide.superview === container,
                      "Ready empty population must still wait for the final identity/rest acknowledgement")
        slide.sidebarDidUpdate(store, renderedSpaceID: spaces[1].id, atRest: true)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(slide.superview, "An acknowledged destination retires without waiting for the safeguard")
    }

    func testRenderedSpaceLandingAcknowledgesItsLiveSidebarPromptly() async throws {
        let (store, spaces, window, monitor) = try fixture()
        monitor.track(-80, width: fixtureSidebarWidth(in: store), in: store)
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        monitor.land(1, to: spaces[1], width: fixtureSidebarWidth(in: store), store: store, duration: 0.12)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.currentSpaceID, spaces[1].id)
        XCTAssertNil(host.spaceSlide, "The rendered identity must retire the cover before the one-second safeguard")
    }

    func testSynchronousLiveSidebarAcknowledgementIsNotLostDuringCompletion() async throws {
        let (store, spaces, window, _) = try fixture()
        let population = try EmptyNativeSidebarPopulationFixture(store: store, spaceID: spaces[1].id)
        defer { population.close() }
        population.complete()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        window.contentView = container
        let slide = ProfileSpaceSlide(frame: container.bounds,
            outgoing: store.swipePreview(in: spaces[0]), incoming: store.swipePreview(in: spaces[1]),
            drag: -80, direction: 1, source: store, includesFavorites: false, travelWidth: 250)
        container.addSubview(slide)
        defer { slide.cancel() }
        slide.start(duration: 0.02) {
            store.switchTo(space: spaces[1])
            store.spaceDrag = 0
            store.spaceSwiping = false
            store.spaceGesture.profileSliding = false
            // NSHostingView can update synchronously with final state publication,
            // before finish() arms its destination-specific retirement guard.
            slide.sidebarDidUpdate(store, renderedSpaceID: spaces[1].id, atRest: true)
        }
        // This state-machine fixture has no live sidebar/application-loop owner.
        // Deliver completion synchronously so the assertion exercises the
        // acknowledgement reentering finish(), rather than CA startup timing.
        slide.finish()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertNil(slide.superview,
                     "A valid acknowledgement during completion must retire without the safeguard")
    }

    func testCommittedNativeLandingRetainsFingerVelocity() async throws {
        try await withFixtureApplicationLoop { try await checkCommittedNativeLandingRetainsFingerVelocity() }
    }

    func testNativeLandingKeepsEventVelocityAcrossDelayedDelivery() async throws {
        try await withFixtureApplicationLoop {
            try await checkCommittedNativeLandingRetainsFingerVelocity(delayedDelivery: true)
        }
    }

    func testNativeLandingDiscardsVelocityAfterAnEventTimeHold() async throws {
        try await withFixtureApplicationLoop {
            try await checkCommittedNativeLandingRetainsFingerVelocity(staleRelease: true)
        }
    }

    private func checkCommittedNativeLandingRetainsFingerVelocity(
        delayedDelivery: Bool = false, staleRelease: Bool = false
    ) async throws {
        let (store, spaces, window, monitor) = try fixture(registerTeardown: false)
        defer { retireFixture(store, window: window, monitor: monitor) }
        try await admitFixtureSidebar(store, window: window)
        try await waitForPreparation(monitor, target: spaces[1].id)
        // Deliver actual monitor events with the finger's 20ms sample interval.
        // Rendering/scheduling may delay delivery without changing event time.
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .began, timestamp: 1))
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -20, timestamp: 1))
        try await Task.sleep(for: .milliseconds(20))
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -40, timestamp: 1.02))
        if delayedDelivery { try await Task.sleep(for: .milliseconds(150)) }
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .ended,
            timestamp: staleRelease ? 1.22 : 1.03))
        let slide = try XCTUnwrap((window.contentView as? BrowserWindowHost)?.spaceSlide)
        let animation = try XCTUnwrap(slide.outgoing.layer?.animation(forKey: "space-position") as? CASpringAnimation)
        if staleRelease {
            XCTAssertEqual(animation.initialVelocity, 0, "A stationary hold must expire the finger velocity")
        } else {
            XCTAssertGreaterThan(animation.initialVelocity, 0, "Release must retain the finger's forward velocity")
        }
        XCTAssertLessThanOrEqual(animation.initialVelocity, sqrt(animation.stiffness / animation.mass),
                                 "A fast flick must not overshoot the destination")
        try await Task.sleep(for: .milliseconds(400))
    }

    func testArmedNativeLandingKeepsReleaseVelocityAcrossPagePreparation() async throws {
        try await withFixtureApplicationLoop {
            let (store, spaces, window, monitor) = try self.fixture(registerTeardown: false)
            defer { self.retireFixture(store, window: window, monitor: monitor) }
            try await self.admitFixtureSidebar(store, window: window)
            try await self.waitForPreparation(monitor, target: spaces[1].id)
            let width = self.fixtureSidebarWidth(in: store)
            monitor.track(-20, width: width, in: store)
            let slide = try XCTUnwrap((window.contentView as? BrowserWindowHost)?.spaceSlide)
            // Control sample time independently of native rendering work. The
            // integration case above retains real event timing; this case tests
            // only ownership of that sample across delayed page preparation.
            let sampleTime = ProcessInfo.processInfo.systemUptime
            slide.track(drag: -20, at: sampleTime)
            slide.track(drag: -60, at: sampleTime + 0.02)
            slide.armLanding(to: spaces[1], at: sampleTime + 0.02, completion: {})
            // Preparation can outlive the event freshness window. It must not
            // turn an already committed moving release into a stationary click.
            try await Task.sleep(for: .milliseconds(150))
            slide.start(duration: Look.spaceLandingDuration, completion: {})
            let animation = try XCTUnwrap(slide.outgoing.layer?.animation(forKey: "space-position") as? CASpringAnimation)
            XCTAssertGreaterThan(animation.initialVelocity, 0)
            XCTAssertLessThanOrEqual(animation.initialVelocity, sqrt(animation.stiffness / animation.mass))
        }
    }

    func testCanceledNativeDragUsesTheReturnSpring() async throws {
        try await withFixtureApplicationLoop { try await self.checkCanceledNativeDragUsesTheReturnSpring() }
    }

    private func checkCanceledNativeDragUsesTheReturnSpring() async throws {
        let app = NSApplication.shared
        let (store, _, window, monitor) = try fixture(registerTeardown: false)
        defer { retireFixture(store, window: window, monitor: monitor) }
        try await compatibilityWait {
            window.contentView?.layoutSubtreeIfNeeded()
            if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
            if !app.isActive { app.activate(ignoringOtherApps: true) }
            guard app.isRunning, app.isActive, window.isKeyWindow,
                  window.occlusionState.contains(.visible),
                  let anchor = store.spaceGesture.sectionsView, anchor.window === window,
                  let root = window.contentView?.layer, let presentedRoot = root.presentation(),
                  let layer = anchor.layer, let presented = layer.presentation(),
                  SidebarNativeReadinessCoordinator.shared.isReady(
                    SidebarNativeReadinessScope(store: store, spaceID: store.currentSpaceID),
                    allowingUnregistered: !NativeCachedSidebarBatchesExperiment.enabled) else { return false }
            return abs(presented.convert(.zero, to: presentedRoot).x - layer.convert(.zero, to: root).x) < 0.125
        }
        monitor.track(-60, width: fixtureSidebarWidth(in: store), in: store)
        let slide = try XCTUnwrap((window.contentView as? BrowserWindowHost)?.spaceSlide)
        var completed = false
        slide.start(duration: 0.16, returning: true) {
            Motion.spaceHandoff {
                completed = true
                store.spaceDrag = 0
                store.spaceSwiping = false
            }
        }
        XCTAssertNotNil(slide.outgoing.layer?.animation(forKey: "space-position") as? CASpringAnimation,
                        "The visible native surface must spring back, not just its hidden SwiftUI copy")
        XCTAssertFalse(completed)
        try await Task.sleep(for: .milliseconds(500))
        print("RETURN_SPRING completed=\(completed) active=\(slide.isActive) cover=\((window.contentView as? BrowserWindowHost)?.spaceSlide === slide) appActive=\(app.isActive) key=\(window.isKeyWindow)")
        XCTAssertTrue(completed)
        XCTAssertNil((window.contentView as? BrowserWindowHost)?.spaceSlide)
    }

    func testNativeLandingReusesItsCoverBeforeTheLiveAnchorMounts() async throws {
        try await withFixtureApplicationLoop { try self.checkNativeLandingBeforeTheLiveAnchorMounts() }
    }

    private func checkNativeLandingBeforeTheLiveAnchorMounts() throws {
        let (store, spaces, window, monitor) = try fixture(registerTeardown: false)
        defer { retireFixture(store, window: window, monitor: monitor) }
        monitor.track(-80, width: fixtureSidebarWidth(in: store), in: store)
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let slide = try XCTUnwrap(host.spaceSlide)
        let anchor = store.spaceGesture.sectionsView
        defer {
            monitor.interruptLanding()
            host.cancelSpaceSlide()
            store.spaceGesture.sectionsView = anchor
        }
        // A cold arriving profile can own the captured native rows before its
        // replacement live anchor exists. The valid cover already has geometry.
        store.spaceGesture.sectionsView = nil
        monitor.land(1, to: spaces[1], width: fixtureSidebarWidth(in: store), store: store, duration: 0.8)
        XCTAssertTrue(host.spaceSlide === slide,
                      "Missing live geometry must not discard an already owned native landing")
        XCTAssertTrue(slide.isActive)
    }

    func testFingerTrackingCanCrossZeroAndReverseToAnotherNeighbour() throws {
        let (store, spaces, window, monitor) = try fixture()
        store.switchTo(space: spaces[1])
        window.contentView?.layoutSubtreeIfNeeded()
        monitor.track(-40, width: 250, in: store)
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let first = try XCTUnwrap(host.spaceSlide)
        monitor.track(0, width: 250, in: store)
        XCTAssertTrue(host.spaceSlide === first)
        XCTAssertEqual(first.offset, 0, accuracy: 1)
        monitor.track(40, width: 250, in: store)
        let reversed = try XCTUnwrap(host.spaceSlide)
        XCTAssertFalse(reversed === first)
        XCTAssertTrue(reversed.follows(spaces[0], direction: -1))
        XCTAssertEqual(reversed.offset, 40, accuracy: 1)
        monitor.abort()
    }

    func testAbortedFingerTrackingRemovesNativeSurface() throws {
        let (store, _, window, monitor) = try fixture()
        monitor.track(-40, width: 250, in: store)
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        XCTAssertNotNil(host.spaceSlide)
        monitor.abort()
        XCTAssertNil(host.spaceSlide)
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertFalse(store.spaceGesture.profileSliding)
        XCTAssertEqual(store.spaceDrag, 0)
    }

    private func selectThroughApplicationEvent(_ space: Space, in store: TabStore,
                                               window: NSWindow,
                                               afterSelection: @escaping @MainActor () -> Void) async throws -> ContinuousClock.Instant {
        // Dispatch through the admitted NSApplication loop, rather than reentering
        // the action from an XCTest executor continuation between display commits.
        let token = Int.random(in: 1...Int.max)
        var selectedAt: ContinuousClock.Instant?
        var admitted = false
        let handler = try XCTUnwrap(NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { event in
            guard event.type == .applicationDefined, event.data1 == token else { return event }
            MainActor.assumeIsolated {
                guard NSApp.isRunning, NSApp.isActive, NSApp.keyWindow === window,
                      window.isKeyWindow, window.isVisible, window.occlusionState.contains(.visible),
                      NSApp.modalWindow == nil, window.attachedSheet == nil,
                      store.window === window, store.profileVisible,
                      store.spaceGesture.sectionsView?.window === window,
                      store.spaceGesture.monitor.isInstalled else {
                    selectedAt = .now
                    return
                }
                admitted = true
                store.spaceGesture.monitor.select(space, in: store)
                let returnedAt = ContinuousClock.now
                afterSelection()
                selectedAt = returnedAt
            }
            return nil
        })
        defer { NSEvent.removeMonitor(handler) }
        let event = try XCTUnwrap(NSEvent.otherEvent(with: .applicationDefined, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, subtype: 0, data1: token, data2: 0))
        NSApp.postEvent(event, atStart: false)
        try await compatibilityWait { selectedAt != nil }
        return try XCTUnwrap(admitted ? selectedAt : nil,
                            "Posted selection must still own the actual foreground sidebar when dispatched")
    }

    func testProfileClickPreservesSlideAndReduceMotionAcrossHosts() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do { try await checkProfileClickPreservesSlideAndReduceMotionAcrossHosts() }
        catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Profile click AppKit loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func checkProfileClickPreservesSlideAndReduceMotionAcrossHosts() async throws {
        let manager = ProfileManager.shared
        let previous = manager.active
        let firstProfile = fixtureProfile(named: "Immediate origin")
        let secondProfile = fixtureProfile(named: "Immediate destination")
        let first = manager.createSpace(name: "First", in: firstProfile.id)
        let second = manager.createSpace(name: "Second", in: secondProfile.id)
        let source = Windows.open(profile: firstProfile, space: first, focus: false)
        let window = try XCTUnwrap(source.window)
        window.animationBehavior = .none
        defer {
            retireProfileWindow(window)
            _ = manager.delete(firstProfile.id)
            _ = manager.delete(secondProfile.id)
            manager.active = previous
        }
        let reduced = Motion.spaceReduced
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await compatibilityWait {
            if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            return NSApp.isRunning && NSApp.isActive && NSApp.keyWindow === window
                && window.isVisible && window.occlusionState.contains(.visible)
                && NSApp.modalWindow == nil && window.attachedSheet == nil
                && source.window === window && source.profileVisible
                && source.spaceGesture.sectionsView?.window === window
                && source.spaceGesture.monitor.isInstalled
        }
        let selectedAt = try await selectThroughApplicationEvent(second, in: source, window: window) {
            if reduced {
                let immediate = TabStore.all.first { $0.window === window }
                XCTAssertEqual(immediate?.profileID, secondProfile.id)
                XCTAssertEqual(immediate?.currentSpaceID, second.id)
                XCTAssertFalse(source.spaceSwiping)
                XCTAssertNil(window.contentView?.layer?.animation(forKey: "profile-space"))
                XCTAssertNil((window.contentView as? BrowserWindowHost)?.spaceSlide,
                             "Reduce Motion must complete inside the action, before another AppKit turn")
            } else {
                XCTAssertTrue(source.window === window)
            }
        }
        if !reduced {
            try await Task.sleep(until: selectedAt + .milliseconds(310))
        }
        let destination = try XCTUnwrap(TabStore.all.first { $0.window === window })
        XCTAssertEqual(destination.profileID, secondProfile.id)
        XCTAssertEqual(destination.currentSpaceID, second.id)
        XCTAssertFalse(source.spaceSwiping)
        XCTAssertNil(window.contentView?.layer?.animation(forKey: "profile-space"), "No full-window fade")
        if reduced {
            XCTAssertNil((window.contentView as? BrowserWindowHost)?.spaceSlide,
                         "Reduce Motion switches the page and sidebar immediately")
        } else {
            // Preserve the original second, post-arrival display interval. A
            // delayed first wake after cold mounting must still yield to AppKit
            // completion delivery rather than skip this phase as already late.
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertNil((window.contentView as? BrowserWindowHost)?.spaceSlide,
                         "Retire the overlay once the arriving profile has drawn")
        }
        let returnedAt = try await selectThroughApplicationEvent(first, in: destination, window: window) {
            if reduced {
                XCTAssertTrue(source.window === window)
                XCTAssertEqual(source.currentSpaceID, first.id)
            }
        }
        if !reduced { try await Task.sleep(until: returnedAt + .milliseconds(310)) }
        XCTAssertTrue(source.window === window, "A cached profile must also switch during its slide")
        XCTAssertEqual(source.currentSpaceID, first.id)
    }

    func testHiddenCrossProfileLandingTracksAndRetiresTheActualArrivingSidebar() async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "A committed native profile landing requires motion")
        let manager = ProfileManager.shared
        let previous = manager.active
        let firstProfile = fixtureProfile(named: "Hidden profile origin")
        let secondProfile = fixtureProfile(named: "Hidden profile destination")
        let first = manager.createSpace(name: "First", in: firstProfile.id)
        let second = manager.createSpace(name: "Second", in: secondProfile.id)
        let source = Windows.open(profile: firstProfile, space: first, focus: false)
        let window = try XCTUnwrap(source.window)
        window.animationBehavior = .none
        defer {
            retireProfileWindow(window)
            _ = manager.delete(firstProfile.id)
            _ = manager.delete(secondProfile.id)
            manager.active = previous
        }
        try await Task.sleep(for: .milliseconds(80))
        source.spaceGesture.monitor.select(second, in: source)
        let departing = try XCTUnwrap((window.contentView as? BrowserWindowHost)?.spaceSlide)
        Motion.instant { source.sidebarShown = false; source.sidebarPeeking = false }
        window.contentView?.layoutSubtreeIfNeeded()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.4
        while source.window === window, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let arriving = try XCTUnwrap(TabStore.all.first { $0.window === window })
        XCTAssertEqual(arriving.profileID, secondProfile.id, "Hiding preserves the committed profile selection")
        XCTAssertEqual(arriving.currentSpaceID, second.id)
        XCTAssertTrue(departing.isDestination(arriving),
                      "Completion must attach the actual destination before deciding sidebar retirement")
        XCTAssertFalse(arriving.sidebarShown)
        XCTAssertFalse(arriving.spaceGesture.profileSliding)
        XCTAssertNil((window.contentView as? BrowserWindowHost)?.spaceSlide)
        XCTAssertNil(departing.superview)
    }

    func testQueuedSameProfileSelectionPreservesVisibleProfileLandingBeforeReturning() async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "Interrupting a native slide requires animation")
        let manager = ProfileManager.shared
        let previous = manager.active
        let firstProfile = fixtureProfile(named: "Interrupted origin")
        let secondProfile = fixtureProfile(named: "Interrupted destination")
        let first = manager.createSpace(name: "First", in: firstProfile.id)
        let local = manager.createSpace(name: "Local", in: firstProfile.id)
        let remote = manager.createSpace(name: "Remote", in: secondProfile.id)
        let source = Windows.open(profile: firstProfile, space: first, focus: false)
        let window = try XCTUnwrap(source.window)
        window.animationBehavior = .none
        defer {
            retireProfileWindow(window)
            _ = manager.delete(firstProfile.id)
            _ = manager.delete(secondProfile.id)
            manager.active = previous
        }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertNotNil(source.beginSpaceSelection(remote))
        try await Task.sleep(for: .milliseconds(30))
        source.spaceGesture.monitor.land(1, to: remote, width: fixtureSidebarWidth(in: source),
            store: source, animation: .linear(duration: 0.4), duration: 0.4)
        try await Task.sleep(for: .milliseconds(40))
        let host = try XCTUnwrap(window.contentView as? BrowserWindowHost)
        let previousSlide = try XCTUnwrap(host.spaceSlide)
        let showing = try XCTUnwrap(TabStore.all.first { $0.window === window })
        showing.spaceGesture.monitor.select(local, in: showing)
        XCTAssertTrue(host.spaceSlide === previousSlide,
                      "Already visible incoming profile rows must finish on their original surface")
        XCTAssertTrue(source.spaceGesture.profileSlidesFavorites,
                      "The committed profile's visible favourites must not disappear on the next click")
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while (source.window !== window || source.currentSpaceID != local.id || source.spaceSwiping || host.spaceSlide != nil),
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(source.window === window)
        XCTAssertEqual(source.currentSpaceID, local.id, "The latest requested local Space must follow the visible profile leg")
        XCTAssertNil(host.spaceSlide)
    }
}

/// Temporary characterization of WindowServer pixels. These observations never
/// replace the base-gradient assertions or interpret missing capture as continuity.
private final class ProfilePixelCharacterization: NSObject, SCStreamOutput, @unchecked Sendable {
    private struct Frame {
        let time: Double
        let receipt: Double
        let status: Int
        let sites: [[Double]]?
    }
    private struct Leg {
        let label: String
        let start: Double
        let baseline: Frame?
        var retired: Double?
        var end: Double?
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "vane.profile.pixel-characterization")
    private var frames: [Frame] = []
    private var dropped = 0
    private var queueDrained = false
    @MainActor private var stream: SCStream?
    @MainActor private var generation: UUID?
    @MainActor private var legs: [Leg] = []
    @MainActor private var geometry = "not-started"
    @MainActor private var calibration = "not-started"
    @MainActor private var started = false
    @MainActor private var stopped = false
    private var lastComplete: Frame? { lock.withLock { frames.last { $0.sites != nil && $0.status == SCFrameStatus.complete.rawValue } } }

    @MainActor private func bounded(_ name: String, _ operation: @escaping @MainActor () async throws -> Void) async throws {
        var result: Result<Void, any Error>?
        let task = Task { @MainActor in
            do { try await operation(); result = .success(()) }
            catch { result = .failure(error) }
        }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while result == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard let result else {
            XCTFail("Profile pixel characterization timed out: \(name)")
            throw NSError(domain: "ProfilePixelCharacterizationTimeout", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: name])
        }
        try result.get()
    }

    @MainActor func start(source: TabStore, host: BrowserWindowHost, window: NSWindow) async throws {
        let pill = try XCTUnwrap(source.mountedAddressEndpoint)
        XCTAssertTrue(pill.window === window && host.window === window)
        let pillRect = pill.convert(pill.bounds, to: host)
        let width = SidebarWidth.inWindow(source)
        let middleY = host.isFlipped ? pillRect.minY - Look.inset / 2 : pillRect.maxY + Look.inset / 2
        let band = CGRect(x: host.bounds.minX + 2 * Look.inset, y: middleY - 2,
                          width: width - 4 * Look.inset, height: 4)
        let sidebar = CGRect(x: host.bounds.minX, y: host.bounds.minY, width: width, height: host.bounds.height)
        guard band.width >= 12, host.bounds.contains(band), sidebar.contains(band), !band.intersects(pillRect) else {
            XCTFail("Profile pixel crop must be an admitted sidebar gap outside the address pill")
            throw NSError(domain: "ProfilePixelCrop", code: 1)
        }
        for owner in TabStore.all where owner.window === window || owner.parkedIn === window {
            let strip = try XCTUnwrap(owner.spaceGesture.stripView)
            XCTAssertTrue(strip.window === window)
            XCTAssertFalse(band.intersects(strip.convert(strip.bounds, to: host)),
                           "Moving row ink must never cross the pixel crop")
        }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = window.standardWindowButton(kind) {
                XCTAssertFalse(band.intersects(button.convert(button.bounds, to: host)),
                               "Traffic lights must remain outside the pixel crop")
            }
        }
        let screenCrop = window.convertToScreen(host.convert(band, to: nil))
        let sourceRect = CGRect(x: screenCrop.minX - window.frame.minX,
            y: window.frame.maxY - screenCrop.maxY, width: band.width, height: band.height)
        guard CGRect(origin: .zero, size: window.frame.size).contains(sourceRect) else {
            XCTFail("Profile pixel sourceRect must lie inside the exact filtered window")
            throw NSError(domain: "ProfilePixelCrop", code: 2)
        }
        geometry = "host=\(host.bounds) sidebar=\(sidebar) pill=\(pillRect) band=\(band) sourceRect=\(sourceRect) windowSize=\(window.frame.size)"
        calibration = "media=\(CACurrentMediaTime()) uptime=\(ProcessInfo.processInfo.systemUptime) cmHost=\(CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())))"
        let token = UUID()
        generation = token
        var content: SCShareableContent?
        try await bounded("currentProcess") { content = try await SCShareableContent.currentProcess }
        let target = try XCTUnwrap(content?.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = max(1, Int(ceil(band.width * scale)))
        configuration.height = max(1, Int(ceil(band.height * scale)))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureDynamicRange = .SDR
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.displayP3
        configuration.minimumFrameInterval = CMTime(value: 1,
            timescale: CMTimeScale(window.screen?.maximumFramesPerSecond ?? 60))
        configuration.queueDepth = 8
        let capture = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = capture
        try await bounded("startCapture") { [self] in
            try await capture.startCapture()
            // A cancelled startup must not adopt a stream after fixture cleanup.
            guard generation == token, !Task.isCancelled else {
                try await capture.stopCapture()
                throw CancellationError()
            }
        }
        started = true
        let admissionDeadline = ContinuousClock.now + .seconds(5)
        while lastComplete == nil, ContinuousClock.now < admissionDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard lastComplete != nil else {
            XCTFail("Profile pixel characterization needs a complete baseline before input")
            throw NSError(domain: "ProfilePixelBaseline", code: 1)
        }
    }

    @MainActor func beginLeg(label: String) {
        legs.append(Leg(label: label, start: CACurrentMediaTime(), baseline: lastComplete))
    }
    @MainActor func endLeg() {
        guard !legs.isEmpty else { return }
        legs[legs.count - 1].retired = CACurrentMediaTime()
    }
    // Characterization-only tail begins after every original action/assertion.
    // It cannot extend a gesture, retirement deadline, or raw continuity gate.
    @MainActor func completeLegObservation() async throws {
        guard let retired = legs.last?.retired else { return }
        let deadline = retired + 0.1
        while CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        legs[legs.count - 1].end = CACurrentMediaTime()
    }
    @MainActor func stop() async throws {
        generation = nil
        guard let capture = stream else { return }
        var failure: (any Error)?
        do { try await bounded("stopCapture") { try await capture.stopCapture() }; stopped = true }
        catch { failure = error }
        do { try capture.removeStreamOutput(self, type: .screen) }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Profile pixel output removal also failed: \(error)") }
        }
        lock.withLock { queueDrained = false }
        queue.async { [self] in lock.withLock { queueDrained = true } }
        let drainDeadline = ContinuousClock.now + .seconds(1)
        while !lock.withLock({ queueDrained }), ContinuousClock.now < drainDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        if !lock.withLock({ queueDrained }) {
            XCTFail("Profile pixel callback queue did not drain")
            if failure == nil { failure = NSError(domain: "ProfilePixelDrain", code: 1) }
        }
        if stopped { stream = nil }
        if let failure { throw failure }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let time = CMTimeGetSeconds(buffer.presentationTimeStamp)
        let receipt = CACurrentMediaTime()
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let status = buffer.isValid ? (attachments?.first?[.status] as? Int ?? -1) : -2
        var sites: [[Double]]?
        if status == SCFrameStatus.complete.rawValue, let pixel = buffer.imageBuffer {
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
            if let bytes = CVPixelBufferGetBaseAddress(pixel)?.assumingMemoryBound(to: UInt8.self) {
                let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
                let stride = CVPixelBufferGetBytesPerRow(pixel)
                if width >= 6, height >= 1 {
                    sites = [1, 3, 5].map { sixth in
                        let x = min(width - 1, width * sixth / 6)
                        let offset = height / 2 * stride + x * 4
                        return [Double(bytes[offset + 2]) / 255, Double(bytes[offset + 1]) / 255, Double(bytes[offset]) / 255]
                    }
                }
            }
        }
        let frame = Frame(time: time, receipt: receipt, status: status, sites: sites)
        lock.withLock {
            if frames.count < 4096 { frames.append(frame) }
            else { dropped += 1 }
        }
    }

    @MainActor func dump() {
        let recorded = lock.withLock { (frames, dropped) }
        let invalid = recorded.0.filter { !$0.time.isFinite }
        print("PROFILE_PIXEL_BEGIN started=\(started) stopped=\(stopped) dropped=\(recorded.1) invalidTimes=\(invalid.count) \(geometry) calibration={\(calibration)}")
        for frame in invalid {
            print("PROFILE_PIXEL_INVALID time=\(frame.time) receipt=\(frame.receipt) status=\(frame.status)")
        }
        func red(_ frame: Frame) -> Double? { frame.sites.map { $0.map { $0[0] }.sorted()[1] } }
        func spread(_ frame: Frame) -> Double {
            guard let sites = frame.sites else { return .infinity }
            return (0..<3).map { channel in
                let values = sites.map { $0[channel] }
                return values.max()! - values.min()!
            }.max()!
        }
        for leg in legs {
            let end = leg.end ?? leg.start
            let observed = recorded.0.filter { $0.time.isFinite && $0.time >= leg.start && $0.time <= end }
            let complete = observed.filter { $0.status == SCFrameStatus.complete.rawValue && $0.sites != nil }
            let last = complete.last
            let contrast = abs((leg.baseline.flatMap(red) ?? 0) - (last.flatMap(red) ?? 0))
            // Cover the entire actual handoff and post-retirement observation,
            // including delayed commits; the nominal 300 ms is not its endpoint.
            let times = [leg.start] + observed.map(\.time) + [end]
            let maxGap = zip(times, times.dropFirst()).map { $1 - $0 }.max() ?? .infinity
            let badStatus = observed.contains {
                ($0.status != SCFrameStatus.complete.rawValue && $0.status != SCFrameStatus.idle.rawValue)
                    || ($0.status == SCFrameStatus.complete.rawValue && $0.sites == nil)
            }
            let monotonic = zip(observed, observed.dropFirst()).allSatisfy { $0.time <= $1.time }
            let spatial = max(leg.baseline.map(spread) ?? .infinity, complete.map(spread).max() ?? .infinity)
            let baselineFresh = leg.baseline.map { (0...0.1).contains(leg.start - $0.time) } ?? false
            let endpointFresh = last.map { frame in
                guard let retired = leg.retired else { return false }
                return frame.time >= retired && (0...0.1).contains(end - frame.time)
            } ?? false
            let adequate = started && stopped && recorded.1 == 0 && invalid.isEmpty && monotonic && leg.end != nil && leg.retired != nil
                && complete.count > 3 && contrast > 0.025 && maxGap <= 0.05 && !badStatus && spatial <= 0.03
                && baselineFresh && endpointFresh
            let sourceRed = leg.baseline.flatMap(red)
            let endpointRed = last.flatMap(red)
            let reds = [leg.baseline].compactMap { $0 }.compactMap(red) + complete.compactMap(red)
            let direction = (endpointRed ?? 0) >= (sourceRed ?? 0) ? 1.0 : -1.0
            let reverse = zip(reds, reds.dropFirst()).map { ($0 - $1) * direction }.max() ?? 0
            print("PROFILE_PIXEL_LEG \(leg.label) sensitivity=\(adequate ? "ADEQUATE" : "INCONCLUSIVE") start=\(leg.start) retired=\(String(describing: leg.retired)) end=\(end) complete=\(complete.count) statuses=\(observed.map(\.status)) contrast=\(contrast) spatial=\(spatial) maxGap=\(maxGap) source=\(String(describing: sourceRed)) endpoint=\(String(describing: endpointRed)) maxReverse=\(reverse) normalizedReverse=\(contrast > 0 ? reverse / contrast : .infinity)")
            for frame in observed {
                print("PROFILE_PIXEL_FRAME \(leg.label) time=\(frame.time) relative=\(frame.time - leg.start) receipt=\(frame.receipt) status=\(frame.status) rgb=\(String(describing: frame.sites))")
            }
        }
        print("PROFILE_PIXEL_END")
    }
}

/// Temporary public-only discriminator. A native main-run-loop callback and a
/// Swift task read the same values, without changing any gesture or assertion.
@MainActor private final class ProfileLandingCallbackProbe: NSObject {
    private struct Sample {
        let channel: String
        let time: TimeInterval
        let displayTime: TimeInterval?
        let targetTime: TimeInterval?
        let offset: CGFloat
        let modelX: CGFloat
        let active: Bool
        let targetActive: Bool
        let pageMounted: Bool
        let ownerPresented: Bool
        let red: CGFloat?
        let footerDrag: CGFloat?
        let profileSliding: Bool
        let animation: Bool
        let foreground: Bool
    }
    private weak var window: NSWindow?
    private weak var slide: ProfileSpaceSlide?
    private let targetID: UUID
    private var began: TimeInterval?
    private var link: CADisplayLink?
    private var samples: [Sample] = []
    private var nativeCallbacks = 0
    private var nativeCallbacksBeforeRelease = 0
    private var dropped = 0

    init(window: NSWindow, targetID: UUID) {
        self.window = window
        self.targetID = targetID
        samples.reserveCapacity(256)
    }
    func start(on screen: NSScreen) {
#if DEBUG
        ProfileHopPhaseDiagnostics.reset()
#endif
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        let rate = Float(screen.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func begin(slide: ProfileSpaceSlide) {
        self.slide = slide
        began = CACurrentMediaTime()
        nativeCallbacksBeforeRelease = nativeCallbacks
        samples.removeAll(keepingCapacity: true)
    }
    func noteTask(_ name: String) { record(channel: "task:\(name)", link: nil) }
    @objc private func tick(_ link: CADisplayLink) {
        nativeCallbacks += 1
        record(channel: "native", link: link)
    }
    private func record(channel: String, link: CADisplayLink?) {
        guard let began, let slide, let window else { return }
        let now = CACurrentMediaTime()
        if link != nil, now - began > 1.2 {
            self.link?.invalidate()
            self.link = nil
            return
        }
        guard samples.count < 256 else { dropped += 1; return }
        let owner = TabStore.all.first { $0.window === window }
        let surface = owner?.spaceGesture.groundSurface
        var ownerPresented = surface?.window === window
        var reachedHost = false
        var node: NSView? = surface
        while let view = node {
            if let layer = view.layer {
                guard let presentation = layer.presentation() else { ownerPresented = false; break }
                if presentation.isHidden || presentation.opacity <= 0 { ownerPresented = false; break }
            } else if view.isHidden { ownerPresented = false; break }
            if view === window.contentView { reachedHost = true; break }
            node = view.superview
        }
        ownerPresented = ownerPresented && reachedHost
        let red: CGFloat?
        if let color = (surface?.base.presentation()?.colors as? [CGColor])?.first,
           let rgb = NSColor(cgColor: color)?.usingColorSpace(.deviceRGB) { red = rgb.redComponent }
        else { red = nil }
        samples.append(Sample(channel: channel, time: now - began,
            displayTime: link.map { $0.timestamp - began }, targetTime: link.map { $0.targetTimestamp - began },
            offset: slide.offset, modelX: slide.outgoing.frame.minX, active: slide.isActive,
            targetActive: owner?.currentSpaceID == targetID,
            pageMounted: owner?.active?.existingWeb?.window === window,
            ownerPresented: ownerPresented, red: red, footerDrag: owner?.spaceGesture.footer.drag,
            profileSliding: owner?.spaceGesture.profileSliding == true,
            animation: slide.outgoing.layer?.animation(forKey: "space-position") != nil,
            foreground: NSApp.isActive && NSApp.keyWindow === window && window.isVisible
                && window.occlusionState.contains(.visible)))
    }
    func stopAndDump(label: String) {
#if DEBUG
        ProfileHopPhaseDiagnostics.dump()
#endif
        link?.invalidate()
        link = nil
        guard began != nil else { return }
        print("PROFILE_CALLBACK_PROBE_BEGIN \(label) baselineCallbacks=\(nativeCallbacksBeforeRelease) dropped=\(dropped)")
        for sample in samples {
            print("PROFILE_CALLBACK_PROBE channel=\(sample.channel) time=\(sample.time) display=\(String(describing: sample.displayTime)) nextDisplay=\(String(describing: sample.targetTime)) offset=\(sample.offset) modelX=\(sample.modelX) active=\(sample.active) target=\(sample.targetActive) page=\(sample.pageMounted) presented=\(sample.ownerPresented) red=\(String(describing: sample.red)) footer=\(String(describing: sample.footerDrag)) sliding=\(sample.profileSliding) animation=\(sample.animation) foreground=\(sample.foreground)")
        }
        print("PROFILE_CALLBACK_PROBE_END \(label)")
    }
}

@MainActor private final class ProfileWashSampler: NSObject {
    weak var host: BrowserWindowHost?
    private var baselineReds: [Double] = []
    private var transitionSampler: ProfileWashLayerSampler?
    private var transitionSnapshot: ProfileWashLayerSnapshot?
    private var heldRed: Double?
    private weak var screen: NSScreen?
    var reds: [Double] { transitionSampler?.snapshot.reds ?? baselineReds }
    var travelReds: [Double] { heldRed.map { Self.travelValues(in: reds, held: $0) } ?? [] }

    static func travelValues(in reds: [Double], held: Double) -> [Double] {
        guard let endpoint = reds.last else { return [] }
        let epsilon = 0.000001
        let lower = min(held, endpoint) + epsilon
        let upper = max(held, endpoint) - epsilon
        var travel: [Double] = []
        for red in reds where red > lower && red < upper {
            if let previous = travel.last, abs(red - previous) <= epsilon { continue }
            travel.append(red)
        }
        return travel
    }

    var unadmittedTransitionCallbacks: Int { transitionSampler?.snapshot.unadmitted ?? 0 }
    var foregroundInterrupted = false
    private var samplingTransition = false
    private var baselineMaxGap: TimeInterval = 0
    var maxGap: TimeInterval { transitionSampler?.snapshot.maxGap ?? baselineMaxGap }
    private(set) var firstCallbackLatency: TimeInterval?
    private var started: TimeInterval?
    private var last: TimeInterval?
    private var link: CADisplayLink?
    private let diagnosticsEnabled = ProcessInfo.processInfo.environment["VANE_DIAG_PROFILE_WASH_SAMPLES"] == "1"
    private var diagnosticFrames: [String] = []
    init(host: BrowserWindowHost) { self.host = host }
    private func presentedSurfaces(in view: NSView) -> [ThemeWashSurface] {
        if let layer = view.layer {
            // The model host switches before its next compositor commit. Mixing
            // model visibility with presentation colors can sample the hidden
            // cached profile's old endpoint and fabricate a full-color reversal.
            guard let presentation = layer.presentation(), !presentation.isHidden,
                  presentation.opacity > 0 else { return [] }
        } else if view.isHidden { return [] }
        if let surface = view as? ThemeWashSurface { return [surface] }
        return view.subviews.flatMap { presentedSurfaces(in: $0) }
    }
    private func visibleSurface(in view: NSView) -> ThemeWashSurface? {
        let candidates = presentedSurfaces(in: view)
        return candidates.count == 1 ? candidates[0] : nil
    }
    func start(on screen: NSScreen) {
        self.screen = screen
        started = ProcessInfo.processInfo.systemUptime
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func beginTransitionSampling() {
        baselineReds.removeAll(keepingCapacity: true)
        diagnosticFrames.removeAll(keepingCapacity: true)
        samplingTransition = true
        baselineMaxGap = 0
        // Include delay before the first transition callback in the gap diagnostic.
        last = ProcessInfo.processInfo.systemUptime
    }
    func admitTransitionLayers() async throws {
        let host = try XCTUnwrap(host)
        let window = try XCTUnwrap(host.window)
        let owners = TabStore.all.filter { $0.window === window || $0.parkedIn === window }
        let surfaces = owners.compactMap { $0.spaceGesture.groundSurface }
        XCTAssertEqual(owners.count, 2, "Both cached profile owners must be known before sampling")
        XCTAssertEqual(surfaces.count, 2, "Both cached profile washes must be mounted before sampling")
        let snapshot = try ProfileWashLayerSnapshot(host: host, expectedSurfaces: surfaces)
        transitionSnapshot = snapshot
        let sampler = ProfileWashLayerSampler(layers: snapshot)
        transitionSampler = sampler
        sampler.start(on: try XCTUnwrap(screen))
        // Admit this independent run loop while the finger is held, before any
        // landing outcome exists. Do not count its admission frames as travel.
        try await compatibilityWait {
            let held = sampler.snapshot.reds.suffix(3)
            return held.count == 3 && (held.max()! - held.min()!) <= 0.000001
        }
        heldRed = sampler.snapshot.reds.last
        sampler.resetSamples()
    }
    func validateTransitionLayers() throws {
        guard let transitionSnapshot, let host else { return }
        let current = try ProfileWashLayerSnapshot(host: host, expectedSurfaces: [])
        XCTAssertEqual(current.surfaceSignature, transitionSnapshot.surfaceSignature,
                       "Cached profile wash owners and their ancestry must remain captured for the entire transition")
    }
    func close() async throws {
        samplingTransition = false
        link?.invalidate()
        link = nil
        guard let transitionSampler else { return }
        transitionSampler.stop()
        let deadline = ContinuousClock.now + .seconds(1)
        while !transitionSampler.isStopped, ContinuousClock.now < deadline {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.005) { continuation.resume() }
            }
        }
        guard transitionSampler.isStopped else {
            XCTFail("The profile layer sampler must join before fixture cleanup")
            throw NSError(domain: "ProfileWashSamplerShutdown", code: 1)
        }
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = ProcessInfo.processInfo.systemUptime
        if firstCallbackLatency == nil, let started { firstCallbackLatency = now - started }
        if let last { baselineMaxGap = max(baselineMaxGap, now - last) }
        last = now
        if diagnosticsEnabled, let host { recordDiagnostics(at: now, in: host) }
        guard let host, let surface = visibleSurface(in: host),
              let cg = (surface.base.presentation()?.colors as? [CGColor])?.first,
              let colour = NSColor(cgColor: cg)?.usingColorSpace(.deviceRGB) else {
            return
        }
        if !samplingTransition { baselineReds.append(colour.redComponent) }
    }
    func dumpLayerCharacterization(label: String) {
        guard let transitionSampler else { return }
        let trace = transitionSampler.snapshot
        print("PROFILE_RAW_BEGIN \(label) records=\(trace.frames.count) dropped=\(trace.droppedFrames)")
        for frame in trace.frames {
            print("PROFILE_RAW_FRAME time=\(frame.time) display=\(frame.displayTime) targetDisplay=\(frame.targetTime) surface=\(String(describing: frame.read.surfaceIndex)) presented=\(String(describing: frame.read.red)) model=\(String(describing: frame.read.modelRed)) animation=\(frame.read.animationPresent) begin=\(String(describing: frame.read.animationBegin)) reason=\(frame.read.reason)")
        }
        print("PROFILE_RAW_END \(label)")
    }
    func dumpDiagnostics(label: String) {
        guard diagnosticsEnabled else { return }
        print("PROFILE_WASH_DIAGNOSTICS_BEGIN \(label)")
        diagnosticFrames.forEach { print($0) }
        print("PROFILE_WASH_DIAGNOSTICS_END \(label)")
    }
    private func identity(_ object: AnyObject?) -> String {
        object.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
    }
    private func red(_ colors: Any?) -> String {
        guard let cg = (colors as? [CGColor])?.first,
              let color = NSColor(cgColor: cg)?.usingColorSpace(.deviceRGB) else { return "nil" }
        return String(format: "%.6f", Double(color.redComponent))
    }
    private func firstSurface(in view: NSView) -> ThemeWashSurface? {
        if let surface = view as? ThemeWashSurface { return surface }
        return view.subviews.lazy.compactMap { self.firstSurface(in: $0) }.first
    }
    private func recordDiagnostics(at now: TimeInterval, in host: BrowserWindowHost) {
        let selected = visibleSurface(in: host)
        let current = host.window.flatMap { window in TabStore.all.first { $0.window === window } }
        let profile = current?.profileID.uuidString ?? "nil"
        let space = current?.currentSpaceID?.uuidString ?? "nil"
        let slide = host.spaceSlide
        let offset = slide.map { String(format: "%.3f", Double($0.offset)) } ?? "nil"
        var details: [String] = []
        for (index, root) in host.subviews.enumerated() {
            guard let surface = firstSurface(in: root) else { continue }
            let rootPresentation = root.layer?.presentation()
            let surfacePresentation = surface.layer?.presentation()
            let modelRootHidden = root.isHiddenOrHasHiddenAncestor
            let presentationRootHidden = rootPresentation.map { String($0.isHidden) } ?? "nil"
            let presentationRootOpacity = rootPresentation.map { String($0.opacity) } ?? "nil"
            let modelRed = red(surface.base.colors)
            let presentationRed = red(surface.base.presentation()?.colors)
            var ancestors: [String] = []
            var node: NSView? = surface
            while let view = node {
                let presentation = view.layer?.presentation()
                let hidden = presentation.map { String($0.isHidden) } ?? "nil"
                let opacity = presentation.map { String($0.opacity) } ?? "nil"
                ancestors.append("\(identity(view)):modelHidden=\(view.isHidden),presentHidden=\(hidden),presentOpacity=\(opacity)")
                if view === root { break }
                node = view.superview
            }
            details.append("rootIndex=\(index),root=\(identity(root)),surface=\(identity(surface)),selected=\(surface === selected),modelRootHidden=\(modelRootHidden),presentRootHidden=\(presentationRootHidden),presentRootOpacity=\(presentationRootOpacity),modelRed=\(modelRed),presentRed=\(presentationRed),nativeAnimating=\(surface.nativeAnimating),ancestors=[\(ancestors.joined(separator: ";"))]")
            _ = surfacePresentation // Ancestor diagnostics include this layer as well.
        }
        let appActive = NSApp.isActive
        let key = host.window?.isKeyWindow ?? false
        let visible = host.window?.isVisible ?? false
        let compositorVisible = host.window?.occlusionState.contains(.visible) ?? false
        diagnosticFrames.append("PROFILE_WASH_FRAME t=\(now) sampleIndex=\(reds.count) activeProfile=\(profile) activeSpace=\(space) offset=\(offset) slideActive=\(slide?.isActive ?? false) appActive=\(appActive) key=\(key) windowVisible=\(visible) occlusionVisible=\(compositorVisible) roots={\(details.joined(separator: " | "))}")
    }

}

/// Only immutable Core Animation references cross into the sampling worker.
/// Capture the complete mounted wash set, including parked roots, on the main actor.
private final class ProfileWashLayerSnapshot: @unchecked Sendable {
    struct Surface {
        let base: CAGradientLayer
        let ancestry: [CALayer]
    }
    let host: CALayer
    let roots: Set<ObjectIdentifier>
    let surfaces: [Surface]
    let surfaceSignature: [ObjectIdentifier: [ObjectIdentifier]]

    @MainActor init(host view: BrowserWindowHost, expectedSurfaces: [ThemeWashSurface]) throws {
        func washes(in view: NSView) -> [ThemeWashSurface] {
            if let surface = view as? ThemeWashSurface { return [surface] }
            return view.subviews.flatMap { washes(in: $0) }
        }
        let mounted = washes(in: view)
        for surface in expectedSurfaces {
            XCTAssertTrue(mounted.contains { $0 === surface }, "Every cached owner must be in the captured wash set")
        }
        let hostLayer = try XCTUnwrap(view.layer)
        CATransaction.lock()
        defer { CATransaction.unlock() }
        roots = Set((hostLayer.sublayers ?? []).map(ObjectIdentifier.init))
        var captured: [Surface] = []
        for surface in mounted {
            var ancestry: [CALayer] = []
            var node: CALayer? = surface.base
            while let layer = node {
                ancestry.append(layer)
                if layer === hostLayer { break }
                node = layer.superlayer
            }
            XCTAssertTrue(ancestry.last === hostLayer, "A sampled wash must belong to the admitted host layer")
            captured.append(Surface(base: surface.base, ancestry: ancestry))
        }
        host = hostLayer
        surfaces = captured
        surfaceSignature = Dictionary(uniqueKeysWithValues: captured.map {
            (ObjectIdentifier($0.base), $0.ancestry.map(ObjectIdentifier.init))
        })
    }
}

/// AppKit restoration can occupy the main actor for longer than the 300 ms
/// animation. A separate display-link run loop observes its original layer-color
/// metric while the compositor moves, without touching AppKit from that thread.
private final class ProfileWashLayerSampler: NSObject, @unchecked Sendable {
    struct LayerRead {
        var red: Double?
        var modelRed: Double?
        var surfaceIndex: Int?
        var animationPresent = false
        var animationBegin: TimeInterval?
        var reason: String
    }
    struct Frame {
        let time: TimeInterval
        let displayTime: TimeInterval
        let targetTime: TimeInterval
        let read: LayerRead
    }
    struct Samples {
        var frames: [Frame] = []
        var droppedFrames = 0
        var reds: [Double] = []
        var unadmitted = 0
        var maxGap: TimeInterval = 0
        var last: TimeInterval?
    }
    private let layers: ProfileWashLayerSnapshot
    private let queue = DispatchQueue(label: "vane.profile.wash.layer-sampler")
    private let lock = NSLock()
    private var samples = Samples()
    private var stopping = false
    private var stopped = false
    private var link: CADisplayLink?
    var snapshot: Samples { lock.withLock { samples } }
    var isStopped: Bool { lock.withLock { stopped } }

    init(layers: ProfileWashLayerSnapshot) { self.layers = layers }

    @MainActor func start(on screen: NSScreen) {
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        let rate = Float(screen.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        lock.withLock { self.link = link; samples.last = ProcessInfo.processInfo.systemUptime }
        queue.async { [self] in
            guard let link = lock.withLock({ self.link }) else {
                lock.withLock { stopped = true }
                return
            }
            let runLoop = RunLoop.current
            link.add(to: runLoop, forMode: .default)
            while !lock.withLock({ stopping }) {
                // Each iteration is bounded even after invalidation removes the
                // display link's last run-loop source.
                autoreleasepool { _ = runLoop.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02)) }
            }
            link.invalidate()
            lock.withLock { self.link = nil; stopped = true }
        }
    }

    func resetSamples() {
        lock.withLock { samples = Samples(last: ProcessInfo.processInfo.systemUptime) }
    }

    func stop() {
        let link = lock.withLock { stopping = true; return self.link }
        // CADisplayLink explicitly permits invalidation from another thread.
        link?.invalidate()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = ProcessInfo.processInfo.systemUptime
        CATransaction.lock()
        let read = presentedRead()
        CATransaction.unlock()
        lock.withLock {
            if samples.frames.count < 256 {
                samples.frames.append(Frame(time: now, displayTime: link.timestamp,
                                            targetTime: link.targetTimestamp, read: read))
            } else { samples.droppedFrames += 1 }
            if let last = samples.last { samples.maxGap = max(samples.maxGap, now - last) }
            samples.last = now
            guard let red = read.red, samples.reds.count < 4096 else {
                samples.unadmitted += 1
                return
            }
            samples.reds.append(red)
        }
    }

    /// Called only under CATransaction's recursive lock. Reject unknown roots,
    /// detached ancestry and ambiguous/missing visibility rather than silently
    /// dropping a frame that could hide a color reversal.
    private func presentedRead() -> LayerRead {
        func failure(_ reason: String) -> LayerRead { LayerRead(reason: reason) }
        func red(_ colors: Any?) -> Double? {
            guard let color = (colors as? [CGColor])?.first,
                  let rgb = color.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
                  let components = rgb.components, components.count >= 3 else { return nil }
            return Double(components[0])
        }
        let currentRoots = Set((layers.host.sublayers ?? []).map(ObjectIdentifier.init))
        guard currentRoots.isSubset(of: layers.roots) else { return failure("unknown-root") }
        var visible: [(Int, CAGradientLayer)] = []
        for (index, surface) in layers.surfaces.enumerated() {
            for (child, parent) in zip(surface.ancestry, surface.ancestry.dropFirst()) {
                guard child.superlayer === parent else { return failure("detached-ancestry") }
            }
            var hidden = false
            for ancestor in surface.ancestry.reversed() {
                guard let presentation = ancestor.presentation() else { return failure("missing-presentation") }
                if presentation.isHidden || presentation.opacity <= 0 { hidden = true; break }
            }
            if !hidden { visible.append((index, surface.base)) }
        }
        guard visible.count == 1 else { return failure("visible-count-\(visible.count)") }
        let (index, base) = visible[0]
        guard let presentedRed = red(base.presentation()?.colors) else { return failure("missing-color") }
        let animation = base.animation(forKey: "colors")
        return LayerRead(red: presentedRed, modelRed: red(base.colors), surfaceIndex: index,
                         animationPresent: animation != nil,
                         animationBegin: animation.map { base.convertTime($0.beginTime, to: nil) }, reason: "admitted")
    }
}

@MainActor private final class SwipeColourSampler: NSObject {
    struct Sample { let time: TimeInterval; let offset: CGFloat; let colour: NSColor }
    weak var host: BrowserWindowHost?
    weak var surface: ThemeWashSurface?
    var samples: [Sample] = []
    var link: CADisplayLink?
    init(host: BrowserWindowHost, surface: ThemeWashSurface) { self.host=host; self.surface=surface }
    func start(on screen: NSScreen) {
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        let rate = Float(screen.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func stop() { link?.invalidate(); link=nil }
    @objc func tick(_ link: CADisplayLink) {
        guard let slide=host?.spaceSlide, let surface,
              let color=(surface.base.presentation()?.colors as? [CGColor])?.first,
              let rgb=NSColor(cgColor: color)?.usingColorSpace(.deviceRGB) else { return }
        samples.append(Sample(time: ProcessInfo.processInfo.systemUptime, offset: slide.offset, colour: rgb))
    }
}
