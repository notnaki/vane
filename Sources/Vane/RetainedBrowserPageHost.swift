import AppKit
import SwiftUI

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
    let hostingView: NSHostingView<AnyView>
    private weak var store: TabStore?
    private weak var slot: NativeBrowserPageSlot?
    private var slotGeneration = UUID()
    private var retired = false
    private var revision: UInt64 = 0
    private let transactionRelay = PageInitialTransactionRelay()
    private var geometry: Geometry?
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
    }

    init(store: TabStore, presentation: BrowserProfilePresentation) {
        self.store = store
        self.presentation = presentation
        // The real page root is installed once by its actual slot/context. Do
        // not create and then replace a speculative cold page/FocusStore here.
        hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        hostingView.sizingOptions = []
    }

    fileprivate func reserveSlot() -> UUID {
        slotGeneration = UUID()
        geometry = nil
        displayAuthorization = nil
        return slotGeneration
    }

    fileprivate func configure(_ candidate: NativeBrowserPageSlot, environment: PagePublicEnvironment,
                               envelope: WebCardEnvelopeSpec, transaction: Transaction) {
        guard !retired, candidate.generation == slotGeneration, let store else { return }
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
        hostingView.rootView = AnyView(RetainedPageRoot(store: store, presentation: presentation,
            environment: environment, edgeToEdge: envelope.edgeToEdge, revision: revision,
            parentTransaction: transaction, initialTransaction: transactionRelay))
        synchronize(candidate)
    }

    fileprivate func synchronize(_ candidate: NativeBrowserPageSlot) {
        guard !retired, candidate.generation == slotGeneration, slot === candidate,
              candidate.superview != nil else { return }
        if hostingView.superview !== candidate {
            hostingView.removeFromSuperview()
            candidate.addSubview(hostingView)
        }
        if hostingView.frame != candidate.bounds { hostingView.frame = candidate.bounds }
        hostingView.autoresizingMask = [.width, .height]
        commitGeometry(candidate)
    }

    private func commitGeometry(_ candidate: NativeBrowserPageSlot) {
        guard let store, let window = candidate.window, let root = window.contentView,
              let envelope = candidate.envelope, let signature = candidate.signature,
              signature == PageLayoutSignature(store), candidate.environment != nil,
              candidate.generation == slotGeneration, slot === candidate,
              candidate.bounds.width > 0, candidate.bounds.height > 0 else { geometry = nil; return }
        let content = candidate.convert(candidate.bounds, to: root)
        geometry = Geometry(window: window, root: ObjectIdentifier(root), generation: slotGeneration,
            slot: ObjectIdentifier(candidate), bounds: root.bounds, scale: window.backingScaleFactor,
            content: content, outer: envelope.outerRect(around: content, flipped: root.isFlipped),
            envelope: envelope, signature: signature, environmentRevision: revision)
    }

    /// Fail closed without a real current Library receipt. A later capture from
    /// the same destination provider may succeed after cold marker readiness;
    /// this recaptures CURRENT native geometry, never a departing profile's state.
    func layoutForProfileHandoff(in window: NSWindow) -> Bool {
        displayAuthorization = nil
        guard !retired, let store, store.window === window, store.profileVisible,
              !store.libraryOpen, store.libraryGesture.progress == nil, store.palette == nil,
              !window.inLiveResize, let slot, let inherited = slot.environment,
              let receipt = inherited.librarySource?.capture(), receipt.isCurrentAndIdle(),
              receipt.owner == inherited.paintOwner,
              !slot.isHiddenOrHasHiddenAncestor, slot.window === window,
              hostingView.superview === slot, hostingView.window === window,
              !hasNativeResizeOwner(hostingView) else { return false }
        commitGeometry(slot)
        guard let geometry, let root = window.contentView,
              geometry.window === window, geometry.root == ObjectIdentifier(root),
              geometry.generation == slotGeneration, geometry.slot == ObjectIdentifier(slot),
              geometry.bounds == root.bounds, geometry.scale == window.backingScaleFactor,
              geometry.signature == PageLayoutSignature(store), geometry.environmentRevision == revision,
              slot.envelope == geometry.envelope,
              slot.convert(slot.bounds, to: root) == geometry.content,
              geometry.outer.width > 0, geometry.outer.height > 0,
              receipt.isCurrentAndIdle() else { return false }
        hostingView.layoutSubtreeIfNeeded()
        guard receipt.isCurrentAndIdle(), !hasNativeResizeOwner(hostingView),
              geometry.environmentRevision == revision, geometry.generation == slotGeneration,
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
              store.window === window, store.profileVisible, !store.libraryOpen,
              store.libraryGesture.progress == nil, store.palette == nil, !window.inLiveResize,
              slot.window === window, hostingView.superview === slot,
              !slot.isHiddenOrHasHiddenAncestor, !hasNativeResizeOwner(hostingView),
              authorization.receipt.isCurrentAndIdle() else { return false }
        let geometry = authorization.geometry
        guard geometry.window === window, geometry.root == ObjectIdentifier(root),
              geometry.generation == slotGeneration, geometry.slot == ObjectIdentifier(slot),
              geometry.environmentRevision == revision, geometry.bounds == root.bounds,
              geometry.scale == window.backingScaleFactor,
              geometry.signature == PageLayoutSignature(store), geometry.envelope == slot.envelope,
              geometry.content == slot.convert(slot.bounds, to: root) else { return false }
        hostingView.displayIfNeededIgnoringOpacity()
        return true
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
        guard slot === candidate, candidate.generation == slotGeneration else { return }
        geometry = nil
        displayAuthorization = nil
        hostingView.removeFromSuperview()
        slot = nil
    }

    func retire() {
        guard !retired else { return }
        retired = true
        displayAuthorization = nil
        slotGeneration = UUID()
        geometry = nil
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
        return CGSize(width: max(0, width), height: max(0, height))
    }
    static func dismantleNSView(_ view: NativeBrowserPageSlot, coordinator: ()) { view.dismantle() }
}

@MainActor final class NativeBrowserPageSlot: NSView {
    private let owner: RetainedBrowserPageHost
    fileprivate let generation: UUID
    fileprivate var environment: PagePublicEnvironment?
    fileprivate var envelope: WebCardEnvelopeSpec?
    fileprivate var signature: PageLayoutSignature?
    private var live = true

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
    override func layout() { super.layout(); if live { owner.synchronize(self) } }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if live { owner.synchronize(self) }
    }
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        if live { owner.synchronize(self) }
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { owner.detach(self) }
        else if live { owner.synchronize(self) }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if live { owner.synchronize(self) } }
    func dismantle() {
        guard live else { return }
        live = false
        owner.detach(self)
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
