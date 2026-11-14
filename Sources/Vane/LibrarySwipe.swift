import AppKit
import SwiftUI

extension Look {
    static let librarySlideDuration: TimeInterval = 0.24
    static let librarySlide = Animation.easeInOut(duration: librarySlideDuration)
}

/// Finger samples affect navigation geometry, not the browser or its tab rows.
@MainActor final class LibraryGesture: ObservableObject {
    @Published var progress: CGFloat? {
        willSet { if progress != newValue { paint?.invalidatePageMountMetadata() } }
        didSet {
            sampledAt = CACurrentMediaTime()
            if progress == nil { pageLeadingInset = nil }
        }
    }
    private(set) var sampledAt = CACurrentMediaTime()
    /// Capture the initial gutter; floating navigation interpolates it to its endpoint.
    @Published var pageLeadingInset: CGFloat?
    weak var paint: LibraryNavigationPaint? {
        willSet {
            if paint !== newValue {
                paint?.invalidatePageMountMetadata()
                newValue?.invalidatePageMountMetadata()
            }
        }
    }
}

private struct LibraryPageLeadingInset: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var libraryPageLeadingInset: CGFloat? {
        get { self[LibraryPageLeadingInset.self] }
        set { self[LibraryPageLeadingInset.self] = newValue }
    }
}

/// Keep the animated geometry in one small observation boundary. The page, sidebar
/// and Library values remain unchanged during dragging, so their bodies can stay cached.
struct LibraryNavigationLayout<Page: View, Sidebar: View, Panel: View>: View {
    @ObservedObject var gesture: LibraryGesture
    let libraryOpen: Bool
    let sidebarShown: Bool
    let floating: Bool
    @WindowSidebarWidth private var sidebarWidth
    let panelWidth: CGFloat
    let palettePresented: Bool
    let monitor: LibrarySwipeMonitor
    let page: Page
    let sidebar: Sidebar
    let panel: Panel
    var store: TabStore? = nil

    private var progress: CGFloat { gesture.progress ?? (libraryOpen ? 1 : 0) }

    var body: some View {
        PaintedLibraryNavigation(gesture: gesture, targetProgress: progress,
            libraryOpen: libraryOpen, sidebarShown: sidebarShown, floating: floating,
            sidebarWidth: sidebarWidth, panelWidth: panelWidth, palettePresented: palettePresented,
            monitor: monitor, page: page, sidebar: sidebar, panel: panel, store: store)
    }
}

/// Interpolate requested navigation first, then publish only geometry whose
/// document viewport has painted. The page and both rails share that publication.
private struct PaintedLibraryNavigation<Page: View, Sidebar: View, Panel: View>: View, @preconcurrency Animatable {
    @ObservedObject var gesture: LibraryGesture
    var targetProgress: CGFloat
    let libraryOpen: Bool
    let sidebarShown: Bool
    let floating: Bool
    let sidebarWidth: CGFloat
    let panelWidth: CGFloat
    let palettePresented: Bool
    let monitor: LibrarySwipeMonitor
    let page: Page
    let sidebar: Sidebar
    let panel: Panel
    let store: TabStore?
    @Environment(\.displayScale) private var displayScale
    @StateObject private var paint: LibraryNavigationPaint

    var animatableData: CGFloat {
        get { targetProgress }
        set { targetProgress = newValue }
    }

    init(gesture: LibraryGesture, targetProgress: CGFloat, libraryOpen: Bool, sidebarShown: Bool,
         floating: Bool, sidebarWidth: CGFloat, panelWidth: CGFloat, palettePresented: Bool,
         monitor: LibrarySwipeMonitor, page: Page, sidebar: Sidebar, panel: Panel, store: TabStore?) {
        self.gesture = gesture; self.targetProgress = targetProgress
        self.libraryOpen = libraryOpen; self.sidebarShown = sidebarShown; self.floating = floating
        self.sidebarWidth = sidebarWidth; self.panelWidth = panelWidth; self.palettePresented = palettePresented
        self.monitor = monitor; self.page = page; self.sidebar = sidebar; self.panel = panel; self.store = store
        _paint = StateObject(wrappedValue: LibraryNavigationPaint(progress: targetProgress))
    }

    private func pageLeading(at progress: CGFloat) -> CGFloat {
        let leading = (sidebarShown ? sidebarWidth : Look.cardGap) * (1 - progress)
            + panelWidth * progress
        return (leading * displayScale).rounded() / displayScale
    }

    var body: some View {
        let progress = paint.progress
        let leading = pageLeading(at: progress)
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                Color.clear.frame(width: leading)
                // Resolve navigation geometry once per surface, rather than per leaf.
                page.environment(\.libraryNavigationPaintOwner, paint.owner)
                    .environment(\.libraryPageMountReceiptSource,
                        paint.pageMountReceiptSource(store: store, gesture: gesture, monitor: monitor))
                    .environment(\.libraryPageLeadingInset, 0)
                    .geometryGroup()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(palettePresented)
            .accessibilityHidden(palettePresented)
            // Adjacent surfaces follow the same translation, clipped at the page seam.
            sidebar
                .geometryGroup()
                .offset(x: panelWidth * progress)
                .frame(width: (sidebarWidth + (floating ? 2 * Look.floatingSidebarGap : 0))
                    * (1 - progress) + panelWidth * progress, alignment: .leading)
                .mask {
                    Rectangle().padding(floating ? -2 * Look.barShadowRadius * (1 - progress) : 0)
                }
                .zIndex(1)
            // Keep the panel laid out offscreen. Mounting its search field and list
            // during the first directional sample otherwise stalls that frame.
            panel
                .frame(width: panelWidth)
                .overlay(alignment: .leading) {
                    LibrarySwipePosition(monitor: monitor)
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                .geometryGroup()
                .offset(x: -panelWidth * (1 - progress))
                .opacity(libraryOpen || gesture.progress != nil ? 1 : 0)
                .disabled(palettePresented || (!libraryOpen && gesture.progress == nil))
                .allowsHitTesting(libraryOpen && !palettePresented)
                .accessibilityHidden(!libraryOpen || palettePresented)
                .zIndex(1)
        }
        .background {
            LibraryPaintBridge(paint: paint, target: targetProgress,
                sampledAt: gesture.progress == targetProgress ? gesture.sampledAt : nil,
                leading: pageLeading)
                .frame(width: 0, height: 0)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .onAppear { gesture.paint = paint }
        .onDisappear { if gesture.paint === paint { gesture.paint = nil } }
    }
}

extension View {
    /// Keep the monitor on the window root: closing Library must still consume the
    /// gesture's momentum instead of handing it to the newly exposed page or sidebar.
    func librarySwipe(_ store: TabStore) -> some View {
        modifier(LibrarySwipe(store: store))
    }
}

private struct LibrarySwipe: ViewModifier {
    @ObservedObject var store: TabStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var batterySaver = BatterySaver.shared

    private func reconcileInput() {
        if store.profileVisible { store.librarySwipeMonitor.install(store) }
        else { store.librarySwipeMonitor.remove() }
    }

    func body(content: Content) -> some View {
        let monitor = store.librarySwipeMonitor
        content
            .onAppear { reconcileInput() }
            .onDisappear {
                if !store.profileVisible || store.window == nil || !TabStore.all.contains(where: { $0 === store }) {
                    monitor.remove()
                }
            }
            .onChange(of: store.profileVisible) { reconcileInput() }
            .onChange(of: reduceMotion) { if reduceMotion { monitor.finishForReducedMotion() } }
            .onChange(of: batterySaver.isActive) {
                if batterySaver.isActive { monitor.finishForReducedMotion() }
            }
    }
}

/// Library sits before the first Space: the previous-Space swipe opens it from the first
/// Space's sidebar, and the next-Space swipe closes it from its panel. Right and left
/// respectively with Natural Scrolling on; the other way round with it off.
/// Decide on fingers-up and consume momentum so one gesture cannot do both.
/// Page content, vertical scrolling and other Spaces' gestures keep their recipient.
@MainActor final class LibrarySwipeMonitor {
    private var monitor: Any?
    private weak var store: TabStore? {
        willSet { if store !== newValue { pageMountMetadata.retire() } }
    }
    private var settlement = UUID() {
        willSet { if settlement != newValue { pageMountMetadata.retire() } }
    }
    private var pageMountMetadata = LibraryPageMountSettlement()
    private weak var pageMountWindow: NSWindow?
    var pageMountEpoch: LibraryPageMountEpoch { pageMountMetadata.epoch }
    var pageMountPendingSettlement: UUID? { pageMountMetadata.pending }

    init(mountEpoch: LibraryPageMountEpoch = .init()) {
        pageMountMetadata = LibraryPageMountSettlement(epoch: mountEpoch)
    }

    func pageMountIsIdle(in store: TabStore, window: NSWindow) -> Bool {
        self.store === store && pageMountWindow === window && monitor != nil
            && !pageMountMetadata.epoch.exhausted && pageMountMetadata.pending == nil
            && destination == nil && !(!finished && (claim == .mine || claim == .undecided))
    }

    // Mirrors only the successful production completion point. A stale token
    // cannot clear a newer metadata tail or change any navigation state.
    func pageMountSettlementCompleted(_ token: UUID) { pageMountMetadata.complete(token) }

    private func recordPageMountWindow(_ window: NSWindow?) {
        if pageMountWindow !== window { pageMountMetadata.retire(); pageMountWindow = window }
    }
    private var panelWidth: CGFloat = 1
    private var dragOrigin: CGFloat?
    /// An inert native marker travels with the panel. Read its presentation layer only
    /// when interrupting a landing, so a reverse swipe can take over without a jump.
    weak var presentationView: NSView? {
        willSet { if presentationView !== newValue { pageMountMetadata.invalidate() } }
    }

    private var presentedProgress: CGFloat? {
        guard let view = presentationView, let layer = view.layer?.presentation(),
              let root = view.window?.contentView?.layer?.presentation() else { return nil }
        return min(1, max(0, 1 + layer.convert(.zero, to: root).x / max(1, panelWidth)))
    }
    private func panelHasArrived(at target: CGFloat) -> Bool {
        guard let presentedProgress else { return true }
        return abs(presentedProgress - target) * panelWidth <= 0.5
    }

    private var watchers: [any NSObjectProtocol] = []
    private enum Claim: Equatable { case idle, undecided, mine, theirs }
    private enum Action { case close, open(UUID) }
    private var action: Action?
    private var claim = Claim.idle {
        willSet { if claim != newValue { pageMountMetadata.invalidate() } }
    }
    private weak var lastEvent: NSEvent?
    private var lastWasConsumed = false
    private var travel = (x: CGFloat(0), horizontal: CGFloat(0), vertical: CGFloat(0))
    private var finished = false {
        willSet { if finished != newValue { pageMountMetadata.invalidate() } }
    }
    @MainActor private struct KeyboardOwner {
        weak var responder: NSResponder?
        weak var editorDelegate: AnyObject?
        let fieldEditor: Bool

        init(window: NSWindow?) {
            responder = window?.firstResponder
            let editor = responder as? NSTextView
            fieldEditor = editor?.isFieldEditor == true
            editorDelegate = fieldEditor ? editor?.delegate : nil
        }

        func stillOwnsKeyboard(in window: NSWindow?) -> Bool {
            guard window?.firstResponder === responder else { return false }
            // AppKit reuses one field editor across the Library and page Find.
            // Its delegate identifies the field that currently owns that editor.
            guard fieldEditor else { return true }
            return (window?.firstResponder as? NSTextView)?.delegate === editorDelegate
        }
    }
    private struct Destination {
        let open: Bool
        let space: UUID?
        let keyboard: KeyboardOwner
    }
    private var destination: Destination? {
        willSet { pageMountMetadata.invalidate() }
    }

    /// Route a second gesture against the released gesture's intent while the
    /// visible layout is still landing. The browser itself changes only at rest.
    func intendsOpen(in store: TabStore) -> Bool { destination?.open ?? store.libraryOpen }

    /// Explicit commands supersede a pending swipe, including a close issued
    /// before the opening has published its destination.
    func cancelPendingActivation(toward open: Bool? = nil) {
        pageMountMetadata.invalidate()
        guard destination != nil else { return }
        destination = nil
        guard let store else { return }
        let target: CGFloat = (open ?? store.libraryOpen) ? 1 : 0
        // A command agreeing with the released endpoint can keep the existing
        // tail and its cleanup, while retiring only the deferred activation.
        if !Motion.reduced, presentationView?.window != nil,
           store.librarySwipeProgress == target { return }
        let token = UUID()
        settlement = token
        pageMountMetadata.begin(token)
        let clear = { [weak self, weak store] in
            guard let self, self.settlement == token, let store else { return }
            Motion.instant { store.librarySwipeProgress = nil }
            self.pageMountSettlementCompleted(token)
        }
        if Motion.reduced || presentationView?.window == nil || store.librarySwipeProgress == nil {
            clear()
        } else {
            // Retarget from the position actually on screen, not the old
            // animation's model endpoint. Commit that baseline before starting
            // a new curve so the opening spring cannot carry its velocity on.
            if let visible = presentedProgress {
                Motion.instant {
                    store.librarySwipeProgress = visible
                    store.window?.contentView?.layoutSubtreeIfNeeded()
                }
            }
            withAnimation(Look.librarySlide, completionCriteria: .removed) {
                store.librarySwipeProgress = target
            } completion: { [weak self, weak store] in
                if let paint = store?.libraryGesture.paint {
                    paint.afterPresentation(of: target, when: { [weak self] in
                        self?.panelHasArrived(at: target) ?? true
                    }, clear)
                } else { clear() }
            }
        }
    }

    private func activateDestination(in store: TabStore) {
        guard let destination else { return }
        self.destination = nil
        if destination.open {
            guard store.profileVisible, !store.libraryOpen, store.currentSpaceID == destination.space,
                  !store.creatingSpace, !store.spaceSwiping, !store.isPrivate, !store.isLittle else { return }
            store.palette = nil
            Library.open(Library.shared.section, in: store)
        } else if store.libraryOpen {
            if destination.keyboard.stillOwnsKeyboard(in: store.window) {
                Library.close(store)
            } else {
                // A newer focus request (for example page Find) owns the keyboard.
                // Retire Library without releasing that new responder.
                store.libraryOpen = false
            }
        }
    }

    func install(_ store: TabStore) {
        guard monitor == nil else { return }
        pageMountMetadata.invalidate()
        recordPageMountWindow(store.window)
        self.store = store
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak store] event in
            guard let self, let store else { return event }
            return self.handle(event, in: store)
        }
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            watchers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: name == NSWindow.didResignKeyNotification ? store.window : nil,
                queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reset() }
                })
        }
    }

    func remove() {
        pageMountMetadata.invalidate()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        watchers.forEach(NotificationCenter.default.removeObserver)
        watchers = []
        reset()
    }

    private func reset(clearPresentation: Bool = true) {
        pageMountMetadata.invalidate()
        if clearPresentation {
            settlement = UUID()
            if let store {
                Motion.instant {
                    activateDestination(in: store)
                    store.librarySwipeProgress = nil
                }
            }
        }
        dragOrigin = nil
        claim = .idle
        action = nil
        travel = (0, 0, 0)
        finished = false
        lastEvent = nil
        lastWasConsumed = false
    }

    func finishForReducedMotion() {
        settlement = UUID()
        if let store {
            Motion.instant {
                activateDestination(in: store)
                store.librarySwipeProgress = nil
            }
        }
    }

    /// Finish the small navigation layout before publishing the destination to
    /// the browser. Publishing at fingers-up invalidates the controls and lists
    /// in the first animation frame, holding a quick swipe at its release point.
    private func settle(in store: TabStore, commit: Bool) {
        let token = UUID()
        settlement = token
        pageMountMetadata.begin(token)
        var open = intendsOpen(in: store)
        if commit, let action {
            open = switch action { case .open: true; case .close: false }
        }
        let target: CGFloat = open ? 1 : 0
        let keyboard = !open && destination?.open == false
            ? destination!.keyboard : KeyboardOwner(window: store.window)
        let space = open && destination?.open == true ? destination?.space : store.currentSpaceID
        destination = Destination(open: open, space: space, keyboard: keyboard)
        let finish = { [weak self, weak store] in
            guard let self, self.settlement == token, let store else { return }
            Motion.instant {
                self.activateDestination(in: store)
                guard self.settlement == token else { return }
                store.librarySwipeProgress = nil
                self.pageMountSettlementCompleted(token)
            }
        }
        if Motion.reduced || presentationView?.window == nil
            || store.librarySwipeProgress == nil || store.librarySwipeProgress == target {
            finish()
        } else {
            withAnimation(Look.appear, completionCriteria: .removed) {
                store.librarySwipeProgress = target
            } completion: { [weak self, weak store] in
                if let paint = store?.libraryGesture.paint {
                    paint.afterPresentation(of: target, when: { [weak self] in
                        self?.panelHasArrived(at: target) ?? true
                    }, finish)
                } else { finish() }
            }
        }
    }

    /// Both local monitors consult this shared owner. An undecided event can pass
    /// through both, so classify and accumulate each native event exactly once.
    func handle(_ event: NSEvent, in store: TabStore) -> NSEvent? {
        guard !FirstLaunch.isPresenting else { return event }
        recordPageMountWindow(store.window)
        self.store = store
        if lastEvent === event { return lastWasConsumed ? nil : event }
        let result = process(event, in: store)
        lastEvent = event
        lastWasConsumed = result == nil
        return result
    }

    private func valid(_ action: Action, in store: TabStore) -> Bool {
        switch action {
        case .close: return intendsOpen(in: store)
        case .open(let space):
            return !intendsOpen(in: store) && !store.isPrivate && !store.isLittle
                && !store.creatingSpace && !store.spaceSwiping && store.currentSpaceID == space
        }
    }

    /// Match BrowserWindow's rail geometry, including the inset floating sidebar and
    /// Library's section-dependent width. Only inspect this at fingers-down: a gesture
    /// keeps its recipient even if the pointer moves or the panel closes beneath it.
    private func startsInNavigationArea(_ event: NSEvent, window: NSWindow, store: TabStore) -> Bool {
        let bounds = window.contentView.map { $0.convert($0.bounds, to: nil) }
            ?? NSRect(origin: .zero, size: window.frame.size)
        if intendsOpen(in: store) {
            let spaces = Library.shared.section == .spaces ? ProfileManager.shared.allSpaces.count : 0
            let width = Library.panelWidth(section: Library.shared.section, spaces: spaces,
                                          private: store.isPrivate, available: bounds.width)
            let panel = NSRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height)
            return panel.contains(event.locationInWindow)
        }
        guard store.sidebarShown || (window as? VaneWindow)?.peekingSidebar == true else { return false }
        guard !store.spaceGesture.isOverScrollingFooter(event) else { return false }
        let inset = store.sidebarShown ? 0 : Look.floatingSidebarGap
        let sidebar = NSRect(x: bounds.minX + inset, y: bounds.minY + inset,
                             width: SidebarWidth.inWindow(store),
                             height: max(0, bounds.height - 2 * inset))
        return sidebar.contains(event.locationInWindow)
    }

    private func process(_ event: NSEvent, in store: TabStore) -> NSEvent? {
        guard let window = event.window, window === store.window,
              event.hasPreciseScrollingDeltas else { return event }
        if !event.momentumPhase.isEmpty {
            // Keep the verdict after fingers-up even though Library has now closed.
            return claim == .mine ? nil : event
        }
        guard !event.phase.isEmpty else { return event }
        if event.phase.contains(.began) {
            // A new scroll is not necessarily navigation. Let an existing landing
            // continue until this gesture actually earns ownership.
            reset(clearPresentation: false)
            if startsInNavigationArea(event, window: window, store: store) {
                let bounds = window.contentView?.bounds ?? NSRect(origin: .zero, size: window.frame.size)
                panelWidth = Library.panelWidth(section: Library.shared.section,
                    spaces: Library.shared.section == .spaces ? ProfileManager.shared.allSpaces.count : 0,
                    private: store.isPrivate, available: bounds.width)
                if intendsOpen(in: store) { action = .close }
                else if let space = store.currentSpaceID, !store.isPrivate, !store.isLittle,
                        !store.creatingSpace, !store.spaceSwiping {
                    action = .open(space)
                }
            }
            claim = action == nil ? .theirs : .undecided
        }
        guard claim == .undecided || claim == .mine else { return event }
        if finished { return claim == .mine ? nil : event }
        guard let action else { return event }
        if claim == .undecided && !valid(action, in: store) { claim = .theirs; return event }
        if event.phase.contains(.cancelled) {
            finished = true
            if claim == .mine { settle(in: store, commit: false) }
            return claim == .mine ? nil : event
        }
        if event.phase.contains(.ended) {
            finished = true
            if claim == .mine {
                let commit: Bool
                switch action {
                case .close: commit = travel.x <= -60
                case .open(let space): commit = travel.x >= 60 && store.strip.first?.id == space
                }
                settle(in: store, commit: commit && valid(action, in: store))
            }
            return claim == .mine ? nil : event
        }
        // Read the way Space swipes are (`scrollingDeltaX`, scrolling preference and all), so
        // Library is always one step before the first Space. Reading the fingers instead put
        // "open Library" on the first Space's next-Space swipe with Natural Scrolling off.
        let dx = event.scrollingDeltaX
        travel.x += dx
        travel.horizontal += abs(event.scrollingDeltaX)
        travel.vertical += abs(event.scrollingDeltaY)
        if claim == .undecided {
            // Match the sidebar's axis lock: a vertical scroll cannot later become
            // navigation as the fingers drift sideways.
            if travel.vertical >= 6 { claim = .theirs; return event }
            guard travel.horizontal + travel.vertical >= 10 else { return event }
            guard travel.horizontal > travel.vertical * 1.5 else { claim = .theirs; return event }
            switch action {
            case .close: claim = travel.x < 0 ? .mine : .theirs
            case .open(let space):
                // Read the strip only after a rightward horizontal gesture qualifies,
                // rather than decoding every profile's Spaces on vertical/page scrolls.
                claim = travel.x > 0 && store.strip.first?.id == space ? .mine : .theirs
            }
        }
        if claim == .mine, valid(action, in: store), !Motion.reduced {
            if dragOrigin == nil {
                let endpoint: CGFloat = switch action { case .close: 1; case .open: 0 }
                dragOrigin = store.librarySwipeProgress == nil ? endpoint
                    : (presentedProgress ?? store.librarySwipeProgress ?? endpoint)
                settlement = UUID()
                if store.libraryGesture.pageLeadingInset == nil {
                    store.libraryGesture.pageLeadingInset = store.sidebarShown || store.libraryOpen ? 0 : Look.cardGap
                }
            }
            Motion.instant {
                store.librarySwipeProgress = min(1, max(0, (dragOrigin ?? 0)
                    + travel.x / max(1, panelWidth)))
            }
        }
        return claim == .mine ? nil : event
    }
}

/// No drawing or event handling: this marker lets a new gesture sample the actual
/// SwiftUI slide position without publishing model changes on every animation frame.
struct LibrarySwipePosition: NSViewRepresentable {
    let monitor: LibrarySwipeMonitor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        monitor.presentationView = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        monitor.presentationView = view
    }
}
