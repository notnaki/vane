import AppKit
import SwiftUI

/// One native hosting owner is not one logical keyboard/AX group. Owners can
/// interleave after reorder; navigation always uses the current authorized rows.
@MainActor final class NativeSidebarNavigation {
    private final class WeakNavigation {
        weak var value: NativeSidebarNavigation?
        init(_ value: NativeSidebarNavigation) { self.value = value }
    }
    private final class Control {
        let token: UUID
        var row: String
        weak var anchor: NSView?
        var enabled: Bool
        var request: @MainActor () -> Void
        init(token: UUID, row: String, anchor: NSView, enabled: Bool, request: @escaping @MainActor () -> Void) {
            self.token = token; self.row = row; self.anchor = anchor; self.enabled = enabled; self.request = request
        }
    }
    private final class OuterControl {
        let token: UUID
        weak var anchor: NSView?
        var enabled: Bool
        weak var focusedResponder: NSResponder?
        weak var focusedWindow: NSWindow?
        var request: @MainActor () -> Void
        init(token: UUID, anchor: NSView, enabled: Bool, request: @escaping @MainActor () -> Void) {
            self.token = token; self.anchor = anchor; self.enabled = enabled; self.request = request
        }
    }
    private enum Item {
        case row(NativeSidebarNavigation, String)
        case outer(UUID)
    }
    private static var outerControls: [UUID: OuterControl] = [:]
    private static var activeOuterToken: UUID?
    /// A focus request belongs to the native responder that originated it.
    /// Virtualization may finish later; intervening input/focus retires the lease.
    @MainActor private final class FocusLease {
        private weak var window: NSWindow?
        private weak var responder: NSResponder?
        private var bound: Bool
        private var hadResponder: Bool
        private let inputGeneration: UInt64
        init(window: NSWindow?) {
            self.window = window
            responder = window?.firstResponder
            bound = window != nil
            hadResponder = window?.firstResponder != nil
            inputGeneration = NativeSidebarNavigation.inputGeneration
        }
        func isCurrent(in destinationWindow: NSWindow) -> Bool {
            guard inputGeneration == NativeSidebarNavigation.inputGeneration,
                  NSApp.isActive, destinationWindow.isKeyWindow, NSApp.keyWindow === destinationWindow,
                  !(destinationWindow.firstResponder is NSTextView) else { return false }
            if !bound {
                // Initial programmatic requests can precede native attachment.
                // Admit their first attached responder only if no input occurred
                // since the request; all later deliveries use exact ownership.
                window = destinationWindow
                responder = destinationWindow.firstResponder
                hadResponder = destinationWindow.firstResponder != nil
                bound = true
            }
            guard window === destinationWindow else { return false }
            if hadResponder {
                guard let responder else { return false }
                return destinationWindow.firstResponder === responder
            }
            return destinationWindow.firstResponder == nil
        }
    }
    private static var inputGeneration: UInt64 = 0
    private struct Pending {
        let row: String
        let token: UUID?
        let backwards: Bool
        let lease: FocusLease
        var delivered: UUID?
    }
    private static var navigations: [WeakNavigation] = []
    private static var monitor: Any?
    private weak var container: NSView?
    private var rows: [String] = []
    private var controls: [UUID: Control] = [:]
    private var activeToken: UUID?
    private var pending: Pending?
    private var prepareRow: ((String?) -> Void)?
    private var nativeRows: () -> [(String, NSView)] = { [] }
    private var deliveryScheduled = false
    private var readingAccessibility = false
    static let diagnosticsEnabled = ProcessInfo.processInfo.environment["VANE_NATIVE_NAV_DIAGNOSTICS"] == "1"
    private var diagnosticCount = 0

    private func diagnose(_ message: @autoclosure () -> String) {
        guard Self.diagnosticsEnabled, diagnosticCount < 3000 else { return }
        diagnosticCount += 1
        print("NATIVE_NAV \(message())")
    }

    func configure(rows: [String], container: NSView,
                   prepareRow: ((String?) -> Void)? = nil,
                   nativeRows: @escaping () -> [(String, NSView)]) {
        self.container = container
        self.rows = rows
        self.prepareRow = prepareRow
        self.nativeRows = nativeRows
        let authorized = Set(rows)
        controls = controls.filter { authorized.contains($0.value.row) && $0.value.anchor != nil }
        if let activeToken, controls[activeToken] == nil { self.activeToken = nil }
        if let pending, !authorized.contains(pending.row) {
            self.pending = nil
            prepareRow?(nil)
        }
        Self.navigations.removeAll { $0.value == nil }
        if !Self.navigations.contains(where: { $0.value === self }) { Self.navigations.append(WeakNavigation(self)) }
        Self.installMonitor()
        scheduleDelivery()
    }

    private static func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                inputGeneration &+= 1
                guard event.type == .keyDown, event.keyCode == 48,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      let window = event.window,
                      !(window.firstResponder is NSTextView) else { return false }
                for navigation in navigations.compactMap(\.value) where navigation.container?.window === window {
                    if let token = navigation.activeToken,
                       navigation.ownsResponder(token: token, in: window),
                       navigation.move(from: token, backwards: event.modifierFlags.contains(.shift)) { return true }
                }
                if let token = activeOuterToken,
                   moveOuter(from: token, backwards: event.modifierFlags.contains(.shift), in: window) { return true }
                return false
            }
            return consumed ? nil : event
        }
    }

    func register(token: UUID, row: String, anchor: NSView, enabled: Bool,
                  request: @escaping @MainActor () -> Void) {
        guard rows.contains(row) else { return }
        if let current = controls[token] {
            current.row = row; current.anchor = anchor; current.enabled = enabled; current.request = request
        } else {
            controls[token] = Control(token: token, row: row, anchor: anchor, enabled: enabled, request: request)
        }
        if pending?.row == row {
            diagnose("register row=\(row) token=\(token) enabled=\(enabled) frame=\(anchor.frame) bounds=\(anchor.bounds) window=\(anchor.window?.windowNumber ?? -1)")
        }
        scheduleDelivery()
    }
    func unregister(token: UUID) {
        controls.removeValue(forKey: token)
        if activeToken == token { activeToken = nil }
    }
    func focusChanged(_ focused: Bool, token: UUID) {
        diagnose("focusChanged token=\(token) focused=\(focused) pending=\(String(describing: pending?.row)) delivered=\(String(describing: pending?.delivered))")
        if focused {
            Self.activeOuterToken = nil
            activeToken = token
            if pending?.delivered == token {
                pending = nil
                // BufferedSidebarFocus queued its publication before this ack.
                // Keep the requested owner alive until that publication lands.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.pending == nil else { return }
                    self.prepareRow?(nil)
                }
            }
        } else if activeToken == token { activeToken = nil }
    }
    func requestFocus(token: UUID, row: String) {
        diagnose("request row=\(row) token=\(token) authorized=\(rows.contains(row)) controls=\(controls.count) containerWindow=\(container?.window?.windowNumber ?? -1)")
        guard rows.contains(row) else { return }
        pending = Pending(row: row, token: token, backwards: false, lease: FocusLease(window: container?.window))
        prepareRow?(row)
        scheduleDelivery()
    }
    private func ownsResponder(token: UUID, in window: NSWindow) -> Bool {
        guard let container, let anchor = controls[token]?.anchor,
              let responder = window.firstResponder as? NSView else { return false }
        var host = anchor
        while let parent = host.superview, parent !== container { host = parent }
        return host.superview === container && (responder === host || responder.isDescendant(of: host))
    }

    /// Only a focused custom control handles Tab. Logical ordering includes
    /// existing outer controls between native sections; editors stay native.
    @discardableResult func move(from token: UUID, backwards: Bool) -> Bool {
        guard let container, let window = container.window,
              !(window.firstResponder is NSTextView),
              let current = controls[token], current.enabled,
              let anchor = current.anchor, anchor.window === window,
              anchor.isDescendant(of: container), !anchor.isHiddenOrHasHiddenAncestor,
              rows.contains(current.row) else { return false }
        let siblings = orderedControls(row: current.row)
        if let index = siblings.firstIndex(where: { $0.token == token }) {
            let next = backwards ? index - 1 : index + 1
            if siblings.indices.contains(next) {
                requestFocus(token: siblings[next].token, row: current.row)
                return true
            }
        }
        let sequence = Self.orderedItems(in: window, scroll: container.enclosingScrollView)
        guard let index = sequence.firstIndex(where: {
            if case let .row(navigation, row) = $0 { return navigation === self && row == current.row }
            return false
        }) else { return false }
        return Self.deliverNeighbor(in: sequence, index: index, backwards: backwards, window: window)
    }

    static func registerOuter(token: UUID, anchor: NSView, enabled: Bool,
                              request: @escaping @MainActor () -> Void) {
        outerControls = outerControls.filter { $0.value.anchor != nil }
        if let current = outerControls[token] {
            current.anchor = anchor; current.enabled = enabled; current.request = request
        } else {
            outerControls[token] = OuterControl(token: token, anchor: anchor, enabled: enabled, request: request)
        }
    }
    static func unregisterOuter(token: UUID) {
        outerControls.removeValue(forKey: token)
        if activeOuterToken == token { activeOuterToken = nil }
    }
    static func outerFocusChanged(_ focused: Bool, token: UUID) {
        guard let control = outerControls[token] else { return }
        if focused, let window = control.anchor?.window, window.isKeyWindow,
           let responder = window.firstResponder, !(responder is NSTextView) {
            control.focusedWindow = window
            control.focusedResponder = responder
            activeOuterToken = token
        } else {
            control.focusedWindow = nil
            control.focusedResponder = nil
            if activeOuterToken == token { activeOuterToken = nil }
        }
    }
    @discardableResult static func moveOuter(from token: UUID, backwards: Bool, in suppliedWindow: NSWindow? = nil) -> Bool {
        guard let control = outerControls[token], let anchor = control.anchor,
              let window = anchor.window, suppliedWindow == nil || suppliedWindow === window,
              NSApp.isActive, window.isKeyWindow, NSApp.keyWindow === window,
              control.focusedWindow === window, let acknowledgedResponder = control.focusedResponder,
              window.firstResponder === acknowledgedResponder,
              !(acknowledgedResponder is NSTextView) else { return false }
        let sequence = orderedItems(in: window, scroll: anchor.enclosingScrollView)
        guard let index = sequence.firstIndex(where: {
            if case let .outer(candidate) = $0 { return candidate == token }
            return false
        }) else { return false }
        return deliverNeighbor(in: sequence, index: index, backwards: backwards, window: window)
    }
    private static func orderedItems(in window: NSWindow, scroll: NSScrollView?) -> [Item] {
        guard let scroll else { return [] }
        let sections = navigations.compactMap(\.value).filter {
            guard let container = $0.container else { return false }
            return container.window === window && container.enclosingScrollView === scroll
                && !container.isHiddenOrHasHiddenAncestor && !$0.rows.isEmpty
        }
        guard !sections.isEmpty else { return [] }
        // Only Tab constructs this compact logical sequence. Scrolling does not
        // enumerate the model or mount missing row controls. Native section
        // geometry supplies positions even for authorized rows not resident yet.
        var positioned: [(Item, NSRect)] = []
        for navigation in sections {
            guard let container = navigation.container else { continue }
            for (index, row) in navigation.rows.enumerated() {
                let frame = NSRect(x: 0, y: CGFloat(index) * (Look.rowHeight + Look.rowGap),
                                   width: container.bounds.width, height: Look.rowHeight)
                positioned.append((.row(navigation, row), container.convert(frame, to: nil)))
            }
        }
        for control in outerControls.values {
            guard control.enabled, let anchor = control.anchor,
                  anchor.window === window, anchor.enclosingScrollView === scroll,
                  !anchor.isHiddenOrHasHiddenAncestor, anchor.bounds.width > 0, anchor.bounds.height > 0,
                  !sections.contains(where: { navigation in
                      guard let container = navigation.container else { return false }
                      return anchor === container || anchor.isDescendant(of: container)
                  }) else { continue }
            positioned.append((.outer(control.token), anchor.convert(anchor.bounds, to: nil)))
        }
        return positioned.sorted {
            if abs($0.1.midY - $1.1.midY) > 0.5 { return $0.1.midY > $1.1.midY }
            return $0.1.minX < $1.1.minX
        }.map(\.0)
    }
    private static func deliverNeighbor(in sequence: [Item], index: Int, backwards: Bool, window: NSWindow) -> Bool {
        guard sequence.count > 1 else { return false }
        // Eager SwiftUI's ScrollView wraps its complete key group. Independent
        // cached roots must wrap that same logical list, not one resident owner.
        let next = (index + (backwards ? sequence.count - 1 : 1)) % sequence.count
        let lease = FocusLease(window: window)
        switch sequence[next] {
        case let .row(navigation, row):
            navigation.pending = Pending(row: row, token: nil, backwards: backwards, lease: lease)
            navigation.prepareRow?(row)
            navigation.scheduleDelivery()
        case let .outer(token):
            guard let control = outerControls[token], control.enabled, control.anchor?.window === window else { return false }
            DispatchQueue.main.async { [weak control, weak window] in
                guard let control, let window, lease.isCurrent(in: window),
                      outerControls[token] === control, control.enabled,
                      let anchor = control.anchor, anchor.window === window,
                      !anchor.isHiddenOrHasHiddenAncestor,
                      anchor.bounds.width > 0, anchor.bounds.height > 0 else { return }
                // This existing control owns its SwiftUI focus store. Request its
                // original FocusState rather than taking its outer host responder.
                control.request()
            }
        }
        return true
    }
    private func orderedControls(row: String) -> [Control] {
        guard let window = container?.window else { return [] }
        return controls.values.filter {
            guard $0.row == row, $0.enabled, let anchor = $0.anchor else { return false }
            return anchor.window === window && !anchor.isHiddenOrHasHiddenAncestor && anchor.bounds.width > 0 && anchor.bounds.height > 0
        }.sorted {
            guard let a = $0.anchor, let b = $1.anchor else { return false }
            let ar = a.convert(a.bounds, to: nil), br = b.convert(b.bounds, to: nil)
            if abs(ar.minX - br.minX) > 0.5 { return ar.minX < br.minX }
            return ar.maxY > br.maxY
        }
    }
    private func scheduleDelivery() {
        guard pending != nil, !deliveryScheduled else { return }
        deliveryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deliveryScheduled = false
            self.deliverPending()
        }
    }
    private func deliverPending() {
        guard let pending, pending.delivered == nil, let container, let window = container.window else { return }
        guard pending.lease.isCurrent(in: window) else {
            self.pending = nil
            prepareRow?(nil)
            return
        }
        let candidates = orderedControls(row: pending.row)
        diagnose("deliver row=\(pending.row) token=\(String(describing: pending.token)) candidates=\(candidates.map(\.token)) key=\(window.isKeyWindow) currentResponder=\(String(describing: window.firstResponder.map { String(describing: type(of: $0)) }))")
        let destination = pending.token.flatMap { token in candidates.first { $0.token == token } }
            ?? (pending.token == nil ? (pending.backwards ? candidates.last : candidates.first) : nil)
        guard let destination, let anchor = destination.anchor else { return }
        // Independent NSHostingViews have independent SwiftUI focus systems.
        // Enter the original native owner before requesting its exact control.
        var host = anchor
        while let parent = host.superview, parent !== container { host = parent }
        guard host.superview === container else { return }
        // A rejected native responder request is not a focus acknowledgement.
        // Leave the request pending so the next committed row layout retries
        // after attachment instead of permanently swallowing the first Tab.
        let admitted = window.makeFirstResponder(host)
        diagnose("nativeHandoff row=\(pending.row) host=\(String(describing: type(of: host))) accepts=\(host.acceptsFirstResponder) admitted=\(admitted) actualResponder=\(String(describing: window.firstResponder.map { String(describing: type(of: $0)) })) anchor=\(anchor.frame)")
        guard admitted else { return }
        self.pending?.delivered = destination.token
        destination.request()
    }

    func layoutDidCommit() { scheduleDelivery() }

    /// Eager SwiftUI prunes offscreen AX objects too. Return the real currently
    /// exposed controls in logical row order; NSScrollView retains its native
    /// scroll-to-realize route. A query never swaps or expands hosting owners.
    func accessibilityChildren() -> [Any] {
        guard !readingAccessibility, let container, let window = container.window else { return [] }
        readingAccessibility = true
        defer { readingAccessibility = false }
        let rowFrames = nativeRows().enumerated().map { index, pair in
            (index, window.convertToScreen(pair.1.convert(pair.1.bounds, to: nil)))
        }
        var seen = Set<ObjectIdentifier>(), result: [(NSObject, Int, NSRect)] = []
        func children(_ object: NSObject) -> [NSObject] {
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let values = object.perform(selector)?.takeUnretainedValue() as? [NSObject] { return values }
            return object.accessibilityAttributeValue(.children) as? [NSObject] ?? []
        }
        func frame(_ object: NSObject) -> NSRect? {
            if let element = object as? any NSAccessibilityProtocol { return element.accessibilityFrame() }
            if let element = object as? any NSAccessibilityElementProtocol { return element.accessibilityFrame() }
            guard let position = object.accessibilityAttributeValue(.position) as? NSValue,
                  let size = object.accessibilityAttributeValue(.size) as? NSValue else { return nil }
            return NSRect(origin: position.pointValue, size: size.sizeValue)
        }
        func visit(_ object: NSObject) {
            guard seen.count < 16_384, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let descendants = children(object)
            if let rect = frame(object), rect.width > 0, rect.height > 0,
               let row = rowFrames.first(where: { _, row in
                   rect.height <= row.height + 2 && row.insetBy(dx: -1, dy: -1).contains(NSPoint(x: rect.midX, y: rect.midY))
               }) {
                let protocolElement = object as? any NSAccessibilityProtocol
                // SwiftUI's real virtual nodes may expose only the public
                // Element protocol. NSObject's legacy ignored fallback does
                // not describe those nodes; preserve the host's actual leaves.
                let button = object as? any NSAccessibilityButton
                let exposed = protocolElement?.isAccessibilityElement()
                    ?? (object is any NSAccessibilityElementProtocol || !object.accessibilityIsIgnored())
                let actionable = button != nil || protocolElement?.accessibilityRole() == .button
                    || !object.accessibilityActionNames().isEmpty
                if exposed && (actionable || descendants.isEmpty) {
                    result.append((object, row.0, rect))
                    return
                }
            }
            descendants.forEach(visit)
        }
        container.subviews.forEach { visit($0) }
        return result.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if abs($0.2.minX - $1.2.minX) > 0.5 { return $0.2.minX < $1.2.minX }
            return $0.2.maxY > $1.2.maxY
        }.map { $0.0 }
    }
    func accessibilityChildrenInNavigationOrder() -> [any NSAccessibilityElementProtocol] {
        accessibilityChildren().compactMap { $0 as? any NSAccessibilityElementProtocol }
    }
    func detach() {
        prepareRow?(nil)
        controls.removeAll(); rows.removeAll(); activeToken = nil; pending = nil
        prepareRow = nil; nativeRows = { [] }; container = nil
        Self.navigations.removeAll { $0.value == nil || $0.value === self }
        if Self.navigations.isEmpty, let monitor = Self.monitor {
            NSEvent.removeMonitor(monitor)
            Self.monitor = nil
        }
    }
}

struct NativeSidebarNavigationRow: Sendable {
    let row: String
    weak var navigation: NativeSidebarNavigation?
}
private struct NativeSidebarNavigationRowKey: EnvironmentKey {
    static let defaultValue: NativeSidebarNavigationRow? = nil
}
extension EnvironmentValues {
    var nativeSidebarNavigationRow: NativeSidebarNavigationRow? {
        get { self[NativeSidebarNavigationRowKey.self] }
        set { self[NativeSidebarNavigationRowKey.self] = newValue }
    }
}

struct NativeSidebarNavigationControl: NSViewRepresentable {
    let row: NativeSidebarNavigationRow?
    let token: UUID
    let enabled: Bool
    let request: @MainActor () -> Void
    final class Anchor: NSView {
        weak var navigation: NativeSidebarNavigation?
        var token: UUID?
        var refresh: (() -> Void)?
        override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(false) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh?() }
        override func layout() { super.layout(); navigation?.layoutDidCommit() }
        func detach() {
            if let token {
                navigation?.unregister(token: token)
                NativeSidebarNavigation.unregisterOuter(token: token)
            }
            navigation = nil; token = nil; refresh = nil
        }
    }
    func makeNSView(context: Context) -> Anchor { Anchor(frame: .zero) }
    func updateNSView(_ view: Anchor, context: Context) {
        if view.navigation !== row?.navigation || view.token != token { view.detach() }
        view.navigation = row?.navigation; view.token = token
        view.refresh = { [weak view, weak navigation = row?.navigation] in
            guard let view else { return }
            if let row {
                navigation?.register(token: token, row: row.row, anchor: view, enabled: enabled, request: request)
            } else {
                NativeSidebarNavigation.registerOuter(token: token, anchor: view, enabled: enabled, request: request)
            }
        }
        view.refresh?()
    }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.detach() }
}
