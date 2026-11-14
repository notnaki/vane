import AppKit
import SwiftUI
import Combine

/// Created before either hosting root, so a cold page never creates a second
/// download presentation identity or waits for the chrome's body to create it.
@MainActor final class BrowserProfilePresentation {
    let downloads = DownloadFeedback()
}

/// One source of page-envelope insets for inline and retained content.
struct WebCardEnvelopeSpec: Equatable {
    let topGap: CGFloat
    let edgeToEdge: Bool
    let leading: CGFloat
    var trailing: CGFloat { edgeToEdge ? 0 : Look.cardGap }
    var bottom: CGFloat { edgeToEdge ? 0 : Look.cardGap }

    func outerRect(around content: NSRect, flipped: Bool) -> NSRect {
        NSRect(x: content.minX - leading,
               y: content.minY - (flipped ? topGap : bottom),
               width: content.width + leading + trailing,
               height: content.height + topGap + bottom)
    }
}

/// Only explicit public values cross this hosting boundary. In particular this
/// contains neither EnvironmentValues nor the parent SwiftUI FocusStore.
@MainActor struct PagePublicEnvironment: ViewModifier {
    var theme: SpaceChromeTheme
    let colorScheme: ColorScheme
    let displayScale: CGFloat
    let layoutDirection: LayoutDirection
    let locale: Locale
    let font: Font?
    let dynamicTypeSize: DynamicTypeSize
    let legibilityWeight: LegibilityWeight?
    let controlSize: ControlSize
    let isEnabled: Bool
    let multilineTextAlignment: TextAlignment
    let lineSpacing: CGFloat
    let lineLimit: Int?
    let truncationMode: Text.TruncationMode
    let minimumScaleFactor: CGFloat
    var resizeLayout: PageResizeLayout
    let pageLeadingInset: CGFloat?
    let paintOwner: UUID?
    let librarySource: LibraryPageMountReceiptSource?
    let feedbackScope: FeedbackOcclusionScope?
    let pressFeedbackEnabled: Bool

    init(_ inherited: EnvironmentValues) {
        theme = inherited.spaceChromeTheme
        colorScheme = inherited.colorScheme
        displayScale = inherited.displayScale
        layoutDirection = inherited.layoutDirection
        locale = inherited.locale
        font = inherited.font
        dynamicTypeSize = inherited.dynamicTypeSize
        legibilityWeight = inherited.legibilityWeight
        controlSize = inherited.controlSize
        isEnabled = inherited.isEnabled
        multilineTextAlignment = inherited.multilineTextAlignment
        lineSpacing = inherited.lineSpacing
        lineLimit = inherited.lineLimit
        truncationMode = inherited.truncationMode
        minimumScaleFactor = inherited.minimumScaleFactor
        resizeLayout = inherited.pageResizeLayout
        pageLeadingInset = inherited.libraryPageLeadingInset
        paintOwner = inherited.libraryNavigationPaintOwner
        librarySource = inherited.libraryPageMountReceiptSource
        feedbackScope = inherited.feedbackOcclusionScope
        pressFeedbackEnabled = inherited.feel02PressFeedbackEnabled
    }

    func body(content: Content) -> some View {
        content
            .environment(\.spaceChromeTheme, theme)
            .tint(theme.accent).accentColor(theme.accent)
            .environment(\.colorScheme, colorScheme)
            .environment(\.displayScale, displayScale)
            .environment(\.layoutDirection, layoutDirection)
            .environment(\.locale, locale)
            .environment(\.font, font)
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            .environment(\.legibilityWeight, legibilityWeight)
            .environment(\.controlSize, controlSize)
            .environment(\.isEnabled, isEnabled)
            .environment(\.multilineTextAlignment, multilineTextAlignment)
            .environment(\.lineSpacing, lineSpacing)
            .environment(\.lineLimit, lineLimit)
            .environment(\.truncationMode, truncationMode)
            .environment(\.minimumScaleFactor, minimumScaleFactor)
            .environment(\.pageResizeLayout, resizeLayout)
            .environment(\.libraryPageLeadingInset, pageLeadingInset)
            .environment(\.libraryNavigationPaintOwner, paintOwner)
            .environment(\.libraryPageMountReceiptSource, librarySource)
            .environment(\.feedbackOcclusionScope, feedbackScope)
            .environment(\.feel02PressFeedbackEnabled, pressFeedbackEnabled)
    }
}

/// Geometry-affecting model inputs must still match the actual native slot.
/// Space selection, tab selection and page state are intentionally not snapshots:
/// the complete page root observes those original destination objects directly.
@MainActor private struct PageLayoutSignature: Equatable {
    let store: ObjectIdentifier
    let profile: UUID
    let sidebarShown: Bool
    let peeking: Bool
    let floating: Bool
    let sidebarWidth: CGFloat
    let libraryOpen: Bool

    init(_ store: TabStore) {
        self.store = ObjectIdentifier(store)
        profile = store.profileID
        sidebarShown = store.sidebarShown
        peeking = store.sidebarPeeking
        floating = store.sidebarFloatingChrome
        sidebarWidth = SidebarWidth.inWindow(store)
        libraryOpen = store.libraryOpen
    }
}

/// One native page root belongs to one real profile/window, with the same complete
/// SwiftUI page selection/overlays as inline WebCard. It does not take over WebHost
/// sizing/paint policy, Library navigation, or protection/selection publications.
@MainActor final class RetainedBrowserPageHost {
    let presentation: BrowserProfilePresentation
    let hostingView: BrowserHostingView<AnyView>
    private weak var store: TabStore?
    private weak var slot: NativeBrowserPageSlot?
    private var slotGeneration = UUID()
    private var retired = false
    private var revision: UInt64 = 0
    private let transactionRelay = PageInitialTransactionRelay()
    private var geometry: Geometry?
    private var geometryRevision: UInt64 = 0
    private weak var outerMarker: NativePageEnvelopeMarker?
    private var outerGeneration = UUID()
    private weak var normalWindow: NSWindow?
    private var normalRoot: ObjectIdentifier?
    private var normalBounds: NSRect?
    private var normalScale: CGFloat?
    private var normalRevision: UInt64?
    private var receiptLayoutRequestedRevision: UInt64?
    private var windowObservations: PageGeometryObservations?
    private weak var observedWindow: NSWindow?
    private weak var observedRoot: NSView?
    private var visibilityObservation: AnyCancellable?
    private var displayAuthorization: DisplayAuthorization?

    private struct DisplayAuthorization {
        let geometry: Geometry
        let receipt: LibraryPageMountReceipt
    }

    private struct Geometry {
        weak var window: NSWindow?
        let root: ObjectIdentifier
        let generation: UUID
        let slot: ObjectIdentifier
        let bounds: NSRect
        let scale: CGFloat
        let content: NSRect
        let outer: NSRect
        let envelope: WebCardEnvelopeSpec
        let signature: PageLayoutSignature
        let environmentRevision: UInt64
        let geometryRevision: UInt64
        let outerMarker: ObjectIdentifier
        let outerGeneration: UUID
        let receipt: LibraryPageMountReceipt?
    }

    init(store: TabStore, presentation: BrowserProfilePresentation) {
        self.store = store
        self.presentation = presentation
        // The real page root is installed once by its actual slot/context. Do
        // not create and then replace a speculative cold page/FocusStore here.
        hostingView = BrowserHostingView(rootView: AnyView(EmptyView()))
        hostingView.sizingOptions = []
        visibilityObservation = store.$profileVisible.dropFirst().sink { [weak self] _ in
            self?.invalidateGeometry(clearNormalCommit: true)
        }
    }

    fileprivate func reserveSlot() -> UUID {
        slotGeneration = UUID()
        invalidateGeometry(clearNormalCommit: true)
        return slotGeneration
    }

    fileprivate func configure(_ candidate: NativeBrowserPageSlot, environment: PagePublicEnvironment,
                               envelope: WebCardEnvelopeSpec, transaction: Transaction) {
        guard !retired, candidate.live, candidate.generation == slotGeneration, let store else { return }
        displayAuthorization = nil
        if slot !== candidate {
            hostingView.removeFromSuperview()
            slot = candidate
        }
        candidate.environment = environment
        candidate.envelope = envelope
        candidate.signature = PageLayoutSignature(store)
        guard revision < .max else { retire(); return }
        revision += 1
        normalRevision = revision
        normalWindow = nil; normalRoot = nil; normalBounds = nil; normalScale = nil
        candidate.normalLayoutPassed = false
        candidate.needsLayout = true
        bindNormalWindow(candidate)
        hostingView.rootView = AnyView(RetainedPageRoot(store: store, presentation: presentation,
            environment: environment, edgeToEdge: envelope.edgeToEdge, revision: revision,
            parentTransaction: transaction, initialTransaction: transactionRelay))
        synchronize(candidate)
    }

    fileprivate func synchronize(_ candidate: NativeBrowserPageSlot) {
        guard !retired, candidate.live, candidate.generation == slotGeneration,
              candidate.superview != nil, candidate.environment != nil else { return }
        // A valid slot may reparent without another SwiftUI update. Its generation
        // can recover its own host; an obsolete/replaced slot cannot do so.
        if slot == nil { slot = candidate }
        guard slot === candidate else { return }
        bindNormalWindow(candidate)
        if hostingView.superview !== candidate {
            hostingView.removeFromSuperview()
            candidate.addSubview(hostingView)
        }
        if hostingView.frame != candidate.bounds { hostingView.frame = candidate.bounds }
        hostingView.autoresizingMask = [.width, .height]
    }

    private func invalidateGeometry(clearNormalCommit: Bool) {
        geometry = nil
        displayAuthorization = nil
        if geometryRevision == .max { retire(); return }
        geometryRevision += 1
        if clearNormalCommit {
            normalRevision = nil
            normalWindow = nil; normalRoot = nil; normalBounds = nil; normalScale = nil
        }
    }

    private func ownsSlot(_ candidate: NativeBrowserPageSlot) -> Bool {
        !retired && candidate.live && candidate.generation == slotGeneration && slot === candidate
    }

    private func ownsMarker(_ candidate: NativePageEnvelopeMarker) -> Bool {
        !retired && candidate.live && candidate.generation == outerGeneration && outerMarker === candidate
    }

    fileprivate func slotGeometryChanged(_ candidate: NativeBrowserPageSlot, clearNormalCommit: Bool) {
        guard ownsSlot(candidate) else { return }
        invalidateGeometry(clearNormalCommit: clearNormalCommit)
    }

    fileprivate func markerGeometryChanged(_ candidate: NativePageEnvelopeMarker, clearNormalCommit: Bool) {
        guard ownsMarker(candidate) else { return }
        invalidateGeometry(clearNormalCommit: clearNormalCommit)
    }

    fileprivate func slotDidLayout(_ candidate: NativeBrowserPageSlot) {
        guard ownsSlot(candidate) else { return }
        commitNormalGeometry()
    }

    fileprivate func normalLayoutProposed(_ candidate: NativeBrowserPageSlot) {
        guard ownsSlot(candidate), let window = candidate.window,
              let root = window.contentView else { return }
        // A native resize can change SwiftUI's proposal without another
        // updateNSView/environment update. Renew only from that normal proposal;
        // the actual slot/envelope layout must still agree before commitment.
        guard normalRevision != revision || normalWindow !== window
                || normalRoot != ObjectIdentifier(root) || normalBounds != root.bounds
                || normalScale != window.backingScaleFactor else { return }
        invalidateGeometry(clearNormalCommit: false)
        normalRevision = revision
        normalWindow = window; normalRoot = ObjectIdentifier(root)
        normalBounds = root.bounds; normalScale = window.backingScaleFactor
        receiptLayoutRequestedRevision = nil
        observeGeometry(window: window, root: root)
        candidate.normalLayoutPassed = false
        candidate.needsLayout = true
    }

    fileprivate func markerDidLayout(_ candidate: NativePageEnvelopeMarker) {
        guard ownsMarker(candidate) else { return }
        commitNormalGeometry()
    }

    fileprivate func slotWindowChanged(_ candidate: NativeBrowserPageSlot) {
        guard ownsSlot(candidate) else { return }
        // First attachment belongs to the pending normal SwiftUI mount. Later
        // detach/reattach requires another normal commit; it cannot revive proof.
        if normalWindow == nil, normalRevision == revision, candidate.window != nil {
            invalidateGeometry(clearNormalCommit: false)
        } else {
            invalidateGeometry(clearNormalCommit: true)
        }
        synchronize(candidate)
    }

    private func bindNormalWindow(_ candidate: NativeBrowserPageSlot) {
        guard normalRevision == revision, normalWindow == nil,
              let window = candidate.window, let root = window.contentView else { return }
        normalWindow = window
        normalRoot = ObjectIdentifier(root)
        normalBounds = root.bounds
        normalScale = window.backingScaleFactor
        observeGeometry(window: window, root: root)
    }

    private func observeGeometry(window: NSWindow, root: NSView) {
        guard observedWindow !== window || observedRoot !== root else { return }
        windowObservations = nil
        observedWindow = window; observedRoot = root
        let observations = PageGeometryObservations()
        root.postsFrameChangedNotifications = true
        root.postsBoundsChangedNotifications = true
        for (name, object) in [
            (NSWindow.didResizeNotification, window as AnyObject),
            (NSWindow.didChangeBackingPropertiesNotification, window as AnyObject),
            (NSView.frameDidChangeNotification, root as AnyObject),
            (NSView.boundsDidChangeNotification, root as AnyObject)
        ] {
            observations.tokens.append(NotificationCenter.default.addObserver(
                forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.invalidateGeometry(clearNormalCommit: true) }
                })
        }
        windowObservations = observations
    }

    fileprivate func reserveOuterMarker() -> UUID {
        outerGeneration = UUID()
        invalidateGeometry(clearNormalCommit: false)
        return outerGeneration
    }

    fileprivate func registerOuterMarker(_ marker: NativePageEnvelopeMarker) {
        guard !retired, marker.live, marker.generation == outerGeneration else { return }
        if outerMarker !== marker {
            invalidateGeometry(clearNormalCommit: false)
            outerMarker = marker
        }
    }

    fileprivate func outerMarkerDetached(_ marker: NativePageEnvelopeMarker) {
        guard ownsMarker(marker) else { return }
        outerMarker = nil
        invalidateGeometry(clearNormalCommit: true)
    }

#if DEBUG
    var handoffProofDiagnostic: String {
        "revision=\(revision) normal=\(String(describing: normalRevision))"
            + " geometry=\(geometry != nil) receipt=\(geometry?.receipt != nil)"
            + " visible=\(String(describing: store?.profileVisible))"
            + " hidden=\(String(describing: slot?.isHiddenOrHasHiddenAncestor))"
    }
#endif

    /// Only a normal native slot/envelope layout callback may commit geometry.
    /// Fast-path admission NEVER overwrites a stamp with current window bounds.
    private func commitNormalGeometry() {
        guard !retired, let store, let slot, let marker = outerMarker,
              slot.normalLayoutPassed, marker.normalLayoutPassed,
              slot.generation == slotGeneration, marker.generation == outerGeneration,
              normalRevision == revision,
              let window = slot.window, normalWindow === window,
              let root = window.contentView, normalRoot == ObjectIdentifier(root),
              normalBounds == root.bounds, normalScale == window.backingScaleFactor,
              marker.window === window, let envelope = slot.envelope,
              let signature = slot.signature, signature == PageLayoutSignature(store),
              slot.normalProposal == nil || slot.normalProposal == slot.bounds.size,
              slot.bounds.width > 0, slot.bounds.height > 0 else { return }
        let content = slot.convert(slot.bounds, to: root)
        let outer = marker.convert(marker.bounds, to: root)
        // The actual complete envelope must occupy its committed page proposal.
        // This catches a stale positive-size slot after a parked parent resize.
        guard outer == envelope.outerRect(around: content, flipped: root.isFlipped),
              outer.maxX == root.bounds.maxX,
              outer.minY == root.bounds.minY, outer.maxY == root.bounds.maxY else { return }
        geometry = Geometry(window: window, root: ObjectIdentifier(root), generation: slotGeneration,
            slot: ObjectIdentifier(slot), bounds: root.bounds, scale: window.backingScaleFactor,
            content: content, outer: outer, envelope: envelope, signature: signature,
            environmentRevision: revision, geometryRevision: geometryRevision,
            outerMarker: ObjectIdentifier(marker), outerGeneration: outerGeneration,
            receipt: slot.environment?.librarySource?.capture())
        // Library's identical initial bridge request can still be queued during
        // this normal layout. Revisit the native slot once after that drain;
        // only its real layout callback may commit a fresh geometry/receipt pair.
        if geometry?.receipt == nil, receiptLayoutRequestedRevision != revision {
            let expectedRevision = revision
            receiptLayoutRequestedRevision = expectedRevision
            DispatchQueue.main.async { [weak self, weak slot] in
                guard let self, let slot, self.revision == expectedRevision,
                      self.normalRevision == expectedRevision, self.ownsSlot(slot) else { return }
                slot.needsLayout = true
            }
        }
    }

    /// Admission only reads a prior NORMAL native commitment. A later normal
    /// callback may bind a fresh destination receipt after cold marker readiness;
    /// this method never recaptures geometry or manufactures layout authority.
    func layoutForProfileHandoff(in window: NSWindow) -> Bool {
        displayAuthorization = nil
        guard !retired, let store, store.window === window, store.profileVisible,
              !store.libraryOpen, store.libraryGesture.progress == nil, !hasBlockingPresentation(in: window, store: store),
              !window.inLiveResize, (window as? VaneWindow)?.isPreparingPageResize != true,
              let slot, let inherited = slot.environment,
              let geometry, let receipt = geometry.receipt, receipt.isCurrentAndIdle(),
              receipt.owner == inherited.paintOwner,
              !slot.isHiddenOrHasHiddenAncestor, slot.window === window,
              hostingView.superview === slot, hostingView.window === window,
              !hasNativeResizeOwner(hostingView) else { return false }
        guard let root = window.contentView, let marker = outerMarker,
              geometry.window === window, geometry.root == ObjectIdentifier(root),
              geometry.generation == slotGeneration, geometry.slot == ObjectIdentifier(slot),
              geometry.bounds == root.bounds, geometry.scale == window.backingScaleFactor,
              geometry.signature == PageLayoutSignature(store), geometry.environmentRevision == revision,
              geometry.geometryRevision == geometryRevision,
              geometry.outerGeneration == outerGeneration, geometry.outerMarker == ObjectIdentifier(marker),
              marker.window === window, marker.convert(marker.bounds, to: root) == geometry.outer,
              slot.envelope == geometry.envelope,
              slot.convert(slot.bounds, to: root) == geometry.content,
              geometry.outer.width > 0, geometry.outer.height > 0,
              receipt.isCurrentAndIdle() else { return false }
        hostingView.layoutSubtreeIfNeeded()
        guard receipt.isCurrentAndIdle(), !hasNativeResizeOwner(hostingView),
              geometry.environmentRevision == revision, geometry.geometryRevision == geometryRevision,
              geometry.generation == slotGeneration,
              geometry.content == slot.convert(slot.bounds, to: root) else { return false }
        displayAuthorization = DisplayAuthorization(geometry: geometry, receipt: receipt)
        return true
    }

    /// Single-use proof is consumed BEFORE validation/drawing, including any
    /// reentrant display callback. An old layout can never authorize a later draw.
    func displayForProfileHandoff(in window: NSWindow) -> Bool {
        let authorization = displayAuthorization
        displayAuthorization = nil
        guard let authorization, !retired, let store, let slot, let root = window.contentView,
              let marker = outerMarker,
              store.window === window, store.profileVisible, !store.libraryOpen,
              store.libraryGesture.progress == nil, !hasBlockingPresentation(in: window, store: store),
              !window.inLiveResize, (window as? VaneWindow)?.isPreparingPageResize != true,
              slot.window === window, hostingView.superview === slot,
              !slot.isHiddenOrHasHiddenAncestor, !hasNativeResizeOwner(hostingView),
              authorization.receipt.isCurrentAndIdle() else { return false }
        let geometry = authorization.geometry
        guard geometry.window === window, geometry.root == ObjectIdentifier(root),
              geometry.generation == slotGeneration, geometry.slot == ObjectIdentifier(slot),
              geometry.environmentRevision == revision, geometry.geometryRevision == geometryRevision,
              geometry.outerGeneration == outerGeneration, geometry.outerMarker == ObjectIdentifier(marker),
              marker.window === window, geometry.outer == marker.convert(marker.bounds, to: root),
              geometry.bounds == root.bounds,
              geometry.scale == window.backingScaleFactor,
              geometry.signature == PageLayoutSignature(store), geometry.envelope == slot.envelope,
              geometry.content == slot.convert(slot.bounds, to: root) else { return false }
        hostingView.displayIfNeededIgnoringOpacity()
        return true
    }

    private func hasBlockingPresentation(in window: NSWindow, store: TabStore) -> Bool {
        NSApp.modalWindow != nil || window.attachedSheet != nil || store.palette != nil
            || store.externalApp != nil || store.liveFolderSheet || store.tidyPreview != nil
            || store.workspaceSheet != nil || store.organizationSheet
    }

    private func hasNativeResizeOwner(_ view: NSView) -> Bool {
        if let host = view as? WebHost, !host.offscreen,
           host.pageResizeOwnershipWillChange != nil { return true }
        return view.subviews.contains(where: hasNativeResizeOwner)
    }

    fileprivate func permitsNativeAccess(_ candidate: NativeBrowserPageSlot) -> Bool {
        guard !retired, slot === candidate, candidate.generation == slotGeneration,
              let store, store.profileVisible, let window = store.window,
              candidate.window === window, window.isVisible,
              !candidate.isHiddenOrHasHiddenAncestor else { return false }
        return true
    }

    fileprivate func detach(_ candidate: NativeBrowserPageSlot) {
        guard ownsSlot(candidate) else { return }
        invalidateGeometry(clearNormalCommit: true)
        hostingView.removeFromSuperview()
        slot = nil
    }

    func retire() {
        guard !retired else { return }
        retired = true
        displayAuthorization = nil
        slotGeneration = UUID()
        geometry = nil
        windowObservations = nil
        visibilityObservation = nil
        hostingView.removeFromSuperview()
        hostingView.rootView = AnyView(EmptyView())
        presentation.downloads.cancel()
        slot = nil
    }
}

@MainActor struct RetainedBrowserPageSlot: NSViewRepresentable {
    let owner: RetainedBrowserPageHost
    let envelope: WebCardEnvelopeSpec

    func makeNSView(context: Context) -> NativeBrowserPageSlot { NativeBrowserPageSlot(owner: owner) }
    func updateNSView(_ view: NativeBrowserPageSlot, context: Context) {
        view.configure(environment: PagePublicEnvironment(context.environment), envelope: envelope,
                       transaction: context.transaction)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeBrowserPageSlot,
                     context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        let size = CGSize(width: max(0, width), height: max(0, height))
        nsView.normalLayoutProposed(size)
        return size
    }
    static func dismantleNSView(_ view: NativeBrowserPageSlot, coordinator: ()) { view.dismantle() }
}

@MainActor final class NativeBrowserPageSlot: NSView {
    private let owner: RetainedBrowserPageHost
    fileprivate let generation: UUID
    fileprivate var environment: PagePublicEnvironment?
    fileprivate var envelope: WebCardEnvelopeSpec?
    fileprivate var signature: PageLayoutSignature?
    fileprivate var live = true
    fileprivate var normalLayoutPassed = false
    fileprivate var normalProposal: CGSize?

    init(owner: RetainedBrowserPageHost) {
        self.owner = owner
        generation = owner.reserveSlot()
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(environment: PagePublicEnvironment, envelope: WebCardEnvelopeSpec,
                   transaction: Transaction) {
        guard live else { return }
        owner.configure(self, environment: environment, envelope: envelope, transaction: transaction)
    }
    func normalLayoutProposed(_ size: CGSize) {
        guard live else { return }
        if normalProposal != size {
            owner.slotGeometryChanged(self, clearNormalCommit: false)
            normalLayoutPassed = false
            needsLayout = true
        }
        normalProposal = size
        owner.normalLayoutProposed(self)
    }
    override func layout() {
        super.layout()
        if live {
            owner.synchronize(self)
            normalLayoutPassed = true
            owner.slotDidLayout(self)
        }
    }
    override func setFrameSize(_ newSize: NSSize) {
        if frame.size != newSize { owner.slotGeometryChanged(self, clearNormalCommit: false); normalLayoutPassed = false }
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
        if live { owner.synchronize(self) }
    }
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        if frame.origin != newOrigin { owner.slotGeometryChanged(self, clearNormalCommit: false); normalLayoutPassed = false }
        let changed = frame.origin != newOrigin
        super.setFrameOrigin(newOrigin)
        if changed { needsLayout = true }
        if live { owner.synchronize(self) }
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { owner.detach(self) }
        else if live { owner.synchronize(self) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if live { owner.slotWindowChanged(self) }
    }
    override func viewDidHide() { super.viewDidHide(); owner.slotGeometryChanged(self, clearNormalCommit: true) }
    override func viewDidUnhide() { super.viewDidUnhide(); owner.slotGeometryChanged(self, clearNormalCommit: true) }
    func dismantle() {
        guard live else { return }
        owner.detach(self)
        live = false
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard live, owner.permitsNativeAccess(self) else { return nil }
        return super.hitTest(point)
    }
    override func isAccessibilityElement() -> Bool { live && owner.permitsNativeAccess(self) }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityChildren() -> [Any]? {
        guard live, owner.permitsNativeAccess(self) else { return [] }
        return owner.hostingView.accessibilityChildren() ?? [owner.hostingView]
    }
    private struct AccessibilityHit: @unchecked Sendable { let value: Any? }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        MainActor.assumeIsolated {
            guard live, owner.permitsNativeAccess(self), let window else { return AccessibilityHit(value: nil) }
            let local = convert(window.convertPoint(fromScreen: point), from: nil)
            guard bounds.intersection(visibleRect).contains(local) else { return AccessibilityHit(value: nil) }
            return AccessibilityHit(value: owner.hostingView.accessibilityHitTest(point))
        }.value
    }

}

@MainActor private final class PageInitialTransactionRelay {
    private var pending = true
    func apply(_ parent: Transaction, to transaction: inout Transaction) {
        guard pending else { return }
        pending = false
        transaction = parent
    }
}

@MainActor private struct RetainedPageRoot: View {
    @ObservedObject var store: TabStore
    let presentation: BrowserProfilePresentation
    let environment: PagePublicEnvironment
    let edgeToEdge: Bool
    let revision: UInt64
    let parentTransaction: Transaction
    let initialTransaction: PageInitialTransactionRelay

    var body: some View {
        var pageEnvironment = environment
        // Restrict existing resize permission during native Space travel; this
        // can never grant permission that the Library parent did not supply.
        if store.spaceGesture.swiping {
            pageEnvironment.resizeLayout.enabled = false
            pageEnvironment.resizeLayout.libraryNavigationEnabled = false
        }
        return WebCardSurfaceContent(edgeToEdge: edgeToEdge)
            .spaceChrome(store)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(pageEnvironment)
            .environmentObject(store).environmentObject(ProfileManager.shared)
            .environmentObject(store.spaceGesture)
            .environmentObject(presentation.downloads)
            .transaction(value: revision) { $0 = parentTransaction }
            .transaction { initialTransaction.apply(parentTransaction, to: &$0) }
            .transaction(value: store.sidebarPresentationRevision) {
                $0.animation = nil
                $0.disablesAnimations = true
            }
            .vaneMotionPolicy()
    }
}


/// A native marker after the shared padding records the ACTUAL outer envelope.
/// It owns no content, focus, events or preference key.
@MainActor struct RetainedPageEnvelopeMarker: NSViewRepresentable {
    let owner: RetainedBrowserPageHost
    func makeNSView(context: Context) -> NativePageEnvelopeMarker { NativePageEnvelopeMarker(owner: owner) }
    func updateNSView(_ view: NativePageEnvelopeMarker, context: Context) { view.register() }
    static func dismantleNSView(_ view: NativePageEnvelopeMarker, coordinator: ()) { view.dismantle() }
}

@MainActor final class NativePageEnvelopeMarker: NSView {
    private let owner: RetainedBrowserPageHost
    fileprivate let generation: UUID
    fileprivate var normalLayoutPassed = false
    fileprivate var live = true
    private var wasAttached = false
    init(owner: RetainedBrowserPageHost) {
        self.owner = owner
        generation = owner.reserveOuterMarker()
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func register() { if live { owner.registerOuterMarker(self); needsLayout = true } }
    override func layout() {
        super.layout()
        if live { normalLayoutPassed = true; owner.markerDidLayout(self) }
    }
    override func setFrameSize(_ size: NSSize) {
        if frame.size != size { owner.markerGeometryChanged(self, clearNormalCommit: false); normalLayoutPassed = false }
        let changed = frame.size != size
        super.setFrameSize(size)
        if changed { needsLayout = true }
    }
    override func setFrameOrigin(_ origin: NSPoint) {
        if frame.origin != origin { owner.markerGeometryChanged(self, clearNormalCommit: false); normalLayoutPassed = false }
        let changed = frame.origin != origin
        super.setFrameOrigin(origin)
        if changed { needsLayout = true }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wasAttached { owner.markerGeometryChanged(self, clearNormalCommit: true) }
        if window != nil { wasAttached = true }
        register()
    }
    override func viewDidHide() { super.viewDidHide(); owner.markerGeometryChanged(self, clearNormalCommit: true) }
    override func viewDidUnhide() { super.viewDidUnhide(); owner.markerGeometryChanged(self, clearNormalCommit: true) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func dismantle() {
        guard live else { return }
        owner.outerMarkerDetached(self)
        live = false
    }
}

private final class PageGeometryObservations {
    var tokens: [NSObjectProtocol] = []
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}
