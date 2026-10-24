import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class NativeContentBoundaryTests: XCTestCase {
    private func window<V: View>(_ view: V, width: CGFloat = 320, height: CGFloat = 260)
        -> (NSWindow, NSHostingView<V>) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
        return (window, host)
    }

    private func anchors(_ view: NSView) -> [NativeContentBoundaryAnchor] {
        (view as? NativeContentBoundaryAnchor).map { [$0] } ?? view.subviews.flatMap(anchors)
    }

    func testParentResponderQueryDoesNotWalkSiblingHostingRoot() async throws {
        let child = CountingBoundaryHost(rootView: AnyView(VStack {
            TextField("Child input", text: .constant("A real editable value"))
            ForEach(0..<28) { Text("Focusable row \($0)").focusable() }
        }))
        let (_, parent) = window(VStack {
            Text("Stationary parent header")
            NativeContentBoundary(makeHostingView: { _ in child }) {
                VStack {
                    TextField("Child input", text: .constant("A real editable value"))
                    ForEach(0..<28) { Text("Focusable row \($0)").focusable() }
                }
            }
        })
        try await compatibilityWait { self.anchors(parent).first?.host.window != nil }
        let anchor = try XCTUnwrap(anchors(parent).first)
        XCTAssertTrue(child.superview === anchor.superview)
        XCTAssertFalse(child.isDescendant(of: anchor))
        child.getterCalls = 0
        for _ in 0..<10 { _ = parent.acceptsFirstResponder }
        XCTAssertEqual(child.getterCalls, 0,
            "Parent focus eligibility must not traverse the complete child focus graph")
        _ = child.acceptsFirstResponder
        XCTAssertEqual(child.getterCalls, 1, "The test must observe the actual native getter")
    }

    func testAnchorReparentResizeVisibilityAndDismantleFollowNativeLifetime() {
        TestEnvironment.prepare()
        let first = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let second = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let child = NativeContentBoundaryHostingView(rootView: AnyView(Text("Owned content")))
        let anchor = NativeContentBoundaryAnchor(host: child)
        anchor.frame = NSRect(x: 10, y: 20, width: 250, height: 180)
        first.addSubview(anchor)
        XCTAssertTrue(child.superview === first)
        XCTAssertEqual(child.frame, anchor.frame)
        anchor.setFrameOrigin(NSPoint(x: 30, y: 40))
        anchor.setFrameSize(NSSize(width: 280, height: 210))
        XCTAssertEqual(child.frame, anchor.frame)
        anchor.alphaValue = 0.4
        XCTAssertEqual(child.alphaValue, 0.4)
        anchor.isHidden = true
        XCTAssertTrue(child.isHidden)
        anchor.isHidden = false
        XCTAssertFalse(child.isHidden)
        second.addSubview(anchor)
        XCTAssertTrue(child.superview === second)
        XCTAssertFalse(first.subviews.contains { $0 === child })
        anchor.removeFromSuperview()
        XCTAssertNil(child.superview, "An unmounted anchor must not leave an owned sibling behind")
        first.addSubview(anchor)
        XCTAssertTrue(child.superview === first)
        anchor.dismantle()
        XCTAssertNil(child.superview)
        XCTAssertNil(child.boundaryAccessibilityParent)
        anchor.setFrameOrigin(NSPoint(x: 50, y: 60))
        second.addSubview(anchor)
        XCTAssertNil(child.superview, "Late native callbacks must not revive a dismantled boundary")
    }

    func testDismantleReleasesContentRatherThanRetainingAHiddenHostingTree() async throws {
        weak var released: NativeContentBoundaryHostingView?
        autoreleasepool {
            let parent = NSView()
            let child = NativeContentBoundaryHostingView(rootView: AnyView(Text("Temporary")))
            released = child
            let anchor = NativeContentBoundaryAnchor(host: child)
            parent.addSubview(anchor)
            anchor.dismantle()
            anchor.removeFromSuperview()
        }
        try await compatibilityWait { released == nil }
    }

    func testEnvironmentObjectThemeEnabledMotionNamespaceAndUpdatesReachChild() async throws {
        let dependency = BoundaryDependency()
        let signal = BoundarySignal()
        let childSignal = BoundaryChildSignal()
        let record = BoundaryRecord()
        let (_, parent) = window(BoundaryEnvironmentFixture(signal: signal, childSignal: childSignal, record: record)
            .environmentObject(dependency)
            .environment(\.spaceChromeTheme, SpaceChromeTheme(primary: ThemeColor(hex: "#1278AB")))
            .environment(\.isEnabled, false)
            .transaction { $0.disablesAnimations = true })
        try await compatibilityWait { record.latest != nil }
        var value = try XCTUnwrap(record.latest)
        XCTAssertEqual(value.dependency, dependency.id)
        XCTAssertEqual(value.theme, SpaceChromeTheme(primary: ThemeColor(hex: "#1278AB")))
        XCTAssertFalse(value.enabled)
        XCTAssertEqual(value.reduceMotion, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        XCTAssertTrue(value.disablesAnimations, "The parent's reduced-motion transaction must still apply")
        XCTAssertEqual(value.namespace, record.expectedNamespace,
            "Namespace identity is forwarded as a value; this does not prove cross-host animation matching")
        Motion.spaceHandoff { signal.generation += 1 }
        try await compatibilityWait { record.latest?.generation == 1 }
        value = try XCTUnwrap(record.latest)
        XCTAssertTrue(value.spaceHandoff,
            "A parent update's transaction must reach the new child root")

        var local = Transaction(animation: nil)
        local[BoundaryChildTransactionTag.self] = 17
        withTransaction(local) { childSignal.generation = 1 }
        try await compatibilityWait { record.latest?.childGeneration == 1 }
        value = try XCTUnwrap(record.latest)
        XCTAssertEqual(value.childTransactionTag, 17)
        XCTAssertFalse(value.spaceHandoff,
            "A later child-origin transaction must not inherit the previous parent handoff")

        signal.generation = 2
        try await compatibilityWait { record.latest?.generation == 2 }
        value = try XCTUnwrap(record.latest)
        XCTAssertFalse(value.spaceHandoff, "An ordinary parent update must clear an earlier handoff")
        XCTAssertEqual(value.childTransactionTag, 0)
        XCTAssertTrue(value.disablesAnimations, "The ordinary parent's explicit policy must still apply")

        local[BoundaryChildTransactionTag.self] = 23
        withTransaction(local) { childSignal.generation = 2 }
        try await compatibilityWait { record.latest?.childGeneration == 2 }
        value = try XCTUnwrap(record.latest)
        XCTAssertEqual(value.childTransactionTag, 23)
        XCTAssertFalse(value.spaceHandoff)
        XCTAssertFalse(anchors(parent).isEmpty)
    }

    func testChildAnchorPreferenceAndConsumerResolveInsideTheSameGraph() async throws {
        let signal = BoundarySignal()
        let record = BoundaryRecord()
        let (_, _) = window(BoundaryPreferenceFixture(signal: signal, record: record))
        try await compatibilityWait { record.preferenceRect?.width == 40 }
        let initial = try XCTUnwrap(record.preferenceRect)
        XCTAssertEqual(initial.height, 20, accuracy: 0.5)
        signal.generation = 1
        try await compatibilityWait { (record.preferenceRect?.minX ?? 0) > initial.minX + 10 }
        XCTAssertEqual(try XCTUnwrap(record.preferenceRect).width, 40, accuracy: 0.5)
    }

    func testAccessibilityBridgeForwardsRealMountedControlAndHidesWithAnchor() throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let field = NSTextField(string: "Live editable AX value")
        field.setAccessibilityIdentifier("boundary-real-field")
        let child = ActualControlAXHost(rootView: AnyView(BoundaryNativeField(field: field)), field: field)
        let anchor = NativeContentBoundaryAnchor(host: child)
        anchor.frame = NSRect(x: 20, y: 20, width: 250, height: 100)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 160))
        let window = NSWindow(contentRect: root.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        root.addSubview(anchor)
        window.orderFront(nil)
        child.layoutSubtreeIfNeeded()
        defer { anchor.dismantle(); window.contentView = nil; window.close() }
        XCTAssertTrue(field.window === window, "The AX node must be a mounted native editable control")
        XCTAssertTrue((child.accessibilityParent() as? NSView) === anchor)
        let exposed = try XCTUnwrap(anchor.accessibilityChildren()?.first as? NSTextField)
        XCTAssertTrue(exposed === field, "Forward the actual dynamic control, not a fabricated AX description")
        field.stringValue = "Changed by the actual field"
        XCTAssertEqual((anchor.accessibilityChildren()?.first as? NSTextField)?.stringValue, field.stringValue)
        anchor.isHidden = true
        XCTAssertFalse(anchor.isAccessibilityElement())
        XCTAssertTrue(anchor.accessibilityChildren()?.isEmpty == true)
        anchor.isHidden = false
        XCTAssertTrue((anchor.accessibilityChildren()?.first as? NSTextField) === field)
        anchor.removeFromSuperview()
        XCTAssertTrue(anchor.accessibilityChildren()?.isEmpty == true)
    }
}

@MainActor private final class CountingBoundaryHost: NativeContentBoundaryHostingView {
    var getterCalls = 0
    override var acceptsFirstResponder: Bool { getterCalls += 1; return super.acceptsFirstResponder }
}

@MainActor private final class BoundaryDependency: ObservableObject { let id = UUID() }
@MainActor private final class BoundarySignal: ObservableObject { @Published var generation = 0 }
@MainActor private final class BoundaryChildSignal: ObservableObject { @Published var generation = 0 }
private struct BoundaryChildTransactionTag: TransactionKey { static let defaultValue = 0 }
@MainActor private final class BoundaryRecord {
    struct Snapshot {
        let generation: Int
        let childGeneration: Int
        let dependency: UUID
        let theme: SpaceChromeTheme
        let enabled: Bool
        let reduceMotion: Bool
        let namespace: Namespace.ID
        let disablesAnimations: Bool
        let spaceHandoff: Bool
        let childTransactionTag: Int
    }
    var expectedNamespace: Namespace.ID?
    var latest: Snapshot?
    var preferenceRect: CGRect?
}

private struct BoundaryEnvironmentFixture: View {
    @ObservedObject var signal: BoundarySignal
    // Read this only in the child root: child mutations must not cause a parent
    // representable/root assignment and accidentally turn this into a mirror test.
    let childSignal: BoundaryChildSignal
    let record: BoundaryRecord
    @Namespace private var namespace
    var body: some View {
        let _ = record.expectedNamespace = namespace
        NativeContentBoundary {
            BoundaryEnvironmentLeaf(generation: signal.generation, childSignal: childSignal,
                namespace: namespace, record: record)
                .vaneMotionPolicy()
        }
    }
}
private struct BoundaryEnvironmentLeaf: View {
    let generation: Int
    @ObservedObject var childSignal: BoundaryChildSignal
    let namespace: Namespace.ID
    let record: BoundaryRecord
    @EnvironmentObject private var dependency: BoundaryDependency
    @Environment(\.spaceChromeTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        BoundaryEnvironmentProbe(generation: generation, childGeneration: childSignal.generation, dependency: dependency.id,
            theme: theme, enabled: enabled, reduceMotion: reduceMotion, namespace: namespace, record: record)
    }
}
private struct BoundaryEnvironmentProbe: NSViewRepresentable {
    let generation: Int
    let childGeneration: Int
    let dependency: UUID
    let theme: SpaceChromeTheme
    let enabled: Bool
    let reduceMotion: Bool
    let namespace: Namespace.ID
    let record: BoundaryRecord
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        record.latest = .init(generation: generation, childGeneration: childGeneration, dependency: dependency, theme: theme,
            enabled: enabled, reduceMotion: reduceMotion, namespace: namespace,
            disablesAnimations: context.transaction.disablesAnimations,
            spaceHandoff: context.transaction.isSpaceHandoff,
            childTransactionTag: context.transaction[BoundaryChildTransactionTag.self])
    }
}

private struct BoundaryBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}
private struct BoundaryPreferenceFixture: View {
    @ObservedObject var signal: BoundarySignal
    let record: BoundaryRecord
    var body: some View {
        NativeContentBoundary {
            HStack {
                Color.clear.frame(width: signal.generation == 0 ? 10 : 40)
                Color.blue.frame(width: 40, height: 20)
                    .anchorPreference(key: BoundaryBounds.self, value: .bounds) { $0 }
                Spacer()
            }
            .overlayPreferenceValue(BoundaryBounds.self) { anchor in
                GeometryReader { geometry in
                    if let anchor { BoundaryPreferenceProbe(rect: geometry[anchor], record: record) }
                }
            }
        }
    }
}
private struct BoundaryPreferenceProbe: NSViewRepresentable {
    let rect: CGRect
    let record: BoundaryRecord
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { record.preferenceRect = rect }
}
private struct BoundaryNativeField: NSViewRepresentable {
    let field: NSTextField
    func makeNSView(context: Context) -> NSTextField { field }
    func updateNSView(_ view: NSTextField, context: Context) {}
}
/// Inject only the child's AX children contract, using an actual mounted field.
/// SwiftUI AX-tree integration and Tab order also require the visible app test.
@MainActor private final class ActualControlAXHost: NativeContentBoundaryHostingView {
    let field: NSTextField
    init(rootView: AnyView, field: NSTextField) {
        self.field = field
        super.init(rootView: rootView)
    }
    required init(rootView: AnyView) { fatalError("Use the actual-control initializer") }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
    override func accessibilityChildren() -> [Any]? { [field] }
}
