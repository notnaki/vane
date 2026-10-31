import AppKit
import SwiftUI
import XCTest
@testable import vane

/// Real AppKit input and overlay-geometry contracts, with owned loop and visible-owner admission.
@MainActor final class FeedbackOcclusionTests: XCTestCase {
    @MainActor private final class Model: ObservableObject {
        let scope = FeedbackOcclusionScope()
        let store = TabStore(isPrivate: true)
        let downloads = DownloadLibrary(managers: [])
        let entry = Archive.Entry(url: "about:blank#known-library-preview", title: "Preview action", at: .now)
        @Published var showsPreview = false
        @Published var previewOffset: CGFloat = 0
        var hovered: [String: Bool] = [:]
        var clicks: [String: Int] = [:]
        var modalPoint = CGPoint.zero
        var pressChanges: [Bool] = []
    }

    private struct Row: View {
        let id: String
        let model: Model
        var body: some View {
            HStack {
                Text(id)
                Spacer()
                Button { model.clicks["child-" + id, default: 0] += 1 } label: {
                    Text("×").frame(width: 32, height: 44).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .modifier(Feel02PressFeedback(hoverChanged: { model.hovered["child-" + id] = $0 }))
            }
            .padding(.leading, 12)
            .frame(width: 300, height: 44)
            .background(Color.gray.opacity(0.1))
            .contentShape(.rect)
            .modifier(Feel02PressFeedback(hoverChanged: { model.hovered[id] = $0 }))
            .onTapGesture { model.clicks[id, default: 0] += 1 }
        }
    }

    private struct Fixture: View {
        @ObservedObject var model: Model
        var body: some View {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    Row(id: "top", model: model)
                    Row(id: "bottom", model: model)
                }
                .environment(\.feedbackOcclusionScope, model.scope)
                if model.showsPreview {
                    RecentLibraryPreview(items: [.archived(model.entry)], category: .archived,
                        downloads: model.downloads, store: model.store, close: {
                            model.clicks["preview", default: 0] += 1
                            model.showsPreview = false
                        })
                        .frame(width: 300, height: 44)
                        .background(FeedbackOccluder(scope: model.scope))
                        .offset(y: model.previewOffset)
                }
            }
            .frame(width: 300, height: 88, alignment: .topLeading)
        }
    }

    private final class Host: NSHostingView<Fixture> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private func descendants<T: NSView>(_ root: NSView, _: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, T.self) }
    }

    private func withMountedFixture(_ body: (Model, NSWindow, Host) async throws -> Void) async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        let model = Model(), host = Host(rootView: Fixture(model: model))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 88),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        host.layoutSubtreeIfNeeded()
        var failure: (any Error)?
        do {
            try await admitVisibleState {
                NSApp.isRunning && NSRunningApplication.current.isFinishedLaunching && NSApp.isActive
                    && window.isVisible && window.isKeyWindow && host.window === window
                    && window.contentView === host
                    && self.descendants(host, Feel02PressAnchorView.self).count == 4
                    && self.descendants(host, Feel02PressAnchorView.self).allSatisfy {
                        $0.window === window && $0.feedbackScope === model.scope && !$0.visibleRect.isEmpty
                    }
            }
            XCTAssertTrue(descendants(host, Feel02PressAnchorView.self).allSatisfy {
                $0.feedbackScope === model.scope
            }, "The real modifier must inherit the scoped feedback contract")
            try await body(model, window, host)
        } catch { failure = error }
        // The owned nested run loop must return before XCTest can finish this
        // invocation. Post-method teardown is too late to close it.
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        model.store.dropStashes()
        SharedTabs.release(model.store.tabs)
        TabStore.all.removeAll { $0 === model.store }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Feedback fixture loop cleanup failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func admitVisibleState(file: StaticString = #filePath, line: UInt = #line,
                                   _ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            let observed = ready()
            guard ContinuousClock.now < deadline else {
                XCTFail("Feedback fixture visible-state admission timed out", file: file, line: line)
                throw NSError(domain: "FeedbackFixtureAdmission", code: 1)
            }
            if observed { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Read only the actual native cover. Do not cause layout/invalidation or
    /// wait for the hover outcome whose immediate assertion follows admission.
    private func admitPreview(_ model: Model, in window: NSWindow, host: Host,
                              covering point: CGPoint, excluding other: CGPoint) async throws {
        try await admitVisibleState {
            guard NSApp.isActive, window.isKeyWindow, window.isVisible,
                  window.contentView === host, host.window === window else { return false }
            return self.descendants(host, FeedbackOccluder.Marker.self).contains { marker in
                guard marker.scope === model.scope, marker.window === window,
                      !marker.isHiddenOrHasHiddenAncestor, !marker.visibleRect.isEmpty,
                      !marker.bounds.isEmpty else { return false }
                let local = marker.convert(point, from: nil)
                let excluded = marker.convert(other, from: nil)
                return marker.bounds.contains(local) && marker.visibleRect.contains(local)
                    && !(marker.bounds.contains(excluded) && marker.visibleRect.contains(excluded))
            }
        }
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    private func move(to point: CGPoint, in window: NSWindow) throws {
        let event = try event(.mouseMoved, at: point, in: window)
        XCTAssertTrue(Feel02PressMonitor.shared.handle(event) === event)
    }

    private func click(at point: CGPoint, in window: NSWindow) async throws {
        let down = try event(.leftMouseDown, at: point, in: window)
        XCTAssertTrue(Feel02PressMonitor.shared.handle(down) === down)
        NSApp.sendEvent(down)
        try await Task.sleep(for: .milliseconds(30))
        let up = try event(.leftMouseUp, at: point, in: window)
        XCTAssertTrue(Feel02PressMonitor.shared.handle(up) === up)
        NSApp.sendEvent(up)
        try await Task.sleep(for: .milliseconds(30))
    }

    private func rowAnchor(at point: CGPoint, in host: Host) throws -> Feel02PressAnchorView {
        try XCTUnwrap(descendants(host, Feel02PressAnchorView.self).filter {
            $0.bounds.contains($0.convert(point, from: nil))
        }.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
    }

    private func observePress(_ anchor: Feel02PressAnchorView, in model: Model) {
        let original = anchor.changed
        anchor.changed = { next in
            model.pressChanges.append(next)
            original?(next)
        }
    }

    func testAncestorMovementRevokesStationaryHover() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        defer { app.setActivationPolicy(previousPolicy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        let scope = FeedbackOcclusionScope()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 88))
        let anchor = Feel02PressAnchorView(frame: NSRect(x: 0, y: 0, width: 300, height: 44))
        let ancestor = NSView(frame: NSRect(x: 0, y: 44, width: 300, height: 44))
        let marker = FeedbackOccluder.Marker(frame: NSRect(x: 0, y: 0, width: 300, height: 44))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 88),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var hovered: [Bool] = []
        anchor.feedbackScope = scope
        anchor.hoverChanged = { hovered.append($0) }
        marker.scope = scope
        ancestor.addSubview(marker)
        root.addSubview(anchor)
        root.addSubview(ancestor)
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        root.layoutSubtreeIfNeeded()
        Feel02PressMonitor.shared.register(anchor)
        scope.attach(marker)
        var failure: (any Error)?
        do {
            try await admitVisibleState {
                app.isActive && window.isKeyWindow && window.isVisible
                    && window.contentView === root && anchor.window === window
                    && marker.window === window && marker.scope === scope
                    && !marker.visibleRect.isEmpty
            }
            let point = anchor.convert(CGPoint(x: 80, y: 22), to: nil)
            XCTAssertFalse(scope.contains(point, in: window), "The actual initial cover must leave the row exposed")
            try move(to: CGPoint(x: point.x + 1, y: point.y), in: window)
            try move(to: point, in: window)
            XCTAssertEqual(hovered.last, true, "The actual native target must own hover before movement")
            let localFrame = marker.frame
            // Move only the ancestor. Do not invoke marker layout or scope
            // invalidation: those are the production behavior under test.
            ancestor.setFrameOrigin(.zero)
            XCTAssertEqual(marker.frame, localFrame)
            XCTAssertTrue(scope.contains(point, in: window), "The moved native cover must actually cover the stationary pointer")
            await drainMainQueue()
            XCTAssertEqual(hovered.last, false, "Ancestor movement must revoke covered feedback without pointer movement")
        } catch { failure = error }
        scope.detach(marker)
        marker.scope = nil
        Feel02PressMonitor.shared.remove(anchor)
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        do { try await loop.close() } catch { if failure == nil { failure = error } }
        if let failure { throw failure }
    }

    func testMountingKnownPreviewReleasesAHeldPress() async throws {
        try await withMountedFixture { model, window, host in
            let top = host.convert(CGPoint(x: 80, y: 22), to: nil)
            let anchor = try rowAnchor(at: top, in: host)
            observePress(anchor, in: model)
            let down = try event(.leftMouseDown, at: top, in: window)
            XCTAssertTrue(Feel02PressMonitor.shared.handle(down) === down)
            XCTAssertEqual(model.pressChanges, [true], "The real native anchor must hold the press before coverage")
            model.showsPreview = true
            host.layoutSubtreeIfNeeded()
            // SwiftUI may replace the representable callback during this render. Keep
            // observing the current real callback before its deferred false is delivered.
            observePress(anchor, in: model)
            let bottom = host.convert(CGPoint(x: 80, y: 66), to: nil)
            try await admitPreview(model, in: window, host: host, covering: top, excluding: bottom)
            await drainMainQueue()
            XCTAssertEqual(model.pressChanges.last, false, "Mounting the known preview must forward a held press release")
            let up = try event(.leftMouseUp, at: top, in: window)
            XCTAssertTrue(Feel02PressMonitor.shared.handle(up) === up)
            XCTAssertNil(model.clicks["top"], "The passive monitor must not activate its held row")

        }
    }

    func testKnownPreviewBlocksCoveredFeedbackWithoutChangingActualActivation() async throws {
        try await withMountedFixture { model, window, host in
            let top = host.convert(CGPoint(x: 80, y: 22), to: nil)
            let bottom = host.convert(CGPoint(x: 80, y: 66), to: nil)
            try move(to: top, in: window)
            XCTAssertEqual(model.hovered["top"], true)
            model.showsPreview = true
            host.layoutSubtreeIfNeeded()
            try await admitPreview(model, in: window, host: host, covering: top, excluding: bottom)
            await drainMainQueue()
            XCTAssertEqual(model.hovered["top"], false, "Mounting the known preview must revoke covered feedback")
            try move(to: CGPoint(x: top.x + 1, y: top.y), in: window)
            XCTAssertEqual(model.hovered["top"], false)
            try move(to: bottom, in: window)
            XCTAssertEqual(model.hovered["bottom"], true)
            try await click(at: bottom, in: window)
            XCTAssertEqual(model.clicks["bottom"], 1, "Uncovered row activation remains enabled")
            let child = host.convert(CGPoint(x: 284, y: 66), to: nil)
            try move(to: child, in: window)
            XCTAssertEqual(model.hovered["child-bottom"], true)
            XCTAssertEqual(model.hovered["bottom"], false, "The existing smaller-target arbitration must remain intact")
            try await click(at: child, in: window)
            XCTAssertEqual(model.clicks["child-bottom"], 1)
            XCTAssertEqual(model.clicks["bottom"], 1, "A child control must not also activate its row")
            try await click(at: top, in: window)
            XCTAssertEqual(model.clicks["preview"], 1)
            XCTAssertNil(model.clicks["top"], "The covering control must receive the real native click")

        }
    }

    func testMovingPreviewRevokesHoverAndDismissalDoesNotAdmitAStationaryRow() async throws {
        try await withMountedFixture { model, window, host in
            model.showsPreview = true
            host.layoutSubtreeIfNeeded()
            let top = host.convert(CGPoint(x: 80, y: 22), to: nil)
            let bottom = host.convert(CGPoint(x: 80, y: 66), to: nil)
            try await admitPreview(model, in: window, host: host, covering: top, excluding: bottom)
            try move(to: bottom, in: window)
            XCTAssertEqual(model.hovered["bottom"], true)
            model.previewOffset = 44
            host.layoutSubtreeIfNeeded()
            try await admitPreview(model, in: window, host: host, covering: bottom, excluding: top)
            await drainMainQueue()
            XCTAssertEqual(model.hovered["bottom"], false, "Moving the known preview must revoke newly covered feedback")
            try move(to: CGPoint(x: bottom.x + 1, y: bottom.y), in: window)
            model.showsPreview = false
            host.layoutSubtreeIfNeeded()
            try await admitVisibleState { self.descendants(host, NSScrollView.self).isEmpty }
            try move(to: CGPoint(x: bottom.x + 1, y: bottom.y), in: window)
            XCTAssertEqual(model.hovered["bottom"], false, "Removing the overlay must not admit a new stationary hover")
            try move(to: CGPoint(x: bottom.x + 2, y: bottom.y), in: window)
            XCTAssertEqual(model.hovered["bottom"], true)

        }
    }

    func testQuitModalSuppressesFeedbackAndPreservesStationaryPointerAfterCancel() async throws {
        try await withMountedFixture { model, window, host in
            let top = host.convert(CGPoint(x: 80, y: 22), to: nil)
            try move(to: top, in: window)
            XCTAssertEqual(model.hovered["top"], true)
            let anchor = try rowAnchor(at: top, in: host)
            observePress(anchor, in: model)
            let down = try event(.leftMouseDown, at: top, in: window)
            XCTAssertTrue(Feel02PressMonitor.shared.handle(down) === down)
            XCTAssertEqual(model.pressChanges, [true])
            model.modalPoint = CGPoint(x: top.x + 4, y: top.y)
            let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard QuitDialog.isUp else { return }
                    defer { NSApp.stopModal() }
                    XCTAssertEqual(model.hovered["top"], false, "Keyboard-only modal entry must revoke hover before any pointer event")
                    XCTAssertEqual(model.pressChanges.last, false, "Keyboard-only modal entry must release a held press before any pointer event")
                    let move = NSEvent.mouseEvent(with: .mouseMoved, location: model.modalPoint,
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
                    XCTAssertTrue(Feel02PressMonitor.shared.handle(move) === move)
                    XCTAssertEqual(model.hovered["top"], false)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            defer { timer.invalidate() }
            XCTAssertEqual(QuitDialog.ask(over: window), .cancel)
            try move(to: model.modalPoint, in: window)
            XCTAssertEqual(model.hovered["top"], false)
            try move(to: CGPoint(x: model.modalPoint.x + 1, y: model.modalPoint.y), in: window)
            XCTAssertEqual(model.hovered["top"], true)

        }
    }
}
