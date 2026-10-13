import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class Feel09NativeInteractionTests: XCTestCase {
    private var frame = 0
    func testRapidNativeClicksKeepTheFullTargetAndReturnToRest() async throws {
        TestEnvironment.prepare()
        let saver = BatterySaver.shared
        let originalMode = saver.mode
        defer { saver.setMode(originalMode) }
        let state = Feel09NativeState()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Feel09NativeButton(state: state))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        for mode in 0..<2 {
            saver.setMode(mode == 1 ? .alwaysOn : .off)
            try await Task.sleep(for: .milliseconds(80))
            let idle = try pixels(host)
            let before = state.actions
            for click in 0..<20 {
                let point = NSPoint(x: click.isMultiple(of: 2) ? 140 : 81, y: 50)
                func event(_ type: NSEvent.EventType) throws -> NSEvent {
                    try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        eventNumber: click, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                }
                window.sendEvent(try event(.leftMouseDown))
                try await Task.sleep(for: .milliseconds(10))
                if mode == 0 && click == 0 {
                    XCTAssertGreaterThan(difference(try pixels(host), idle), 10,
                                         "Press acknowledgement must be visible before activation")
                }
                window.sendEvent(try event(.leftMouseUp))
                try await Task.sleep(for: .milliseconds(10))
                if mode == 0 && click == 10 {
                    saver.setMode(.alwaysOn)
                    try await Task.sleep(for: .milliseconds(30))
                    XCTAssertLessThanOrEqual(difference(try pixels(host), idle), 2,
                                             "Battery Saver must finish an in-flight button release")
                    saver.setMode(.off)
                }
            }
            XCTAssertEqual(state.actions - before, 20, "Rapid clicks, including target edges, must activate once")
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertLessThanOrEqual(difference(try pixels(host), idle), 2,
                                     "Rapid release must not leave scale or opacity stuck")
        }
    }

    func testLiveMotionPoliciesSettleArrivalAndTidyWithoutReplaying() async throws {
        TestEnvironment.prepare()
        let saver = BatterySaver.shared
        let originalMode = saver.mode
        saver.setMode(.off)
        defer { saver.setMode(originalMode) }
        try XCTSkipIf(Motion.spaceReduced, "Full-motion comparison requires system motion")
        let state = Feel09NativeState()
        let feedback = InteractionFeedback()
        let id = UUID()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Feel09NativeRows(state: state, feedback: feedback, id: id))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(80))
        let idle = try pixels(host)
        for battery in [false, true] {
            state.probeReduceMotion = !battery
            state.reduced = false
            saver.setMode(.off)
            try await Task.sleep(for: .milliseconds(40))
            feedback.arrived(id)
            feedback.tidied(["row"])
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertGreaterThan(difference(try pixels(host), idle), 10,
                                 "Normal motion must visibly acknowledge the action")
            feedback.withoutArrivalHighlight {}
            feedback.cancelTidy()
            try await Task.sleep(for: .milliseconds(30))
            if battery { saver.setMode(.alwaysOn) } else { state.reduced = true }
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertLessThanOrEqual(difference(try pixels(host), idle), 2,
                                     "Changing policy must settle owned effects immediately")
            // Actions while reduced still update semantic state, without visual motion.
            for _ in 0..<20 { feedback.arrived(id); feedback.tidied(["row"]) }
            XCTAssertEqual(feedback.arrivingTab, id)
            XCTAssertEqual(feedback.tidyRanks, ["row": 0])
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertLessThanOrEqual(difference(try pixels(host), idle), 2)
            state.reduced = false
            saver.setMode(.off)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertLessThanOrEqual(difference(try pixels(host), idle), 2,
                                     "Restoring motion must not replay feedback suppressed by policy")
            // No stale completion may bring either effect back after expiry.
            try await Task.sleep(for: .milliseconds(900))
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertLessThanOrEqual(difference(try pixels(host), idle), 2)
        }
    }

    func testNativeToastReplacementAndBatteryPolicyFinishInPlace() async throws {
        TestEnvironment.prepare()
        let saver = BatterySaver.shared
        let originalMode = saver.mode
        saver.setMode(.off)
        let toasts = Toasts.shared
        toasts.showing.forEach { toasts.dismiss($0) }
        let store = TabStore(isPrivate: true)
        defer {
            toasts.showing.forEach { toasts.dismiss($0) }
            saver.setMode(originalMode)
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
        }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ToastHost().environmentObject(store)
            .frame(width: 280, height: 100, alignment: .bottomLeading).background(.white))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(80))
        Toasts.show("Copied URL", in: store)
        try await Task.sleep(for: .milliseconds(30))
        saver.setMode(.alwaysOn)
        try await Task.sleep(for: .milliseconds(30))
        let reduced = try pixels(host)
        saver.setMode(.off)
        try await Task.sleep(for: .milliseconds(30))
        let restored = try pixels(host)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertLessThanOrEqual(difference(try pixels(host), reduced), 2,
                                 "Battery Saver must finish an in-flight toast transition")
        XCTAssertLessThanOrEqual(difference(try pixels(host), restored), 2,
                                 "Restoring motion must not resume the cancelled toast entrance")
        saver.setMode(.alwaysOn)
        for index in 0..<30 {
            Toasts.show("Copied URL \(index)", in: store)
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(toasts.showing.count, 1)
        XCTAssertEqual(toasts.current?.text, "Copied URL 29")
        let latest = try pixels(host)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertLessThanOrEqual(difference(try pixels(host), latest), 2,
                                 "Reduced replacement must leave the final pill immediately visible")
    }

    func testToastReplacementCannotRetargetAnInFlightNativePress() async throws {
        TestEnvironment.prepare()
        let toasts = Toasts.shared
        toasts.showing.forEach { toasts.dismiss($0) }
        let store = TabStore(isPrivate: true)
        defer {
            toasts.showing.forEach { toasts.dismiss($0) }
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
        }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ToastHost().environmentObject(store)
            .frame(width: 280, height: 100, alignment: .bottomLeading)
            .transaction { $0.disablesAnimations = true })
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        var oldActions = 0, newActions = 0
        func send(_ type: NSEvent.EventType, x: CGFloat = 80) async throws {
            // Both one-word messages put Undo at this point; the fresh-click assertion
            // below verifies that the control, rather than empty space, receives input.
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type,
                location: NSPoint(x: x, y: 16), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
            try await Task.sleep(for: .milliseconds(30))
        }
        Toasts.show("First", action: ("Undo", { oldActions += 1 }), in: store)
        try await Task.sleep(for: .milliseconds(80))
        try await send(.leftMouseDown)
        Toasts.show("First", action: ("Undo", { newActions += 1 }), in: store)
        let successor = try XCTUnwrap(toasts.current)
        try await Task.sleep(for: .milliseconds(30))
        try await send(.leftMouseUp)
        XCTAssertEqual(oldActions, 0)
        XCTAssertEqual(newActions, 0, "A press begun on the replaced toast must not activate its successor")
        XCTAssertEqual(toasts.current?.id, successor.id)
        if toasts.current == nil {
            Toasts.show("First", action: ("Undo", { newActions += 1 }), in: store)
            try await Task.sleep(for: .milliseconds(30))
        }
        let beforeFresh = newActions
        try await send(.leftMouseDown)
        try await send(.leftMouseUp)
        XCTAssertEqual(newActions, beforeFresh + 1, "A fresh press must activate the successor normally")

        // A sticky update keeps its toast ID while Download becomes Restart.
        let id = UUID()
        let beforeSticky = newActions
        Toasts.stick("First", id: id, action: ("Download", { oldActions += 1 }))
        try await Task.sleep(for: .milliseconds(30))
        try await send(.leftMouseDown)
        Toasts.stick("First", id: id, action: ("Restart", { newActions += 1 }))
        try await Task.sleep(for: .milliseconds(30))
        try await send(.leftMouseUp)
        XCTAssertEqual(oldActions, 0)
        XCTAssertEqual(newActions, beforeSticky)
        XCTAssertEqual(toasts.current?.id, id)
        try await send(.leftMouseDown)
        try await send(.leftMouseUp)
        XCTAssertEqual(newActions, beforeSticky + 1)

        // The same replacement rule applies to the dismiss target.
        Toasts.show("First", action: ("Undo", {}), in: store)
        try await Task.sleep(for: .milliseconds(30))
        try await send(.leftMouseDown, x: 106)
        Toasts.show("First", action: ("Undo", {}), in: store)
        let dismissSuccessor = try XCTUnwrap(toasts.current)
        try await Task.sleep(for: .milliseconds(30))
        try await send(.leftMouseUp, x: 106)
        XCTAssertEqual(toasts.current?.id, dismissSuccessor.id)
        try await send(.leftMouseDown, x: 106)
        try await send(.leftMouseUp, x: 106)
        XCTAssertNil(toasts.current, "A fresh dismiss press must remove the successor")
    }

    private func pixels(_ host: NSView) throws -> Data {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let directory = ProcessInfo.processInfo.environment["VANE_FEEL09_CAPTURE_DIR"] {
            let path = URL(fileURLWithPath: directory).appendingPathComponent("frame-\(frame).png")
            try rep.representation(using: .png, properties: [:])?.write(to: path)
            frame += 1
        }
        return Data(bytes: try XCTUnwrap(rep.bitmapData), count: rep.bytesPerRow * rep.pixelsHigh)
    }

    private func difference(_ lhs: Data, _ rhs: Data) -> Int {
        guard lhs.count == rhs.count else { return 255 }
        return zip(lhs, rhs).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }
}

@MainActor private final class Feel09NativeState: ObservableObject {
    @Published var reduced = false
    @Published var probeReduceMotion = false
    var actions = 0
}

private struct Feel09NativeButton: View {
    @ObservedObject var state: Feel09NativeState
    var body: some View {
        Button { state.actions += 1 } label: {
            Text("Press").frame(width: 120, height: 32)
                .background(.blue, in: .rect(cornerRadius: 8))
                .foregroundStyle(.white)
        }
        .buttonStyle(TactileButtonStyle())
        .frame(width: 280, height: 100)
        .background(.white)
        .vaneMotionPolicy()
    }
}

private struct Feel09NativeRows: View {
    @ObservedObject var state: Feel09NativeState
    @ObservedObject var feedback: InteractionFeedback
    let id: UUID
    var body: some View {
        VStack(spacing: 8) {
            if state.probeReduceMotion {
                // SwiftUI's Reduce Motion environment is read-only. Exercise the shared
                // effect's policy input here; the other pass uses real Battery Saver.
                Text("Arriving tab").frame(width: 220, height: 32)
                    .modifier(Feel09FeedbackHighlight(active: feedback.arrivingTab == id,
                        stamp: feedback.arrivalStamp, arrival: true, reduced: state.reduced))
                Text("Tidied row").frame(width: 220, height: 32)
                    .modifier(Feel09FeedbackHighlight(active: feedback.tidyRanks["row"] != nil,
                        stamp: feedback.tidyStamp, arrival: false, reduced: state.reduced))
            } else {
                Text("Arriving tab").frame(width: 220, height: 32)
                    .modifier(TabArrivalFeedback(feedback: feedback, id: id))
                Text("Tidied row").frame(width: 220, height: 32)
                    .modifier(TidyRowFeedback(feedback: feedback, id: "row"))
            }
        }
        .frame(width: 280, height: 100)
        .background(Color.white)
        .foregroundStyle(.black)
        .tint(.blue)
        .environment(\.colorScheme, .light)
        .vaneMotionPolicy()
    }
}
