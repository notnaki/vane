import AppKit
import SwiftUI
import QuartzCore
import Darwin
import XCTest
@testable import vane

/// Actual key events and actual AX objects are prerequisites. An unavailable
/// eager baseline is a skipped/unverified gate, never candidate admission.
@MainActor final class NativeSidebarNavigationTests: XCTestCase {
    private var applicationLoop: NativeFixtureApplicationLoop?
    private var fixtureCleanups: [@MainActor () -> Void] = []
    /// Retain one native window throughout the parity sequence. Replacing its
    /// hosting root still gives every exercise fresh SwiftUI state and owners.
    private var reusableFixtureWindow: NSWindow?
    private var externalClientAdmitted = false

    private func withNativeApplicationLoop(_ body: @MainActor () async throws -> Void) async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        // A real owned GUI host supplies its own normal application menu and
        // Launch Services identity. Foreground still requires the physical gate.
        let previousMenu = app.mainMenu
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Vane Native Parity")
        let quit = NSMenuItem(title: "Quit Vane Native Parity", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = app
        applicationMenu.addItem(quit)
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        app.mainMenu = menu
        let policyAccepted = app.setActivationPolicy(.regular)
        defer {
            app.mainMenu = previousMenu
            app.setActivationPolicy(originalPolicy)
        }
        guard policyAccepted || app.activationPolicy() == .regular else {
            throw XCTSkip("macOS did not admit the interactive GUI fixture application")
        }
        let lease = try await NativeFixtureApplicationLoop.acquire()
        applicationLoop = lease
        var bodyFailure: (any Error)?
        do { try await body() } catch { bodyFailure = error }
        // Tear down hosts/windows while their real AppKit loop still runs. This
        // is deliberately inside the test method, never an XCTest teardown that
        // cannot run until the method returns and would deadlock loop shutdown.
        let cleanups = fixtureCleanups.reversed()
        fixtureCleanups.removeAll()
        for cleanup in cleanups { cleanup() }
        reusableFixtureWindow = nil
        externalClientAdmitted = false
        applicationLoop = nil
        do { try await lease.close() }
        catch {
            if bodyFailure == nil { bodyFailure = error }
            else { XCTFail("AppKit loop cleanup also failed: \(error)") }
        }
        if let bodyFailure { throw bodyFailure }
    }
    private final class State: ObservableObject {
        @Published var rows: [SidebarRows.Row]
        @Published var requested: String?
        @Published var editing: String?
        @Published var nativeButtons = false
        var focused: String?
        var activated: [String] = []
        var fields: [String: WeakField] = [:]
        let split: String
        init(rowCount: Int = 100) {
            let initial = (0..<rowCount).map { index in
                SidebarRows.Row(visible: Pins.Visible(entry: .init(row: .folder(Folder(name: "Navigation \(index)"))), depth: 0), tab: nil)
            }
            rows = initial
            split = initial[7].id
        }
        var keys: [String] { rows.flatMap { $0.id == split ? ["\($0.id)/0", "\($0.id)/1"] : ["\($0.id)/0"] } }
    }
    private final class WeakField {
        weak var value: NSTextField?
        init(_ value: NSTextField) { self.value = value }
    }
    private struct Editor: NSViewRepresentable {
        let id: String
        let state: State
        func makeNSView(context: Context) -> NSTextField {
            let field = NSTextField(string: "Original")
            state.fields[id] = WeakField(field)
            return field
        }
        func updateNSView(_ view: NSTextField, context: Context) {}
    }
    private struct ControlRow: View {
        let row: SidebarRows.Row
        @ObservedObject var state: State
        var body: some View {
            HStack(spacing: 0) {
                if state.editing == row.id { Editor(id: row.id, state: state) }
                else { control(0) }
                if row.id == state.split { control(1) }
                if state.nativeButtons && row.id == state.rows.first?.id {
                    let key = "\(row.id)/native"
                    Button("Row action") { state.activated.append(key) }
                        .buttonStyle(TactileButtonStyle())
                        .nativeSidebarKeyboardControl(focusChanged: {
                            if $0 { state.focused = key } else if state.focused == key { state.focused = nil }
                        })
                }
            }.frame(height: Look.rowHeight)
        }
        private func control(_ pane: Int) -> some View {
            let key = "\(row.id)/\(pane)"
            return Text(key).lineLimit(1).frame(maxWidth: .infinity).frame(height: Look.rowHeight)
                .contentShape(.rect)
                .onTapGesture { state.activated.append(key) }
                .vaneKeyboardAction(requestFocus: Binding(get: { state.requested == key }, set: { if !$0 && state.requested == key { state.requested = nil } }), focusChanged: {
                    if $0 { state.focused = key } else if state.focused == key { state.focused = nil }
                }, action: { state.activated.append(key) })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(key).accessibilityAddTraits(.isButton)
                .accessibilityAction { state.activated.append(key) }
        }
    }
    /// Diagnostic isolation only: the production bridge forwards its context
    /// environment. This route creates the same real owner with a fresh public
    /// environment to distinguish host-private focus state from navigation code.
    private struct FreshEnvironmentOwner: NSViewRepresentable {
        @ObservedObject var state: State
        func makeNSView(context: Context) -> NativeCachedSidebarBatchesView<ControlRow> {
            NativeCachedSidebarBatchesView(frame: .zero)
        }
        func updateNSView(_ view: NativeCachedSidebarBatchesView<ControlRow>, context: Context) {
            view.configure(rows: state.rows, modelIDs: Set(state.rows.map(\.id)), environment: EnvironmentValues(),
                           transaction: context.transaction) { row, _, _ in
                ControlRow(row: row, state: state)
            }
        }
        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeCachedSidebarBatchesView<ControlRow>, context: Context) -> CGSize? {
            CGSize(width: proposal.width ?? 0,
                   height: max(0, CGFloat(state.rows.count) * (Look.rowHeight + Look.rowGap) - Look.rowGap))
        }
        static func dismantleNSView(_ view: NativeCachedSidebarBatchesView<ControlRow>, coordinator: ()) { view.detach() }
    }
    private struct Outline: View {
        let grouped: Bool
        let divided: Bool
        @ObservedObject var state: State
        var body: some View {
            VStack(spacing: 0) {
                ScrollView {
                    if divided {
                        VStack(spacing: Look.rowGap) {
                            section(Array(state.rows.prefix(50)))
                            if state.nativeButtons {
                                Button("Tidy") { state.activated.append("tidy") }
                                    .buttonStyle(TactileButtonStyle())
                                    .nativeSidebarKeyboardControl(focusChanged: {
                                        if $0 { state.focused = "tidy" } else if state.focused == "tidy" { state.focused = nil }
                                    })
                                    .frame(maxWidth: .infinity).frame(height: Look.rowHeight)
                            } else {
                            Text("Tidy sentinel")
                                .frame(maxWidth: .infinity).frame(height: Look.rowHeight)
                                .vaneKeyboardAction(requestFocus: Binding(get: { state.requested == "tidy" }, set: { if !$0 && state.requested == "tidy" { state.requested = nil } }), focusChanged: {
                                    if $0 { state.focused = "tidy" } else if state.focused == "tidy" { state.focused = nil }
                                }, action: { state.activated.append("tidy") })
                            }
                            section(Array(state.rows.dropFirst(50)))
                        }
                    } else if grouped && ProcessInfo.processInfo.environment["VANE_NATIVE_NAV_FRESH_HOST_ENV"] == "1" {
                        FreshEnvironmentOwner(state: state)
                            .frame(height: max(0, CGFloat(state.rows.count) * (Look.rowHeight + Look.rowGap) - Look.rowGap))
                    } else if grouped {
                        NativeCachedSidebarBatchSectionRows(rows: state.rows, modelIDs: Set(state.rows.map(\.id))) { row, _, _ in
                            ControlRow(row: row, state: state)
                        }
                    } else {
                        VStack(spacing: Look.rowGap) {
                            ForEach(state.rows) { ControlRow(row: $0, state: state) }
                        }
                    }
                }
                Text("Outside sentinel").vaneKeyboardAction(requestFocus: Binding(get: { state.requested == "outside" }, set: { if !$0 { state.requested = nil } }), focusChanged: {
                    if $0 { state.focused = "outside" } else if state.focused == "outside" { state.focused = nil }
                }, action: { state.activated.append("outside") })
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Native sidebar navigation fixture")
        }
        @ViewBuilder private func section(_ rows: [SidebarRows.Row]) -> some View {
            if grouped {
                NativeCachedSidebarBatchSectionRows(rows: rows, modelIDs: Set(rows.map(\.id))) { row, _, _ in
                    ControlRow(row: row, state: state)
                }
            } else {
                VStack(spacing: Look.rowGap) {
                    ForEach(rows) { ControlRow(row: $0, state: state) }
                }
            }
        }
    }
    private struct Fixture {
        let state: State
        let window: NSWindow
        let host: NSHostingView<Outline>
        let scroll: NSScrollView
    }
    private func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, type) }
    }
    private func drainPendingApplicationEvents() {
        guard !NSApp.isRunning else { return }
        // Outside the leased real loop, XCTest services CFRunLoop/GCD, but does not run NSApplication's event
        // loop. Dispatch real pending activation/window/input events through the
        // public application route, without waiting or manufacturing success.
        // A hard per-turn bound prevents a busy queue from starving the test.
        for _ in 0..<16 {
            guard let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) else { break }
            NSApp.sendEvent(event)
        }
    }
    /// XCTest does not run NSApplication's usual update/display pass. Commit
    /// native window drawing as well as SwiftUI layout before reading focus/AX.
    /// One bounded pass per settle/poll mirrors the public application idle cycle.
    private func commitApplicationDisplayCycle(in window: NSWindow) {
        drainPendingApplicationEvents()
        NSApp.updateWindows()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }
    private func foregroundIsAdmitted(in window: NSWindow) -> Bool {
        NSApp.isActive && NSApp.keyWindow === window && window.isKeyWindow
            && window.isVisible && window.occlusionState.contains(.visible)
            && window.contentView?.window === window
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }
    private func foregroundDescription(in window: NSWindow) -> String {
        "active=\(NSApp.isActive) key=\(window.isKeyWindow) exactKey=\(NSApp.keyWindow === window) visible=\(window.isVisible) unoccluded=\(window.occlusionState.contains(.visible)) frontmostPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1) ownPID=\(ProcessInfo.processInfo.processIdentifier)"
    }
    private func requireForeground(in window: NSWindow) throws {
        guard foregroundIsAdmitted(in: window) else {
            throw XCTSkip("Native navigation fixture lost actual foreground; keyboard/AX parity is UNVERIFIED. \(foregroundDescription(in: window))")
        }
    }
    private struct ExternalRequest: Codable {
        let schema: Int
        let nonce: String
        let pid: Int32
        let windowNumber: Int
        let kind: String
        let phase: String
        let expectedLabels: [String]
        let requiredLabels: [String]
        let forbiddenLabels: [String]
        let targetLabel: String?
    }
    private struct ExternalAcknowledgement: Codable {
        let schema: Int
        let nonce: String
        let pid: Int32
        let windowNumber: Int
        let kind: String
        let phase: String
        let status: String
        let observedLabels: [String]
    }
    private func externalDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["VANE_NATIVE_NAV_EXTERNAL_DIR"], !path.isEmpty else {
            throw XCTSkip("External CUA controller is absent; native keyboard/AX parity is UNVERIFIED")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard path.hasPrefix("/"), directory.path == path,
              directory.resolvingSymlinksInPath() == directory else {
            throw NativeOutcomeTimeout(description: "External controller directory must be an absolute canonical owned path")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
            throw NativeOutcomeTimeout(description: "External controller directory must be owned by this user and mode 0700")
        }
        return directory
    }
    /// Only a real external CUA client supplies observations and native actions.
    /// The acknowledgement is evidence transport, never an in-process AX proxy.
    @discardableResult private func externalInteraction(in window: NSWindow, kind: String, phase: String,
        expectedLabels: [String], requiredLabels: [String] = [], forbiddenLabels: [String] = [],
        targetLabel: String? = nil) async throws -> ExternalAcknowledgement {
        let directory = try externalDirectory()
        let request = ExternalRequest(schema: 1, nonce: UUID().uuidString, pid: ProcessInfo.processInfo.processIdentifier,
            windowNumber: window.windowNumber, kind: kind, phase: phase, expectedLabels: expectedLabels,
            requiredLabels: requiredLabels, forbiddenLabels: forbiddenLabels, targetLabel: targetLabel)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(request)
        let requestURL = directory.appendingPathComponent("request-\(request.nonce).json")
        let currentURL = directory.appendingPathComponent("current-request.json")
        for url in [requestURL, currentURL] {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        NativeFixtureDiagnostics.emit("NATIVE_NAV_EXTERNAL_REQUEST phase=\(phase) kind=\(kind) nonce=\(request.nonce) pid=\(request.pid) window=\(request.windowNumber)")
        let ackURL = directory.appendingPathComponent("ack-\(request.nonce).json")
        let deadline = ContinuousClock.now + .seconds(180)
        while !FileManager.default.fileExists(atPath: ackURL.path) {
            // The first request gives CUA the opportunity to raise/read this
            // exact window. Every subsequent interaction keeps strict foreground.
            if externalClientAdmitted { try requireForeground(in: window) }
            guard ContinuousClock.now < deadline else {
                if !externalClientAdmitted {
                    throw XCTSkip("External CUA controller did not admit the actual window; native parity is UNVERIFIED")
                }
                throw NativeOutcomeTimeout(description: "External CUA controller timed out during \(phase); native parity is UNVERIFIED")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: ackURL.path)
        guard ackURL.resolvingSymlinksInPath() == ackURL,
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 262_144 else {
            throw NativeOutcomeTimeout(description: "External acknowledgement is not a bounded private owned regular file")
        }
        let acknowledgement = try JSONDecoder().decode(ExternalAcknowledgement.self, from: Data(contentsOf: ackURL))
        guard acknowledgement.schema == request.schema, acknowledgement.nonce == request.nonce,
              acknowledgement.pid == request.pid, acknowledgement.windowNumber == request.windowNumber,
              acknowledgement.kind == request.kind, acknowledgement.phase == request.phase else {
            throw NativeOutcomeTimeout(description: "External acknowledgement does not identify this exact request/window/launch")
        }
        guard acknowledgement.status == "ok" else {
            if !externalClientAdmitted {
                throw XCTSkip("External CUA client is unavailable; native parity is UNVERIFIED")
            }
            throw NativeOutcomeTimeout(description: "External CUA action failed during \(phase): \(acknowledgement.status)")
        }
        try requireForeground(in: window)
        let observed = acknowledgement.observedLabels
        let allowed = Set(expectedLabels + forbiddenLabels)
        XCTAssertFalse(observed.isEmpty, "A real external AX query must expose actual row controls")
        XCTAssertEqual(Set(observed).count, observed.count, "Native UI observations must not duplicate controls")
        XCTAssertTrue(observed.allSatisfy { allowed.contains($0) }, "Only actual requested row-label observations belong in this acknowledgement")
        XCTAssertTrue(requiredLabels.allSatisfy { observed.contains($0) }, "Required actual native controls must be exposed")
        XCTAssertTrue(forbiddenLabels.allSatisfy { !observed.contains($0) }, "Deleted controls must leave the actual native UI tree")
        let ordered = expectedLabels.filter { Set(observed).contains($0) }
        XCTAssertEqual(observed, ordered, "External AX order must follow authoritative row/pane order")
        guard !observed.isEmpty, Set(observed).count == observed.count,
              observed.allSatisfy({ allowed.contains($0) }),
              requiredLabels.allSatisfy({ observed.contains($0) }),
              forbiddenLabels.allSatisfy({ !observed.contains($0) }), observed == ordered else {
            throw NativeOutcomeTimeout(description: "Actual external AX observations failed during \(phase)")
        }
        externalClientAdmitted = true
        NativeFixtureDiagnostics.emit("NATIVE_NAV_EXTERNAL_ACKNOWLEDGED phase=\(phase) nonce=\(request.nonce) observed=\(observed.count)")
        return acknowledgement
    }
    private struct NativeOutcomeTimeout: Error, CustomStringConvertible {
        let description: String
    }
    /// A foreground loss invalidates the physical-input prerequisite. In valid
    /// foreground, an unavailable eager route is unverified; candidate outcomes
    /// remain hard failures and never become an eager-baseline skip.
    private func waitForNativeOutcome(in window: NSWindow, baseline: String? = nil,
                                      file: StaticString = #filePath, line: UInt = #line,
                                      _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + (baseline == nil ? .seconds(10) : .seconds(2))
        while true {
            try requireForeground(in: window)
            if predicate() { return }
            guard ContinuousClock.now < deadline else {
                if let baseline {
                    throw XCTSkip("Actual eager \(baseline) unavailable; grouped parity is UNVERIFIED. \(foregroundDescription(in: window))")
                }
                XCTFail("Native candidate outcome timed out in admitted foreground", file: file, line: line)
                throw NativeOutcomeTimeout(description: "Native candidate outcome timed out at \(file):\(line)")
            }
            commitApplicationDisplayCycle(in: window)
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func fixture(grouped: Bool, divided: Bool = false, nativeButtons: Bool = false, rowCount: Int = 100, reusing reusedWindow: NSWindow? = nil) async throws -> Fixture {
        TestEnvironment.prepare()
        try XCTUnwrap(applicationLoop, "Native fixture requires its admitted AppKit loop").verifyRunning()
        let state = State(rowCount: rowCount)
        state.nativeButtons = nativeButtons
        let createsWindow = reusedWindow == nil && reusableFixtureWindow == nil
        let window = reusedWindow ?? reusableFixtureWindow ?? NSWindow(contentRect: NSRect(x: 80, y: 80, width: 260, height: 320), styleMask: .titled, backing: .buffered, defer: false)
        reusableFixtureWindow = window
        window.title = "Vane native navigation fixture — external CUA"
        if createsWindow,
           let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame.insetBy(dx: 20, dy: 20)
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.midY - window.frame.height / 2))
        }
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Outline(grouped: grouped, divided: divided, state: state))
        window.makeFirstResponder(nil)
        window.contentView = host
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        // Expose the owned test window without treating ordering as physical
        // foreground admission. The exact-titlebar click gate still owns that.
        window.orderFrontRegardless()
        // This is a public AppKit key-window request, not an assumption that
        // activating the XCTest host succeeded at the WindowServer level.
        window.makeKey()
        drainPendingApplicationEvents()
        host.layoutSubtreeIfNeeded()
        fixtureCleanups.append { @MainActor in
            if window.contentView === host {
                window.makeFirstResponder(nil); window.orderOut(nil); window.contentView = nil; window.close()
            }
        }
        if createsWindow {
            try await externalInteraction(in: window, kind: "client-ready", phase: "initial-client-ready",
                expectedLabels: state.keys, requiredLabels: [state.keys[0]])
        }
        let admissionDeadline = ContinuousClock.now + .seconds(10)
        while !foregroundIsAdmitted(in: window) && ContinuousClock.now < admissionDeadline {
            commitApplicationDisplayCycle(in: window)
            try await Task.sleep(for: .milliseconds(20))
        }
        drainPendingApplicationEvents()
        try requireForeground(in: window)
        try await waitForNativeOutcome(in: window) { !self.descendants(host, NSScrollView.self).isEmpty }
        XCTAssertTrue(window.contentView === host && host.window === window
            && host.bounds.width > 0 && host.bounds.height > 0)
        // Native focus and AX graphs commit after the hosting view's first
        // layout; merely finding an allocated scroll view is not admission.
        try await Task.sleep(for: .milliseconds(200))
        commitApplicationDisplayCycle(in: window)
        try requireForeground(in: window)
        NativeFixtureDiagnostics.emit("NATIVE_NAV_FOREGROUND_ADMITTED window=\(window.windowNumber) \(foregroundDescription(in: window))")
        return Fixture(state: state, window: window, host: host, scroll: try XCTUnwrap(descendants(host, NSScrollView.self).first))
    }
    private func key(_ code: UInt16, shift: Bool = false, in window: NSWindow) throws {
        try requireForeground(in: window)
        let text = code == 48 ? (shift ? "\u{19}" : "\t") : " "
        for phase in [NSEvent.EventType.keyDown, .keyUp] {
            try requireForeground(in: window)
            // Let the admitted NSApplication loop dispatch after this task
            // yields, rather than reentering SwiftUI during a focus update.
            NSApp.postEvent(try XCTUnwrap(NSEvent.keyEvent(with: phase, location: .zero, modifierFlags: shift ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)), atStart: false)
        }
        try requireForeground(in: window)
    }
    private enum BoundaryDestination: CustomStringConvertible {
        case outside
        case row(Int)
        var description: String {
            switch self { case .outside: "outside"; case let .row(index): "row(\(index))" }
        }
        func key(in keys: [String]) throws -> String {
            switch self {
            case .outside: return "outside"
            case let .row(index): return try XCTUnwrap(keys.indices.contains(index) ? keys[index] : nil)
            }
        }
    }
    private func admitKeys(_ f: Fixture) async throws -> BoundaryDestination {
        commitApplicationDisplayCycle(in: f.window)
        let keys = f.state.keys
        f.state.requested = keys[0]
        try await waitForNativeOutcome(in: f.window, baseline: "keyboard focus/activation route") { f.state.focused == keys[0] }
        try key(49, in: f.window)
        try await waitForNativeOutcome(in: f.window, baseline: "keyboard focus/activation route") { f.state.activated == [keys[0]] }
        try key(48, in: f.window)
        for _ in 0..<50 where f.state.focused != keys[1] {
            try requireForeground(in: f.window)
            try await Task.sleep(for: .milliseconds(10))
        }
        guard f.state.focused == keys[1] else {
            print("NATIVE_NAV_EAGER_KEY_UNAVAILABLE focused=\(String(describing: f.state.focused)) key=\(f.window.isKeyWindow) fullKeyboardAccess=\(NSApp.isFullKeyboardAccessEnabled) responder=\(String(describing: f.window.firstResponder.map { String(describing: type(of: $0)) }))")
            throw XCTSkip("Actual eager Tab event route unavailable; grouped keyboard parity is UNVERIFIED")
        }
        try key(48, shift: true, in: f.window)
        try await waitForNativeOutcome(in: f.window, baseline: "keyboard focus/activation route") { f.state.focused == keys[0] }
        f.state.requested = keys.last
        try await waitForNativeOutcome(in: f.window, baseline: "keyboard focus/activation route") { f.state.focused == keys.last }
        try key(48, in: f.window)
        try await waitForNativeOutcome(in: f.window, baseline: "last-row Tab destination") {
            f.state.focused != nil && f.state.focused != keys.last
        }
        let observed = try XCTUnwrap(f.state.focused)
        let destination: BoundaryDestination
        if observed == "outside" {
            destination = .outside
        } else if let index = keys.firstIndex(of: observed) {
            destination = .row(index)
        } else {
            throw XCTSkip("Actual eager Tab destination is not a known native control; grouped boundary parity is UNVERIFIED")
        }
        // A focus callback alone is insufficient: Space must activate the exact
        // different control reached by the real queued Tab. Eager ScrollView may
        // wrap to its first row instead of leaving the scroll view entirely.
        let priorActivations = f.state.activated
        try key(49, in: f.window)
        try await waitForNativeOutcome(in: f.window, baseline: "observed boundary Space activation") {
            f.state.activated == priorActivations + [observed]
        }
        NativeFixtureDiagnostics.emit("NATIVE_NAV_EAGER_BOUNDARY_ADMITTED direction=forward destination=\(destination) actualTab=true actualSpace=true")
        return destination
    }

    /// One admitted foreground lease and one native window cover all keyboard,
    /// row-owner and actual AX parity checks. Each fixture replaces its host and
    /// observable state; no result or control identity leaks between exercises.
    func testActualNativeNavigationAndAccessibilityParity() async throws {
        _ = try externalDirectory()
        try await withNativeApplicationLoop {
            try await self.exerciseActualTabEventsWalkAuthoritativeRowsAndSplitControlsAfterCrossOwnerReorder()
            try await self.exerciseActualTabEventsPreserveOuterControlsBetweenPinnedAndTodaySections()
            try await self.exerciseActualNativeButtonTabEligibility()
            try await self.exerciseOuterControlScopeExclusions()
            try await self.exerciseDeferredNativeFocusLeaseGuards()
            try await self.exerciseAnyAXChildrenClientPreservesOwnersAndEditorAndCanPressRealizedDistantControl()
        }
    }

    private func exerciseActualNativeButtonTabEligibility() async throws {
        let eager = try await fixture(grouped: false, divided: true, nativeButtons: true)
        let includesRowButton = try await nativeButtonProbe(in: eager, from: 0,
            nativeKey: "\(eager.state.rows[0].id)/native", next: 1, expectedNative: nil)
        let includesTidy = try await nativeButtonProbe(in: eager, from: 49,
            nativeKey: "tidy", next: 50, expectedNative: nil)
        if !NSApp.isFullKeyboardAccessEnabled {
            XCTAssertFalse(includesRowButton, "Eager native row Buttons remain skipped without Full Keyboard Access")
            XCTAssertFalse(includesTidy, "Eager native outer Buttons remain skipped without Full Keyboard Access")
        }
        let candidate = try await fixture(grouped: true, divided: true, nativeButtons: true, reusing: eager.window)
        _ = try await nativeButtonProbe(in: candidate, from: 0,
            nativeKey: "\(candidate.state.rows[0].id)/native", next: 1, expectedNative: includesRowButton)
        _ = try await nativeButtonProbe(in: candidate, from: 49,
            nativeKey: "tidy", next: 50, expectedNative: includesTidy)
        NativeFixtureDiagnostics.emit("NATIVE_NAV_NATIVE_BUTTON_PARITY_VERIFIED fullKeyboardAccess=\(NSApp.isFullKeyboardAccessEnabled) includesRowButton=\(includesRowButton) includesTidy=\(includesTidy) actualSpace=true")
    }

    private func nativeButtonProbe(in fixture: Fixture, from index: Int, nativeKey: String,
                                   next nextIndex: Int, expectedNative: Bool?) async throws -> Bool {
        let before = "\(fixture.state.rows[index].id)/0"
        let next = "\(fixture.state.rows[nextIndex].id)/0"
        let baseline = expectedNative == nil ? "native Button Tab/Space route" : nil
        fixture.state.requested = before
        try await waitForNativeOutcome(in: fixture.window, baseline: baseline) { fixture.state.focused == before }
        try key(48, in: fixture.window)
        try await waitForNativeOutcome(in: fixture.window, baseline: baseline) {
            if let expectedNative { return fixture.state.focused == (expectedNative ? nativeKey : next) }
            return fixture.state.focused == nativeKey || fixture.state.focused == next
        }
        let destination = try XCTUnwrap(fixture.state.focused)
        let prior = fixture.state.activated
        try key(49, in: fixture.window)
        try await waitForNativeOutcome(in: fixture.window, baseline: baseline) {
            fixture.state.activated == prior + [destination]
        }
        return destination == nativeKey
    }

    @MainActor private final class LeaseButton: NSButton {
        var receivedTabs = 0
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 48 { receivedTabs += 1 }
            else { super.keyDown(with: event) }
        }
    }
    @MainActor private final class LeaseHost: NSView {
        override var acceptsFirstResponder: Bool { true }
    }
    private func finishQueuedFocusDelivery() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
    /// Contract checks use actual AppKit responders while holding destination
    /// registration. The application/foreground lease is the same real one used
    /// by the SwiftUI parity checks; these are not presentation/FPS measurements.
    private func exerciseDeferredNativeFocusLeaseGuards() async throws {
        let fixture = try await self.fixture(grouped: true)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 180, height: 180))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 180))
        scroll.documentView = document
        fixture.host.addSubview(scroll)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: Look.rowHeight))
        let host = LeaseHost(frame: container.bounds)
        let rowAnchor = NSView(frame: host.bounds)
        container.addSubview(host); host.addSubview(rowAnchor); document.addSubview(container)
        let source = LeaseButton(frame: NSRect(x: 0, y: 100, width: 80, height: 30))
        let other = LeaseButton(frame: NSRect(x: 90, y: 100, width: 80, height: 30))
        source.title = "Source"; other.title = "Other"
        document.addSubview(source); document.addSubview(other)
        let field = NSTextField(string: "Intervening real field editor")
        field.frame = NSRect(x: 0, y: 140, width: 170, height: 24)
        document.addSubview(field)
        let transferWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 100, height: 80),
                                      styleMask: .titled, backing: .buffered, defer: false)
        transferWindow.title = "Native focus lease transfer"
        transferWindow.isReleasedWhenClosed = false
        let navigation = NativeSidebarNavigation()
        let rowToken = UUID(), outerToken = UUID()
        var delivered = 0, outerDelivered = 0
        var prepared: [String?] = []
        navigation.configure(rows: ["held"], container: container,
                             prepareRow: { prepared.append($0) }, nativeRows: { [] })
        defer {
            navigation.detach()
            NativeSidebarNavigation.unregisterOuter(token: outerToken)
            transferWindow.close()
            scroll.removeFromSuperview()
        }
        func registerDestination() {
            navigation.register(token: rowToken, row: "held", anchor: rowAnchor, enabled: true) {
                delivered += 1
                navigation.focusChanged(true, token: rowToken)
            }
        }
        for scenario in ["button", "editor", "window"] {
            navigation.unregister(token: rowToken)
            XCTAssertTrue(fixture.window.makeFirstResponder(source))
            navigation.requestFocus(token: rowToken, row: "held")
            // The original request has no registered destination yet. Change
            // native ownership before its late registration/layout can complete.
            switch scenario {
            case "button": XCTAssertTrue(fixture.window.makeFirstResponder(other))
            case "editor":
                XCTAssertTrue(fixture.window.makeFirstResponder(field))
                XCTAssertTrue(fixture.window.firstResponder is NSTextView)
            default: transferWindow.makeKeyAndOrderFront(nil); transferWindow.makeKey()
            }
            let interveningResponder = fixture.window.firstResponder
            registerDestination()
            navigation.layoutDidCommit()
            await finishQueuedFocusDelivery()
            XCTAssertEqual(delivered, 0, "Late destination registration cannot steal the \(scenario) focus handoff")
            XCTAssertTrue(fixture.window.firstResponder === interveningResponder)
            XCTAssertNil(prepared.last.flatMap { $0 }, "Cancelled focus must release its pending row keepalive")
            if scenario == "window" {
                XCTAssertTrue(transferWindow.isKeyWindow)
                transferWindow.orderOut(nil)
                fixture.window.makeKeyAndOrderFront(nil); fixture.window.makeKey()
            }
        }
        try requireForeground(in: fixture.window)
        XCTAssertTrue(fixture.window.makeFirstResponder(source))
        navigation.requestFocus(token: rowToken, row: "held")
        registerDestination()
        await finishQueuedFocusDelivery()
        XCTAssertEqual(delivered, 1, "An unchanged valid native source must still deliver its focus request")
        XCTAssertTrue(fixture.window.firstResponder === host)

        NativeSidebarNavigation.registerOuter(token: outerToken, anchor: source, enabled: true) {
            outerDelivered += 1
            XCTAssertTrue(fixture.window.makeFirstResponder(source))
            NativeSidebarNavigation.outerFocusChanged(true, token: outerToken)
        }
        navigation.focusChanged(true, token: rowToken)
        XCTAssertTrue(navigation.move(from: rowToken, backwards: false))
        XCTAssertTrue(fixture.window.makeFirstResponder(other))
        await finishQueuedFocusDelivery()
        XCTAssertEqual(outerDelivered, 0, "Queued outer delivery cannot steal an intervening native Button")
        XCTAssertTrue(fixture.window.firstResponder === other)

        XCTAssertTrue(fixture.window.makeFirstResponder(host))
        navigation.focusChanged(true, token: rowToken)
        XCTAssertTrue(navigation.move(from: rowToken, backwards: false))
        await finishQueuedFocusDelivery()
        XCTAssertEqual(outerDelivered, 1)
        XCTAssertTrue(fixture.window.firstResponder === source)
        // Deliberately leave the old SwiftUI acknowledgement pending. The exact
        // actual native responder changed, so this token no longer owns Tab.
        XCTAssertTrue(fixture.window.makeFirstResponder(other))
        XCTAssertFalse(NativeSidebarNavigation.moveOuter(from: outerToken, backwards: false))
        try key(48, in: fixture.window)
        try await waitForNativeOutcome(in: fixture.window) { other.receivedTabs == 1 }
        XCTAssertTrue(fixture.window.firstResponder === other)
        XCTAssertEqual(outerDelivered, 1)
        NativeFixtureDiagnostics.emit("NATIVE_NAV_FOCUS_LEASE_GUARDS_VERIFIED button=true editor=true window=true outerDelivery=true actualStaleOuterTab=true validDelivery=true")
    }

    private func exerciseOuterControlScopeExclusions() async throws {
        let fixture = try await self.fixture(grouped: true)
        let document = try XCTUnwrap(fixture.scroll.documentView)
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: Look.rowHeight))
        document.addSubview(anchor)
        let token = UUID()
        defer {
            NativeSidebarNavigation.unregisterOuter(token: token)
            anchor.removeFromSuperview()
        }
        NativeSidebarNavigation.registerOuter(token: token, anchor: anchor, enabled: false) {
            XCTFail("An excluded outer control must not receive a focus request")
        }
        XCTAssertFalse(NativeSidebarNavigation.moveOuter(from: token, backwards: false), "Disabled controls cannot enter logical Tab order")
        NativeSidebarNavigation.registerOuter(token: token, anchor: anchor, enabled: true) {
            XCTFail("An excluded outer control must not receive a focus request")
        }
        anchor.isHidden = true
        XCTAssertFalse(NativeSidebarNavigation.moveOuter(from: token, backwards: false), "Hidden controls cannot enter logical Tab order")
        anchor.isHidden = false
        let otherWindow = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        defer { otherWindow.close() }
        XCTAssertFalse(NativeSidebarNavigation.moveOuter(from: token, backwards: false, in: otherWindow), "A different event window cannot use this outline")
        let otherScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let otherDocument = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        otherScroll.documentView = otherDocument
        fixture.host.addSubview(otherScroll)
        defer { otherScroll.removeFromSuperview() }
        otherDocument.addSubview(anchor)
        XCTAssertFalse(NativeSidebarNavigation.moveOuter(from: token, backwards: false), "Another scroll view cannot join a native outline in the same window")
        document.addSubview(anchor)
        let field = NSTextField(string: "Native editor guard")
        field.frame = NSRect(x: 0, y: 0, width: 100, height: Look.rowHeight)
        document.addSubview(field)
        defer { field.removeFromSuperview() }
        XCTAssertTrue(fixture.window.makeFirstResponder(field))
        XCTAssertTrue(fixture.window.firstResponder is NSTextView)
        XCTAssertFalse(NativeSidebarNavigation.moveOuter(from: token, backwards: false), "The actual native field editor keeps Tab")
        fixture.window.makeFirstResponder(nil)
        anchor.removeFromSuperview()
        XCTAssertFalse(NativeSidebarNavigation.moveOuter(from: token, backwards: false), "Detached controls cannot join a native outline")
        NativeFixtureDiagnostics.emit("NATIVE_NAV_SCOPE_EXCLUSIONS_VERIFIED disabled=true hidden=true wrongWindow=true wrongScroll=true editor=true detached=true")
    }

    private func exerciseActualTabEventsPreserveOuterControlsBetweenPinnedAndTodaySections() async throws {
        let eager = try await fixture(grouped: false, divided: true)
        try await exerciseInterstitialControl(in: eager, admittingBaseline: true)
        let candidate = try await fixture(grouped: true, divided: true, reusing: eager.window)
        try await exerciseInterstitialControl(in: candidate, admittingBaseline: false)
    }

    private func exerciseInterstitialControl(in fixture: Fixture, admittingBaseline: Bool) async throws {
        let before = "\(fixture.state.rows[49].id)/0"
        let after = "\(fixture.state.rows[50].id)/0"
        fixture.state.requested = before
        try await waitForNativeOutcome(in: fixture.window, baseline: admittingBaseline ? "interstitial focus/Space/Tab route" : nil) { fixture.state.focused == before }
        try key(48, in: fixture.window)
        if admittingBaseline {
            for _ in 0..<50 where fixture.state.focused != "tidy" {
                try requireForeground(in: fixture.window)
                commitApplicationDisplayCycle(in: fixture.window)
                try await Task.sleep(for: .milliseconds(10))
            }
            guard fixture.state.focused == "tidy" else {
                throw XCTSkip("Actual eager interstitial Tab route unavailable; grouped section-boundary parity is UNVERIFIED")
            }
        } else {
            try await waitForNativeOutcome(in: fixture.window, baseline: admittingBaseline ? "interstitial focus/Space/Tab route" : nil) { fixture.state.focused == "tidy" }
        }
        try key(49, in: fixture.window)
        try await waitForNativeOutcome(in: fixture.window, baseline: admittingBaseline ? "interstitial focus/Space/Tab route" : nil) { fixture.state.activated == ["tidy"] }
        try key(48, in: fixture.window)
        try await waitForNativeOutcome(in: fixture.window, baseline: admittingBaseline ? "interstitial focus/Space/Tab route" : nil) { fixture.state.focused == after }
        try key(48, shift: true, in: fixture.window)
        try await waitForNativeOutcome(in: fixture.window, baseline: admittingBaseline ? "interstitial focus/Space/Tab route" : nil) { fixture.state.focused == "tidy" }
        try key(48, shift: true, in: fixture.window)
        try await waitForNativeOutcome(in: fixture.window, baseline: admittingBaseline ? "interstitial focus/Space/Tab route" : nil) { fixture.state.focused == before }
    }

    private func exerciseActualTabEventsWalkAuthoritativeRowsAndSplitControlsAfterCrossOwnerReorder() async throws {
        let eager = try await fixture(grouped: false)
        let expectedBoundary = try await admitKeys(eager)
        let f = try await fixture(grouped: true, reusing: eager.window)
        var keys = f.state.keys
        commitApplicationDisplayCycle(in: f.window)
        f.state.requested = keys[0]
        try await waitForNativeOutcome(in: f.window) { f.state.focused == keys[0] }
        for index in 1...40 {
            try key(48, in: f.window)
            try await waitForNativeOutcome(in: f.window) { f.state.focused == keys[index] }
            XCTAssertEqual(f.scroll.contentView.bounds.minX, 0, accuracy: 0.01)
        }
        for index in stride(from: 39, through: 0, by: -1) {
            try key(48, shift: true, in: f.window)
            try await waitForNativeOutcome(in: f.window) { f.state.focused == keys[index] }
        }
        try await externalInteraction(in: f.window, kind: "scroll-bottom", phase: "keyboard-far-scroll",
            expectedLabels: f.state.keys, requiredLabels: [try XCTUnwrap(f.state.keys.last)])
        XCTAssertGreaterThan(f.scroll.contentView.bounds.minY, 1000)
        try key(48, in: f.window)
        try await waitForNativeOutcome(in: f.window) { f.state.focused == keys[1] && f.scroll.contentView.bounds.minY < 100 }
        // Bring a row from owner 2 between two owner-0 rows. Stable owners now
        // interleave in authoritative geometry; sorting whole roots is wrong.
        let moved = f.state.rows.remove(at: 17)
        f.state.rows.insert(moved, at: 2)
        keys = f.state.keys
        try await Task.sleep(for: .milliseconds(100))
        for index in 2...5 {
            try key(48, in: f.window)
            try await waitForNativeOutcome(in: f.window) { f.state.focused == keys[index] }
        }
        f.state.requested = keys.last
        try await waitForNativeOutcome(in: f.window) { f.state.focused == keys.last }
        try key(48, in: f.window)
        let destinationKey = try expectedBoundary.key(in: keys)
        try await waitForNativeOutcome(in: f.window) { f.state.focused == destinationKey }
        try key(49, in: f.window)
        try await waitForNativeOutcome(in: f.window) { f.state.activated == [destinationKey] }
        NativeFixtureDiagnostics.emit("NATIVE_NAV_CANDIDATE_BOUNDARY_MATCHED direction=forward destination=\(expectedBoundary) actualTab=true actualSpace=true")
    }

    private func exerciseAnyAXChildrenClientPreservesOwnersAndEditorAndCanPressRealizedDistantControl() async throws {
        // Keep this functional AX query below the external client's 100-item
        // paging boundary. Keyboard traversal still uses 100 rows; presentation
        // timing is measured separately in the browser with 100 real websites.
        let eager = try await fixture(grouped: false, rowCount: 80)
        let eagerLast = try XCTUnwrap(eager.state.keys.last)
        try await externalInteraction(in: eager.window, kind: "scroll-bottom-press", phase: "eager-ax-press",
            expectedLabels: eager.state.keys, requiredLabels: [eagerLast], targetLabel: eagerLast)
        XCTAssertGreaterThan(eager.scroll.contentView.bounds.minY, 1000)
        try await waitForNativeOutcome(in: eager.window) { eager.state.activated == [eagerLast] }
        let f = try await fixture(grouped: true, rowCount: 80, reusing: eager.window)
        let owner = try XCTUnwrap(descendants(f.host, NativeCachedSidebarBatchesView<ControlRow>.self).first)
        XCTAssertFalse(owner.accessibilityRowsExpanded)
        let editedID = f.state.rows[3].id
        f.state.editing = editedID
        try await waitForNativeOutcome(in: f.window) { f.state.fields[editedID]?.value?.window === f.window }
        let field = try XCTUnwrap(f.state.fields[editedID]?.value)
        XCTAssertTrue(f.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(f.window.firstResponder as? NSTextView)
        editor.string = "Draft retained during accessibility queries"
        let originalHosts = owner.subviews
        let last = try XCTUnwrap(f.state.keys.last)
        _ = owner.accessibilityChildren()
        XCTAssertFalse(owner.accessibilityRowsExpanded, "Match eager visible-AX semantics without mounting the entire outline")
        XCTAssertTrue(originalHosts.allSatisfy { old in owner.subviews.contains { $0 === old } }, "AX queries must preserve the original hosting owners")
        XCTAssertTrue(f.state.fields[editedID]?.value === field)
        XCTAssertTrue(f.window.firstResponder === editor, "An AX query must preserve the real active field editor")
        XCTAssertEqual(editor.string, "Draft retained during accessibility queries")
        let moved = f.state.rows.remove(at: 17)
        f.state.rows.insert(moved, at: 2)
        try await waitForNativeOutcome(in: f.window) {
            guard let anchor = owner.nativeRowsInAuthoritativeOrder().first(where: { $0.0 == moved.id })?.1 else { return false }
            return abs(anchor.convert(anchor.bounds, to: owner).minY - 2 * (Look.rowHeight + Look.rowGap)) < 1
        }
        try await externalInteraction(in: f.window, kind: "query", phase: "grouped-reordered-editor-query",
            expectedLabels: f.state.keys, requiredLabels: ["\(moved.id)/0"])
        XCTAssertFalse(owner.accessibilityRowsExpanded)
        XCTAssertTrue(originalHosts.allSatisfy { old in owner.subviews.contains { $0 === old } })
        XCTAssertTrue(f.state.fields[editedID]?.value === field)
        XCTAssertTrue(f.window.firstResponder === editor)
        XCTAssertEqual(editor.string, "Draft retained during accessibility queries")
        try await externalInteraction(in: f.window, kind: "scroll-bottom-press", phase: "grouped-ax-press",
            expectedLabels: f.state.keys, requiredLabels: [last], targetLabel: last)
        XCTAssertGreaterThan(f.scroll.contentView.bounds.minY, 1000)
        try await waitForNativeOutcome(in: f.window) { f.state.activated == [last] }
        XCTAssertFalse(owner.accessibilityRowsExpanded)
        let deleted = f.state.rows.removeLast()
        try await waitForNativeOutcome(in: f.window) {
            !owner.nativeRowsInAuthoritativeOrder().contains { $0.0 == deleted.id }
        }
        let remaining = try XCTUnwrap(f.state.keys.last)
        try await externalInteraction(in: f.window, kind: "query", phase: "grouped-deleted-query",
            expectedLabels: f.state.keys, requiredLabels: [remaining], forbiddenLabels: ["\(deleted.id)/0"])
        XCTAssertFalse(owner.accessibilityRowsExpanded)
        NativeFixtureDiagnostics.emit("NATIVE_NAV_EXTERNAL_AX_PARITY_VERIFIED eagerPress=true reorderedEditor=true groupedPress=true deletion=true")

    }
}
