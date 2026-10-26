import AppKit
import SwiftUI
import XCTest
@testable import vane

/// Native AX-route parity, not a requirement that offscreen rows stay mounted.
/// An unavailable OFF route is an explicit prerequisite rejection, never evidence
/// that buffering broke accessibility or that this gate passed.
@MainActor final class BufferedSidebarAccessibilityTests: XCTestCase {
    private struct RouteUnavailable: Error { let detail: String }
    private struct RouteFailure: Error { let detail: String }

    private func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, type) }
    }
    private func require(_ valid: Bool, _ detail: String) throws {
        guard valid else { XCTFail(detail); throw RouteFailure(detail: detail) }
    }

    // Public Objective-C accessibility getters also support objects which expose
    // the informal protocol without declaring NSAccessibilityProtocol conformance.
    private func get(_ object: NSObject, _ getter: String) -> Any? {
        let selector = NSSelectorFromString(getter)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }
    private func label(_ object: NSObject) -> String {
        (get(object, "accessibilityLabel") as? String)
            ?? (object.accessibilityAttributeValue(.description) as? String)
            ?? (get(object, "accessibilityValue") as? String) ?? ""
    }
    private func axObjects(_ root: NSObject) -> [NSObject] {
        var result: [NSObject] = [], pending = [root], seen = Set<ObjectIdentifier>()
        while let next = pending.popLast(), result.count < 4_096 {
            guard seen.insert(ObjectIdentifier(next)).inserted else { continue }
            result.append(next)
            for getter in ["accessibilityChildrenInNavigationOrder", "accessibilityChildren",
                           "accessibilityVisibleChildren", "accessibilityContents"] {
                if let children = get(next, getter) as? [NSObject] { pending.append(contentsOf: children) }
            }
            if let children = next.accessibilityAttributeValue(.children) as? [NSObject] {
                pending.append(contentsOf: children)
            }
        }
        return result
    }
    private func tabAnchor(_ title: String, in root: NSView) -> TabTooltipAnchorView? {
        descendants(root, TabTooltipAnchorView.self).first {
            $0.title == title && !$0.isHiddenOrHasHiddenAncestor
                && $0.visibleRect.intersection($0.bounds).height > Look.rowHeight / 2
        }
    }
    private func rowAX(_ title: String, host: NSView) -> NSObject? {
        var candidates = axObjects(host)
        // Public AX hit testing can return the actual SwiftUI element even when
        // the NSHostingView's direct children getter flattens its representation.
        if let anchor = tabAnchor(title, in: host), let window = host.window {
            let local = anchor.convert(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: nil)
            var next = host.accessibilityHitTest(window.convertPoint(toScreen: local)) as? NSObject
            var seen = Set<ObjectIdentifier>()
            while let current = next, seen.insert(ObjectIdentifier(current)).inserted, seen.count < 32 {
                candidates.insert(current, at: 0)
                next = get(current, "accessibilityParent") as? NSObject
            }
        }
        return candidates.first { label($0) == title && canPress($0) }
    }
    private func canPress(_ object: NSObject) -> Bool {
        if let element = object as? any NSAccessibilityProtocol,
           element.isAccessibilityElement(), element.accessibilityRole() == .button { return true }
        return object.accessibilityActionNames().contains(.press)
    }
    private func press(_ object: NSObject) -> Bool {
        if let element = object as? any NSAccessibilityProtocol { return element.accessibilityPerformPress() }
        guard object.accessibilityActionNames().contains(.press) else { return false }
        object.accessibilityPerformAction(.press)
        return true // The caller must also verify the actual resulting state.
    }
    private func namedAction(_ name: String, object: NSObject) -> NSAccessibilityCustomAction? {
        (get(object, "accessibilityCustomActions") as? [NSAccessibilityCustomAction])?.first { $0.name == name }
    }
    private func perform(_ action: NSAccessibilityCustomAction) -> Bool {
        if let handler = action.handler { return handler() }
        guard let target = action.target as? NSObject, let selector = action.selector,
              target.responds(to: selector), let implementation = target.method(for: selector) else { return false }
        // These are the two public signatures documented by NSAccessibilityCustomAction.
        if NSStringFromSelector(selector).hasSuffix(":") {
            typealias WithAction = @convention(c) (AnyObject, Selector, AnyObject) -> ObjCBool
            return unsafeBitCast(implementation, to: WithAction.self)(target, selector, action).boolValue
        }
        typealias WithoutAction = @convention(c) (AnyObject, Selector) -> ObjCBool
        return unsafeBitCast(implementation, to: WithoutAction.self)(target, selector).boolValue
    }

    private func traverse(scroll: NSScrollView, host: NSView, to title: String,
                          forward: Bool, forbidden: Set<String>) async throws -> Set<String> {
        guard let bar = scroll.accessibilityVerticalScrollBar() as? any NSAccessibilityProtocol,
              bar.accessibilityRole() == .scrollBar else {
            throw RouteUnavailable(detail: "the native scroll area exposes no public vertical AX scrollbar")
        }
        var observed = Set<String>()
        for step in 0..<600 {
            let objects = axObjects(host)
            let labels = Set(objects.map(label))
            try require(labels.isDisjoint(with: forbidden), "AX exposed a locked/collapsed descendant during traversal")
            // Collect only actual AX-labelled row objects, never tooltip metadata.
            observed.formUnion(labels)
            if tabAnchor(title, in: host) != nil {
                guard rowAX(title, host: host) != nil else {
                    throw RouteUnavailable(detail: "the destination is painted but its actual row AX object is unavailable")
                }
                return observed
            }
            let previous = scroll.contentView.bounds.minY
            let accepted = forward ? bar.accessibilityPerformIncrement() : bar.accessibilityPerformDecrement()
            guard accepted else { throw RouteUnavailable(detail: "the native AX scrollbar rejected \(forward ? "increment" : "decrement") at step \(step)") }
            let deadline = ContinuousClock.now + .seconds(2)
            while abs(scroll.contentView.bounds.minY - previous) < 0.5, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard abs(scroll.contentView.bounds.minY - previous) >= 0.5 else {
                throw RouteUnavailable(detail: "the accepted native AX action did not move its clip viewport")
            }
            try await Task.sleep(for: .milliseconds(20)) // Allow coalesced realization/AX publication.
        }
        throw RouteUnavailable(detail: "the public native AX route did not reach its destination within 600 actions")
    }

    func testNativeAXScrollTraversalMatchesUnbufferedSidebarAndRespectsProtection() async throws {
        useLegacySidebarMountingPolicy()
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let flag = "VANE_EXPERIMENT_BUFFERED_SIDEBAR"
        let previousFlag = ProcessInfo.processInfo.environment[flag]
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer {
            if let previousFlag { setenv(flag, previousFlag, 1) } else { unsetenv(flag) }
            NSApp.setActivationPolicy(policy)
        }
        let store = TabStore(isPrivate: true, session: [])
        store.sharingReady = false
        store.folderAuthentication = FolderAuthentication { _, reply in reply(true); return nil }
        let nonce = UUID().uuidString
        let tabs: [vane.Tab] = (0..<100).map { index in
            let tab = Tab(isPrivate: true, profileID: store.profileID)
            tab.park(url: URL(string: "about:blank#ax-buffer-\(nonce)-\(index)")!,
                     Parked(title: "AX row \(index) \(nonce.prefix(4))", needsRecovery: true))
            return tab
        }
        let locked = Folder(name: "AX protected group", requiresAuthentication: true)
        let collapsed = Folder(name: "AX collapsed group", collapsed: true)
        let titles = tabs.map { TidyTitles.title(for: $0) }
        let forbidden = Set([titles[46], titles[47], titles[71], titles[72]])
        let expected = Set(titles).subtracting(forbidden)
        var entries: [Pins.Entry] = []
        for index in tabs.indices {
            if index == 46 { entries.append(.init(row: .folder(locked))) }
            if index == 71 { entries.append(.init(row: .folder(collapsed))) }
            let parent = (46...47).contains(index) ? locked.id : ((71...72).contains(index) ? collapsed.id : nil)
            entries.append(.init(row: .tab(tabs[index].id.uuidString), parent: parent))
        }
        store.tabs = tabs; store.pins = Pins(entries: [])
        store.todayShape = Pins(entries: entries); store.palette = nil
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 270, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        addTeardownBlock { @MainActor in
            store.spaceGesture.monitor.remove(); store.librarySwipeMonitor.remove()
            window.orderOut(nil); window.contentView = nil; window.close(); store.window = nil
            tabs.forEach { TidyTitles.rename($0, to: nil); $0.tearDown() }
            store.dropStashes(); SharedTabs.release(tabs)
            TabStore.all.removeAll { $0 === store }
        }
        var baselineObserved = Set<String>()
        for buffered in [false, true] {
            window.contentView = nil
            setenv(flag, buffered ? "1" : "0", 1)
            let host = NSHostingView(rootView: SidebarSpaceSections().environmentObject(store)
                .environmentObject(ProfileManager.shared).font(Look.text))
            window.contentView = host
            // Native AX getters/actions are valid for an inactive application.
            // This gate does not type into an editor or measure foreground cadence.
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            try await compatibilityWait {
                window.isVisible && window.contentView === host && host.window === window
                    && !host.isHiddenOrHasHiddenAncestor && host.bounds.width > 0 && host.bounds.height > 0
            }
            try await compatibilityWait { SidebarSectionsViewport.scrollView(in: host) != nil }
            let scroll = try XCTUnwrap(SidebarSectionsViewport.scrollView(in: host))
            try await compatibilityWait { self.tabAnchor(titles[0], in: host) != nil }
            do {
                guard let first = rowAX(titles[0], host: host) else {
                    throw RouteUnavailable(detail: "the first real TabRow has no readable/pressable native AX object")
                }
                try require(press(first), "Actual first-row AXPress was rejected")
                try await compatibilityWait { store.current == tabs[0].id }
                var observed = try await traverse(scroll: scroll, host: host, to: titles[99],
                                                   forward: true, forbidden: forbidden)
                let last = try XCTUnwrap(rowAX(titles[99], host: host))
                try require(press(last), "Actual last-row AXPress was rejected")
                try await compatibilityWait { store.current == tabs[99].id }
                guard let activeLast = rowAX(titles[99], host: host),
                      let rename = namedAction("Rename Tab", object: activeLast) else {
                    throw RouteUnavailable(detail: "the realized TabRow exposes no public Rename Tab custom action")
                }
                try require(perform(rename), "Actual Rename Tab AX action was rejected")
                try await compatibilityWait { store.renamingTab == tabs[99].id }
                store.renamingTab = nil
                observed.formUnion(try await traverse(scroll: scroll, host: host, to: titles[0],
                                                      forward: false, forbidden: forbidden))
                try require(expected.isSubset(of: observed), "AX scroll traversal skipped authorized logical row labels")
                if buffered {
                    try require(expected.intersection(observed) == expected.intersection(baselineObserved),
                                "Buffered AX traversal differed from the valid native baseline")
                } else { baselineObserved = observed }
                print("BUFFERED_AX_PARITY buffered=\(buffered) authorized_rows=\(expected.count) actual_AX_rows_reached=\(expected.intersection(observed).count) native_offset=\(scroll.contentView.bounds.minY)")
            } catch let unavailable as RouteUnavailable {
                if !buffered {
                    print("BUFFERED_AX_PREREQUISITE_UNAVAILABLE \(unavailable.detail)")
                    throw XCTSkip("Unbuffered native AX route unavailable; parity is unverified: \(unavailable.detail)")
                }
                XCTFail("The valid OFF AX route became unavailable with buffering: \(unavailable.detail)")
                throw unavailable
            }
        }
    }
}
