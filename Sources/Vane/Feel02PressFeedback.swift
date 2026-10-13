import AppKit
import SwiftUI

/// One passive monitor for all mounted row targets. It returns every native event
/// unchanged: tap, double-click, scrolling, context menus and drag initiation retain
/// their existing recognizers and activation timing.
@MainActor final class Feel02PressMonitor {
    static let shared = Feel02PressMonitor()
    private let anchors = NSHashTable<Feel02PressAnchorView>.weakObjects()
    private weak var pressed: Feel02PressAnchorView?
    private var origin = CGPoint.zero
    private var monitor: Any?
    private var resignation: NSObjectProtocol?

    func register(_ anchor: Feel02PressAnchorView) {
        anchors.add(anchor)
        anchor.pressMonitor = self
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) {
            [weak self] event in self?.handle(event) ?? event
        }
        resignation = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.release() } }
    }

    func remove(_ anchor: Feel02PressAnchorView) {
        if pressed === anchor { release() }
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
    }

    func release() {
        pressed?.changed?(false)
        pressed = nil
    }

    func handle(_ event: NSEvent) -> NSEvent {
        switch event.type {
        case .leftMouseDown:
            release()
            guard let window = event.window else { return event }
            let targets = anchors.allObjects.filter { anchor in
                anchor.enabled && anchor.window === window && !anchor.isHiddenOrHasHiddenAncestor
                    && anchor.visibleRect.contains(anchor.convert(event.locationInWindow, from: nil))
            }
            pressed = targets.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
            origin = event.locationInWindow
            pressed?.changed?(true)
        case .leftMouseDragged:
            if event.window !== pressed?.window || hypot(event.locationInWindow.x - origin.x,
                                                        event.locationInWindow.y - origin.y) > 4 { release() }
        case .leftMouseUp: release()
        default: break
        }
        return event
    }
}

final class Feel02PressAnchorView: NSView {
    var enabled = true
    var changed: ((Bool) -> Void)?
    weak var pressMonitor: Feel02PressMonitor?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { pressMonitor?.cancel(for: self) }
        super.viewWillMove(toWindow: newWindow)
    }
}

private struct Feel02PressAnchor: NSViewRepresentable {
    let enabled: Bool
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> Feel02PressAnchorView {
        let view = Feel02PressAnchorView(frame: .zero)
        Feel02PressMonitor.shared.register(view)
        return view
    }
    func updateNSView(_ view: Feel02PressAnchorView, context: Context) {
        view.enabled = enabled
        view.changed = changed
    }
    static func dismantleNSView(_ view: Feel02PressAnchorView, coordinator: ()) {
        Feel02PressMonitor.shared.remove(view)
    }
}

private struct Feel02PressFeedbackEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
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
                if interactive {
                    Feel02PressAnchor(enabled: true) { next in
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { pressed = next }
                    }
                }
            }
    }
}
