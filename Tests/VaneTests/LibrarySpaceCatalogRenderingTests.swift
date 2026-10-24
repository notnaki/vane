import AppKit
import SwiftUI
import Vision
import XCTest
@testable import vane

/// Stop real immutable snapshots after decoding. Native mounted views must remain
/// correct while a worker is parked, regardless of how quickly the machine loads.
private final class LibraryRenderingReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private let blockedCalls: Set<Int>
    private var calls = 0
    private var admitted: Set<Int> = []
    private var mainThread = false

    init(blockedCalls: Set<Int>) { self.blockedCalls = blockedCalls }
    var ranOnMain: Bool { lock.withLock { mainThread } }
    func entered(_ call: Int) -> Bool { lock.withLock { admitted.contains(call) } }
    func load(directory: URL, profiles: [UUID]) -> [LibrarySpaceCatalog.Entry] {
        let snapshot = LibrarySpaceCatalog.read(directory: directory, profiles: profiles)
        let block = lock.withLock {
            calls += 1
            mainThread = mainThread || Thread.isMainThread
            admitted.insert(calls)
            return blockedCalls.contains(calls)
        }
        // A main-actor regression should fail an assertion instead of deadlocking.
        if block && !Thread.isMainThread { release.wait() }
        return snapshot
    }
    func resume() { release.signal() }
}

@MainActor final class LibrarySpaceCatalogRenderingTests: XCTestCase {
    private func manager() throws -> ProfileManager {
        TestEnvironment.prepare()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vane-library-rendering-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ProfileManager(directory: directory, sandboxed: true)
    }

    private func mount(manager: ProfileManager, catalog: LibrarySpaceCatalog? = nil,
                       owner: TabStore? = nil) -> (window: NSWindow, host: NSView, store: TabStore) {
        let application = NSApplication.shared
        let policy = application.activationPolicy()
        application.setActivationPolicy(.accessory)
        let store = owner ?? TabStore(profileID: UUID(), session: [])
        let library = Library.shared
        let previous = (library.section, library.query, library.littleArcOnly,
                        library.completedOnly, library.naming)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 760, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        store.palette = nil
        Library.open(.spaces, in: store)
        var root = AnyView(LibraryPanel().environmentObject(store).environmentObject(manager))
        if let catalog { root = AnyView(root.environment(\.librarySpaceCatalog, catalog)) }
        let host = NSHostingView(rootView: root)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in
            // Removing the real host dismantles any owned native bridges/popovers.
            window.orderOut(nil)
            window.contentView = nil
            store.window = nil
            window.close()
            store.libraryOpen = false
            Library.open(previous.0, in: store)
            library.query = previous.1
            library.littleArcOnly = previous.2
            library.completedOnly = previous.3
            library.naming = previous.4
            store.libraryOpen = false
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Favicons.forget(store.profileID)
            Store.forget(store.profileID)
            application.setActivationPolicy(policy)
        }
        return (window, host, store)
    }

    /// SwiftUI's direct NSView accessibility getters are empty in this XCTest
    /// host although its pixels are painted. Read the owned host bitmap instead;
    /// Vision runs on a worker and requires neither AX permission nor OS settings.
    private func renderedStrings(in host: NSView) async throws -> [String] {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }.value
    }

    private func contains(_ text: String, in strings: [String]) -> Bool {
        func normalized(_ string: String) -> String {
            String(string.lowercased().filter { $0.isLetter || $0.isNumber })
        }
        let expected = normalized(text)
        return strings.contains { normalized($0).contains(expected) }
    }

    private func renders(_ text: String, in host: NSView) async throws -> Bool {
        contains(text, in: try await renderedStrings(in: host))
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
    }

    private func waitForRendering(_ text: String, in host: NSView, manager: ProfileManager,
                                  catalog: LibrarySpaceCatalog? = nil) async throws {
        do {
            try await compatibilityWait { try await self.renders(text, in: host) }
        } catch {
            print("LIBRARY_RENDER_DIAGNOSTIC expected=\(text) visible=\(host.window?.isVisible == true) strings=\((try? await renderedStrings(in: host)) ?? [])")
            if let catalog {
                print("LIBRARY_RENDER_DIAGNOSTIC loading=\(catalog.loading) generation=\(catalog.generation) spaces=\(catalog.spaces(manager: manager).map(\.name))")
            }
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    let path = "/tmp/vane-library-rendering-\(UUID()).png"
                    try? data.write(to: URL(fileURLWithPath: path))
                    print("LIBRARY_RENDER_DIAGNOSTIC image=\(path)")
                }
            }
            throw error
        }
    }

    /// Short letters-only markers fit the 180pt card and avoid OCR digit ambiguity.
    private func marker() -> String {
        let alphabet = Array("abcdefghjkmnpqrs")
        return String(UUID().uuidString.lowercased().prefix(4).map {
            alphabet[Int(String($0), radix: 16)!]
        })
    }

    // Fails if the standalone fallback reads .shared instead of the manager that
    // actually supplies SpacesPane, or if the async result never reaches the host.
    func testStandalonePanelRendersItsCustomEnvironmentManagersSpaces() async throws {
        let manager = try manager()
        let name = "Oak" + marker()
        let space = manager.createSpace(name: name, in: manager.active.id)
        let fixture = mount(manager: manager)
        XCTAssertFalse(ProfileManager.shared.spaces(for: space.profileID).contains { $0.id == space.id })
        try await waitForRendering(name, in: fixture.host, manager: manager)
        try await waitForRendering("No pages", in: fixture.host, manager: manager)
        XCTAssertTrue(fixture.window.isVisible)
        let pencil = try XCTUnwrap(descendants(TabTooltipAnchorView.self, in: fixture.host)
            .first { $0.title == "Edit Space" })
        XCTAssertTrue(pencil.enabled && pencil.window === fixture.window && !pencil.isHiddenOrHasHiddenAncestor,
                      "The mounted custom-manager card must have an enabled native editing anchor")
    }

    // Fails if a stale/default nil shape leaks saved Today content during a blocked
    // refresh, or if holding saved rows also hides the authoritative live owner's rows.
    func testSavedTodayWaitsForCurrentProtectionWhileLiveOwnerRowsRemainAuthoritative() async throws {
        let manager = try manager()
        let profile = manager.create(name: "R")
        let nonce = marker()
        let savedTitle = "saved" + nonce
        let liveTitle = "Live" + nonce
        let savedURL = URL(string: "https://\(savedTitle).invalid/")!
        let liveURL = URL(string: "https://live\(nonce).invalid/")!
        let space = Space(name: "Elm" + nonce, profileID: profile.id, tabURLs: [savedURL])
        XCTAssertTrue(manager.updateSpace(space))
        let key = TabStore.shapeKey(.today, space: space.id, profileID: profile.id)
        let prior = UserDefaults.vane.data(forKey: key)
        addTeardownBlock {
            if let prior { UserDefaults.vane.set(prior, forKey: key) }
            else { UserDefaults.vane.removeObject(forKey: key) }
        }
        let gate = LibraryRenderingReadGate(blockedCalls: [2, 3])
        defer { gate.resume(); gate.resume() }
        let catalog = LibrarySpaceCatalog(load: gate.load)
        await catalog.prepare(manager: manager)?.value
        let savedFixture = mount(manager: manager, catalog: catalog)
        XCTAssertEqual(catalog.entry(for: space, manager: manager)?.space.tabURLs, [savedURL])
        try await waitForRendering(savedTitle, in: savedFixture.host, manager: manager, catalog: catalog)

        let locked = Folder(name: "Protected", requiresAuthentication: true)
        let shape = Pins(entries: [.init(row: .folder(locked), parent: nil),
                                  .init(row: .tab(savedURL.absoluteString), parent: locked.id)])
        UserDefaults.vane.set(try JSONEncoder().encode(shape), forKey: key)
        let protection = catalog.prepare(manager: manager, force: true)
        try await compatibilityWait { gate.entered(2) }
        XCTAssertFalse(gate.ranOnMain)
        try await compatibilityWait {
            savedFixture.host.layoutSubtreeIfNeeded()
            return self.descendants(NSProgressIndicator.self, in: savedFixture.host).contains {
                !$0.isHiddenOrHasHiddenAncestor && $0.window === savedFixture.window && $0.visibleRect.height > 0
            }
        }
        let pencil = try XCTUnwrap(descendants(TabTooltipAnchorView.self, in: savedFixture.host)
            .first { $0.title == "Edit Space" })
        XCTAssertFalse(pencil.enabled, "Retained metadata must not admit a stale card editor")
        for _ in 0..<3 {
            let painted = try await renderedStrings(in: savedFixture.host)
            XCTAssertTrue(contains(space.name, in: painted), "Card metadata survives the pending shape refresh")
            XCTAssertFalse(contains(savedTitle, in: painted),
                           "No intermediate painted frame may expose a saved row while its current shape is pending")
        }
        gate.resume()
        await protection?.value
        try await waitForRendering("No pages", in: savedFixture.host, manager: manager, catalog: catalog)
        let protectedPaint = try await renderedStrings(in: savedFixture.host)
        XCTAssertFalse(contains(savedTitle, in: protectedPaint))

        let live = TabStore(profileID: profile.id, space: space, session: [])
        let tab = vane.Tab(profileID: profile.id)
        tab.park(url: liveURL, Parked(title: liveTitle))
        live.tabs = [tab]
        live.todayShape = Pins()
        live.palette = nil
        let liveFixture = mount(manager: manager, catalog: catalog, owner: live)
        let refresh = catalog.prepare(manager: manager, force: true)
        try await compatibilityWait { gate.entered(3) }
        XCTAssertNil(catalog.entry(for: space, manager: manager))
        XCTAssertEqual(tab.currentURL, liveURL)
        try await waitForRendering(liveTitle, in: liveFixture.host, manager: manager, catalog: catalog)
        let livePaint = try await renderedStrings(in: liveFixture.host)
        XCTAssertFalse(contains(savedTitle, in: livePaint),
                       "The saved URL list must not replace the owner's current tabs")
        live.todayShape = Pins(entries: [.init(row: .folder(locked), parent: nil),
                                         .init(row: .tab(tab.id.uuidString), parent: locked.id)])
        try await waitForRendering("No pages", in: liveFixture.host, manager: manager, catalog: catalog)
        let lockedLivePaint = try await renderedStrings(in: liveFixture.host)
        XCTAssertFalse(contains(liveTitle, in: lockedLivePaint),
                       "The live owner's latest protection state must win even while the saved worker is blocked")
        gate.resume()
        await refresh?.value
    }
}
