import AppKit
import SwiftUI

/// One passive monitor for all mounted row targets. It returns every native event
/// unchanged: tap, double-click, scrolling, context menus and drag initiation retain
/// their existing recognizers and activation timing.
@MainActor final class Feel02PressMonitor {
    static let shared = Feel02PressMonitor()
    private let anchors = NSHashTable<Feel02PressAnchorView>.weakObjects()
    private weak var pressed: Feel02PressAnchorView?
    private weak var hovered: Feel02PressAnchorView?
    private var origin = CGPoint.zero
    private var pointerPosition: CGPoint?
    private var monitor: Any?
    private var resignation: NSObjectProtocol?

    func register(_ anchor: Feel02PressAnchorView) {
        anchors.add(anchor)
        anchor.pressMonitor = self
        anchor.feedbackScope?.track(self)
        guard monitor == nil else { return }
        pointerPosition = NSEvent.mouseLocation
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .mouseMoved, .mouseExited, .scrollWheel]) {
            [weak self] event in self?.handle(event) ?? event
        }
        resignation = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated {
                self?.release()
                self?.releaseHover()
            } }
    }

    /// Modal entry can be keyboard-only, with no pointer event to clear decoration.
    static func quitDialogDidOpen() {
        shared.revokeForQuitDialog()
        PaletteHoverInput.shared.revokeForQuitDialog()
    }

    private func revokeForQuitDialog() {
        pointerPosition = NSEvent.mouseLocation
        release()
        releaseHover()
    }

    func remove(_ anchor: Feel02PressAnchorView) {
        if pressed === anchor { release() }
        if hovered === anchor { releaseHover(afterLayout: true) }
        anchors.remove(anchor)
        anchor.pressMonitor = nil
        guard anchors.allObjects.isEmpty else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignation { NotificationCenter.default.removeObserver(resignation) }
        resignation = nil
    }

    func cancel(for anchor: Feel02PressAnchorView) {
        if pressed === anchor { release() }
        if hovered === anchor { releaseHover(afterLayout: true) }
    }

    func cancelHover(for anchor: Feel02PressAnchorView) {
        if hovered === anchor { releaseHover(afterLayout: true) }
    }

    func release(afterLayout: Bool = false) {
        let previous = pressed
        pressed = nil
        guard afterLayout else { previous?.changed?(false); return }
        DispatchQueue.main.async { [weak self, weak previous] in
            guard let previous, self?.pressed !== previous else { return }
            previous.changed?(false)
        }
    }

    /// Geometry may revoke decoration but must never admit a stationary target.
    func feedbackOcclusionChanged(_ scope: FeedbackOcclusionScope) {
        guard let position = pointerPosition else { return }
        func covered(_ anchor: Feel02PressAnchorView?) -> Bool {
            guard let anchor, anchor.feedbackScope === scope, let window = anchor.window else { return false }
            return scope.contains(window.convertPoint(fromScreen: position), in: window)
        }
        if covered(pressed) { release(afterLayout: true) }
        if covered(hovered) { releaseHover(afterLayout: true) }
    }

    private func releaseHover(afterLayout: Bool = false) {
        let previous = hovered
        hovered = nil
        guard afterLayout else { previous?.hoverChanged?(false); return }
        // Representable updates and AppKit layout can revoke a target while SwiftUI
        // is rendering. Revoke input now, then clear decoration after that update.
        DispatchQueue.main.async { [weak self, weak previous] in
            guard let previous, self?.hovered !== previous else { return }
            previous.hoverChanged?(false)
        }
    }

    private func contains(_ event: NSEvent, in anchor: Feel02PressAnchorView) -> Bool {
        guard anchor.enabled, let window = event.window, anchor.window === window,
              !anchor.isHiddenOrHasHiddenAncestor else { return false }
        guard anchor.feedbackScope?.contains(event.locationInWindow, in: window) != true else { return false }
        let point = anchor.convert(event.locationInWindow, from: nil)
        // SwiftUI can expose a representable's ancestor clip as its visibleRect,
        // extending beyond this row. Both bounds and clipping must admit input.
        return anchor.bounds.contains(point) && anchor.visibleRect.contains(point)
    }

    private func updateHover(_ event: NSEvent) {
        guard let window = event.window else { releaseHover(); return }
        let position = window.convertPoint(toScreen: event.locationInWindow)
        defer { pointerPosition = position }
        // Tracking updates can replay a stationary pointer after disclosure, scroll
        // or window movement. Only a changed screen position admits a new hover.
        guard position != pointerPosition else {
            if let hovered, !contains(event, in: hovered) { releaseHover() }
            return
        }
        let next = anchors.allObjects.filter {
            $0.hoverChanged != nil && contains(event, in: $0)
        }.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        if hovered !== next { releaseHover(); hovered = next }
        // Geometry may already have cleared the SwiftUI decoration. Actual movement
        // within the same native target must be able to restore it.
        next?.hoverChanged?(true)
    }

    func handle(_ event: NSEvent) -> NSEvent {
        if QuitDialog.isUp {
            // Track the real modal pointer without admitting feedback behind the card.
            // Its dismissal must not turn a stationary replay into a fresh hover.
            if let window = event.window {
                pointerPosition = window.convertPoint(toScreen: event.locationInWindow)
            }
            release()
            releaseHover()
            return event
        }
        switch event.type {
        case .leftMouseDown:
            release()
            guard let window = event.window else { return event }
            pointerPosition = window.convertPoint(toScreen: event.locationInWindow)
            if let hovered, !contains(event, in: hovered) { releaseHover() }
            let targets = anchors.allObjects.filter { anchor in
                contains(event, in: anchor)
            }
            pressed = targets.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
            origin = event.locationInWindow
            pressed?.changed?(true)
        case .leftMouseDragged:
            if event.window !== pressed?.window || hypot(event.locationInWindow.x - origin.x,
                                                        event.locationInWindow.y - origin.y) > 4 { release() }
            updateHover(event)
        case .mouseMoved, .rightMouseDragged, .otherMouseDragged:
            updateHover(event)
        case .mouseExited:
            if let hovered, !contains(event, in: hovered) { releaseHover() }
        case .scrollWheel:
            if event.window == nil || event.window === hovered?.window { releaseHover() }
        case .leftMouseUp: release()
        default: break
        }
        return event
    }
}

final class Feel02PressAnchorView: NSView {
    private var exitTracking: NSTrackingArea?
    var enabled = true {
        didSet { if !enabled { pressMonitor?.cancel(for: self) } }
    }
    var changed: ((Bool) -> Void)?
    var hoverChanged: ((Bool) -> Void)? {
        didSet {
            requestPointerMotion()
            updateExitTracking()
        }
    }
    weak var pressMonitor: Feel02PressMonitor?
    weak var feedbackScope: FeedbackOcclusionScope? {
        didSet { feedbackScope?.track(pressMonitor) }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateExitTracking()
    }
    private func updateExitTracking() {
        guard hoverChanged != nil else {
            if let exitTracking { removeTrackingArea(exitTracking) }
            exitTracking = nil
            return
        }
        guard exitTracking == nil else { return }
        // Native motion also admits non-key windows. Exit observation must cover
        // the same windows, while entry remains governed by actual pointer motion.
        let area = NSTrackingArea(rect: .zero,
            options: [.inVisibleRect, .mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        exitTracking = area
    }
    override func mouseExited(with event: NSEvent) {
        // Tracking can exit during layout. Revoke hover now and defer decoration;
        // native mouse-up and drag handling keep ownership of an ongoing press.
        pressMonitor?.cancelHover(for: self)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestPointerMotion()
    }
    private func requestPointerMotion() {
        // Rows also appear in app-owned sheets, not only VaneWindow. Request input
        // for the window's lifetime without undoing another component's request.
        if hoverChanged != nil, let window, !window.acceptsMouseMovedEvents {
            window.acceptsMouseMovedEvents = true
        }
    }
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        if frame.origin != newOrigin { pressMonitor?.cancel(for: self) }
        super.setFrameOrigin(newOrigin)
    }
    override func setFrameSize(_ newSize: NSSize) {
        if frame.size != newSize { pressMonitor?.cancel(for: self) }
        super.setFrameSize(newSize)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { pressMonitor?.cancel(for: self) }
        super.viewWillMove(toWindow: newWindow)
    }
}

private struct Feel02PressAnchor: NSViewRepresentable {
    @Environment(\.feedbackOcclusionScope) private var feedbackScope
    let enabled: Bool
    let changed: (Bool) -> Void
    var hoverChanged: ((Bool) -> Void)?
    func makeNSView(context: Context) -> Feel02PressAnchorView {
        let view = Feel02PressAnchorView(frame: .zero)
        Feel02PressMonitor.shared.register(view)
        return view
    }
    func updateNSView(_ view: Feel02PressAnchorView, context: Context) {
        view.changed = changed
        view.hoverChanged = hoverChanged
        view.enabled = enabled
        view.feedbackScope = feedbackScope
    }
    static func dismantleNSView(_ view: Feel02PressAnchorView, coordinator: ()) {
        Feel02PressMonitor.shared.remove(view)
    }
}

private struct SidebarRetainsControlsKey: EnvironmentKey {
    static let defaultValue = false
}

private struct Feel02PressFeedbackEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// A small sidebar can disable a folded slot without discarding its press anchor.
    var sidebarRetainsControls: Bool {
        get { self[SidebarRetainsControlsKey.self] }
        set { self[SidebarRetainsControlsKey.self] = newValue }
    }

    /// Passive native monitors cannot infer SwiftUI's allowsHitTesting flag.
    /// Inert preview roots explicitly exclude all of their descendant anchors.
    var feel02PressFeedbackEnabled: Bool {
        get { self[Feel02PressFeedbackEnabledKey.self] }
        set { self[Feel02PressFeedbackEnabledKey.self] = newValue }
    }
}

/// Feedback changes decoration immediately; text and hit rectangles never scale.
struct Feel02PressFeedback: ViewModifier {
    var enabled = true
    var hoverChanged: ((Bool) -> Void)?
    @Environment(\.sidebarRetainsControls) private var retainsControls
    @Environment(\.isEnabled) private var controlEnabled
    @Environment(\.feel02PressFeedbackEnabled) private var surfaceEnabled
    @State private var pressed = false
    private var interactive: Bool { enabled && controlEnabled && surfaceEnabled }

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: Look.pillRadius)
                    .fill(Look.inkPrimary.opacity(pressed && interactive ? 0.055 : 0))
                    .transaction { $0.animation = nil; $0.disablesAnimations = true }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .background {
                // Preview/held surfaces are inert. Mounting one native view per row
                // still adds layout work even when its monitor target is disabled.
                if interactive || (retainsControls && enabled && surfaceEnabled) {
                    Feel02PressAnchor(enabled: interactive, changed: { next in
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { pressed = next }
                    }, hoverChanged: hoverChanged)
                }
            }
    }
}

/// Palette rows arbitrate independently of smaller controls behind their modal surface.
/// The monitor's passive event and stationary-pointer rules are shared, not its targets.
@MainActor private enum PaletteHoverInput {
    static let shared = Feel02PressMonitor()
}

private struct PaletteHoverAnchor: NSViewRepresentable {
    let hoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> Feel02PressAnchorView {
        let view = Feel02PressAnchorView(frame: .zero)
        PaletteHoverInput.shared.register(view)
        return view
    }

    func updateNSView(_ view: Feel02PressAnchorView, context: Context) {
        view.changed = nil
        view.hoverChanged = hoverChanged
        view.enabled = true
    }

    static func dismantleNSView(_ view: Feel02PressAnchorView, coordinator: ()) {
        PaletteHoverInput.shared.remove(view)
    }
}

/// Hover decoration only: native hit testing and keyboard activation stay with the row.
/// Scroll clears pointer feedback until actual pointer movement; selected rows remain lit.
struct Feel02HoverFeedback: ViewModifier {
    let hoverChanged: (Bool) -> Void
    @Environment(\.isEnabled) private var controlEnabled
    @Environment(\.feel02PressFeedbackEnabled) private var surfaceEnabled

    private var interactive: Bool { controlEnabled && surfaceEnabled }

    func body(content: Content) -> some View {
        content.background {
            if interactive {
                PaletteHoverAnchor(hoverChanged: hoverChanged)
            }
        }
        .onChange(of: interactive) { _, enabled in
            if !enabled { hoverChanged(false) }
        }
    }
}
