import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class RenderSurfaceActivityTests: XCTestCase {
    private final class Input: ObservableObject {
        @Published var active = false
    }
    /// Cancellation deliberately does not resume this sleeper. Releasing an old
    /// close after reopening proves the modifier rejects stale task completion.
    @MainActor private final class Delay {
        var calls = 0
        var durations: [Duration] = []
        private var waiting: [CheckedContinuation<Void, Error>] = []
        func sleep(_ duration: Duration) async throws {
            calls += 1; durations.append(duration)
            try await withCheckedThrowingContinuation { waiting.append($0) }
        }
        func releaseAll() {
            let pending = waiting; waiting = []
            for continuation in pending { continuation.resume() }
        }
    }
    private final class NativeProbe: NSView { var admitted = false }
    private final class ProbeOwner { weak var view: NativeProbe? }
    private struct Probe: NSViewRepresentable {
        @Environment(\.renderSurfaceActive) private var active
        let owner: ProbeOwner
        func makeNSView(context: Context) -> NativeProbe {
            let view = NativeProbe(); owner.view = view; return view
        }
        func updateNSView(_ view: NativeProbe, context: Context) { view.admitted = active }
    }
    private struct Fixture: View {
        @ObservedObject var input: Input
        let saver: BatterySaver
        let delay: Delay
        let owner: ProbeOwner
        var body: some View {
            Probe(owner: owner)
                .modifier(RetainedRenderSurfaceActivity(active: input.active,
                    batterySaver: saver, sleep: delay.sleep))
        }
    }
    private func fixture() -> (Input, BatterySaver, Delay, ProbeOwner) {
        TestEnvironment.prepare()
        let suite = "vane-render-activity-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(BatterySaver.Mode.off.rawValue, forKey: BatterySaver.key)
        let saver = BatterySaver(defaults: defaults)
        let input = Input(), delay = Delay(), owner = ProbeOwner()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 120, height: 100),
                              styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Fixture(input: input, saver: saver, delay: delay, owner: owner))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in
            window.orderOut(nil); window.contentView = nil; window.close(); delay.releaseAll()
            defaults.removePersistentDomain(forName: suite)
        }
        return (input, saver, delay, owner)
    }
    private func eventually(_ predicate: @MainActor () -> Bool, file: StaticString = #filePath,
                            line: UInt = #line) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Mounted activity did not reach the expected state", file: file, line: line)
    }

    func testInitiallyClosedOpenClosingTailAndSettledHiddenKeepNativeIdentity() async throws {
        let (input, _, delay, owner) = fixture()
        try await eventually { owner.view != nil }
        let probe = try XCTUnwrap(owner.view)
        XCTAssertFalse(probe.admitted)
        XCTAssertEqual(delay.calls, 0, "An initially hidden retained panel needs no tail")
        input.active = true
        try await eventually { probe.admitted }
        XCTAssertEqual(delay.calls, 0, "Opening admits work immediately without waiting for a timer")
        input.active = false
        try await eventually { delay.calls == 1 }
        XCTAssertTrue(probe.admitted, "The panel's contents must remain intact throughout its close")
        XCTAssertEqual(delay.durations, [.milliseconds(240)])
        delay.releaseAll()
        try await eventually { !probe.admitted }
        XCTAssertTrue(owner.view === probe, "Settling offscreen must preserve the native control host")
    }

    func testReopeningCancelsOldTailAndASecondCloseGetsItsOwnTail() async throws {
        let (input, _, delay, owner) = fixture()
        input.active = true
        try await eventually { owner.view?.admitted == true }
        input.active = false
        try await eventually { delay.calls == 1 }
        input.active = true
        try await Task.sleep(for: .milliseconds(40))
        delay.releaseAll()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(owner.view?.admitted, true, "An old close completion cannot hide a reopened panel")
        input.active = false
        try await eventually { delay.calls == 2 }
        XCTAssertEqual(owner.view?.admitted, true)
        delay.releaseAll()
        try await eventually { owner.view?.admitted == false }
    }

    func testBatterySaverEndsClosingTailWithoutRevival() async throws {
        let (input, saver, delay, owner) = fixture()
        input.active = true
        try await eventually { owner.view?.admitted == true }
        input.active = false
        try await eventually { delay.calls == 1 }
        saver.setMode(.alwaysOn)
        try await eventually { owner.view?.admitted == false }
        delay.releaseAll()
        saver.setMode(.off)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(owner.view?.admitted, false)
        XCTAssertEqual(delay.calls, 1, "Lifting Battery Saver must not restart a closed panel")
    }
}
