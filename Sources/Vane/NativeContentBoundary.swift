import AppKit
import SwiftUI

/// Default-off experiment. Sidebar should capture this once in its own State so
/// enabling a future preference never swaps an active focus/scroll tree in place.
@MainActor enum NativeSidebarBoundaryExperiment {
    static let enabled = ProcessInfo.processInfo.environment["VANE_EXPERIMENT_SIDEBAR_HOST"] == "1"
}

/// Hosts a bounded, self-contained SwiftUI cluster next to its native layout anchor.
/// Keep all anchor-preference producers/consumers and matching-geometry participants
/// inside `content`; neither preferences nor animation matching cross hosting roots.
/// No first-responder or focus-eligibility answers are overridden.
@MainActor struct NativeContentBoundary<Content: View>: NSViewRepresentable {
    private let makeHostingView: (AnyView) -> NativeContentBoundaryHostingView
    private let content: () -> Content

    init(makeHostingView: @escaping (AnyView) -> NativeContentBoundaryHostingView = {
        NativeContentBoundaryHostingView(rootView: $0)
    }, @ViewBuilder content: @escaping () -> Content) {
        self.makeHostingView = makeHostingView
        self.content = content
    }

    /// SwiftUI's value-scoped transaction relay deliberately skips its initial
    /// value. This non-observable coordinator fills only that first-mount gap.
    /// Later child-origin changes retain their own transactions.
    final class Coordinator {
        private var initialPending = true

        func applyInitial(_ parent: Transaction, to transaction: inout Transaction) {
            guard initialPending else { return }
            initialPending = false
            transaction = parent
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func root(context: Context, revision: UInt64) -> AnyView {
        let transaction = context.transaction
        let coordinator = context.coordinator
        return AnyView(content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.self, context.environment)
            .transaction(value: revision) { $0 = transaction }
            .transaction { coordinator.applyInitial(transaction, to: &$0) })
    }

    func makeNSView(context: Context) -> NativeContentBoundaryAnchor {
        NativeContentBoundaryAnchor(host: makeHostingView(root(context: context, revision: 0)))
    }

    func updateNSView(_ view: NativeContentBoundaryAnchor, context: Context) {
        // NSHostingView.rootView does not retain the caller's current transaction.
        // Increment only for actual root assignments; the value-scoped modifier
        // passes that update through without clobbering child-local interactions.
        view.updateRoot { revision in root(context: context, revision: revision) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeContentBoundaryAnchor,
                     context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: max(0, width), height: max(0, height))
    }

    static func dismantleNSView(_ view: NativeContentBoundaryAnchor, coordinator: Coordinator) {
        view.dismantle()
    }
}

/// The injected factory is for native mechanism tests, not responder-policy changes.
/// This subclass only supplies the public accessibility parent relationship.
@MainActor class NativeContentBoundaryHostingView: NSHostingView<AnyView> {
    weak var boundaryAccessibilityParent: NSView?

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = []
    }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func accessibilityParent() -> Any? {
        boundaryAccessibilityParent ?? super.accessibilityParent()
    }
}

/// The anchor stays in SwiftUI's native hierarchy. Its owned host is a sibling,
/// so the parent hosting root does not traverse the child's focus graph while
/// answering AppKit's window drag-region queries. Public NSView hierarchy APIs
/// retain the anchor's shared clipping, transforms, overlay ordering, and lifetime.
@MainActor final class NativeContentBoundaryAnchor: NSView {
    let host: NativeContentBoundaryHostingView
    private var live = true
    private var synchronizing = false
    private var rootRevision: UInt64 = 0

    init(host: NativeContentBoundaryHostingView) {
        self.host = host
        super.init(frame: .zero)
        host.boundaryAccessibilityParent = self
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateRoot(_ root: (UInt64) -> AnyView) {
        guard live else { return }
        rootRevision &+= 1
        host.rootView = root(rootRevision)
        synchronizeHost()
    }

    private func synchronizeHost() {
        guard live, !synchronizing else { return }
        synchronizing = true
        defer { synchronizing = false }
        guard let parent = superview else {
            host.removeFromSuperview()
            return
        }
        if host.superview !== parent {
            host.removeFromSuperview()
            parent.addSubview(host, positioned: .above, relativeTo: self)
        }
        if host.frame != frame { host.frame = frame }
        if host.isHidden != isHidden { host.isHidden = isHidden }
        if host.alphaValue != alphaValue { host.alphaValue = alphaValue }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        synchronizeHost()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        synchronizeHost()
    }
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        synchronizeHost()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        synchronizeHost()
    }
    override var isHidden: Bool { didSet { synchronizeHost() } }
    override var alphaValue: CGFloat { didSet { synchronizeHost() } }

    func dismantle() {
        guard live else { return }
        live = false
        host.removeFromSuperview()
        host.boundaryAccessibilityParent = nil
        host.rootView = AnyView(EmptyView())
    }

    private var exposesAccessibility: Bool {
        live && window?.isVisible == true && !isHiddenOrHasHiddenAncestor
            && host.superview === superview && host.window === window
    }
    override func isAccessibilityElement() -> Bool { exposesAccessibility }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityChildren() -> [Any]? {
        guard exposesAccessibility else { return [] }
        return host.accessibilityChildren() ?? [host]
    }
    private struct AccessibilityHit: @unchecked Sendable {
        // NSAccessibility's legacy Any result crosses this synchronous actor
        // assertion only; AppKit retains ownership of the actual UI object.
        let value: Any?
    }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        // Like NSHostingView's implementation, AppKit performs native view hit
        // testing on the UI thread; the legacy NSAccessibility declaration omits it.
        MainActor.assumeIsolated {
            guard exposesAccessibility, let window else { return AccessibilityHit(value: nil) }
            let local = convert(window.convertPoint(fromScreen: point), from: nil)
            guard bounds.intersection(visibleRect).contains(local) else { return AccessibilityHit(value: nil) }
            return AccessibilityHit(value: host.accessibilityHitTest(point))
        }.value
    }
}
