import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SidebarSnapshotReadinessTests: XCTestCase {
    func testVisibleSnapshotPlacementExcludesPointerAtEveryCorner() throws {
        let screen = NSRect(x: -1200, y: 100, width: 1000, height: 800)
        let size = NSSize(width: 250, height: 400)
        let points = [NSPoint(x: screen.minX + 20, y: screen.minY + 337),
                      NSPoint(x: screen.maxX - 20, y: screen.minY + 337),
                      NSPoint(x: screen.minX + 20, y: screen.maxY - 20),
                      NSPoint(x: screen.maxX - 20, y: screen.maxY - 20),
                      NSPoint(x: screen.midX, y: screen.midY)]
        for point in points {
            let frame = try XCTUnwrap(SidebarSnapshot.frame(avoiding: point, size: size, within: screen))
            XCTAssertTrue(screen.contains(frame), "The exact snapshot owner must stay on screen")
            XCTAssertFalse(frame.contains(point), "The live return control must not acquire physical-pointer hover")
            XCTAssertEqual(frame.size, size)
            // Persistent-occlusion recovery cycles through every remaining corner.
            let alternatives = SidebarSnapshot.frames(avoiding: point, size: size, within: screen)
            XCTAssertEqual(alternatives.first, frame)
            XCTAssertEqual(alternatives.count, point == points.last ? 4 : 3)
            XCTAssertTrue(alternatives.allSatisfy { screen.contains($0) && !$0.contains(point) })
        }
    }

    func testVisibleSnapshotPlacementRejectsScreensWithoutAnUnhoveredPosition() {
        let screen = NSRect(x: 100, y: 100, width: 250, height: 400)
        XCTAssertNil(SidebarSnapshot.frame(avoiding: NSPoint(x: 120, y: 437), size: screen.size, within: screen))
        XCTAssertNil(SidebarSnapshot.frame(avoiding: .zero, size: NSSize(width: 251, height: 400), within: screen))
    }

    func testSnapshotRecoversItsKeyWindowBeforeContinuingAdmission() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            let competing = NSWindow(contentRect: NSRect(x: 500, y: 100, width: 200, height: 150),
                styleMask: .titled, backing: .buffered, defer: false)
            competing.isReleasedWhenClosed = false
            defer { competing.orderOut(nil); competing.close() }
            var displaced = false
            var recovered = false
            _ = try await SidebarSnapshot.imageWhenReady(Color.gray) { host in
                guard let window = host.window else { return false }
                if !displaced {
                    competing.makeKeyAndOrderFront(nil)
                    XCTAssertTrue(competing.isKeyWindow, "The fixture must actually displace the snapshot owner")
                    XCTAssertFalse(window.isKeyWindow)
                    displaced = true
                    return false
                }
                recovered = true
                XCTAssertTrue(window.isKeyWindow)
                XCTAssertTrue(NSApp.keyWindow === window)
                return true
            }
            XCTAssertTrue(displaced)
            XCTAssertTrue(recovered, "Snapshot admission must recover its exact visible owner after focus changes")
        } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Snapshot focus loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    func testInteractiveProbeSelectionRequiresTheExactAttachedHost() throws {
        _ = NSApplication.shared
        let bounds = NSRect(x: 0, y: 0, width: 250, height: 400)
        let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        let otherWindow = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; otherWindow.isReleasedWhenClosed = false
        let host = NSView(frame: bounds), otherHost = NSView(frame: bounds)
        window.contentView = host; otherWindow.contentView = otherHost
        defer {
            window.contentView = nil; window.close()
            otherWindow.contentView = nil; otherWindow.close()
        }
        let state = SnapshotInteractiveState()
        let current = SnapshotInteractiveProbe.Native(frame: bounds)
        let foreign = SnapshotInteractiveProbe.Native(frame: bounds)
        let unsized = SnapshotInteractiveProbe.Native(frame: .zero)
        // Selection is a descendant search of the exact host: a bridge SwiftUI
        // updated in another (sizing or retired) graph is never a candidate.
        host.addSubview(current); otherHost.addSubview(foreign)
        XCTAssertTrue(state.probe(in: host) === current)
        XCTAssertTrue(state.probe(in: otherHost) === foreign)
        host.addSubview(unsized)
        XCTAssertTrue(state.probe(in: host) === current, "An unsized bridge is not a visible presentation")
        current.removeFromSuperview()
        XCTAssertNil(state.probe(in: host), "A detached native view cannot admit a visible snapshot")
        let replacement = SnapshotInteractiveProbe.Native(frame: bounds)
        host.addSubview(replacement)
        XCTAssertTrue(state.probe(in: host) === replacement)
        host.addSubview(current)
        XCTAssertNil(state.probe(in: host), "Two visible bridges cannot identify one presentation owner")
        XCTAssertNil(state.probe(in: NSView(frame: bounds)), "A host outside any window has no presentation")
    }

    func testPointerIntrusionDiscardsThePreviousInteractivePresentation() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            let state = SnapshotInteractiveState()
            var pointer = NSEvent.mouseLocation
            // Retained so the detachment assertions observe the real old owner.
            var previousHost: NSView?
            var previousProbe: SnapshotInteractiveProbe.Native?
            var phase = 0
            var captured = false
            defer {
                // Self-explaining evidence for a stalled or slow admission.
                if !captured || state.elapsed > 1 { print(state.report(phase: phase)) }
            }
            _ = try await SidebarSnapshot.imageWhenReady(SnapshotInteractiveSurface(state: state),
                                                         pointerLocation: { pointer }) { host in
                guard let probe = state.admit(in: host, phase: phase), let setHovered = probe.setHovered else {
                    return false
                }
                if phase == 0 {
                    // Enter a real SwiftUI interaction state before introducing the
                    // pointer. The fixture never changes the user's system cursor.
                    setHovered(true)
                    phase = 1
                    return false
                }
                if phase == 1 {
                    guard probe.hovered, let window = host.window else { return false }
                    previousHost = host; previousProbe = probe
                    pointer = NSPoint(x: window.frame.midX, y: window.frame.midY)
                    phase = 2
                    return false
                }
                XCTAssertFalse(host === previousHost, "Relocation must discard the old interaction and its animation graph")
                XCTAssertFalse(probe === previousProbe, "The replacement graph must own a new native bridge")
                XCTAssertFalse(probe.hovered, "The replacement surface must start in its idle state")
                XCTAssertNil(previousHost?.window, "The previous presentation owner must be detached before capture")
                XCTAssertNil(previousProbe?.window, "The previous interactive bridge must be detached before capture")
                phase = 3
                return true
            }
            captured = true
            XCTAssertEqual(phase, 3)
        } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Snapshot intrusion loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    func testSnapshotRecoversAnOccludedWindowThatStillOwnsKeyboardFocus() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            var displaced = false
            let occlusion = SnapshotOcclusion()
            var recovered = false
            defer {
                print("Snapshot occlusion displaced=\(displaced) observed=\(occlusion.observed) recovered=\(recovered)")
            }
            _ = try await SidebarSnapshot.imageWhenReady(Color.gray, observePresentation: { window in
                if displaced, window.isKeyWindow, NSApp.keyWindow === window,
                   !window.occlusionState.contains(.visible) { occlusion.observed = true }
            }, allowRecovery: { _ in
                // Native occlusion arrives asynchronously after displacement.
                // Preserve that injected prerequisite until the observer sees it;
                // re-presenting earlier can move the window back on screen first.
                !displaced || occlusion.observed
            }) { host in
                guard let window = host.window else { return false }
                if !displaced {
                    // A fully offscreen ordered window produces real native
                    // occlusion without relying on same-app covering detection.
                    window.setFrameOrigin(NSPoint(x: -40_000, y: -40_000))
                    XCTAssertTrue(window.isKeyWindow, "Occlusion must leave keyboard ownership unchanged")
                    displaced = true
                    return false
                }
                guard occlusion.observed else { return false }
                recovered = true
                XCTAssertTrue(window.isKeyWindow)
                XCTAssertTrue(window.occlusionState.contains(.visible))
                XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.contains(window.frame) })
                return true
            }
            XCTAssertTrue(occlusion.observed, "The fixture must observe actual native occlusion of its exact owner")
            XCTAssertTrue(recovered, "Admission must restore the obscured owner before sampling")
        } catch { failure = error }
        do { try await loop.close() } catch {
            if failure == nil { failure = error } else { XCTFail("Occluded snapshot loop cleanup: \(error)") }
        }
        if let failure { throw failure }
    }

    func testSnapshotLeavesAPlacementThatStaysOccluded() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            // An opaque panel ordered above the owner's first placement keeps it
            // occluded however often it is re-presented in place.
            let cover = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            cover.isReleasedWhenClosed = false
            cover.isOpaque = true; cover.backgroundColor = .black
            cover.level = .floating; cover.hidesOnDeactivate = false
            defer { cover.orderOut(nil); cover.close() }
            var covered: NSRect?
            var occluded = false
            var sampled: NSRect?
            _ = try await SidebarSnapshot.imageWhenReady(Color.gray, observePresentation: { window in
                if covered == nil {
                    covered = window.frame
                    cover.setFrame(window.frame.insetBy(dx: -8, dy: -8), display: true)
                    cover.orderFrontRegardless()
                }
                if let covered, window.frame == covered, !window.occlusionState.contains(.visible) { occluded = true }
            }, allowRecovery: { window in
                // Hold recovery until the covered placement is observably occluded.
                occluded || window.frame != covered
            }) { host in
                guard let window = host.window else { return false }
                sampled = window.frame
                return true
            }
            print("Snapshot covered placement covered=\(String(describing: covered)) occluded=\(occluded) sampled=\(String(describing: sampled))")
            let frame = try XCTUnwrap(sampled)
            XCTAssertTrue(occluded, "The fixture must observe native occlusion of the covered placement")
            // Admission already required native `.visible` before sampling. On a small
            // screen the next pointer-free corner can still overlap the cover, so only
            // require that the owner left the placement that stayed occluded.
            XCTAssertNotEqual(frame, covered, "Admission must move a persistently occluded owner")
        } catch { failure = error }
        do { try await loop.close() } catch {
            if failure == nil { failure = error } else { XCTFail("Covered snapshot loop cleanup: \(error)") }
        }
        if let failure { throw failure }
    }

    func testSnapshotDoesNotSampleBeforeItsCurrentNativeRowsCommit() throws {
        TestEnvironment.prepare()
        let owner = NSObject()
        let space = UUID()
        let scope = SidebarNativeReadinessScope(storeID: ObjectIdentifier(owner), spaceID: space, surfaceID: UUID())
        let retainedScope = SidebarNativeReadinessScope(storeID: ObjectIdentifier(owner), spaceID: space, surfaceID: UUID())
        let retainedSection = NSObject()
        let row = SidebarRows.Row(visible: Pins.Visible(entry: .init(row: .folder(Folder(name: "Deferred row"))), depth: 0), tab: nil)
        let population = SnapshotPopulation()
        let gate = SidebarNativeReadinessCoordinator.shared
        let retainedTicket = gate.register(scope: retainedScope, section: ObjectIdentifier(retainedSection),
                                           generation: 1, geometryRevision: 1)
        gate.complete(retainedTicket)
        XCTAssertTrue(gate.isReady(retainedScope), "A retained other surface starts fully ready")
        gate.expectPopulation(scope, sections: ["today": [row.id]])
        // Intentionally hold the real native geometry boundary beyond the former
        // 20ms sample. Releasing work is separate from observing row commitment.
        let release = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let work = population.pending
                population.pending.removeAll()
                work.forEach { $0() }
            }
        }
        defer {
            release.invalidate()
            population.native?.detach()
            gate.releasePopulationExpectation(scope, owner: ObjectIdentifier(owner))
            gate.unregister(retainedTicket)
        }
        gate.retainPopulationExpectation(scope, owner: ObjectIdentifier(owner))
        _ = try SidebarSnapshot.pixels(SpaceSectionsLayout {
            Text("Snapshot fixture")
        } rows: {
            DeferredSnapshotRows(population: population, scope: scope, rows: [row])
                .frame(height: Look.rowHeight)
        }, sidebarScope: scope, beforeCapture: { host in
            XCTAssertTrue(population.native?.window === host.window)
            XCTAssertTrue(gate.isReady(scope), "The exact current visible population must have committed before capture")
            XCTAssertTrue(gate.isReady(retainedScope), "The other ready surface cannot satisfy this viewport's admission")
        })
        XCTAssertEqual(population.native?.attachedLogicalRows, 1,
                       "A snapshot must include the current native row, not its empty shell")
    }
}

@MainActor private final class SnapshotInteractiveState {
    private let start = ContinuousClock.now
    private var timeline: [String] = []
    private var lastObservation = ""
    private var readyCalls = 0

    var elapsed: Double {
        let duration = ContinuousClock.now - start
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// The probe is found structurally under the exact current host. A
    /// registration table can name a bridge SwiftUI updated in another graph.
    func probe(in host: NSView) -> SnapshotInteractiveProbe.Native? {
        guard let window = host.window else { return nil }
        let visible = Self.probes(under: host).filter {
            $0.window === window && $0.bounds.width > 0 && $0.bounds.height > 0
        }
        return visible.count == 1 ? visible[0] : nil
    }

    func admit(in host: NSView, phase: Int) -> SnapshotInteractiveProbe.Native? {
        readyCalls += 1
        observe(host, phase: phase, note: "ready")
        return probe(in: host)
    }

    func record(_ event: String, _ probe: SnapshotInteractiveProbe.Native) {
        append("\(event) \(Self.describe(probe, in: nil))")
    }

    func report(phase: Int) -> String {
        "Snapshot pointer-intrusion phase=\(phase) elapsed=\(String(format: "%.3f", elapsed)) "
            + "readyCalls=\(readyCalls)\n  "
            + timeline.joined(separator: "\n  ")
    }

    private func observe(_ host: NSView, phase: Int, note: String) {
        let probes = Self.probes(under: host).map { Self.describe($0, in: host) }
        let observation = "phase=\(phase) host=\(Self.id(host)) hostWindow=\(host.window.map(Self.id) ?? "nil") "
            + "hostBounds=\(host.bounds) needsLayout=\(host.needsLayout) probes=\(probes.count)[\(probes.joined(separator: "; "))]"
        guard observation != lastObservation else { return }
        lastObservation = observation
        append("\(note) \(observation)")
    }

    private func append(_ line: String) {
        // Keep the earliest transitions (the stall) and the latest state.
        if timeline.count >= 60 { timeline.remove(at: 30) }
        timeline.append("t=\(String(format: "%.3f", elapsed)) \(line)")
    }

    private static func probes(under view: NSView) -> [SnapshotInteractiveProbe.Native] {
        ((view as? SnapshotInteractiveProbe.Native).map { [$0] } ?? []) + view.subviews.flatMap { probes(under: $0) }
    }

    private static func id(_ object: AnyObject) -> String {
        String(UInt(bitPattern: ObjectIdentifier(object).hashValue), radix: 16)
    }

    private static func describe(_ probe: SnapshotInteractiveProbe.Native, in host: NSView?) -> String {
        "probe=\(id(probe)) window=\(probe.window.map(id) ?? "nil") "
            + "superview=\(probe.superview.map { String(describing: type(of: $0)).prefix(24) } ?? "nil") "
            + (host.map { "descends=\(probe.isDescendant(of: $0)) " } ?? "")
            + "bounds=\(probe.bounds) hovered=\(probe.hovered) actuator=\(probe.setHovered != nil)"
    }
}

@MainActor private final class SnapshotOcclusion {
    var observed = false
}

private struct SnapshotInteractiveSurface: View {
    let state: SnapshotInteractiveState
    @State private var hovered = false
    var body: some View {
        SnapshotInteractiveProbe(state: state, hovered: $hovered)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: hovered ? 0.8 : 0.2))
            .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

private struct SnapshotInteractiveProbe: NSViewRepresentable {
    final class Native: NSView {
        var hovered = false
        weak var state: SnapshotInteractiveState?
        var setHovered: ((Bool) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            state?.record("moved", self)
        }
    }
    let state: SnapshotInteractiveState
    @Binding var hovered: Bool
    func makeNSView(context: Context) -> Native {
        let view = Native()
        configure(view)
        state.record("make", view)
        return view
    }
    func updateNSView(_ view: Native, context: Context) {
        // Each bridge owns its graph's actuator. Admission resolves the bridge
        // under the exact current host, never whichever update ran last.
        configure(view)
        state.record("update", view)
    }
    private func configure(_ view: Native) {
        view.state = state
        let binding = $hovered
        view.setHovered = { binding.wrappedValue = $0 }
        view.hovered = hovered
    }
    static func dismantleNSView(_ view: Native, coordinator: ()) {
        view.state?.record("dismantle", view)
        view.setHovered = nil
        view.state = nil
    }
}

@MainActor private final class SnapshotPopulation {
    var pending: [@MainActor () -> Void] = []
    var native: NativeCachedSidebarBatchesView<Text>?
}

private struct DeferredSnapshotRows: NSViewRepresentable {
    let population: SnapshotPopulation
    let scope: SidebarNativeReadinessScope
    let rows: [SidebarRows.Row]

    func makeNSView(context: Context) -> NativeCachedSidebarBatchesView<Text> {
        let native = NativeCachedSidebarBatchesView<Text>(frame: .zero)
        native.geometryScheduler = { population.pending.append($0) }
        population.native = native
        return native
    }
    func updateNSView(_ native: NativeCachedSidebarBatchesView<Text>, context: Context) {
        var environment = context.environment
        environment.sidebarNativeReadinessScope = scope
        native.configure(rows: rows, modelIDs: Set(rows.map(\.id)), environment: environment,
                         readinessSection: "today") { _, _, _ in Text("Deferred row") }
    }
    static func dismantleNSView(_ native: NativeCachedSidebarBatchesView<Text>, coordinator: ()) { native.detach() }
}
