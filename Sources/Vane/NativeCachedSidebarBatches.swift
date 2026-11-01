import AppKit
import Combine
import SwiftUI

/// Keep row controls in stable native owners, with a diagnostic legacy opt-out.
@MainActor enum NativeCachedSidebarBatchesExperiment {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["VANE_EXPERIMENT_NATIVE_ROW_BATCH_CACHE"] != "0"
    }
    static let provenance = "native-row-batch-stable-owners-v2"
}
private struct NativeCachedSidebarBatchesKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var nativeCachedSidebarBatches: Bool {
        get { self[NativeCachedSidebarBatchesKey.self] }
        set { self[NativeCachedSidebarBatchesKey.self] = newValue }
    }
}

struct NativeCachedSidebarBatchCounts: Sendable {
    var coldGraphCreates = 0
    var warmGraphReattachments = 0
    var graphDetaches = 0
    var graphEvictions = 0
    var rootUpdates = 0
    var rangeChanges = 0
    var protectionOwnerTreeScans = 0
    var detachedProtectionOwnerTreeScans = 0
    var inactiveScopeHits = 0
    var inactiveScopeMisses = 0
    var inactiveScopeEvictions = 0
}
@MainActor protocol NativeCachedSidebarBatchesReporting: AnyObject {
    var usesThreeBatchBudget: Bool { get }
    var requestedMaxGraphBudget: Int { get }
    var visibleCoverageExceedsBudget: Bool { get }
    var residentRowRange: Range<Int> { get }
    var stagingEnabled: Bool { get }
    var attachedLogicalRows: Int { get }
    var cachedLogicalRows: Int { get }
    var attachedGraphCount: Int { get }
    /// Nominal viewport plus two endpoint owners; interaction keepalives,
    /// tall viewports, AX expansion and reordered sparse owners may exceed it.
    var nominalAttachedGraphBudget: Int { get }
    var attachedGraphBudgetExceeded: Bool { get }
    var cachedGraphCount: Int { get }
    var inactiveGraphCount: Int { get }
    var batchCacheProvenance: String { get }
    var batchCounts: NativeCachedSidebarBatchCounts { get }
    var recordsProtectionTreeScans: Bool { get set }
}

/// A row never changes hosting owner while its structural model identity exists.
/// Absolute positions are independent of that owner, including cross-chunk moves.
private struct NativeSidebarOwnedSlot: Identifiable {
    let row: SidebarRows.Row
    let index: Int
    var rollout: SidebarFolderRolloutGeometry?
    var id: String { row.id }
}

private struct SidebarFolderRolloutGeometry {
    let id = UUID()
    let distance: CGFloat
    let headerID: String
    let animation: Animation
    let clipTop: CGFloat
    var closing = false
}

/// Folder contents roll as one strip beneath their header, keeping row spacing.
/// Translation and clipping leave row height, controls and native owners intact.
private struct SidebarFolderRollout: AnimatableModifier {
    var progress: CGFloat
    let geometry: SidebarFolderRolloutGeometry?
    let reduced: Bool
    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        if let geometry {
            content
                .offset(y: reduced ? 0 : -geometry.distance * (1 - min(1, max(0, progress))))
                .clipShape(SidebarFolderRolloutClip(top: geometry.clipTop))
        } else { content }
    }
}

private struct SidebarFolderRolloutClip: Shape {
    let top: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: top, width: rect.width, height: max(0, rect.maxY - top)))
    }
}

private struct SidebarFolderRolloutRow<Content: View>: View {
    @State private var geometry: SidebarFolderRolloutGeometry?
    @State private var progress: CGFloat = 1
    @State private var attached = false
    @State private var requestID: UUID?
    @State private var suppressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var saver = BatterySaver.shared
    let requested: SidebarFolderRolloutGeometry?
    let content: Content
    let finished: (UUID) -> Void
    init(geometry: SidebarFolderRolloutGeometry?, finished: @escaping (UUID) -> Void,
         @ViewBuilder content: () -> Content) {
        _geometry = State(initialValue: geometry)
        requested = geometry
        self.finished = finished
        self.content = content()
    }
    var body: some View {
        content.modifier(SidebarFolderRollout(progress: progress,
            geometry: geometry, reduced: suppressed || reduceMotion || saver.isActive))
            .onAppear {
                guard requested != nil else { return }
                attached = true; begin()
            }
            .onDisappear {
                guard geometry != nil else { return }
                attached = false
                // A cancelled yielded start must not leave a cached row folded
                // forever, or replay that old disclosure when it returns.
                Motion.instant { suppressed = true; progress = 1 }
                if let geometry, geometry.closing { finished(geometry.id) }
            }
            .onChange(of: requested?.id) {
                guard requested != nil else { return }
                attached = true; begin()
            }
            .onChange(of: reduceMotion || saver.isActive) { _, reduced in
                if reduced {
                    suppressed = true
                    if let geometry, geometry.closing { finished(geometry.id) }
                }
            }
    }
    private func begin() {
        guard attached, let requested, requested.id != requestID else { return }
        let reduced = reduceMotion || saver.isActive
        Motion.instant {
            geometry = requested
            requestID = requested.id
            suppressed = reduced
            progress = reduced || requested.closing ? 1 : 0
        }
        // A detached root may have retained its old displayed membership. Let
        // this update install the new folded pose before starting its rollout.
        Task { @MainActor in
            await Task.yield()
            guard attached, requestID == requested.id else { return }
            withAnimation(suppressed || reduceMotion || saver.isActive ? nil : requested.animation,
                          completionCriteria: .removed) {
                progress = requested.closing ? 0 : 1
            } completion: {
                if requested.closing { finished(requested.id) }
            }
        }
    }
}

@MainActor protocol NativeSidebarInteractionRetaining: AnyObject, Sendable {
    func setInteraction(_ active: Bool, row: String, token: UUID)
}
struct NativeSidebarInteraction: Sendable {
    let row: String
    weak var owner: (any NativeSidebarInteractionRetaining)?
    @MainActor func set(_ active: Bool, token: UUID) { owner?.setInteraction(active, row: row, token: token) }
}
private struct NativeSidebarInteractionKey: EnvironmentKey {
    static let defaultValue: NativeSidebarInteraction? = nil
}
extension EnvironmentValues {
    var nativeSidebarInteraction: NativeSidebarInteraction? {
        get { self[NativeSidebarInteractionKey.self] }
        set { self[NativeSidebarInteractionKey.self] = newValue }
    }
}
private struct NativeSidebarPresentationLifetime: ViewModifier {
    let active: Bool
    @Environment(\.nativeSidebarInteraction) private var interaction
    @State private var token = UUID()
    func body(content: Content) -> some View {
        content
            .onChange(of: active, initial: true) { _, active in interaction?.set(active, token: token) }
            .onDisappear { interaction?.set(false, token: token) }
    }
}
extension View {
    /// The binding's real presentation lifetime protects the original row root,
    /// including presentations opened through keyboard or accessibility actions.
    func nativeSidebarPresented(_ active: Bool) -> some View {
        modifier(NativeSidebarPresentationLifetime(active: active))
    }
}

/// A committed native row layout, also available to native AX/order bridges.
@MainActor final class NativeSidebarRowLayoutView: NSView {
    var rowID = ""
    var generation: UInt64 = 0
    private(set) var committedGeneration: UInt64?
    private var committedBounds: NSRect?
    private weak var committedWindow: NSWindow?
    var hasCommittedCurrentBounds: Bool { committedBounds == bounds && committedWindow === window && window != nil }
    var committed: ((NativeSidebarRowLayoutView) -> Void)?
    private var callbackScheduled = false
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func configure(row: String, generation: UInt64, committed: @escaping (NativeSidebarRowLayoutView) -> Void) {
        self.rowID = row
        self.committed = committed
        if self.generation != generation || committedGeneration == nil {
            self.generation = generation
            committedGeneration = nil
            needsLayout = true
        }
    }
    override func layout() {
        super.layout()
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        committedGeneration = generation
        committedBounds = bounds
        committedWindow = window
        guard !callbackScheduled else { return }
        callbackScheduled = true
        // The native layout callback has committed; report outside SwiftUI layout.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.callbackScheduled = false
            self.committed?(self)
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        committedGeneration = nil
        committedBounds = nil
        committedWindow = nil
        needsLayout = true
    }
    override func setFrameSize(_ size: NSSize) {
        let changed = frame.size != size
        super.setFrameSize(size)
        if changed { committedGeneration = nil; committedBounds = nil; needsLayout = true }
    }
}
private struct NativeSidebarRowLayoutAnchor: NSViewRepresentable {
    let row: String
    let generation: UInt64
    let committed: (NativeSidebarRowLayoutView) -> Void
    func makeNSView(context: Context) -> NativeSidebarRowLayoutView { NativeSidebarRowLayoutView(frame: .zero) }
    func updateNSView(_ view: NativeSidebarRowLayoutView, context: Context) {
        view.configure(row: row, generation: generation, committed: committed)
    }
}

/// A native hosting boundary must honor both the caller's transaction and the
/// two motion policies before assigning its structural placement animation.
@MainActor enum NativeSidebarPlacementMotion {
    static func animation(transaction: Transaction, reduceMotion: Bool, reducedByPolicy: Bool) -> Animation? {
        transaction.disablesAnimations || reduceMotion || reducedByPolicy ? nil : (transaction.animation ?? Look.quick)
    }
}

private struct NativeSidebarBatchRoot<Content: View>: View {
    let slots: [NativeSidebarOwnedSlot]
    let total: Int
    let generation: UInt64
    let inherited: EnvironmentValues
    let transaction: Transaction
    let viewport: SidebarRowsViewport
    let navigation: NativeSidebarNavigation
    weak var interactionOwner: (any NativeSidebarInteractionRetaining)?
    let committed: (NativeSidebarRowLayoutView) -> Void
    let finishedClosing: (String, UUID) -> Void
    let content: (SidebarRows.Row, Int, Int) -> Content
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(slots) { slot in
                SidebarFolderRolloutRow(geometry: slot.rollout, finished: { finishedClosing(slot.id, $0) }) {
                    content(slot.row, slot.index, total)
                        .frame(maxWidth: .infinity)
                        .frame(height: Look.rowHeight)
                        .background(NativeSidebarRowLayoutAnchor(row: slot.id, generation: generation, committed: committed))
                }
                    .allowsHitTesting(slot.rollout?.closing != true)
                    .disabled(slot.rollout?.closing == true)
                    .accessibilityHidden(slot.rollout?.closing == true)
                    .environment(\.bufferedSidebarFocus, BufferedSidebarFocus(row: slot.id, viewport: viewport))
                    .environment(\.nativeSidebarNavigationRow, NativeSidebarNavigationRow(row: slot.id, navigation: navigation))
                    .environment(\.nativeSidebarInteraction, NativeSidebarInteraction(row: slot.id, owner: interactionOwner))
                    .offset(y: CGFloat(slot.index) * (Look.rowHeight + Look.rowGap))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .nativeSidebarPublicEnvironment(inherited)
        // Apply the incoming structural transaction only when placement changes.
        // Replaying it on every later descendant update would impose stale motion
        // policy on hover, disclosure and control feedback inside the cached root.
        .animation(placementAnimation, value: slots.map(\.id))
        .animation(placementAnimation, value: slots.map(\.index))
    }
    private var placementAnimation: Animation? {
        NativeSidebarPlacementMotion.animation(transaction: transaction,
            reduceMotion: inherited.accessibilityReduceMotion, reducedByPolicy: Motion.reduced)
    }
}

/// Immutable ownership can produce interleaved roots after a reorder. Empty
/// slots are not controls and must pass pointer/drop hits to the actual row root.
@MainActor private final class NativeSidebarBatchHostingView<Content: View>: NSHostingView<NativeSidebarBatchRoot<Content>> {
    private final class WeakRow {
        weak var view: NativeSidebarRowLayoutView?
        init(_ view: NativeSidebarRowLayoutView) { self.view = view }
    }
    private var rowAnchors: [String: WeakRow] = [:]
    private var rollingHeaders: [String: String] = [:]
    private var occupiedRows: [String: NSRect] = [:]
    var revealEdge: ((String) -> CGFloat?)?
    func record(_ anchor: NativeSidebarRowLayoutView) {
        guard occupiedRows[anchor.rowID] != nil else { return }
        rowAnchors[anchor.rowID] = WeakRow(anchor)
    }
    func occupy(_ slots: [NativeSidebarOwnedSlot], width: CGFloat) {
        occupiedRows = Dictionary(uniqueKeysWithValues: slots.filter { $0.rollout?.closing != true }.map {
            ($0.id, NSRect(x: 0, y: CGFloat($0.index) * (Look.rowHeight + Look.rowGap),
                          width: width, height: Look.rowHeight))
        })
        rowAnchors = rowAnchors.filter { occupiedRows[$0.key] != nil }
        rollingHeaders = rollingHeaders.filter { occupiedRows[$0.key] != nil }
        for slot in slots {
            if let rollout = slot.rollout { rollingHeaders[slot.id] = rollout.headerID }
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        // A rollout can carry a child across another eight-row owner's slots.
        // Read the cached native anchors, without scanning the hosting tree.
        let accepts = occupiedRows.contains { id, destination in
            guard let anchor = rowAnchors[id]?.view, anchor.window === window else {
                return rollingHeaders[id] == nil && destination.contains(local)
            }
            let actual = convert(anchor.bounds.intersection(anchor.visibleRect), from: anchor)
            if let header = rollingHeaders[id] {
                if abs(actual.minY - destination.minY) < 0.5 {
                    rollingHeaders.removeValue(forKey: id)
                } else {
                    guard let edge = revealEdge?(header), local.y >= edge else { return false }
                }
            }
            return actual.contains(local)
        }
        guard accepts else { return nil }
        return super.hitTest(point)
    }
}

@MainActor private final class NativeBatchClipObservation: NSObject {
    private let changed: () -> Void
    init(clip: NSClipView, changed: @escaping () -> Void) {
        self.changed = changed
        super.init()
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
            name: NSView.boundsDidChangeNotification, object: clip)
    }
    @objc private func boundsChanged(_ note: Notification) { changed() }
    deinit { NotificationCenter.default.removeObserver(self) }
}

/// Own the local monitor independently of native dismantling. AppKit teardown
/// normally calls detach; a naturally released owner also removes its exact token.
private final class NativeBatchMouseObservation {
    private final class Token: @unchecked Sendable {
        let value: Any
        init(_ value: Any) { self.value = value }
    }
    private var token: Token?
    @MainActor init(changed: @escaping @MainActor (NSEvent) -> Void) {
        token = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                           .leftMouseUp, .rightMouseUp, .otherMouseUp]) { event in
            MainActor.assumeIsolated { changed(event) }
            return event
        }.map(Token.init)
    }
    @MainActor func detach() {
        if let token { NSEvent.removeMonitor(token.value) }
        token = nil
    }
    deinit {
        guard let token else { return }
        // A final reference can be released from outside the main actor. The
        // opaque token stays alive until AppKit removes it on the main queue.
        DispatchQueue.main.async { NSEvent.removeMonitor(token.value) }
    }
}

@MainActor private final class NativeBatchMenuObservation: NSObject {
    private let changed: (NSMenu, Bool) -> Void
    init(changed: @escaping (NSMenu, Bool) -> Void) {
        self.changed = changed
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(began), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(ended), name: NSMenu.didEndTrackingNotification, object: nil)
    }
    @objc private func began(_ note: Notification) { if let menu = note.object as? NSMenu { changed(menu, true) } }
    @objc private func ended(_ note: Notification) { if let menu = note.object as? NSMenu { changed(menu, false) } }
    deinit { NotificationCenter.default.removeObserver(self) }
}

@MainActor final class NativeCachedSidebarBatchesView<Content: View>: NSView, NativeCachedSidebarBatchesReporting, NativeSidebarInteractionRetaining, SidebarWarmOwnerRetaining {
    private typealias Root = NativeSidebarBatchRoot<Content>
    private final class Entry {
        let host: NativeSidebarBatchHostingView<Content>
        var generation: UInt64
        init(host: NativeSidebarBatchHostingView<Content>, generation: UInt64) {
            self.host = host; self.generation = generation
        }
    }
    private final class WeakAnchor {
        weak var value: NativeSidebarRowLayoutView?
        init(_ value: NativeSidebarRowLayoutView) { self.value = value }
    }
    // Bound inactive native graphs across sections; keep a diagnostic opt-out.
    private let retainsInactiveOwners = ProcessInfo.processInfo.environment["VANE_RETAIN_INACTIVE_SPACE_ROW_OWNERS"] != "0"
    private struct InactiveOwners {
        let entries: [UUID: Entry]
        let ownership: [String: UUID]
        let budget: UUID
    }
    private weak var supplyingStore: TabStore?
    private var ownerObservations: [AnyCancellable] = []
    private var visitMayBeArchived = true
    private var ownerVisible = false
    private var inactiveOwners: [SidebarNativeReadinessScope: InactiveOwners] = [:]
    private var inactiveOrder: [SidebarNativeReadinessScope] = []
    private var activeScope: SidebarNativeReadinessScope?
    private var configuredScope = false
    private final class InteractionLease: NativeSidebarInteractionRetaining {
        weak var owner: NativeCachedSidebarBatchesView?
        let visit: UUID
        init(owner: NativeCachedSidebarBatchesView, visit: UUID) { self.owner = owner; self.visit = visit }
        func setInteraction(_ active: Bool, row: String, token: UUID) {
            guard let owner, owner.visit == visit else { return }
            owner.setInteraction(active, row: row, token: token)
        }
    }
    private var visit = UUID()
    private var interactionLease: InteractionLease?
    private var cache: [UUID: Entry] = [:]
    private var mounted = Set<UUID>()
    private var ownership: [String: UUID] = [:]
    private var groups: [UUID: [NativeSidebarOwnedSlot]] = [:]
    private var rows: [SidebarRows.Row] = []
    private var authorizedRowIDs: Set<String> = []
    private var rowIndexByID: [String: Int] = [:]
    private var anchors: [String: WeakAnchor] = [:]
    private var content: ((SidebarRows.Row, Int, Int) -> Content)?
    private var inherited = EnvironmentValues()
    private var transaction = Transaction()
    private var rowWindow = NativeSidebarResidentWindow()
    private var generation: UInt64 = 0
    private var geometryRevision: UInt64 = 0
    private var readiness: SidebarNativeReadinessCoordinator.Ticket?
    private var readinessSection: String?
    private var readinessRowIDs: [String] = []
    private var needsReconcile = true
    private var reconciling = false
    private var reconcileAgain = false
    private var previousWidth: CGFloat = -1
    private var previousVisible: CGRect?
    private var sampledGeometryRevision: UInt64?
    private weak var clip: NSClipView?
    private var observation: NativeBatchClipObservation?
    private var focusObservation: AnyCancellable?
    private var viewport = SidebarRowsViewport()
    private var navigation = NativeSidebarNavigation()
    private let pendingNavigationToken = UUID()
    private(set) var focusedRows: Set<String> = []
    private var requestedProtection: Set<String> = []
    private var interactions: [UUID: String] = [:]
    private var pressedRows: Set<String> = []
    private var menuRows: [ObjectIdentifier: Set<String>] = [:]
    private var menuObservation: NativeBatchMenuObservation?
    private var mouseObservation: NativeBatchMouseObservation?
    /// Injectable population boundary for adversarial readiness tests.
    var geometryScheduler: (@escaping @MainActor () -> Void) -> Void = { work in
        DispatchQueue.main.async { work() }
    }
    private var scheduled = false
    private var disposed = false
    private(set) var accessibilityRowsExpanded = false
    private(set) var batchCounts = NativeCachedSidebarBatchCounts()
    // Opt-in owner-level diagnostics; no per-node instrumentation in shipping.
    var recordsProtectionTreeScans = false
    var usesThreeBatchBudget: Bool { rowWindow.usesThreeBatchBudget }
    var requestedMaxGraphBudget: Int { rowWindow.requestedMaxGraphBudget }
    var visibleCoverageExceedsBudget: Bool { rowWindow.visibleCoverageExceedsBudget }
    var residentRowRange: Range<Int> { rowWindow.range }
    var stagingEnabled: Bool { false }
    var attachedLogicalRows: Int { mounted.reduce(0) { $0 + (groups[$1]?.count ?? 0) } }
    var cachedLogicalRows: Int { cache.keys.reduce(0) { $0 + (groups[$1]?.count ?? 0) } }
    var attachedGraphCount: Int { mounted.count }
    var nominalAttachedGraphBudget: Int { usesThreeBatchBudget ? requestedMaxGraphBudget + 2 : 0 }
    var attachedGraphBudgetExceeded: Bool {
        nominalAttachedGraphBudget > 0 && attachedGraphCount > nominalAttachedGraphBudget
    }
    var cachedGraphCount: Int { cache.count }
    var inactiveGraphCount: Int { inactiveOwners.values.reduce(0) { $0 + $1.entries.count } }
    var batchCacheProvenance: String { NativeCachedSidebarBatchesExperiment.provenance }
    private var pitch: CGFloat { Look.rowHeight + Look.rowGap }
    private var sectionHeight: CGFloat { max(0, CGFloat(rows.count) * pitch - Look.rowGap) }
    override var isFlipped: Bool { true }
    override func accessibilityChildren() -> [Any]? { navigation.accessibilityChildren() }
    override func accessibilityChildrenInNavigationOrder() -> [any NSAccessibilityElementProtocol]? {
        navigation.accessibilityChildrenInNavigationOrder()
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: sectionHeight) }

    /// Every source is intersected with current authorized visible rows. A stale
    /// interaction never resurrects a locked, collapsed or deleted control.
    var protectedRows: Set<String> {
        var result = requestedProtection.union(focusedRows).union(interactions.values).union(pressedRows)
        for source in menuRows.values { result.formUnion(source) }
        if let responder = window?.firstResponder {
            for group in mounted {
                guard let entry = cache[group], entry.host.window === window else { continue }
                recordProtectionScan(group, entry: entry)
                if Self.containsResponder(entry.host, responder: responder) {
                    result.formUnion(groups[group, default: []].map(\.id))
                }
            }
        }
        for group in mounted {
            guard let entry = cache[group], entry.host.window === window else { continue }
            recordProtectionScan(group, entry: entry)
            if Self.containsHighlightedControl(entry.host) {
                result.formUnion(groups[group, default: []].map(\.id))
            }
        }
        if !rows.isEmpty { result.formUnion([rows[0].id, rows[rows.count - 1].id]) }
        for row in focusedRows {
            guard let index = rowIndexByID[row] else { continue }
            if index > 0 { result.insert(rows[index - 1].id) }
            if index + 1 < rows.count { result.insert(rows[index + 1].id) }
        }
        return result.intersection(authorizedRowIDs)
    }
    private func recordProtectionScan(_ group: UUID, entry: Entry) {
        guard recordsProtectionTreeScans else { return }
        batchCounts.protectionOwnerTreeScans += 1
        if !mounted.contains(group) || entry.host.window !== window {
            batchCounts.detachedProtectionOwnerTreeScans += 1
        }
    }
    private static func containsHighlightedControl(_ view: NSView) -> Bool {
        if let control = view as? NSControl, control.cell?.isHighlighted == true { return true }
        return view.subviews.contains(where: containsHighlightedControl)
    }
    private static func containsResponder(_ view: NSView, responder: NSResponder) -> Bool {
        if view === responder { return true }
        if let field = view as? NSTextField, field.currentEditor() === responder { return true }
        return view.subviews.contains { containsResponder($0, responder: responder) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        observeViewport()
        menuObservation = NativeBatchMenuObservation { [weak self] menu, active in
            guard let self else { return }
            let key = ObjectIdentifier(menu)
            if active {
                var source = self.pressedRows
                for ancestor in self.menuRows.values { source.formUnion(ancestor) }
                self.menuRows[key] = source
            } else { self.menuRows.removeValue(forKey: key) }
            self.needsReconcile = true
            self.scheduleGeometry()
        }
        mouseObservation = NativeBatchMouseObservation { [weak self] event in self?.receiveMouse(event) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func observeViewport() {
        focusObservation = viewport.$focusedRows.sink { [weak self] value in
            guard let self else { return }
            self.focusedRows = value
            self.needsReconcile = true
            self.reconcileLastGeometry()
        }
    }

    private func observeOwner(_ store: TabStore?) {
        guard supplyingStore !== store else { return }
        revokeInactiveOwners()
        ownerObservations.removeAll()
        supplyingStore = store
        ownerVisible = store?.profileVisible == true
        // A different owner cannot inherit any authority from the previous visit.
        visitMayBeArchived = false
        guard let store else { return }
        ownerObservations = [
            store.sidebarRowsProtectionRevoked.sink { [weak self] in self?.revokeInactiveOwners() },
            store.$profileVisible.dropFirst().sink { [weak self] visible in
                guard let self else { return }
                self.ownerVisible = visible
                if !visible { self.revokeInactiveOwners() }
            }
        ]
    }

    func discardInactiveOwners(in scope: SidebarNativeReadinessScope) {
        if let retained = inactiveOwners.removeValue(forKey: scope) {
            SidebarWarmOwnerBudget.release(retained.budget)
            batchCounts.inactiveScopeEvictions += 1
        }
        inactiveOrder.removeAll { $0 == scope }
    }

    func revokeInactiveOwners() {
        visitMayBeArchived = false
        for retained in inactiveOwners.values { SidebarWarmOwnerBudget.release(retained.budget) }
        inactiveOwners.removeAll()
        inactiveOrder.removeAll()
        // Authentication can change beneath an already-collapsed outer folder
        // without changing the section's visible IDs. Revoke its old visuals at
        // the protection signal, before another configure can carry them forward.
        for key in Array(groups.keys) {
            guard let slots = groups[key], slots.contains(where: { $0.rollout?.closing == true }) else { continue }
            let remaining = slots.filter { $0.rollout?.closing != true }
            groups[key] = remaining
            if let entry = cache[key] {
                entry.host.rootView = makeRoot(slots: remaining, animate: false)
                batchCounts.rootUpdates += 1
            }
            needsReconcile = true
        }
        reconcileLastGeometry()
    }

    private func mayRetain(_ scope: SidebarNativeReadinessScope?) -> Bool {
        guard let store = supplyingStore, let scope else { return false }
        return ownerVisible && store.profileVisible && scope.storeID == ObjectIdentifier(store)
            && scope.surfaceID == nil && scope.spaceID != nil && !SidebarWarmOwnerBudget.underPressure
    }

    private func changeScope(_ next: SidebarNativeReadinessScope?) {
        guard retainsInactiveOwners else { return }
        if !configuredScope {
            visitMayBeArchived = mayRetain(next)
            interactionLease = InteractionLease(owner: self, visit: visit)
        }
        defer { activeScope = next; configuredScope = true }
        guard configuredScope, activeScope != next else { return }
        // Consume the destination before reserving outgoing capacity. Otherwise
        // the outgoing visit can evict the graph this very configure will reuse.
        let arriving: InactiveOwners?
        if let next, mayRetain(next), let retained = inactiveOwners.removeValue(forKey: next) {
            arriving = retained
            SidebarWarmOwnerBudget.release(retained.budget)
            inactiveOrder.removeAll { $0 == next }
        } else { arriving = nil }
        SidebarNativeReadinessCoordinator.shared.unregister(readiness)
        readiness = nil
        sampledGeometryRevision = nil
        for entry in cache.values { entry.host.removeFromSuperview() }
        if visitMayBeArchived, let previous = activeScope, mayRetain(previous) {
            // Retain only mounted owners, never every graph visited while scrolling.
            // Five eight-row roots per Space, three inactive Spaces per section.
            let keep = Set(mounted.sorted {
                (groups[$0]?.first?.index ?? .max) < (groups[$1]?.first?.index ?? .max)
            }.prefix(5))
            let entries = cache.filter { keep.contains($0.key) }
            if let store = supplyingStore,
               let budget = SidebarWarmOwnerBudget.retain(self, scope: previous, graphs: entries.count, store: store) {
                inactiveOwners[previous] = InactiveOwners(entries: entries,
                    ownership: ownership.filter { entries[$0.value] != nil }, budget: budget)
                inactiveOrder.removeAll { $0 == previous }
                inactiveOrder.append(previous)
            }
        }
        cache.removeAll(); mounted.removeAll(); groups.removeAll(); ownership.removeAll(); anchors.removeAll()
        interactions.removeAll(); pressedRows.removeAll(); menuRows.removeAll(); requestedProtection.removeAll()
        visit = UUID()
        interactionLease = InteractionLease(owner: self, visit: visit)
        focusObservation = nil
        navigation.detach()
        navigation = NativeSidebarNavigation()
        viewport = SidebarRowsViewport()
        focusedRows.removeAll()
        accessibilityRowsExpanded = false
        observeViewport()
        visitMayBeArchived = mayRetain(next)
        if let next, mayRetain(next) {
            if let retained = arriving {
                cache = retained.entries
                ownership = retained.ownership
                batchCounts.inactiveScopeHits += 1
            } else { batchCounts.inactiveScopeMisses += 1 }
        }
        while inactiveOrder.count > 3 {
            discardInactiveOwners(in: inactiveOrder[0])
        }
    }

    func configure(rows supplied: [SidebarRows.Row], modelIDs: Set<String>, environment: EnvironmentValues,
                   protectedRows: Set<String> = [], readinessSection: String? = nil, transaction: Transaction = Transaction(),
                   owner: TabStore? = nil,
                   content: @escaping (SidebarRows.Row, Int, Int) -> Content) {
        guard !disposed else { return }
        let oldHeight = sectionHeight
        let sameScope = activeScope == environment.sidebarNativeReadinessScope
        let previousOrder = rows
        let previousGroups = groups
        let previousRows = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if retainsInactiveOwners { observeOwner(owner) }
        changeScope(environment.sidebarNativeReadinessScope)
        rows = supplied.filter { modelIDs.contains($0.id) }
        authorizedRowIDs = Set(rows.map(\.id))
        rowIndexByID = Dictionary(rows.enumerated().map { ($0.element.id, $0.offset) },
                                  uniquingKeysWith: { first, _ in first })
        requestedProtection = protectedRows
        self.readinessSection = readinessSection
        readinessRowIDs = rows.map(\.id)
        self.content = content
        inherited = environment
        self.transaction = transaction
        generation &+= 1
        needsReconcile = true
        ownership = ownership.filter { modelIDs.contains($0.key) }
        var sizes: [UUID: Int] = [:]
        for group in ownership.values { sizes[group, default: 0] += 1 }
        // Existing members never migrate to a new root. New members join an
        // adjacent non-full owner, otherwise create a local owner of their own.
        for index in rows.indices where ownership[rows[index].id] == nil {
            let before = index > 0 ? ownership[rows[index - 1].id] : nil
            let after = rows[(index + 1)...].first.flatMap { ownership[$0.id] }
            let adjacent = [before, after].compactMap { $0 }.first { sizes[$0, default: 0] < SidebarRowWindow.batch }
            let owner = adjacent ?? UUID()
            ownership[rows[index].id] = owner
            sizes[owner, default: 0] += 1
        }
        groups.removeAll(keepingCapacity: true)
        var folderAncestors: [(depth: Int, index: Int, id: String, distance: CGFloat)] = []
        let disclosureViewport = clip.map { convert($0.bounds, from: $0) } ?? previousVisible ?? bounds
        let animatesDisclosure = sameScope && transaction.animation != nil && !transaction.disablesAnimations
            && !environment.accessibilityReduceMotion && !Motion.reduced
        for (index, row) in rows.enumerated() {
            folderAncestors.removeAll { $0.depth >= row.visible.depth }
            let ancestor = folderAncestors.last { $0.distance > 0 }
            let visible = disclosureViewport.intersects(CGRect(x: 0, y: CGFloat(index) * pitch,
                                                               width: bounds.width, height: Look.rowHeight))
            let rollout = animatesDisclosure && visible && previousRows[row.id] == nil
                ? ancestor.map { SidebarFolderRolloutGeometry(distance: $0.distance,
                    headerID: $0.id, animation: transaction.animation!,
                    clipTop: CGFloat($0.index + 1 - index) * pitch) } : nil
            if let owner = ownership[row.id] {
                groups[owner, default: []].append(NativeSidebarOwnedSlot(row: row, index: index, rollout: rollout))
            }
            if let folder = row.visible.entry.folder {
                let opening = animatesDisclosure && !folder.collapsed
                    && previousRows[row.id]?.visible.entry.folder?.collapsed == true
                let end = opening ? rows[(index + 1)...].firstIndex {
                    $0.visible.depth <= row.visible.depth
                } ?? rows.endIndex : index + 1
                let revealedCount = rows[(index + 1)..<end].filter { previousRows[$0.id] == nil }.count
                // Hundreds of offscreen children must not keep the viewport
                // empty while the whole document rolls past the reveal edge.
                let visibleTravel = max(pitch, disclosureViewport.maxY - CGFloat(index + 1) * pitch)
                folderAncestors.append((row.visible.depth, index, row.id,
                    min(CGFloat(revealedCount) * pitch, visibleTravel)))
            }
        }
        if animatesDisclosure {
            var closingFolders: [(depth: Int, index: Int, id: String, distance: CGFloat)] = []
            for (index, row) in previousOrder.enumerated() {
                closingFolders.removeAll { $0.depth >= row.visible.depth }
                if let ancestor = closingFolders.last, !authorizedRowIDs.contains(row.id), modelIDs.contains(row.id),
                   let owner = ownership[row.id], mounted.contains(owner),
                   previousGroups[owner]?.contains(where: { $0.id == row.id && $0.rollout?.closing != true }) == true,
                   disclosureViewport.intersects(CGRect(x: 0, y: CGFloat(index) * pitch,
                                                       width: bounds.width, height: Look.rowHeight)) {
                    let geometry = SidebarFolderRolloutGeometry(distance: ancestor.distance,
                        headerID: ancestor.id, animation: transaction.animation!,
                        clipTop: CGFloat(ancestor.index + 1 - index) * pitch, closing: true)
                    groups[owner, default: []].append(NativeSidebarOwnedSlot(row: row, index: index, rollout: geometry))
                }
                if let folder = row.visible.entry.folder, !folder.collapsed,
                   let current = rowIndexByID[row.id].map({ rows[$0] }),
                   let folded = current.visible.entry.folder, folded.collapsed,
                   folded.requiresAuthentication != true {
                    let end = previousOrder[(index + 1)...].firstIndex {
                        $0.visible.depth <= row.visible.depth
                    } ?? previousOrder.endIndex
                    let hiddenCount = previousOrder[(index + 1)..<end].filter { !authorizedRowIDs.contains($0.id) }.count
                    let visibleTravel = max(pitch, disclosureViewport.maxY - CGFloat(index + 1) * pitch)
                    closingFolders.append((row.visible.depth, index, row.id,
                        min(CGFloat(hiddenCount) * pitch, visibleTravel)))
                }
            }
        }
        // A content/environment refresh can arrive during disclosure. Preserve
        // the same closing request while its visible layout and authority agree;
        // a reopen, deletion, lock, scope change or immediate transaction revokes it.
        if sameScope && !transaction.disablesAnimations && !environment.accessibilityReduceMotion && !Motion.reduced,
           previousOrder.map(\.id) == rows.map(\.id) {
            for (key, slots) in previousGroups where mounted.contains(key) {
                for slot in slots {
                    guard let geometry = slot.rollout, geometry.closing, modelIDs.contains(slot.id),
                          let headerIndex = rowIndexByID[geometry.headerID],
                          let folder = rows[headerIndex].visible.entry.folder,
                          folder.collapsed, folder.requiresAuthentication != true else { continue }
                    groups[key, default: []].append(slot)
                }
            }
        }
        for key in Array(groups.keys) { groups[key]?.sort { $0.index < $1.index } }
        let currentOwners = Set(ownership.values)
        for key in Array(cache.keys) where !currentOwners.contains(key) {
            cache.removeValue(forKey: key)?.host.removeFromSuperview()
            mounted.remove(key)
            batchCounts.graphEvictions += 1
        }
        interactions = interactions.filter { authorizedRowIDs.contains($0.value) }
        pressedRows.formIntersection(authorizedRowIDs)
        menuRows = menuRows.mapValues { $0.intersection(authorizedRowIDs) }
        anchors = anchors.filter { authorizedRowIDs.contains($0.key) }
        viewport.configure(rows: readinessRowIDs, anchor: self)
        registerReadiness(claimingCurrentSection: true)
        navigation.configure(rows: rows.map(\.id), container: self,
            prepareRow: { [weak self] row in self?.prepareNavigation(row) },
            nativeRows: { [weak self] in self?.nativeRowsInAuthoritativeOrder() ?? [] })
        // Submit authoritative membership/content updates now, including detached
        // cached roots. Only explicitly disabled closing visuals may outlive it.
        for (key, entry) in cache { update(entry, slots: groups[key, default: []], animate: mounted.contains(key)) }
        if oldHeight != sectionHeight { invalidateIntrinsicContentSize() }
        if rows.isEmpty { SidebarNativeReadinessCoordinator.shared.complete(readiness) }
        reconcileLastGeometry()
        refreshClip()
    }

    func setAccessibilityRowsExpanded(_ value: Bool = true) {
        guard !disposed, accessibilityRowsExpanded != value else { return }
        accessibilityRowsExpanded = value
        needsReconcile = true
        // Explicit AX demand realizes the same owners immediately, including a
        // first query before the ordinary population callback has sampled bounds.
        if let clip, bounds.width > 0, clip.bounds.height > 0 {
            reconcile(visible: convert(clip.bounds, from: clip))
        } else {
            reconcileLastGeometry()
            scheduleGeometry()
        }
    }
    func nativeRowsInAuthoritativeOrder() -> [(String, NSView)] {
        // An explicit native query may have just laid out newly expanded owners.
        // Read already-committed native anchors immediately; their coalesced
        // readiness callback need not have run yet. No layout is forced here.
        func collect(_ view: NSView) {
            if let anchor = view as? NativeSidebarRowLayoutView,
               anchor.window === window, anchor.committedGeneration == generation,
               anchor.hasCommittedCurrentBounds { anchors[anchor.rowID] = WeakAnchor(anchor) }
            for child in view.subviews { collect(child) }
        }
        for key in mounted { if let host = cache[key]?.host { collect(host) } }
        return rows.compactMap { row in
            guard let anchor = anchors[row.id]?.value, anchor.window === window,
                  anchor.committedGeneration == generation, anchor.hasCommittedCurrentBounds else { return nil }
            return (row.id, anchor)
        }
    }
    private func prepareNavigation(_ row: String?) {
        guard !disposed else { return }
        if let row, authorizedRowIDs.contains(row) {
            interactions[pendingNavigationToken] = row
        } else { interactions.removeValue(forKey: pendingNavigationToken) }
        needsReconcile = true
        // Keep the original destination root alive before a deferred FocusState
        // request. Navigation releases only after real focus acknowledgement.
        reconcileLastGeometry()
        scheduleGeometry()
    }
    func setInteraction(_ active: Bool, row: String, token: UUID) {
        guard !disposed else { return }
        if active { interactions[token] = row } else { interactions.removeValue(forKey: token) }
        needsReconcile = true
        // Presentation bindings can change during a SwiftUI transaction. Native
        // attachment is coalesced, but authoritative row content never is.
        scheduleGeometry()
    }
    private func receiveMouse(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard event.window === window else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point), pitch > 0 else { return }
            let index = Int(floor(point.y / pitch))
            if rows.indices.contains(index), point.y - CGFloat(index) * pitch <= Look.rowHeight {
                pressedRows.insert(rows[index].id)
            }
        default:
            // Let the receiving native control finish its mouse-up action before
            // releasing its owner, including presentation bindings it may set.
            DispatchQueue.main.async { [weak self] in
                self?.pressedRows.removeAll()
                self?.needsReconcile = true
                self?.scheduleGeometry()
            }
        }
    }

    func reconcile(visible: CGRect) {
        guard !disposed, content != nil else { return }
        guard !reconciling else {
            reconcileAgain = true
            scheduleGeometry()
            return
        }
        reconciling = true
        defer {
            reconciling = false
            if reconcileAgain {
                reconcileAgain = false
                needsReconcile = true
                scheduleGeometry()
            }
        }
        previousVisible = visible
        sampledGeometryRevision = geometryRevision
        if let clip { viewport.receive(count: rows.count, visible: visible, clip: clip) }
        let changed = rowWindow.update(count: rows.count, visible: visible, pitch: pitch)
        guard changed || needsReconcile || previousWidth != bounds.width else { checkReadiness(); return }
        if changed { batchCounts.rangeChanges += 1 }
        let lower = min(rows.count, rowWindow.range.lowerBound)
        let range = lower..<min(rows.count, max(lower, rowWindow.range.upperBound))
        let protected = protectedRows
        var wanted = Set<UUID>()
        if accessibilityRowsExpanded {
            wanted = Set(groups.keys)
        } else {
            // Resident selection touches the viewport and explicit keepalives,
            // independent of the total cached/document population.
            for index in range {
                if let owner = ownership[rows[index].id] { wanted.insert(owner) }
            }
            for row in protected {
                if let owner = ownership[row] { wanted.insert(owner) }
            }
        }
        // Closing controls have lost model authority. Keep only their already
        // mounted owners until the visual strip has passed beneath its header.
        for key in mounted where groups[key]?.contains(where: { $0.rollout?.closing == true }) == true {
            wanted.insert(key)
        }
        let wantedGroups = wanted.compactMap { key -> (key: UUID, value: [NativeSidebarOwnedSlot])? in
            guard let slots = groups[key], !slots.isEmpty else { return nil }
            return (key, slots)
        }.sorted { $0.value[0].index < $1.value[0].index }
        for key in mounted.subtracting(wanted) {
            cache[key]?.host.removeFromSuperview()
            batchCounts.graphDetaches += 1
        }
        let oldMounted = mounted
        mounted = wanted
        var previousHost: NSView?
        for (key, slots) in wantedGroups {
            let entry: Entry
            if let existing = cache[key] {
                entry = existing
                if entry.generation != generation { update(entry, slots: slots) }
                if !oldMounted.contains(key) { batchCounts.warmGraphReattachments += 1 }
            } else {
                let host = NativeSidebarBatchHostingView(rootView: makeRoot(slots: slots))
                host.sizingOptions = []
                entry = Entry(host: host, generation: generation)
                cache[key] = entry
                batchCounts.coldGraphCreates += 1
            }
            // Every permanent owner uses the same document origin. Structural
            // movement is wholly inside SwiftUI; an immediate native-parent jump
            // must never cancel or double a child's animated absolute offset.
            let closingHeight = slots.filter { $0.rollout?.closing == true }
                .map { CGFloat($0.index + 1) * pitch }.max() ?? 0
            let target = NSRect(x: 0, y: 0, width: bounds.width, height: max(sectionHeight, closingHeight))
            entry.host.occupy(slots, width: bounds.width)
            entry.host.revealEdge = { [weak self] header in
                guard let self, self.authorizedRowIDs.contains(header),
                      let anchor = self.anchors[header]?.value, anchor.window === self.window else { return nil }
                return self.convert(anchor.bounds, from: anchor).maxY + Look.rowGap
            }
            if entry.host.frame != target { entry.host.frame = target }
            if entry.host.superview !== self || needsReconcile {
                addSubview(entry.host, positioned: previousHost == nil ? .below : .above, relativeTo: previousHost)
            }
            previousHost = entry.host
        }
        needsReconcile = false
        previousWidth = bounds.width
        checkReadiness()
        SidebarScrollTrace.recordRowWindow(range, count: rows.count, clip: clip)
    }
    private func makeRoot(slots: [NativeSidebarOwnedSlot], animate: Bool = true) -> Root {
        var placementTransaction = transaction
        if !animate {
            // Cached, detached owners absorb authoritative structural updates
            // immediately. Reattachment during scrolling must not replay motion
            // from an earlier model transaction.
            placementTransaction.animation = nil
            placementTransaction.disablesAnimations = true
        }
        return Root(slots: slots, total: rows.count, generation: generation,
             inherited: inherited, transaction: placementTransaction, viewport: viewport, navigation: navigation,
             interactionOwner: (interactionLease as (any NativeSidebarInteractionRetaining)?) ?? self,
             committed: { [weak self] anchor in self?.rowDidLayout(anchor) },
             finishedClosing: { [weak self] row, request in
                 // Finish outside SwiftUI's update/disappearance callbacks.
                 DispatchQueue.main.async { [weak self] in self?.finishClosing(row: row, request: request) }
             }, content: content!)
    }
    private func update(_ entry: Entry, slots: [NativeSidebarOwnedSlot], animate: Bool = true) {
        guard entry.generation != generation else { return }
        entry.host.rootView = makeRoot(slots: slots, animate: animate)
        entry.generation = generation
        batchCounts.rootUpdates += 1
    }
    private func finishClosing(row: String, request: UUID) {
        guard !disposed, let owner = ownership[row], let slots = groups[owner],
              slots.contains(where: { $0.id == row && $0.rollout?.id == request && $0.rollout?.closing == true }) else { return }
        let remaining = slots.filter { $0.id != row }
        groups[owner] = remaining
        if let entry = cache[owner] {
            entry.host.rootView = makeRoot(slots: remaining, animate: false)
            batchCounts.rootUpdates += 1
        }
        needsReconcile = true
        reconcileLastGeometry()
    }
    private func rowDidLayout(_ anchor: NativeSidebarRowLayoutView) {
        guard !disposed, anchor.generation == generation, anchor.committedGeneration == generation,
              authorizedRowIDs.contains(anchor.rowID) else { return }
        anchors[anchor.rowID] = WeakAnchor(anchor)
        if let owner = ownership[anchor.rowID] { cache[owner]?.host.record(anchor) }
        navigation.layoutDidCommit()
        checkReadiness()
    }
    private func registerReadiness(claimingCurrentSection: Bool = false) {
        let coordinator = SidebarNativeReadinessCoordinator.shared
        // A delayed old layout, including an empty section, has no authority once
        // removed from its current window/document. Never register it afresh.
        guard !disposed, let window, let scroll = enclosingScrollView, scroll.window === window,
              let document = scroll.documentView, self === document || isDescendant(of: document) else {
            coordinator.unregister(readiness)
            readiness = nil
            return
        }
        if readiness?.scope != inherited.sidebarNativeReadinessScope { coordinator.unregister(readiness) }
        readiness = coordinator.register(scope: inherited.sidebarNativeReadinessScope,
            section: ObjectIdentifier(self), sectionKey: readinessSection, rowIDs: readinessRowIDs,
            generation: generation, geometryRevision: geometryRevision,
            claimingCurrentSection: claimingCurrentSection,
            populationOwnerID: inherited.sidebarNativeReadinessOwnerID)
        // Empty sections have no row layouts to await. Their zero-height
        // background may never receive layout(), so complete only after this
        // registration has verified actual attachment and current ownership.
        if rows.isEmpty { coordinator.complete(readiness) }
    }
    private func geometryChanged() {
        guard !disposed else { return }
        geometryRevision &+= 1
        sampledGeometryRevision = nil
        registerReadiness()
        scheduleGeometry()
    }
    private func checkReadiness() {
        guard !disposed else { return }
        // Even a nonnil ticket may have been withdrawn between configure and this
        // layout. Idempotent refresh reuses a valid nonce and replaces a stale one.
        // Passive callbacks cannot displace a different current section owner.
        registerReadiness()
        if rows.isEmpty { SidebarNativeReadinessCoordinator.shared.complete(readiness); return }
        guard sampledGeometryRevision == geometryRevision, let window, let visible = previousVisible,
              visible.height > 0, bounds.width > 0 else { return }
        guard visible.minY.isFinite, visible.maxY.isFinite else { return }
        let firstVisible = Int(min(CGFloat(rows.count), max(0, floor(visible.minY / pitch))))
        let endVisible = Int(min(CGFloat(rows.count), max(0, ceil(visible.maxY / pitch))))
        // A short section may be wholly above the scroll viewport. Its resident
        // range is then empty; no row layout is visible or required to commit.
        if firstVisible == endVisible {
            SidebarNativeReadinessCoordinator.shared.complete(readiness)
            return
        }
        // Fail closed if a stale resident range has not yet covered this exact
        // viewport; tall viewport fallback expands the range before readiness.
        let lower = min(rows.count, max(0, rowWindow.range.lowerBound))
        let upper = min(rows.count, max(lower, rowWindow.range.upperBound))
        guard lower <= firstVisible, upper >= endVisible else { return }
        for index in lower..<upper where CGRect(x: 0, y: CGFloat(index) * pitch,
            width: bounds.width, height: Look.rowHeight).intersects(visible) {
            let row = rows[index]
            guard let owner = ownership[row.id], mounted.contains(owner),
                  let entry = cache[owner], entry.generation == generation, entry.host.window === window,
                  let anchor = anchors[row.id]?.value, anchor.window === window,
                  anchor.committedGeneration == generation, anchor.hasCommittedCurrentBounds else { return }
            let actual = anchor.convert(anchor.bounds, to: self)
            guard abs(actual.minY - CGFloat(index) * pitch) < 1, abs(actual.height - Look.rowHeight) < 1,
                  abs(actual.width - bounds.width) < 1 else { return }
        }
        SidebarNativeReadinessCoordinator.shared.complete(readiness)
    }
    private func reconcileLastGeometry() {
        if sampledGeometryRevision == geometryRevision, let visible = previousVisible { reconcile(visible: visible) }
    }
    private func refreshClip() {
        guard !disposed else { return }
        let next = window == nil ? nil : enclosingScrollView?.contentView
        if next !== clip {
            observation = nil
            clip = next
            if let next { observation = NativeBatchClipObservation(clip: next) { [weak self] in self?.geometryChanged() } }
            geometryChanged()
        }
        scheduleGeometry()
    }
    private func scheduleGeometry() {
        guard !disposed, !scheduled, clip != nil else { return }
        scheduled = true
        geometryScheduler { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard !self.disposed, let clip = self.clip, clip.bounds.height > 0, self.bounds.width > 0 else { return }
            self.reconcile(visible: self.convert(clip.bounds, from: clip))
        }
    }
    override func layout() { super.layout(); refreshClip(); checkReadiness() }
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let changed = frame.origin != newOrigin
        super.setFrameOrigin(newOrigin)
        if changed { geometryChanged() }
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { geometryChanged() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Representable configure commonly precedes attachment. Actual window
        // attachment is authoritative; subsequent geometry/layout retries are not.
        if window != nil { registerReadiness(claimingCurrentSection: true) }
        refreshClip()
    }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); refreshClip() }
    func detach() {
        disposed = true
        SidebarNativeReadinessCoordinator.shared.unregister(readiness)
        readiness = nil
        observation = nil; clip = nil
        focusObservation = nil
        navigation.detach()
        menuObservation = nil
        menuRows.removeAll()
        mouseObservation?.detach()
        mouseObservation = nil
        for entry in cache.values { entry.host.removeFromSuperview() }
        cache.removeAll(); mounted.removeAll(); groups.removeAll(); ownership.removeAll(); rows.removeAll(); anchors.removeAll()
        revokeInactiveOwners(); activeScope = nil
        ownerObservations.removeAll(); supplyingStore = nil
        visit = UUID(); interactionLease = nil
        interactions.removeAll(); pressedRows.removeAll(); requestedProtection.removeAll()
        readinessRowIDs.removeAll(); authorizedRowIDs.removeAll(); rowIndexByID.removeAll()
        content = nil; inherited = EnvironmentValues()
    }
}

private struct NativeCachedSidebarBatchesBridge<Content: View>: NSViewRepresentable {
    let rows: [SidebarRows.Row]
    let modelIDs: Set<String>
    var protectedRows: Set<String> = []
    var readinessSection: String? = nil
    var owner: TabStore? = nil
    let content: (SidebarRows.Row, Int, Int) -> Content
    func makeNSView(context: Context) -> NativeCachedSidebarBatchesView<Content> { NativeCachedSidebarBatchesView(frame: .zero) }
    func updateNSView(_ view: NativeCachedSidebarBatchesView<Content>, context: Context) {
        view.configure(rows: rows, modelIDs: modelIDs, environment: context.environment, protectedRows: protectedRows, readinessSection: readinessSection,
                       transaction: context.transaction, owner: owner, content: content)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeCachedSidebarBatchesView<Content>, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: max(0, CGFloat(rows.count) * (Look.rowHeight + Look.rowGap) - Look.rowGap))
    }
    static func dismantleNSView(_ view: NativeCachedSidebarBatchesView<Content>, coordinator: ()) { view.detach() }
}
struct NativeCachedSidebarBatchSectionRows<Content: View>: View {
    let rows: [SidebarRows.Row]
    let modelIDs: Set<String>
    var protectedRows: Set<String> = []
    var readinessSection: String? = nil
    var owner: TabStore? = nil
    let content: (SidebarRows.Row, Int, Int) -> Content
    var body: some View {
        NativeCachedSidebarBatchesBridge(rows: rows, modelIDs: modelIDs, protectedRows: protectedRows,
                                        readinessSection: readinessSection, owner: owner, content: content)
            .frame(height: max(0, CGFloat(rows.count) * (Look.rowHeight + Look.rowGap) - Look.rowGap))
    }
}
