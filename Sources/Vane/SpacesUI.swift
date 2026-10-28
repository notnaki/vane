import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Native finger tracking only republishes the small footer, not sidebar lists or tint.
@MainActor final class SpaceFooterProgress: ObservableObject {
    @Published var drag: CGFloat?
}

/// Only the sliding sections, tint and footer track these per-frame gesture values.
/// Publishing them on TabStore would invalidate the entire browser on every scroll event.
@MainActor final class SpaceGesture: ObservableObject {
    let monitor = SwipeMonitor()
    struct Presentation: Equatable {
        var drag: CGFloat = 0
        var pull: CGFloat = 0
        var swiping = false
        var travelsFavorites = false
        var profileSliding = false
        var profileSlidesFavorites = false
    }
    @Published private(set) var presentation = Presentation()
    private var pendingPresentation: Presentation?
    private var presentationDepth = 0

    /// A native input mounts its overlay before publishing one complete state.
    /// Publishing each flag separately makes SwiftUI synchronously flush several
    /// intermediate browser layouts while the same input is still being handled.
    func beginPresentationUpdate() {
        if presentationDepth == 0 { pendingPresentation = presentation }
        presentationDepth += 1
    }

    func endPresentationUpdate() {
        precondition(presentationDepth > 0)
        presentationDepth -= 1
        guard presentationDepth == 0, let next = pendingPresentation else { return }
        pendingPresentation = nil
        if next != presentation { presentation = next }
    }

    func withPresentationUpdate<Result>(_ body: () throws -> Result) rethrows -> Result {
        beginPresentationUpdate()
        defer { endPresentationUpdate() }
        return try body()
    }

    private func read<Value>(_ key: KeyPath<Presentation, Value>) -> Value {
        (pendingPresentation ?? presentation)[keyPath: key]
    }

    private func write<Value: Equatable>(_ key: WritableKeyPath<Presentation, Value>, _ value: Value) {
        guard read(key) != value else { return }
        if pendingPresentation != nil { pendingPresentation?[keyPath: key] = value }
        else {
            var next = presentation
            next[keyPath: key] = value
            presentation = next
        }
    }

    var drag: CGFloat {
        get { read(\.drag) }
        set { write(\.drag, newValue) }
    }
    /// The native overlay owns travel. Keep its covered live layout at rest.
    var liveContentDrag: CGFloat { profileSliding ? 0 : drag }

    /// While native surfaces follow the fingers, keep raw input out of SwiftUI publication.
    let footer = SpaceFooterProgress()
    var nativeDrag: CGFloat? {
        didSet { if footer.drag != nativeDrag { footer.drag = nativeDrag } }
    }
    var trackGround: ((Double) -> Void)?
    var captureGround: (() -> ThemeWashPresentation?)?
    var animateGround: ((Space, Space, Double, Double, CABasicAnimation, ThemeWashPresentation?) -> ((Space?) -> Void))?
    var colourDuration = Look.spaceSlideDuration
    var pull: CGFloat {
        get { read(\.pull) }
        set { write(\.pull, newValue) }
    }
    var swiping: Bool {
        get { read(\.swiping) }
        set { write(\.swiping, newValue) }
    }
    var travelsFavorites: Bool {
        get { read(\.travelsFavorites) }
        set { write(\.travelsFavorites, newValue) }
    }
    var sidebarOffset: CGFloat = 0
    var strip: [Space]?
    var neighbour: Space?
    var previewDirection = 0
    var previews: [UUID: SpacePreviewList] = [:]
    /// The sidebar stays on its captured origin while the active page changes immediately.
    var outgoing: SpacePreviewList?
    /// The overflowing footer owns its horizontal scroll gestures. Weak because the
    /// SwiftUI anchor can disappear while a floating sidebar is hidden.
    weak var scrollingFooter: NSView?
    weak var stripView: NSView?
    weak var sectionsView: NSView?
    weak var outgoingView: NSView?
    var profileSliding: Bool {
        get { read(\.profileSliding) }
        set { write(\.profileSliding, newValue) }
    }
    var profileSlidesFavorites: Bool {
        get { read(\.profileSlidesFavorites) }
        set { write(\.profileSlidesFavorites, newValue) }
    }

    func isOverScrollingFooter(_ event: NSEvent) -> Bool {
        guard let view = scrollingFooter, let window = view.window,
              event.window === window else { return false }
        return view.convert(view.bounds, to: nil).contains(event.locationInWindow)
    }
}

/// The Spaces chrome: the header row's two clicks, the footer's dots and its `+`, the inline
/// editor Arc's `+` opens, "Move to Space" and the two-finger swipe.
///
/// In its own file so the sidebar's look and the sidebar's Spaces can be worked on at once.
/// The tokens are `Look`'s, extended rather than edited.

extension Look {
    /// Click travel shares the established Space timing.
    static let spaceSlideDuration: TimeInterval = 0.24
    static let spaceSlide = Animation.easeInOut(duration: spaceSlideDuration)
    /// The strip finishing a swipe: the rest of the travel after the fingers leave, and the
    /// spring back when they did not go far enough. A spring rather than an ease because the
    /// gesture handed it a velocity and an ease throws that away — the strip has to leave the
    /// fingers at the speed they left it at.
    static let spaceSpring = Animation.spring(response: 0.35, dampingFraction: 0.85)
    /// A committed swipe finishes continuously while its captured sidebar covers page selection.
    static let spaceLandingDuration: TimeInterval = 0.18
    static let spaceLanding = Animation.easeInOut(duration: spaceLandingDuration)
    /// Returning from a canceled drag keeps its gentler timing.
    static let spaceReturn = Animation.spring(response: 0.16, dampingFraction: 0.9)
    /// A footer-height target leaves room for a rounded hover fill around the glyph.
    static let spaceDotHit: CGFloat = Look.footer
}

// MARK: - The Space's name

/// The space's name in the sidebar header, which is a label until it is being renamed and a
/// field while it is. Arc renames in place; an OS alert for two words is a modal dialog for
/// something the user is already looking at.
struct SpaceName: View {
    @ObservedObject var store: TabStore
    let space: Space?
    /// What a window outside any Space shows instead — the profile's name.
    let fallback: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var renaming: Bool { space.map { store.renamingSpace == $0.id } ?? false }

    var body: some View {
        if let space, renaming {
            TextField("Space name", text: $draft)
                .textFieldStyle(.plain)
                .font(Look.spaceTitle)
                .focused($focused)
                .onSubmit { commit(space) }
                // Escape reverts. `onExitCommand` and not a key handler: the field is first
                // responder, and Escape has to leave the field rather than the window.
                .onExitCommand { store.renamingSpace = nil }
                .onAppear { draft = space.name; focused = true }
                // Clicking away commits, the way renaming a file in the Finder does — the
                // alternative is a field the user has to press Return in to be rid of.
                .onChange(of: focused) { _, now in if !now { commit(space) } }
                .accessibilityLabel("Space name")
        } else {
            Text(space?.name ?? fallback).font(Look.spaceTitle)
        }
    }

    private func commit(_ space: Space) {
        defer { store.renamingSpace = nil }
        let name = draft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != space.name else { return }
        var edited = space
        edited.name = name
        store.update(space: edited)
        rebuild()                       // the Spaces menu lists the names
    }
}

/// The Space picker uses the same custom surface as the footer's creation menu.
@MainActor func showSpaceList(_ store: TabStore, anchor: ChromeMenuAnchor) {
    let items = store.strip.enumerated().map { n, space in
        ChromeMenuItem(title: space.name, symbol: space.icon ?? "cloud",
                       shortcut: n < 9 ? "⌃\(n + 1)" : "",
                       checked: store.currentSpaceID == space.id) {
            store.switchTo(space: space); rebuild()
        }
    } + [ChromeMenuItem(title: "New Space", symbol: "rectangle.stack.badge.plus", startsGroup: true) {
        store.beginCreatingSpace(); rebuild()
    }]
    anchor.show(items, title: "Spaces")
}

// MARK: - Creating a Space

/// The footer's creation menu. Its trigger becomes a close button while the menu is open.
struct NewSpaceButton: View {
    @EnvironmentObject var store: TabStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var menuAnchor = ChromeMenuAnchor()
    @ObservedObject private var batterySaver = BatterySaver.shared

    var body: some View {
        Button {
            let shortcut = Keybindings.binding(for: .newTab)
            menuAnchor.show([
                ChromeMenuItem(title: "New Space", symbol: "rectangle.stack.badge.plus") { store.beginCreatingSpace() },
                ChromeMenuItem(title: "New Folder", symbol: "folder") { store.newFolder() },
                ChromeMenuItem(title: "New Easel", symbol: "scribble.variable",
                               shortcut: Keybindings.binding(for: .newEasel).display,
                               startsGroup: true) { store.openEasel(create: true) },
                ChromeMenuItem(title: "New Split", symbol: "rectangle.split.2x1",
                               shortcut: Keybindings.binding(for: .addSplit).display,
                               startsGroup: true) {
                    if store.current == nil { _ = store.newBlankTab() }
                    store.addSplit()
                },
                ChromeMenuItem(title: "New Tab", symbol: "plus.square",
                               shortcut: shortcut == .unassigned ? "" : shortcut.display) { store.newTab(nil) },
            ], above: true, title: "Create", showsPointer: true)
        } label: {
            Image(systemName: "plus")
                .rotationEffect(.degrees(menuAnchor.isPresented ? 45 : 0))
                .animation(reduceMotion || batterySaver.isActive ? nil : Look.quick,
                           value: menuAnchor.isPresented)
                .id(reduceMotion || batterySaver.isActive)
                .frame(width: Look.footerControl, height: Look.footerControl).contentShape(.rect)
        }
            .buttonStyle(TactileButtonStyle())
            .vaneMotionPolicy()
            .background(ChromeMenuAnchorView(anchor: menuAnchor))
            .foregroundStyle(Look.inkSecondary)
            .vaneTooltip("Create Something", hint: "Folder, Easel, Split, Tab, or Space", enabled: !menuAnchor.isPresented)
            .accessibilityLabel(menuAnchor.isPresented ? "Close creation menu" : "New Folder, Easel, Split, Tab, or Space")
            .onDisappear { if menuAnchor.isPresented { ChromeMenu.shared.dismiss() } }
            .popover(isPresented: Binding(get: { store.editingSpace != nil },
                                          set: { if !$0 { store.editingSpace = nil } }),
                     arrowEdge: .top) {
                // The strip, not this profile's list: `+` can make a Space in another
                // profile, and the editor that opens on it hangs off this same button.
                if let id = store.editingSpace, let space = store.strip.first(where: { $0.id == id }) {
                    ThemeEditor(store: store, space: space, naming: true)
                }
            }
    }
}

// MARK: - The footer's dots

/// The dot being dragged, for a reorder. Separate from `Dragging`, which carries a *tab*: a
/// dot is a drop target for both, and the two have to be told apart before the drop lands.
@MainActor final class SpaceDragging: ObservableObject {
    static let shared = SpaceDragging()
    @Published var id: UUID?
}

/// A footer dot as a drop target. A tab dropped on it moves into that Space (Arc's shortcut
/// for "Move to Space"); a dot dropped on it reorders the strip.
struct SpaceDrop: DropDelegate {
    let store: TabStore
    let space: Space
    @Binding var over: Bool

    func validateDrop(info: DropInfo) -> Bool {
        // A tab may not cross profiles: its page belongs to this profile's cookie jar and its
        // history, and `Spaces.move` only ever writes into a Space this store owns. Refused
        // here rather than in `performDrop` so the dot never lights up as somewhere to drop.
        if Dragging.shared.tab != nil { return space.profileID == store.profileID }
        return SpaceDragging.shared.id.map { $0 != space.id } ?? false
    }
    func dropEntered(info: DropInfo) { over = true }
    func dropExited(info: DropInfo) { over = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        over = false
        if Dragging.shared.tab != nil {
            // A dragged multi-select moves as one, in the order its rows were drawn.
            let (tabs, _) = Dragging.shared.takeAll()
            // `Spaces.move` closes each tab and `close` prunes the selection, so a dragged
            // selection empties itself and a drag of some other row leaves it alone.
            Task {
                for id in tabs { await Spaces.moveAsync(id, to: space.id, as: .today, from: store) }
                axAnnounce(tabs.count == 1 ? "Moved to \(space.name)."
                           : "Moved \(tabs.count) tabs to \(space.name).")
            }
            return true
        }
        guard let dragged = SpaceDragging.shared.id else { return false }
        SpaceDragging.shared.id = nil
        // The strip runs across profiles, but an *order* only exists inside one: dragging a
        // dot onto another profile's would have to change which profile the Space belongs to,
        // which is what the context menu's "Set Profile" is for. So the drop is simply
        // refused unless both ends are the same profile's, and the list it reorders is that
        // profile's own rather than the strip's.
        let list = ProfileManager.shared.spaces(for: space.profileID)
        guard let from = list.firstIndex(where: { $0.id == dragged }),
              let to = list.firstIndex(where: { $0.id == space.id }) else { return false }
        // A dot dropped on a dot means "put it where that one is", so a rightward drag has to
        // land *after* the target — which is what `reordered` reads `to` as.
        store.reorderSpaces(from: from, to: to > from ? to + 1 : to, in: space.profileID)
        return true
    }
}

/// What a dot hands over when it is the thing being dragged.
@MainActor func spaceDragPayload(_ space: Space) -> NSItemProvider {
    let id = space.id
    // Next turn, not now: a state change inside the drag's own start re-renders the dot under
    // the pointer and SwiftUI drops the drag with it. Same reason as `dragPayload`.
    DispatchQueue.main.async { SpaceDragging.shared.id = id }
    return NSItemProvider(object: id.uuidString as NSString)
}

// MARK: - Move to Space

/// "Move to Space ▸ Work ▸ Pinned", under the tab context menu's own `Move To`. Arc's wording
/// and Arc's two destinations; Favourites is not among them because a favourite is in every
/// Space already.
struct MoveToSpaceMenu: View {
    let store: TabStore
    let tab: Tab

    var body: some View {
        // Never in a private window: it is in no Space, so every Space in the profile would
        // look like somewhere to move to — and moving there writes the page down.
        let others = store.isPrivate ? [] : store.spaces.filter { $0.id != store.currentSpaceID }
        if !others.isEmpty {
            Menu("Move to Space") {
                ForEach(others) { space in
                    Menu(space.name) {
                        Button("Pinned") { Task { await Spaces.moveAsync(tab.id, to: space.id, as: .pinned, from: store) } }
                        Button("Today") { Task { await Spaces.moveAsync(tab.id, to: space.id, as: .today, from: store) } }
                    }
                }
            }
            .disabled(!TabAddress.restorable(tab.currentURL))
        }
    }
}

// MARK: - Switching: the slide and the swipe

extension View {
    /// The sidebar's Space-owned sections sliding in from the direction of travel while the
    /// tint cross-fades under them. Within a profile the shared favourites stay in place;
    /// at a profile boundary the grid travels with the incoming profile's sections.
    func spaceSlide(_ store: TabStore) -> some View { modifier(SpaceSlide(store: store)) }

    /// Two-finger horizontal swipe on the sidebar switches Space.
    func spaceSwipe(_ store: TabStore) -> some View {
        modifier(SpaceSwipe(store: store))
    }
}

/// Profile favourites travel with the incoming Space only at a profile boundary.
/// Observing the gesture here keeps the rest of the browser out of per-frame updates.
struct SpaceSidebarStrip<Favorites: View, Sections: View>: View {
    // Section membership changes must refresh the shell's readiness declaration
    // even when the gesture, store identity and generic section view stay equal.
    @SidebarObserved var store: TabStore
    let favorites: Favorites
    let sections: Sections
    private let favoriteCount: Int
    @ObservedObject private var gesture: SpaceGesture
    @ObservedObject private var sidebar = SidebarWidth.shared
    @Environment(\.nativeCachedSidebarBatches) private var nativeCachedBatches
    @State private var readinessPinnedRows = Feel02SidebarRowsCache()
    @State private var readinessTodayRows = Feel02SidebarRowsCache()
    @State private var readinessOwnerID = UUID()

    init(store: TabStore, favorites: Favorites, sections: Sections) {
        _store = SidebarObserved(wrappedValue: store)
        self.favorites = favorites
        self.sections = sections
        favoriteCount = store.tabs.filter { $0.kind == .favourite }.count
        gesture = store.spaceGesture
    }

    // A pull past the last Space keeps the current list. Mounting an outgoing ghost
    // there would expose its initial top offset before scroll restoration takes effect.
    private var showsOutgoingPreview: Bool {
        !usesNativePresentation && gesture.swiping && gesture.neighbour != nil && gesture.outgoing != nil
    }

    /// The native compositor owns these previews. Publishing the initial claim must
    /// not first construct two fallback SwiftUI lists inside the live browser tree.
    /// Keep the live rows visible until the native overlay takes ownership instead.
    private var usesNativePresentation: Bool {
        store.window?.contentView is BrowserWindowHost && gesture.sectionsView != nil
    }

    private func declareNativePopulation(_ scope: SidebarNativeReadinessScope) -> [String: [String]]? {
        guard nativeCachedBatches || NativeCachedSidebarBatchesExperiment.enabled else { return nil }
        let pinned = readinessPinnedRows.resolve(in: store, shape: store.pins).rows
        let today = readinessTodayRows.resolve(in: store, shape: store.todayShape).rows
        let sections = ["today": today.map(\.id),
                        "pinned": store.pinnedSectionCollapsed ? [] : pinned.map(\.id)]
        SidebarNativeReadinessCoordinator.shared.expectPopulation(scope, sections: sections, populationOwnerID: readinessOwnerID)
        return sections
    }

    var body: some View {
        let readinessScope = SidebarNativeReadinessScope(store: store, spaceID: store.currentSpaceID)
        let readinessSections = declareNativePopulation(readinessScope)

        // Keep both sections in one tree when a gesture starts, reverses or springs back.
        // Only profile boundaries move the grid; ordinary Space switches leave it fixed.
        VStack(spacing: Look.rowGap) {
            favorites.offset(x: gesture.travelsFavorites ? gesture.liveContentDrag : 0)
            ZStack(alignment: .topLeading) {
                sections.spaceSlide(store)
                    .environment(\.sidebarNativeReadinessScope, readinessScope)
                    .environment(\.sidebarNativeReadinessOwnerID, readinessOwnerID)
                    .transaction(value: store.currentSpaceID) {
                        if gesture.swiping {
                            $0.animation = nil
                            $0.disablesAnimations = true
                        }
                    }
                    .opacity(showsOutgoingPreview ? 0 : 1)
                    .allowsHitTesting(!gesture.swiping)
                    .accessibilityHidden(gesture.swiping)
                if showsOutgoingPreview, !gesture.profileSliding, let outgoing = gesture.outgoing {
                    outgoing.equatable()
                        .background(SpaceStripAnchor(store: store, gesture: gesture, moving: true))
                        .environment(\.colorScheme, outgoing.colorScheme)
                        .offset(x: gesture.drag)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background(SpaceStripAnchor(store: store, gesture: gesture, moving: false, sectionsOnly: true,
                                         renderedSpaceID: store.currentSpaceID,
                                         renderedAtRest: !gesture.swiping && !gesture.profileSliding && gesture.drag == 0,
                                         readinessSections: readinessSections, readinessOwnerID: readinessOwnerID))
            .opacity(gesture.profileSliding ? 0 : 1)
        }
        .background(SpaceStripAnchor(store: store, gesture: gesture, moving: false))
        .overlay(alignment: .topLeading) { preview }
        .transaction(value: gesture.swiping) { transaction in
            if !gesture.swiping {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .opacity(gesture.profileSliding && gesture.profileSlidesFavorites ? 0 : 1)
    }

    @ViewBuilder private var preview: some View {
        let drag = gesture.drag
        if !usesNativePresentation, gesture.swiping, !gesture.profileSliding, let space = gesture.neighbour {
            let preview = store.swipePreview(in: space)
            preview.equatable()
                .id(space.id)
                .transition(.identity)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.colorScheme, preview.colorScheme)
                // Within a profile the grid stays put, so its ghost starts below it.
                // Across profiles the ghost includes its own grid and starts at the top.
                .padding(.top, preview.includingFavorites ? 0 : favoriteHeight)
                .offset(x: drag + CGFloat(gesture.previewDirection) * sidebar.width)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .opacity(gesture.profileSliding ? 0 : 1)
        }
    }

    private var favoriteHeight: CGFloat {
        guard favoriteCount > 0 else { return 0 }
        let columns = SidebarWidth.favouriteColumns(favoriteCount, width: sidebar.width)
        let rows = (favoriteCount + columns - 1) / columns
        // Tile rows, their gaps, and the inset before the Space heading. Matches Favorites.
        return CGFloat(rows) * (Look.tileHeight + Look.inset)
    }
}

/// Native geometry keeps a profile boundary on the same sidebar track.
private struct SpaceStripAnchor: NSViewRepresentable {
    @Environment(\.nativeCachedSidebarBatches) private var nativeCachedBatches
    final class Anchor: NSView {
        var readinessScope: SidebarNativeReadinessScope?
        var readinessOwnerID: UUID?
        func setReadinessScope(_ next: SidebarNativeReadinessScope?, sections: [String: [String]]? = nil,
                               populationOwnerID: UUID? = nil) {
            if readinessScope == next, readinessOwnerID == populationOwnerID {
                if let next, let sections {
                    SidebarNativeReadinessCoordinator.shared.retainPopulationExpectation(next,
                        owner: ObjectIdentifier(self), sections: sections, populationOwnerID: populationOwnerID)
                }
                return
            }
            if let readinessScope {
                SidebarNativeReadinessCoordinator.shared.releasePopulationExpectation(readinessScope, owner: ObjectIdentifier(self))
            }
            readinessScope = next
            readinessOwnerID = populationOwnerID
            if let next {
                SidebarNativeReadinessCoordinator.shared.retainPopulationExpectation(next, owner: ObjectIdentifier(self),
                    sections: sections, populationOwnerID: populationOwnerID)
            }
        }
    }
    let store: TabStore
    let gesture: SpaceGesture
    let moving: Bool
    var sectionsOnly = false
    var renderedSpaceID: UUID?
    var renderedAtRest = false
    var readinessSections: [String: [String]]? = nil
    var readinessOwnerID: UUID? = nil
    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.wantsLayer = true
        if moving { gesture.outgoingView = view }
        else if sectionsOnly { gesture.sectionsView = view }
        else { gesture.stripView = view }
        return view
    }
    func updateNSView(_ view: Anchor, context: Context) {
        if sectionsOnly {
            view.setReadinessScope(nativeCachedBatches || NativeCachedSidebarBatchesExperiment.enabled
                ? SidebarNativeReadinessScope(store: store, spaceID: renderedSpaceID) : nil,
                sections: readinessSections, populationOwnerID: readinessOwnerID)
            gesture.monitor.schedulePreparation(in: store)
            (store.window?.contentView as? BrowserWindowHost)?.spaceSlide?.sidebarDidUpdate(
                store, renderedSpaceID: renderedSpaceID, atRest: renderedAtRest)
        }
    }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        view.setReadinessScope(nil)
    }
}

@MainActor private final class LiveSidebarIdentity {
    private var initialized = false
    private var spaceID: UUID?
    private var identity = UUID()

    func resolve(spaceID next: UUID?, covered: Bool) -> UUID {
        if !initialized || spaceID != next {
            if !initialized || !covered { identity = UUID() }
            initialized = true
            spaceID = next
        }
        return identity
    }
}

private struct SpaceSlide: ViewModifier {
    @ObservedObject var store: TabStore
    @ObservedObject private var gesture: SpaceGesture
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var liveIdentity = LiveSidebarIdentity()

    init(store: TabStore) {
        self.store = store
        gesture = store.spaceGesture
    }

    func body(content: Content) -> some View {
        let forwards = store.spaceDirection > 0
        let covered = (store.window?.contentView as? BrowserWindowHost)?.spaceSlide?.isActive == true
        content
            // Native travel already owns replacement pixels. Keep its covered live
            // scroll/layout shell; rebuilding it here blocks the next finger sample.
            // Uncovered keyboard/menu changes retain their removal/insertion transition.
            .id(liveIdentity.resolve(spaceID: store.currentSpaceID, covered: covered))
            .transition(.asymmetric(
                insertion: .move(edge: forwards ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: forwards ? .leading : .trailing).combined(with: .opacity)))
            // A swipe has already carried the sections to where the new Space's preview was
            // standing; letting this run on top would slide the same content a second time.
            // Keyboard/menu switches also get the Space exception after the outer policy.
            .transaction(value: store.currentSpaceID) { transaction in
                guard !transaction.isSpaceHandoff, !reduceMotion, !Motion.spaceReduced, !gesture.swiping else { return }
                transaction.disablesAnimations = false
                transaction.animation = Look.spaceSlide
            }
            .offset(x: gesture.liveContentDrag)
    }
}

/// The neighbouring Space's sidebar, as a ghost, for the width of a swipe: its name, its
/// pinned rows, its tabs.
///
/// Rows use already loaded tabs when available, and saved metadata otherwise. Previewing
/// another Space never creates a tab or loads a page.
/// Ceiling: a site never visited has no cached favicon. The label climbs the same ladder the
/// real row does — a typed name, the tidied name, the name it was pinned under, the title
/// the sidecar saved — and only a row nothing has ever named is its host.
struct SpacePreviewList: View, Equatable {
    let space: Space
    let liveTabs: [Tab]?
    private let identity = UUID()
    private let saved: [String: Parked]
    private let savedNames: [String: String]
    let rows: (pinned: [Row], today: [Row])
    private let todayCount: Int
    private let selectedID: UUID?
    private let selectedSavedRow: String?
    private let capturedPRs: [UUID: GitHub.Row]
    private let renderStore: TabStore?
    private let selection: Set<UUID>
    private let scrollOffset: CGFloat
    private let tidyRunning: Bool
    private let splits: [Split]
    private let unlocked: Set<UUID>
    private let live: LiveFolders?
    private let favoriteItems: [(url: URL?, tab: Tab?)]
    private let pinnedAvailable: Bool
    let favorites: [URL]
    let includingFavorites: Bool
    let pinnedCollapsed: Bool
    let eagerlyMountsVisibleRows: Bool
    private let tracksNativePopulation: Bool

    /// Capture once, before the preview moves. Decoding interaction states and rebuilding
    /// folders in body would repeat disk work on every frame of a populated Space swipe.
    init(space requested: Space, liveTabs: [Tab]?, state: Stash? = nil,
         favorites: [URL] = [], includingFavorites: Bool = false, pinnedCollapsed: Bool = false,
         live: LiveFolders? = nil, renderStore: TabStore? = nil,
         favoriteTabs: [Tab] = [], unlocked: Set<UUID> = [], newProfile: Bool = false,
         selection: Set<UUID> = [], scrollOffset: CGFloat = 0, preservesSelection: Bool = false) {
        tracksNativePopulation = NativeCachedSidebarBatchesExperiment.enabled
        var space = requested
        if newProfile && state == nil && liveTabs == nil {
            // A newly mounted profile uses TabStore.init's restoration path, which removes
            // Today URLs already present in its favourites or pinned section.
            let kept = Set(favorites + (space.pinnedTabURLs ?? []))
            space.tabURLs.removeAll { kept.contains($0) }
        }
        self.space = space
        self.liveTabs = state?.tabs ?? liveTabs
        self.favorites = favorites
        self.includingFavorites = includingFavorites
        self.pinnedCollapsed = pinnedCollapsed
        self.renderStore = renderStore
        self.selection = selection
        self.scrollOffset = scrollOffset
        tidyRunning = !newProfile && (renderStore.map { TidyProgress.shared.isRunning($0) } ?? false)
        favoriteItems = favoriteTabs.isEmpty ? favorites.map { ($0, nil) }
            : favoriteTabs.map { ($0.pinnedURL, $0) }
        self.unlocked = unlocked
        self.splits = state?.splits ?? []
        let last = Spaces.lastTab(in: space.id)
        let tabs = state?.tabs ?? liveTabs
        // A cached profile already showing this Space keeps its selection on hop,
        // including an explicitly empty one. Other Spaces use switchTo's landing
        // rules when their stash is restored.
        self.selectedID = preservesSelection ? state?.current : state?.current ?? tabs.flatMap { tabs in
            if newProfile { return tabs.first { $0.kind == .today }?.id }
            return Spaces.landing(on: tabs.map { ($0.pinnedURL?.absoluteString, $0.kind) }, last: last)
                .map { tabs[$0].id }
        }
        let pinURLs = TabStore.pinOrder(shape: TabStore.savedShape(.pinned, space: space.id,
            profileID: space.profileID), urls: space.pinnedTabURLs ?? [])
        let todayURLs = TabStore.pinOrder(shape: TabStore.savedShape(.today, space: space.id,
            profileID: space.profileID), urls: space.tabURLs)
        let diskTabs = pinURLs.enumerated().map { (url: $0.element, kind: TabKind.pinned, index: $0.offset) }
            + todayURLs.enumerated().map { (url: $0.element, kind: TabKind.today, index: $0.offset) }
        let landing = newProfile ? diskTabs.firstIndex { $0.kind == .today }
            : Spaces.landing(on: diskTabs.map { ($0.url.absoluteString, $0.kind) }, last: last)
        self.selectedSavedRow = landing.map { "\(diskTabs[$0].kind)-\(diskTabs[$0].index)" }
        // Live row surfaces already own their page metadata. Loading the sidecar here
        // also decodes opaque interaction states that these previews never use.
        // Saved rows and the favourite grid still need their saved-page fallback.
        let needsSaved = tabs == nil || renderStore == nil || includingFavorites
        let capturedSaved = needsSaved
            ? Suspension.SpaceState.load(space: space.id, profileID: space.profileID, in: Store.directory)
            : [:]
        saved = capturedSaved
        savedNames = Dictionary((self.liveTabs == nil ? diskTabs : []).map { item in
            let name = Self.savedName(url: item.url, kind: item.kind, profile: space.profileID, saved: capturedSaved)
            return ("\(item.kind)-\(item.url.absoluteString)", name)
        }, uniquingKeysWith: { first, _ in first })
        let live = live ?? LiveFolders.existing(for: space.profileID)
        self.live = live
        capturedPRs = Dictionary((self.liveTabs ?? []).compactMap { tab in
            guard let folder = state?.pins.folder(holding: tab.id.uuidString), folder.live != nil,
                  let url = tab.pinnedURL,
                  let pr = live?.row(of: url.absoluteString, in: folder) else { return nil }
            return (tab.id, pr)
        }, uniquingKeysWith: { first, _ in first })
        let pinned = Self.section(space: space, kind: .pinned, tabs: self.liveTabs,
                                  liveShape: state?.pins, splits: splits, live: live, unlocked: unlocked)
        let today = Self.section(space: space, kind: .today, tabs: self.liveTabs,
                                 liveShape: state?.todayShape, splits: splits, live: nil, unlocked: unlocked)
        pinnedAvailable = !pinned.rows.isEmpty
        todayCount = self.liveTabs?.filter { $0.kind == .today }.count ?? space.tabURLs.count
        let regularCount = self.liveTabs?.filter { $0.kind != .favourite }.count ?? diskTabs.count
        let tabCount = regularCount + favoriteItems.count
        let folderCount = pinned.folderCount + today.folderCount
        // Preserve the existing small-preview lazy path, including the retained-lazy
        // experiment. Only the new medium-outline path needs preview/live parity.
        eagerlyMountsVisibleRows = Feel02SidebarRowsCache.usesBoundedEagerRows(
            tabCount: tabCount, folderCount: folderCount)
        rows = (pinnedCollapsed ? [] : pinned.rows, today.rows)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }

    enum Row {
        case folder(Folder, depth: Int = 0)
        case blank(Tab, depth: Int = 0)
        case site(URL, TabKind, Tab? = nil, depth: Int = 0, pr: GitHub.Row? = nil, savedIndex: Int? = nil)

        var depth: Int {
            switch self {
            case .folder(_, let depth), .blank(_, let depth), .site(_, _, _, let depth, _, _): return depth
            }
        }

        var pr: GitHub.Row? {
            guard case .site(_, _, _, _, let pr, _) = self else { return nil }
            return pr
        }
    }

    var colorScheme: ColorScheme {
        switch space.appearance {
        case "light": return .light
        case "dark": return .dark
        default:
            return NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Look.rowGap) {
            if includingFavorites { favoriteGrid }
            SpaceSectionsLayout(initialOffset: scrollOffset, animatesCutoffs: false) {
                HStack(spacing: 0) {
                    HStack(spacing: Look.rowSpacing) {
                        Image(systemName: (space.icon ?? "cloud") == "cloud" ? "cloud.fill" : (space.icon ?? "cloud"))
                            .font(Look.spaceIcon).foregroundStyle(Look.inkPrimary).frame(width: Look.tileIcon)
                        Text(space.name).font(Look.spaceTitle).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    Color.clear.frame(width: Look.rowTarget)
                }
                .foregroundStyle(Look.inkTertiary)
                .padding(.leading, Look.rowInset)
                .padding(.trailing, Look.rowInset / 2)
                .frame(height: Look.rowHeight)
                .padding(.bottom, pinnedCollapsed || !pinnedAvailable ? 0 : Look.sectionGap / 2 - Look.rowGap)
            } rows: {
                if pinnedAvailable {
                    sectionRows(rows.pinned, section: "pinned")
                    .padding(.bottom, pinnedCollapsed ? -Look.rowGap : 0)
                }
                tidy
                newTab
                sectionRows(rows.today, section: "today")
                Color.clear.frame(maxWidth: .infinity, minHeight: Look.rowHeight)
            }
        }
        .environment(\.feel02PressFeedbackEnabled, false)
    }

    private func sectionRows(_ rows: [Row], section: String) -> some View {
        Group {
            if eagerlyMountsVisibleRows {
                VStack(spacing: Look.rowGap) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, entry in
                        previewRow(entry, index: index, section: section)
                    }
                }
            } else {
                LazyVStack(spacing: Look.rowGap) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, entry in
                        previewRow(entry, index: index, section: section)
                    }
                }
            }
        }
        .background {
            if tracksNativePopulation { SidebarPreviewPopulationAnchor(section: section, count: rows.count) }
        }
    }

    private func previewRow(_ entry: Row, index: Int, section: String) -> some View {
        row(entry, selected: isSelected(entry))
            .background {
                if tracksNativePopulation { SidebarPreviewPopulationAnchor(section: section, row: index) }
            }
    }

    private func isSelected(_ row: Row) -> Bool {
        if let tab = liveTab(for: row) {
            if let split = splits.first(where: { $0.contains(tab.id) }) {
                return selectedID.map(split.contains) ?? false
            }
            return tab.id == selectedID
        }
        guard case .site(_, let kind, _, _, _, let index) = row, let index else { return false }
        return selectedSavedRow == "\(kind)-\(index)"
    }

    /// Use the same visible outline as the live sidebar, including nesting and collapse.
    /// Disk shapes name URLs; live shapes name Tab IDs, so restore the former with the
    /// same counted URL mapping as the real section (duplicates remain distinct).
    private static func section(space: Space, kind: TabKind, tabs: [Tab]?,
                                liveShape: Pins?, splits: [Split], live: LiveFolders?, unlocked: Set<UUID>)
        -> (rows: [Row], folderCount: Int) {
        let urls = kind == .pinned ? space.pinnedTabURLs ?? [] : space.tabURLs
        let loaded = tabs?.filter { $0.kind == kind }
        let savedShape = TabStore.savedShape(kind, space: space.id, profileID: space.profileID)
        // Match restorePins' stale-shape guard when the saved section has lost all its URLs.
        let disk = kind == .pinned && urls.isEmpty && savedShape?.tabs.isEmpty == false ? nil : savedShape
        let ordered = TabStore.pinOrder(shape: disk, urls: urls)
        let opened: [(url: String, id: String)] = loaded.map { tabs in
            tabs.map { tab in (tab.pinnedURL?.absoluteString ?? "", tab.id.uuidString) }
        } ?? ordered.enumerated().map { ($0.element.absoluteString, String($0.offset)) }
        var shape = liveShape ?? TabStore.adopted(disk, opened: opened)
        // A live snapshot counts its raw shape. Cold restoration removes stale empty
        // Today folders before the arriving live sidebar evaluates its structural bound.
        let liveFolderCount = liveShape?.entries.filter { $0.folder != nil }.count
        if kind == .today { shape.removeEmptyFolders() }
        let folderCount = liveFolderCount ?? shape.entries.filter { $0.folder != nil }.count
        let byID = Dictionary(uniqueKeysWithValues: opened.map { ($0.id, $0.url) })
        let liveByID = Dictionary(uniqueKeysWithValues: (loaded ?? []).map { ($0.id.uuidString, $0) })
        let strip = (tabs ?? []).map { ($0.id, $0.kind) }
        let rows: [Row] = shape.visible(unlocked: unlocked).compactMap { visible in
            if let folder = visible.entry.folder { return .folder(folder, depth: visible.depth) }
            guard let id = visible.entry.tab, let name = byID[id] else { return nil }
            let tab = liveByID[id]
            if let tab, let split = splits.first(where: { $0.contains(tab.id) }),
               Split.lead(of: split.tabs, strip: strip) != tab.id { return nil }
            // Match the live pinned section's ownership lookup, using the row's saved URL.
            // Capture metadata here so a refresh cannot change the label during a swipe.
            let folder = shape.folder(holding: id)
            let pr = folder.flatMap { $0.live == nil ? nil : live?.row(of: name, in: $0) }
            guard let url = URL(string: name), !name.isEmpty else {
                return tab.map { .blank($0, depth: visible.depth) }
            }
            return .site(url, kind, tab, depth: visible.depth, pr: pr, savedIndex: tab == nil ? Int(id) : nil)
        }
        return (rows, folderCount)
    }

    private var favoriteGrid: some View {
        Group {
            if !favoriteItems.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Look.inset),
                    count: SidebarWidth.favouriteColumns(favoriteItems.count, width: SidebarWidth.shared.width)),
                    spacing: Look.inset) {
                    ForEach(Array(favoriteItems.enumerated()), id: \.offset) { _, item in
                        let tab = item.tab
                        let page = tab?.currentURL ?? item.url.flatMap { saved[$0.absoluteString]?.page ?? $0 }
                        let fixedIcon = tab?.favicon ?? page.flatMap { $0.isFileURL ? Files.icon(for: $0) : nil }
                        CachedFavicon(cache: Favicons.cache(for: space.profileID),
                                      url: fixedIcon == nil && page?.isFileURL != true ? page : nil) { cached in
                            let icon = fixedIcon ?? cached
                            SidebarPageIcon(icon: icon, easel: page.flatMap(EaselAddress.boardID) != nil,
                                            rounded: page?.isFileURL != true, size: Look.tileIcon)
                                .frame(maxWidth: .infinity, minHeight: Look.tileHeight)
                                .background(FavoriteTileBackground(selected: tab?.id == selectedID && tab != nil,
                                                                  hovering: false, icon: icon))
                        }
                    }
                }
                .padding(.bottom, Look.inset - Look.rowGap)
            }
        }
    }

    /// Draw the same housekeeping controls with inert actions while the preview moves.
    private var tidy: some View {
        let control = TidyTabs.control(today: todayCount, threshold: TidyTabs.threshold,
            enabled: TidyTabs.enabled, running: tidyRunning)
        return SidebarTidySurface {
            switch control {
            case .hidden: EmptyView()
            case .tidy: Button("Tidy", action: {})
            case .tidying:
                ProgressView().controlSize(.small).scaleEffect(Look.tidySpinnerScale)
                    .frame(height: Look.tidyRow)
            }
            if TidyTabs.offersHousekeeping(today: todayCount, threshold: Look.tidyThreshold) {
                if control != .hidden { Text("|").foregroundStyle(Look.inkQuiet) }
                Button("Clear", action: {})
            }
        }
    }

    private var newTab: some View {
        SidebarRow(icon: "plus", title: "New Tab", selected: false, dimmed: true, action: {})
    }

    @ViewBuilder private func row(_ row: Row, selected: Bool) -> some View {
        Group {
            if let tab = liveTab(for: row), let renderStore {
                if let split = splits.first(where: { $0.contains(tab.id) }) {
                    let focused = selectedID.flatMap { split.contains($0) ? split.focusing($0) : nil } ?? split
                    let candidates = (liveTabs ?? []) + favoriteItems.compactMap(\.tab)
                    let panes = focused.tabs.compactMap { id in candidates.first { $0.id == id } }
                    PaneStrip(store: renderStore, split: focused, panes: panes, selected: selected,
                              ticked: selection.contains(tab.id), previewPRs: capturedPRs)
                } else {
                    SidebarTabPresentation(store: renderStore, tab: tab, returnHovering: .constant(false),
                                           pr: row.pr, action: {}, selected: selected,
                                           ticked: selection.contains(tab.id), previewing: true, renaming: false)
                        .environment(\.livePR, row.pr)
                }
            } else if case .folder(let folder, _) = row {
                SidebarRow(selected: false, action: {}) {
                    FolderGlyph(folder: folder, live: live)
                } label: {
                    Text(folder.name).font(Look.folderTitle)
                } trailing: {
                    FolderDisclosure(folder: folder,
                                     locked: folder.requiresAuthentication == true && !unlocked.contains(folder.id))
                }
            } else {
                savedRow(row, selected: selected)
            }
        }
        .padding(.leading, CGFloat(row.depth) * Look.folderIndent)
    }

    private func savedRow(_ row: Row, selected: Bool) -> some View {
        let tab = liveTab(for: row)
        let page = pageURL(for: row, saved: saved, tab: tab)
        let developer = page.map { DeveloperMode.wants($0, profile: space.profileID) } ?? false
        let returning: Bool = {
            guard case .site(let url, .pinned, _, _, _, _) = row else { return false }
            return tab.map { !$0.atHome } ?? (page != url)
        }()
        let fixedIcon = tab?.favicon ?? page.flatMap { $0.isFileURL ? Files.icon(for: $0) : nil }
        return SidebarRow(selected: selected, labelSpacing: returning ? 6 : Look.rowSpacing, action: {}) {
            HStack(spacing: 4) {
                CachedFavicon(cache: Favicons.cache(for: space.profileID),
                              url: fixedIcon == nil && page?.isFileURL != true ? page : nil) { cached in
                    SidebarPageIcon(icon: fixedIcon ?? cached, easel: page.flatMap(EaselAddress.boardID) != nil,
                                    pr: row.pr, rounded: page?.isFileURL != true)
                }
                if returning {
                    Text("/").font(Look.rowTitle.weight(.bold)).foregroundStyle(Look.inkTertiary)
                        .frame(width: 6).accessibilityHidden(true)
                }
            }
        } label: {
            LivePRTitle(title: title(for: row), pr: row.pr,
                        developerEndpoint: developer ? DeveloperMode.endpoint(page) : nil)
        } trailing: {
            if let tab, tab.audible || TabAudio.isMuted(tab) {
                Image(systemName: TabAudio.isMuted(tab) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(Look.rowGlyph).frame(width: Look.rowTarget, height: Look.rowTarget).foregroundStyle(Look.inkSecondary)
            }
        }
        .overlay { if developer { DeveloperTabBorder() } }
    }

    func title(for row: Row) -> String {
        if case .site(let url, let kind, nil, _, _, _) = row,
           let title = savedNames["\(kind)-\(url.absoluteString)"] { return title }
        return title(for: row, saved: saved)
    }

    func title(for row: Row, saved: [String: Parked]) -> String {
        switch row {
        case .folder(let folder, _): return folder.name
        case .blank(let tab, _): return TidyTitles.title(for: tab)
        case .site(let url, let kind, _, _, _, _):
            return liveTab(for: row).map { TidyTitles.title(for: $0) }
                ?? Self.savedName(url: url, kind: kind, profile: space.profileID, saved: saved)
        }
    }

    private static func savedName(url: URL, kind: TabKind, profile: UUID, saved: [String: Parked]) -> String {
        let parked = saved[url.absoluteString]
        let page = parked?.page ?? url
        if let id = EaselAddress.boardID(page) {
            let board = EaselStore.shared(profileID: profile, directory: Store.directory).board(id)
            return board.map { $0.title.isEmpty ? "Untitled Easel" : $0.title } ?? "Easel unavailable"
        }
        let raw = TabStore.parkedTitle(saved: parked?.title ?? "",
            remembered: Store.store(for: profile).title(for: page), url: page)
        return TidyTitles.previewName(for: url, in: profile, saved: raw, stays: kind != .today)
    }

    private func liveTab(for row: Row) -> Tab? {
        switch row {
        case .blank(let tab, _): return tab
        case .site(_, _, let tab, _, _, _): return tab
        case .folder: return nil
        }
    }

    private func pageURL(for row: Row, saved: [String: Parked], tab: Tab?) -> URL? {
        if case .blank(let tab, _) = row { return tab.currentURL }
        guard case .site(let url, _, _, _, _, _) = row else { return nil }
        return tab?.currentURL ?? saved[url.absoluteString]?.page ?? url
    }
}

extension TabStore {
    /// Clicks use the swipe preview so the outgoing sidebar survives until the slide ends,
    /// including when the destination skips Spaces or belongs to another profile.
    func beginSpaceSelection(_ requested: Space) -> Int? {
        guard !isPrivate, !isLittle, !isParked,
              requested.id != (spaceGesture.outgoing?.space.id ?? currentSpaceID) else { return nil }
        let origin = spaceGesture.outgoing?.space.id ?? currentSpaceID
        let list = strip
        guard let target = list.first(where: { $0.id == requested.id }),
              list.contains(where: { $0.id == origin }) else { return nil }
        let direction = Spaces.direction(from: origin, to: target.id, in: list.map(\.id))
        if creatingSpace { creatingSpace = false }
        spaceSwiping = true
        spaceGesture.strip = list
        spaceGesture.neighbour = target
        spaceGesture.previewDirection = direction
        spaceGesture.travelsFavorites = target.profileID != profileID
        _ = swipePreview(in: target)
        return direction
    }

    func swipeNeighbour(for drag: CGFloat) -> Space? {
        guard drag != 0, let index = swipeStrip.firstIndex(where: { $0.id == currentSpaceID }) else { return nil }
        let next = drag < 0 ? index + 1 : index - 1
        return swipeStrip.indices.contains(next) ? swipeStrip[next] : nil
    }

    /// Cache the complete visual state once per neighbour, including a parked profile.
    func swipePreview(in space: Space, includingFavorites: Bool = false) -> SpacePreviewList {
        if !includingFavorites, spaceSwiping, let preview = spaceGesture.previews[space.id] { return preview }
        let state = previewState(in: space)
        let owner = previewOwner(for: space)
        // Shared content can come from another window; presentation must come from this one.
        let presentationOwner = space.profileID == profileID ? self : TabStore.all.first {
            $0.profileID == space.profileID && window != nil && $0.parkedIn === window
        }
        let favorites = owner?.tabs.filter { $0.kind == .favourite }.compactMap(\.pinnedURL) ?? {
            let existing = (UserDefaults.vane.stringArray(forKey: TabStore.defaultsKey(.favourite, space.profileID)) ?? [])
                .compactMap { URL(string: $0) }
            let legacy = ProfileManager.shared.spaces(for: space.profileID).map(\.pinnedURLs)
            // Match first-mount migration without writing preferences during a gesture.
            return legacy.contains(where: { !$0.isEmpty })
                ? Spaces.mergedFavourites(existing: existing, perSpace: legacy)
                : Array(existing.prefix(Spaces.favouritesCap))
        }()
        let preview = SpacePreviewList(space: space, liveTabs: state?.tabs, state: state,
                                       favorites: favorites, includingFavorites: includingFavorites || space.profileID != profileID,
                                       pinnedCollapsed: presentationOwner?.collapsedPinnedSpaces.contains(space.id) ?? false,
                                       renderStore: presentationOwner ?? owner ?? self,
                                       favoriteTabs: owner?.tabs.filter { $0.kind == .favourite } ?? [],
                                       unlocked: (presentationOwner ?? self).folderAuthentication.grants(for: space.profileID),
                                       newProfile: space.profileID != profileID && presentationOwner == nil,
                                       selection: presentationOwner?.currentSpaceID == space.id
                                           ? presentationOwner?.selection.ids ?? [] : [],
                                       scrollOffset: presentationOwner?.currentSpaceID == space.id
                                           ? presentationOwner?.spaceGesture.sidebarOffset ?? 0 : 0,
                                       preservesSelection: presentationOwner?.currentSpaceID == space.id)
        if spaceSwiping && !includingFavorites { spaceGesture.previews[space.id] = preview }
        return preview
    }

    private func previewOwner(for space: Space) -> TabStore? {
        if space.profileID == profileID { return self }
        return TabStore.all.first { $0.profileID == space.profileID && $0.parkedIn === window && window != nil }
            ?? TabStore.all.first { $0.profileID == space.profileID && $0.sharesTabs }
    }

    func previewState(in space: Space) -> Stash? {
        if space.profileID != profileID {
            if let parked = TabStore.all.first(where: {
                $0.profileID == space.profileID && window != nil && $0.parkedIn === window
            }) {
                return parked.previewState(in: space)
            }
            return SharedTabs.state(profileID: space.profileID, space: space.id)
        }
        if currentSpaceID == space.id {
            return Stash(tabs: tabs.filter { $0.kind != .favourite }, pins: pins, todayShape: todayShape,
                         splits: splits, current: current, fingerprint: "")
        }
        if var shared = SharedTabs.state(for: self, space: space.id) {
            if let remembered = stashes[space.id] {
                shared.current = remembered.current.flatMap { id in shared.tabs.contains { $0.id == id } ? id : nil }
                    ?? shared.current
                shared.splits = shared.splits.map { split in
                    let focus = remembered.splits.first { Set($0.tabs) == Set(split.tabs) }?.activeTab
                    return focus.map { split.focusing($0) } ?? split
                }
            }
            return shared
        }
        guard let kept = stashes[space.id], kept.fingerprint == fingerprint(of: space.id) else { return nil }
        return kept
    }

    func previewTabs(in space: Space) -> [Tab]? { previewState(in: space)?.tabs }

}

private struct SpaceSwipe: ViewModifier {
    @ObservedObject var store: TabStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var visible: Bool { store.profileVisible && (store.sidebarShown || store.sidebarPeeking) }

    private func reconcileInput() {
        let monitor = store.spaceGesture.monitor
        if !store.profileVisible { monitor.remove() }
        else if visible { monitor.install(store) }
        else { monitor.suspend() }
    }

    func body(content: Content) -> some View {
        let monitor = store.spaceGesture.monitor
        content
            .onAppear { reconcileInput() }
            .onDisappear {
                // Cached-host callbacks can trail a completed return to this profile.
                // Model ownership, rather than that old callback, owns current input.
                if !store.profileVisible || store.window == nil || !TabStore.all.contains(where: { $0 === store }) {
                    monitor.remove()
                }
            }
            // The sidebar stays mounted offscreen between edge reveals. Its gesture
            // lifetime still follows visibility, including cancellation of a live drag.
            .onChange(of: visible) {
                if visible {
                    if !Motion.reduced { monitor.postponePreparation(in: store, by: 0.35, preservingSurfaces: true) }
                }
                reconcileInput()
            }
            .onChange(of: store.sidebarShown) { _, shown in
                // Docking a peek keeps `visible` true, but still animates the page seam.
                if shown, !Motion.reduced { monitor.postponePreparation(in: store, by: 0.35, preservingSurfaces: true) }
            }
            .onChange(of: store.profileVisible) { reconcileInput() }
            .onChange(of: reduceMotion) { _, reduced in
                if reduced { monitor.finishForReducedMotion() }
            }
    }
}

/// The scroll-wheel monitor behind the swipe. A local `NSEvent` monitor rather than a view
/// that overrides `scrollWheel(with:)`: the sidebar's `ScrollView` is an `NSScrollView` and
/// gets the event first, so anything sitting behind it never sees one.
///
/// Its only job is to turn `NSEvent`s into `Spaces.Swipe`'s vocabulary and to put the answer
/// on the store. Everything that can be got wrong — the threshold, the velocity, the band at
/// the ends, the one-commit rule — lives in the pure state machine, where `check()` can hold
/// it to account.
@MainActor final class SwipeMonitor {
    var isInstalled: Bool { monitor != nil }
    private(set) var preparedSlides: [UUID: ProfileSpaceSlide] = [:]
    private var preparation: DispatchWorkItem?
    private var preparationNotBefore: TimeInterval = 0
    private static let preparationQuietInterval: TimeInterval = 0.35
    private var stalePreparedSlides: [ProfileSpaceSlide] = []
    private var preparationObservers: [AnyCancellable] = []
    private var preparationPeers: [ObjectIdentifier: AnyCancellable] = [:]
    private var preparationProfiles: Set<UUID> = []

    /// Preview rows can come from another window or a parked profile. Observe the
    /// supplying profiles, and invalidate synchronously before their row mutations.
    private func observePreparationPeers(for profiles: Set<UUID>, in store: TabStore) {
        preparationProfiles = profiles
        preparationPeers.removeAll()
        for peer in TabStore.all where peer !== store && profiles.contains(peer.profileID) {
            preparationPeers[ObjectIdentifier(peer)] = peer.sidebarSnapshotChanges.sink { [weak self, weak store] _ in
                self?.extendPreparationQuietInterval()
                self?.invalidatePreparation()
                DispatchQueue.main.async { [weak self, weak store] in
                    guard let self, let store else { return }
                    self.schedulePreparation(in: store)
                }
            }
        }
    }

    private func invalidatePreparation() {
        preparation?.cancel()
        preparation = nil
        // Detach and revoke immediately, including protected peer changes. Keep
        // ownership until idle so the input event does not also destroy SwiftUI's
        // focus/hover/layout graphs for every captured row.
        let retired = Array(preparedSlides.values)
        discardPreparation()
        stalePreparedSlides.append(contentsOf: retired)
    }

    private func extendPreparationQuietInterval() {
        preparationNotBefore = max(preparationNotBefore,
            ProcessInfo.processInfo.systemUptime + Self.preparationQuietInterval)
        preparation?.cancel()
        preparation = nil
    }

    /// Hidden hosting trees share the UI thread with visible travel and scrolling.
    /// Keep their work behind a quiet interval, even if another publisher reschedules it.
    func postponePreparation(in store: TabStore, by delay: TimeInterval, preservingSurfaces: Bool = false) {
        preparationNotBefore = max(preparationNotBefore, ProcessInfo.processInfo.systemUptime + delay)
        preparation?.cancel()
        preparation = nil
        // Invalidate reuse immediately, but retain the hidden trees until idle: their
        // AppKit/SwiftUI teardown is also expensive on the first scroll event.
        if !preservingSurfaces {
            stalePreparedSlides.append(contentsOf: preparedSlides.values)
            preparedSlides.removeAll()
        }
        schedulePreparation(in: store)
    }

    /// Consume one validated idle capture for either a finger claim or a button click.
    /// Tracking already owns its surface before subsequent per-event updates reach here.
    private func takePreparedSlide(origin: Space, target: Space, direction: Int,
                                   frame: NSRect, width: CGFloat, in store: TabStore) -> ProfileSpaceSlide? {
        guard let slide = preparedSlides[target.id], self.store === store,
              !Motion.spaceReduced, !store.libraryOpen, store.librarySwipeProgress == nil,
              store.sidebarShown || (store.window as? VaneWindow)?.peekingSidebar == true else { return nil }
        // A newly created/removed supplier has no matching subscription yet. Validate at
        // consumption even when button selection has already marked the store swiping.
        let peers = Set(TabStore.all.filter {
            $0 !== store && preparationProfiles.contains($0.profileID)
        }.map(ObjectIdentifier.init))
        guard peers == Set(preparationPeers.keys) else {
            invalidatePreparation()
            return nil
        }
        guard slide.follows(target, direction: direction),
              slide.preparedFor(origin: origin, target: target, frame: frame, width: width) else { return nil }
        guard slide.preparedPopulationReady,
              slide.updatePreparedScrollOffset(store.spaceGesture.sidebarOffset),
              slide.preparedPopulationReady else {
            invalidatePreparation()
            return nil
        }
        preparedSlides.removeValue(forKey: target.id)
        preparation?.cancel()
        preparation = nil
        return slide
    }

    private func preparedGeometryMatches(in store: TabStore) -> Bool {
        guard !preparedSlides.isEmpty,
              let host = store.window?.contentView as? BrowserWindowHost,
              let origin = store.swipeSpace else { return false }
        let strip = store.strip
        guard let index = strip.firstIndex(where: { $0.id == store.currentSpaceID }) else { return false }
        let adjacent = [-1, 1].compactMap { direction in
            strip.indices.contains(index + direction) ? strip[index + direction].id : nil
        }
        guard Set(preparedSlides.keys) == Set(adjacent) else { return false }
        return preparedSlides.allSatisfy { id, slide in
            guard let target = strip.first(where: { $0.id == id }),
                  let anchor = target.profileID != store.profileID
                    ? store.spaceGesture.stripView : store.spaceGesture.sectionsView else { return false }
            return slide.preparedFor(origin: origin, target: target,
                frame: anchor.convert(anchor.bounds, to: host), width: SidebarWidth.shared.width)
        }
    }

    /// Build adjacent sidebar surfaces while idle, never in the first directional sample.
    /// Anchor updates invalidate them when the live sidebar or its geometry changes.
    func schedulePreparation(in store: TabStore) {
        guard monitor != nil, self.store === store, !store.spaceSwiping, !landing,
              store.palette == nil, !store.creatingSpace, !store.libraryOpen, store.librarySwipeProgress == nil else { return }
        guard preparation == nil else { return }
        // The geometry anchor can acknowledge the same layout several times. Store
        // and peer mutations already invalidate synchronously through the observers;
        // keep ready captures when only an unchanged acknowledgement arrives.
        if ProcessInfo.processInfo.systemUptime >= preparationNotBefore {
            if preparedGeometryMatches(in: store) { return }
            invalidatePreparation()
        }
        let work = DispatchWorkItem { [weak self, weak store] in
            self?.preparation = nil
            guard let self, let store, self.monitor != nil, self.store === store,
                  !store.spaceSwiping, !self.landing, store.palette == nil,
                  !store.creatingSpace, !store.libraryOpen, store.librarySwipeProgress == nil else { return }
            guard ProcessInfo.processInfo.systemUptime >= self.preparationNotBefore else {
                self.schedulePreparation(in: store)
                return
            }
            // Reveal anchors can report intermediate offscreen frames. Validate them
            // after travel settles; claim-time validation still rejects a mismatch.
            if self.preparedGeometryMatches(in: store) { return }
            self.invalidatePreparation()
            self.discardStalePreparation()
            guard !Motion.spaceReduced,
                  store.sidebarShown || (store.window as? VaneWindow)?.peekingSidebar == true,
                  let host = store.window?.contentView as? BrowserWindowHost else { return }
            let strip = store.strip
            guard let index = strip.firstIndex(where: { $0.id == store.currentSpaceID }),
                  let origin = store.swipeSpace else { return }
            let adjacent = [-1, 1].compactMap { direction in
                strip.indices.contains(index + direction) ? strip[index + direction] : nil
            }
            self.observePreparationPeers(for: Set(adjacent.map(\.profileID) + [origin.profileID]), in: store)
            for direction in [-1, 1] where strip.indices.contains(index + direction) {
                let target = strip[index + direction]
                let favorites = target.profileID != store.profileID
                guard let anchor = favorites ? store.spaceGesture.stripView : store.spaceGesture.sectionsView,
                      anchor.bounds.width > 0, anchor.bounds.height > 0 else { continue }
                let slide = ProfileSpaceSlide(frame: anchor.convert(anchor.bounds, to: host),
                    outgoing: store.swipePreview(in: origin, includingFavorites: favorites),
                    incoming: store.swipePreview(in: target), drag: 0, direction: direction,
                    source: store, includesFavorites: favorites, travelWidth: SidebarWidth.shared.width)
                slide.isHidden = true
                // Claim this surface in place; moving it above live rows on the first
                // finger sample would detach its compositor layer until a later frame.
                host.addSubview(slide, positioned: .above, relativeTo: nil)
                slide.prepare()
                self.preparedSlides[target.id] = slide
            }
        }
        preparation = work
        // Preparing two hosting trees during the floating panel's spring blocks its
        // middle frames. Let that travel (including its tail) finish before idle work.
        let revealDelay = !store.sidebarShown && store.sidebarPeeking && !Motion.reduced ? 0.35 : 0.08
        let delay = max(revealDelay, preparationNotBefore - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func discardPreparation() {
        for slide in preparedSlides.values { slide.discardPreparation() }
        preparedSlides.removeAll()
    }

    private func discardStalePreparation() {
        for slide in stalePreparedSlides { slide.discardPreparation() }
        stalePreparedSlides.removeAll()
    }
    /// A committed finger gesture belongs to its window even if a profile hop replaces
    /// the monitor. Consume its finger and momentum tail until the next beginning.
    private static let committedSwipes = NSHashTable<NSWindow>.weakObjects()
    private var monitor: Any?
    /// Weak, and kept, so `abort` has something to put back when the gesture is taken away
    /// rather than finished.
    private weak var store: TabStore?
    private var watchers: [any NSObjectProtocol] = []
    private var swipe = Spaces.Swipe()
    /// The previous event's timestamp, for the velocity. 0 means "no sample yet".
    private var last: TimeInterval = 0
    /// True while the landing spring is running, so a stray second fingers-up cannot spring
    /// the strip home over the top of it.
    private var landing = false
    private var landingFrom: UUID?
    private var returning = false
    private var pendingSelection: UUID?
    /// Invalidates mount delays and animation completions when input reverses or
    /// replaces a transition. SwiftUI continues from its current presentation value.
    private var transition = UUID()
    /// The strip as it was when this gesture was claimed — every profile's Spaces, which is
    /// what a swipe walks. `store.strip` reads and decodes one `spaces.json` per profile every
    /// time it is touched, and a gesture is a hundred events.
    private var list: [Space] = []

    /// Which way a gesture turned out to be going. Undecided until it has travelled far
    /// enough to have an answer — see `mine`.
    private enum Claim { case undecided, mine, theirs }
    private var claim = Claim.undecided
    private var travelled = (h: CGFloat(0), v: CGFloat(0))

    /// Reduce Motion commits an owned destination and finishes its presentation at once.
    func finishForReducedMotion() {
        guard let store, store.spaceSwiping else { return }
        let host = store.window?.contentView as? BrowserWindowHost
        let destination = host?.takeQueuedSpaceSelection()
            ?? (landing && store.currentSpaceID == landingFrom ? store.spaceGesture.neighbour : nil)
        host?.cancelSpaceSlide()
        transition = UUID()
        pendingSelection = nil
        landing = false
        landingFrom = nil
        returning = false
        forget()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            store.spaceGesture.drag = 0
            store.spacePull = 0
            store.spaceSwiping = false
            if let destination { store.switchTo(space: destination); rebuild() }
        }
    }

    func select(_ space: Space, in store: TabStore) {
        if hasNativePresentation(store), space.id != store.currentSpaceID
            || (store.window?.contentView as? BrowserWindowHost)?.spaceSlide?.isActive == true {
            store.spaceGesture.withPresentationUpdate { selectImmediately(space, in: store) }
        } else { selectImmediately(space, in: store) }
    }

    private func hasNativePresentation(_ store: TabStore) -> Bool {
        store.window?.contentView is BrowserWindowHost && store.spaceGesture.sectionsView != nil
    }

    private func selectImmediately(_ space: Space, in store: TabStore) {
        guard !store.isPrivate, !store.isLittle, !store.isParked else { return }
        let host = store.window?.contentView as? BrowserWindowHost
        host?.clearQueuedSpaceSelection()
        if let slide = host?.spaceSlide, slide.isActive, !Motion.spaceReduced,
           (slide.isDestination(store) && space.id == store.spaceGesture.outgoing?.space.id && space.id != store.currentSpaceID
            || returning && space.id == store.spaceGesture.neighbour?.id),
           slide.resumeTracking(in: store, dx: CGFloat(store.spaceGesture.previewDirection)) != nil {
            // Both endpoints already have captured pixels. Rebase that same pair
            // at its presented position before any cross-profile queueing below.
            land(store.spaceGesture.previewDirection, to: space, width: SidebarWidth.shared.width,
                 store: store, animation: Look.spaceSlide, duration: Look.spaceSlideDuration)
            return
        }
        if let host,
           let slide = host.spaceSlide, slide.isDestination(store) {
            // A profile can already own the page while its captured sidebar is landing.
            // Keep exposed rows stable until that leg finishes, just as within a profile.
            if slide.isActive, !Motion.spaceReduced {
                host.queueSpaceSelection(space, after: slide)
                return
            }
            host.cancelSpaceSlide()
        }
        guard !Motion.spaceReduced, store.window != nil else {
            host?.cancelSpaceSlide()
            transition = UUID()
            pendingSelection = nil
            landing = false
            landingFrom = nil
            returning = false
            store.spaceGesture.drag = 0
            store.spaceSwiping = false
            store.cancelCreatingSpace()
            store.switchTo(space: space)
            rebuild()
            return
        }
        if store.spaceSwiping, landing, landingFrom != store.currentSpaceID {
            // Keyboard/menu navigation superseded this preview. The next click owns
            // a fresh transition from the newly selected Space.
            transition = UUID()
            pendingSelection = nil
            landing = false
            landingFrom = nil
            returning = false
            store.spaceDrag = 0
            store.spaceSwiping = false
        }
        if store.spaceSwiping {
            if space.id == (store.spaceGesture.outgoing?.space.id ?? store.currentSpaceID) {
                if let host = store.window?.contentView as? BrowserWindowHost,
                   let slide = host.spaceSlide {
                    store.spaceGesture.drag = slide.offset
                    // A clicked reversal returns the live native surface with its spring;
                    // tearing it down would discard both presented position and wash.
                    if !slide.isActive || !slide.isSource(store) { host.cancelSpaceSlide() }
                }
                if let origin = store.spaceGesture.outgoing?.space {
                    Motion.spaceHandoff { store.switchTo(space: origin) }
                    rebuild()
                }
                settle(store)
                return
            }
            if landing, space.id == store.spaceGesture.neighbour?.id { return }
            if landing || returning, let host, let slide = host.spaceSlide, slide.isActive, slide.isSource(store) {
                // Already exposed incoming rows must not swap underneath a moving strip.
                // Finish that leg, then honor the latest click from its live destination.
                host.queueSpaceSelection(space, after: slide)
                return
            }
            let continuing = landing && pendingSelection == nil
            let previousDirection = store.spaceGesture.previewDirection
            // Keep the presentation offset while replacing the requested destination.
            guard let direction = store.beginSpaceSelection(space),
                  let target = store.spaceGesture.neighbour else { return }
            // The endpoint is already assigned while its presentation is travelling.
            // Reassigning that endpoint creates a zero-length animation whose completion
            // would tear down the moving strip. Its existing completion retires the latest
            // preview; an actual reversal still retargets the offset animation.
            if continuing, direction == previousDirection,
               (store.window?.contentView as? BrowserWindowHost)?.spaceSlide == nil {
                return
            }
            pendingSelection = nil
            land(direction, to: target, width: SidebarWidth.shared.width, store: store,
                 animation: Look.spaceSlide, duration: Look.spaceSlideDuration)
            return
        }
        guard let direction = store.beginSpaceSelection(space),
              let target = store.spaceGesture.neighbour else {
            // Deleting the last Space can leave no outgoing sidebar to animate. The
            // remaining profiles' footer buttons must still take the window into a Space.
            store.cancelCreatingSpace()
            store.switchTo(space: space)
            rebuild()
            return
        }
        // The native track mounts both surfaces before starting its animation clock.
        // It does not need the SwiftUI ghost's extra preparation below.
        let anchor = target.profileID == store.profileID
            ? store.spaceGesture.sectionsView : store.spaceGesture.stripView
        if store.window?.contentView is BrowserWindowHost, anchor != nil {
            land(direction, to: target, width: SidebarWidth.shared.width, store: store,
                 animation: Look.spaceSlide, duration: Look.spaceSlideDuration)
            return
        }
        // Mount the preview offscreen before animating it into place. In the same update
        // as its insertion, SwiftUI would draw it at the final offset and skip the travel.
        let from = store.currentSpaceID
        // Own the landing from preparation onward. Sidebar removal and resign-key
        // notifications use this same monitor and must not release it for a second switch.
        landing = true
        landingFrom = from
        returning = false
        let selectionID = UUID()
        transition = selectionID
        pendingSelection = selectionID
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak store] in
            guard self.pendingSelection == selectionID else { return }
            self.pendingSelection = nil
            guard let store else { self.landing = false; return }
            guard store.spaceSwiping, store.currentSpaceID == from,
                  store.spaceGesture.neighbour?.id == target.id else {
                self.landing = false
                store.spaceDrag = 0
                store.spaceSwiping = false
                return
            }
            self.land(direction, to: target, width: SidebarWidth.shared.width, store: store,
                      animation: Look.spaceSlide, duration: Look.spaceSlideDuration)
        }
    }

    /// Commit the page separately from the sidebar presentation. Profile hops replace
    /// the native host, so they finish this store's gesture before handing over.
    @discardableResult private func activate(_ target: Space, in store: TabStore) -> Bool {
        if target.profileID != store.profileID {
            transition = UUID()
            pendingSelection = nil
            returning = false
            // Keep the departing presentation intact until its host is covered. Its
            // onDisappear monitor must not abort this committed handoff mid-mount.
            landing = true
            let window = store.window
            Motion.spaceHandoff { store.switchTo(space: target) }
            landing = false
            landingFrom = nil
            Motion.spaceHandoff {
                store.spaceDrag = 0
                store.spaceSwiping = false
            }
            if let window, let arriving = TabStore.all.first(where: { $0.window === window }) {
                (window.contentView as? BrowserWindowHost)?.spaceSlide?.attach(arriving)
            }
            rebuild()
            return false
        }
        if store.spaceGesture.outgoing == nil, let origin = store.swipeSpace {
            store.spaceGesture.outgoing = store.swipePreview(in: origin)
        }
        // The native surface covers selection while it travels. Keep the live content
        // replacement immediate rather than starting another animation underneath it.
        Motion.spaceHandoff { store.switchTo(space: target) }
        guard store.currentSpaceID == target.id else {
            transition = UUID()
            pendingSelection = nil
            landing = false
            landingFrom = nil
            returning = false
            store.spaceDrag = 0
            store.spaceSwiping = false
            return false
        }
        landingFrom = store.currentSpaceID
        rebuild()
        return true
    }

    func install(_ store: TabStore) {
        guard monitor == nil else { return }
        if let previous = self.store, previous !== store { remove() }
        self.store = store
        if preparationObservers.isEmpty { observePreparation(in: store) }
        installInput(in: store)
        schedulePreparation(in: store)
    }

    private func observePreparation(in store: TabStore) {
        // Search owns the input/animation thread until its dismissal fade ends.
        // Read the publisher's new value: @Published sends before the store changes.
        preparationObservers.append(store.$palette.removeDuplicates().dropFirst().sink { [weak self, weak store] mode in
            guard let self else { return }
            self.preparation?.cancel()
            self.preparation = nil
            guard mode == nil else { return }
            let delay = Motion.reduced ? 0 : Look.appearDuration
            self.preparationNotBefore = max(self.preparationNotBefore,
                ProcessInfo.processInfo.systemUptime + delay)
            DispatchQueue.main.async { [weak self, weak store] in
                guard let self, let store else { return }
                self.schedulePreparation(in: store)
            }
        })
        // Form and Library transitions can begin without a scroll event. Preserve
        // valid captures, but do not build their replacements underneath this UI.
        preparationObservers.append(Publishers.MergeMany([
            store.$creatingSpace.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$libraryOpen.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.libraryGesture.objectWillChange.eraseToAnyPublisher()
        ]).sink { [weak self, weak store] _ in
            self?.extendPreparationQuietInterval()
            DispatchQueue.main.async { [weak self, weak store] in
                guard let self, let store else { return }
                self.schedulePreparation(in: store)
            }
        })
        // Store collections and neighbouring Space metadata can change without updating
        // the geometry anchor. Read their completed state on the next main-loop turn.
        for (publisher, invalidates) in [
            (store.sidebarSnapshotChanges, true),
            (store.spaceGesture.objectWillChange.eraseToAnyPublisher(), false),
            (ProfileManager.shared.objectWillChange.eraseToAnyPublisher(), true)
        ] {
            preparationObservers.append(publisher.sink { [weak self, weak store] _ in
                if invalidates {
                    self?.extendPreparationQuietInterval()
                    self?.invalidatePreparation()
                }
                DispatchQueue.main.async { [weak self, weak store] in
                    guard let self, let store else { return }
                    self.schedulePreparation(in: store)
                }
            })
        }
    }

    private func installInput(in store: TabStore) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown,
            .leftMouseUp, .leftMouseDragged, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self, weak store] event in
            guard let self, let store else { return event }
            // This runs before actions and Library routing. Extend the deadline on
            // every input packet without discarding valid first-swipe surfaces.
            if event.window === store.window {
                self.postponePreparation(in: store, by: Self.preparationQuietInterval,
                                         preservingSurfaces: true)
            }
            guard event.type == .scrollWheel else { return event }
            // Edge rubber-banding uses SwiftUI's return spring, not a native slide.
            // Inspect scroll-only APIs and neighboring metadata only for this sidebar.
            let batchesPresentation = event.hasPreciseScrollingDeltas
                && self.isOverSidebar(event, store) && self.hasNativePresentation(store)
                && ((store.window?.contentView as? BrowserWindowHost)?.spaceSlide?.isActive == true
                    || store.swipeNeighbour(for: event.scrollingDeltaX) != nil)
            if batchesPresentation { store.spaceGesture.beginPresentationUpdate() }
            defer { if batchesPresentation { store.spaceGesture.endPresentationUpdate() } }
            if event.hasPreciseScrollingDeltas, let window = event.window, window === store.window {
                if event.phase.contains(.began) {
                    Self.committedSwipes.remove(window)
                } else if Self.committedSwipes.contains(window) {
                    self.forget()
                    return nil
                }
            }
            // Library sits before the first Space. Give its shared navigation handler
            // priority even when AppKit invokes the sidebar's monitor first.
            guard store.librarySwipeMonitor.handle(event, in: store) != nil else { return nil }
            guard self.mine(event, store) else {
                // Keep vertical input with NSScrollView. Its momentum tail and ordinary
                // mouse wheels also postpone hidden layout; horizontal claims retain
                // their prepared surfaces for the very first directional sample.
                if event.scrollingDeltaY != 0,
                   (self.claim == .theirs || !event.hasPreciseScrollingDeltas),
                   self.isOverSidebar(event, store) {
                    self.postponePreparation(in: store, by: 0.18, preservingSurfaces: true)
                }
                return event
            }
            let phase = Self.phase(of: event)
            let width = SidebarWidth.shared.width
            let dt = self.last > 0 ? event.timestamp - self.last : 0
            self.last = event.timestamp
            // The Create a Space form is one slot past the last Space: a swipe back from it
            // is Cancel, the same as ⎋, and a swipe further on is the band. Its offset is
            // never applied — the form does not slide, it goes.
            let creating = store.creatingSpace
            let index = creating ? self.list.count
                : (self.list.firstIndex { $0.id == store.currentSpaceID } ?? 0)
            let count = creating ? self.list.count + 1 : self.list.count
            let creatable = !store.isPrivate && !store.isLittle && !creating
            let out = self.swipe.feed(dx: event.scrollingDeltaX, dt: dt, phase: phase,
                                      width: width, count: count, index: index,
                                      create: creatable)
            if creating {
                if let direction = out.commit, direction < 0 { store.cancelCreatingSpace() }
                if phase == .ended || phase == .cancelled || event.momentumPhase.contains(.ended) { self.forget() }
                return nil
            }
            if let offset = out.offset {
                self.track(offset, width: width, in: store)
            }
            store.spacePull = out.pull
            if let direction = out.commit {
                if let window = store.window {
                    Self.committedSwipes.add(window)
                }
                if creatable, direction > 0, index == self.list.count - 1 {
                    self.create(store)
                } else {
                    if self.list.indices.contains(index + direction) {
                        self.land(direction, to: self.list[index + direction], width: width, store: store)
                    } else {
                        self.settle(store)
                    }
                }
            } else if phase == .ended || phase == .cancelled, !self.landing {
                // Not while landing: a `.cancelled` followed by an `.ended` would otherwise
                // spring the strip home over the top of the spring taking it the other way.
                self.settle(store)
            }
            // The verdict is what carries the fingers-up event, which has no deltas of its
            // own to be judged on; past the end of the gesture it must not carry the next
            // one. The momentum tail re-decides itself, on deltas that are still going the
            // way the fingers were.
            if phase == .ended || phase == .cancelled || event.momentumPhase.contains(.ended) { self.forget() }
            return nil              // swallowed, so the tab list does not scroll sideways too
        }
        // The fingers can be taken away without an `.ended`: ⌘S hides the sidebar mid-swipe
        // and `mine`'s own guard then drops the rest of the gesture, the window can lose key,
        // the app can deactivate. Each of those leaves the strip parked sideways with
        // `spaceSwiping` stuck true, and nothing short of another swipe would put it back.
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            watchers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] notification in
                    let notifyingWindow = notification.object as? NSWindow
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if name == NSWindow.didResignKeyNotification {
                            guard let window = notifyingWindow,
                                  window === self.store?.window else { return }
                        }
                        self.abort()
                    }
                })
        }
    }

    /// Hiding chrome ends its input lifetime, but not the content of its idle captures.
    /// Structural and protection observers remain live while the sidebar is hidden.
    func suspend() {
        preparation?.cancel()
        preparation = nil
        removeInput()
        if let store, !store.sidebarShown, !store.sidebarPeeking {
            (store.window?.contentView as? BrowserWindowHost)?.spaceSlide?.sidebarDidDisappear(store)
        }
        abort()
    }

    private func removeInput() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        watchers.forEach(NotificationCenter.default.removeObserver)
        watchers = []
    }

    func remove() {
        preparationObservers.removeAll()
        preparationPeers.removeAll()
        preparationProfiles.removeAll()
        preparation?.cancel()
        preparation = nil
        preparationNotBefore = 0
        discardPreparation()
        discardStalePreparation()
        suspend()
        store = nil
    }

    /// Everything a finished gesture forgets, without touching the strip: the next gesture
    /// starts from scratch whether this one committed, sprang back or was interrupted.
    private func forget() {
        swipe = Spaces.Swipe()
        claim = .undecided
        travelled = (0, 0)
        last = 0
        list = []
    }

    /// A new owner revokes both the compositor completion and any queued page activation.
    func interruptLanding() {
        transition = UUID()
        pendingSelection = nil
        landing = false
        landingFrom = nil
        returning = false
    }

    /// The gesture is gone rather than finished: put the strip back where an idle sidebar
    /// has it. A cut, not a spring — the fingers have already left, and there is nothing
    /// left for a spring to be the tail of.
    func abort() {
        forget()
        (store?.window?.contentView as? BrowserWindowHost)?.clearQueuedSpaceSelection()
        // Several teardown notifications can arrive for the same window. A committed
        // landing keeps ownership until its completion, even after the monitor is removed.
        guard let store, !landing, store.spaceDrag != 0 || store.spaceSwiping else { return }
        (store.window?.contentView as? BrowserWindowHost)?.cancelSpaceSlide()
        store.spaceDrag = 0
        store.spacePull = 0
        store.spaceSwiping = false
    }

    private static func phase(of event: NSEvent) -> Spaces.Swipe.Phase {
        if !event.momentumPhase.isEmpty { return .momentum }
        if event.phase.contains(.began) { return .began }
        if event.phase.contains(.cancelled) { return .cancelled }
        if event.phase.contains(.ended) { return .ended }
        return .changed
    }

    /// Mount once when the gesture acquires a neighbour, then follow scroll deltas without
    /// asking SwiftUI to render a translated list for every event.
    func track(_ offset: CGFloat, width: CGFloat, in store: TabStore) {
        if hasNativePresentation(store), store.swipeNeighbour(for: offset) != nil
            || offset == 0 && (store.window?.contentView as? BrowserWindowHost)?.spaceSlide?.isActive == true {
            store.spaceGesture.withPresentationUpdate { trackImmediately(offset, width: width, in: store) }
        } else { trackImmediately(offset, width: width, in: store) }
    }

    private func trackImmediately(_ offset: CGFloat, width: CGFloat, in store: TabStore) {
        guard width > 0 else { return }
        store.spaceSwiping = true
        if offset == 0, let slide = (store.window?.contentView as? BrowserWindowHost)?.spaceSlide,
           slide.isActive, slide.isSource(store) {
            store.spaceGesture.nativeDrag = 0
            slide.track(drag: 0)
            store.spaceGesture.trackGround?(0)
            return
        }
        let target = store.swipeNeighbour(for: offset)
        let direction = offset < 0 ? 1 : -1
        if let target, !Motion.spaceReduced,
           let slide = (store.window?.contentView as? BrowserWindowHost)?.spaceSlide,
           slide.follows(target, direction: direction) {
            store.spaceGesture.nativeDrag = offset
            slide.track(drag: offset)
            store.spaceGesture.trackGround?(Double(min(1, abs(offset / width))))
            return
        }
        store.spaceGesture.nativeDrag = nil
        if target == nil { (store.window?.contentView as? BrowserWindowHost)?.cancelSpaceSlide() }
        store.spaceDrag = offset
        guard target != nil, !Motion.spaceReduced,
              let host = store.window?.contentView as? BrowserWindowHost,
              let target = store.spaceGesture.neighbour,
              let origin = store.spaceGesture.outgoing?.space else { return }
        let includesFavorites = target.profileID != store.profileID
        guard let anchor = includesFavorites ? store.spaceGesture.stripView : store.spaceGesture.sectionsView else { return }
        let frame = anchor.convert(anchor.bounds, to: host)
        if let slide = takePreparedSlide(origin: origin, target: target, direction: direction,
                                         frame: frame, width: width, in: store) {
            host.beginSpaceSlide(slide)
            slide.isHidden = false
            slide.track(drag: offset)
            store.spaceGesture.nativeDrag = offset
            return
        }
        let slide = ProfileSpaceSlide(frame: frame,
            outgoing: store.swipePreview(in: origin, includingFavorites: includesFavorites),
            incoming: store.swipePreview(in: target), drag: offset, direction: direction,
            source: store, includesFavorites: includesFavorites, travelWidth: width)
        host.beginSpaceSlide(slide)
        slide.prepare()
        slide.track(drag: offset)
        store.spaceGesture.nativeDrag = offset
    }

    /// Continue the captured sidebar to rest while selecting the committed page underneath.
    func land(_ direction: Int, to target: Space, width: CGFloat, store: TabStore,
              animation: Animation = Look.spaceLanding, duration: TimeInterval = Look.spaceLandingDuration) {
        if hasNativePresentation(store) {
            store.spaceGesture.withPresentationUpdate {
                landImmediately(direction, to: target, width: width, store: store, animation: animation, duration: duration)
            }
        } else {
            landImmediately(direction, to: target, width: width, store: store, animation: animation, duration: duration)
        }
    }

    private func landImmediately(_ direction: Int, to target: Space, width: CGFloat, store: TabStore,
                                 animation: Animation, duration: TimeInterval) {
        let token = UUID()
        transition = token
        pendingSelection = nil
        returning = false
        // Reduced motion changes both content and sidebar immediately.
        guard !Motion.spaceReduced else {
            landing = false
            landingFrom = nil
            store.spaceDrag = 0
            store.spaceSwiping = false
            store.switchTo(space: store.spaceGesture.neighbour ?? target)
            rebuild()
            return
        }
        landing = true
        landingFrom = store.currentSpaceID
        let destination = store.spaceGesture.neighbour ?? target
        store.spaceGesture.colourDuration = duration
        let includesFavorites = destination.profileID != store.profileID
        let finish: () -> Void = { [weak self, weak store] in
            guard let self, self.transition == token, let store else { return }
            if store.window != nil, store.currentSpaceID == self.landingFrom,
               let target = store.spaceGesture.neighbour, target.id != store.currentSpaceID {
                _ = self.activate(target, in: store)
            }
            self.landing = false
            self.landingFrom = nil
            Motion.spaceHandoff {
                store.spaceDrag = 0
                store.spaceSwiping = false
            }
        }
        if let host = store.window?.contentView as? BrowserWindowHost,
           let anchor = (includesFavorites ? store.spaceGesture.stripView : store.spaceGesture.sectionsView),
           let origin = store.spaceGesture.outgoing?.space ?? store.swipeSpace {
            let frame = anchor.convert(anchor.bounds, to: host)
            let presentationOffset = store.spaceGesture.outgoingView?.layer?.presentation().map {
                $0.convert(.zero, to: host.layer?.presentation()).x - frame.minX
            }
            let active = host.spaceSlide.flatMap { $0.isActive ? $0 : nil }
            let drag = active?.offset ?? presentationOffset ?? store.spaceDrag
            let slide: ProfileSpaceSlide
            if let tracking = active, tracking.follows(destination, direction: direction) {
                slide = tracking
            } else if drag == 0,
                      let prepared = takePreparedSlide(origin: origin, target: destination, direction: direction,
                                                       frame: frame, width: width, in: store) {
                slide = prepared
                host.beginSpaceSlide(slide, preservingGround: true)
                slide.isHidden = false
                // Idle captures already stand at zero. Keep in-flight retargets on
                // their existing path and do not manufacture finger velocity for clicks.
            } else {
                slide = ProfileSpaceSlide(frame: frame,
                    outgoing: store.swipePreview(in: origin, includingFavorites: includesFavorites),
                    incoming: store.swipePreview(in: destination), drag: drag,
                    direction: direction, source: store, includesFavorites: includesFavorites,
                    travelWidth: width)
                host.beginSpaceSlide(slide, preservingGround: true)
            }
            // Keep native presentation as the footer/tint source across release. Updating
            // the hidden SwiftUI endpoint must not reset it to the first finger sample.
            Motion.spaceHandoff { store.spaceGesture.drag = -CGFloat(direction) * width }
            slide.start(duration: duration, completion: finish)
            // Submit compositor travel first, then restore the page under its covering
            // sidebar. Selection must not wait for the animation's endpoint.
            DispatchQueue.main.async { [weak self, weak store] in
                guard let self, self.transition == token, let store,
                      store.currentSpaceID == self.landingFrom,
                      store.spaceGesture.neighbour?.id == destination.id else { return }
                _ = self.activate(destination, in: store)
            }
        } else {
            if let host = store.window?.contentView as? BrowserWindowHost,
               let slide = host.spaceSlide, slide.isSource(store) {
                store.spaceGesture.drag = slide.offset
                host.cancelSpaceSlide()
            }
            // Keep the SwiftUI track when no native sidebar surface is mounted.
            Motion.space(animation) { store.spaceGesture.drag = -CGFloat(direction) * width }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                if let window = store.window { _ = SpaceLandingFrame(window: window, completion: finish) }
                else { finish() }
            }
        }
    }

    /// The plus is full: the form takes the sidebar, and the strip, which only banded,
    /// goes home underneath it. Nothing is made yet — Create Space is a button.
    private func create(_ store: TabStore) {
        store.beginCreatingSpace()
        settle(store)
    }

    /// Not far enough, or nowhere to go: the strip goes home.
    private func settle(_ store: TabStore) {
        // The model already has the zero endpoint while its presentation returns.
        // Keep that completion instead of creating a zero-length second animation.
        guard !returning else { return }
        let token = UUID()
        transition = token
        pendingSelection = nil
        landing = false
        landingFrom = nil
        Motion.space(Look.spaceSpring) { store.spacePull = 0 }
        // Even a zero target can be in flight (or waiting for its mount delay).
        guard !Motion.spaceReduced else {
            store.spaceDrag = 0
            store.spaceSwiping = false
            return
        }
        returning = true
        store.spaceGesture.colourDuration = 0.16
        if let slide = (store.window?.contentView as? BrowserWindowHost)?.spaceSlide,
           slide.isActive, slide.isSource(store) {
            Motion.spaceHandoff { store.spaceGesture.drag = 0 }
            slide.start(duration: 0.16, returning: true) { [weak self, weak store] in
                guard let self, self.transition == token else { return }
                self.returning = false
                store?.spaceSwiping = false
            }
            return
        }
        if store.spaceGesture.drag == 0, store.spaceGesture.nativeDrag == nil {
            // A claimed beginning can end before any travel. With no native surface
            // or SwiftUI displacement there is no animation completion to wait for.
            returning = false
            store.spaceSwiping = false
            return
        }
        store.spaceGesture.nativeDrag = nil
        Motion.space(Look.spaceReturn) { store.spaceGesture.drag = 0 } completion: { [weak store] in
            guard self.transition == token else { return }
            self.returning = false
            guard let store else { return }
            store.spaceSwiping = false
        }
    }

    /// A horizontal trackpad swipe, over this window's sidebar, decided once per gesture.
    /// Everything else — a mouse wheel, a scroll down the tab list, a scroll over the page,
    /// anything while the Library panel is over the sidebar — is left
    /// alone for whoever it was meant for.
    func mine(_ event: NSEvent, _ store: TabStore) -> Bool {
        // Above the guard on purpose: a gesture that starts over the page card still has to
        // clear the last one's verdict, or a swipe made over the sidebar goes on claiming
        // events long after the fingers have moved somewhere else.
        if event.phase.contains(.began) {
            forget()
        }
        let slide = (store.window?.contentView as? BrowserWindowHost)?.spaceSlide
        let ownsLanding = slide.map { $0.isActive && ($0.isSource(store) || $0.isDestination(store)) } ?? false
        guard !store.spaceSwiping || claim == .mine || ownsLanding,
              event.hasPreciseScrollingDeltas, let window = event.window, isOverSidebar(event, store)
        else { return false }
        switch claim {
        case .mine:   return true
        case .theirs: return false
        case .undecided: break
        }
        if store.spaceGesture.isOverScrollingFooter(event) {
            claim = .theirs
            return false
        }
        travelled.h += abs(event.scrollingDeltaX)
        travelled.v += abs(event.scrollingDeltaY)
        // A gesture that has gone this far down is a scroll, whatever it does next: a flick
        // down a long tab list wanders sideways as the fingers roll, and a monitor that
        // re-asks on every frame will eventually catch one of those wobbles and eat the rest
        // of the flick.
        if travelled.v >= Self.verticalVeto { claim = .theirs; return false }
        // Undecided until there is enough travel to have a direction at all — the opening
        // frames of any two-finger gesture are a pixel of noise in both axes.
        guard travelled.h + travelled.v >= Self.lockDistance else { return false }
        // 1.5, not 1: even a deliberate sideways swipe drifts down a little, and at parity
        // that drift is enough to lose the toss.
        claim = travelled.h > travelled.v * 1.5 ? .mine : .theirs
        guard claim == .mine else { return false }
        if ownsLanding { (window.contentView as? BrowserWindowHost)?.clearQueuedSpaceSelection() }
        var resumedOffset: CGFloat = 0
        if ownsLanding, let offset = slide?.resumeTracking(in: store, dx: event.scrollingDeltaX) {
            resumedOffset = offset
        } else if ownsLanding {
            // A distinct horizontal gesture can begin before the preceding landing
            // reaches rest. Retire that owned leg only after axis lock; unrelated page
            // and vertical scrolling must leave its presentation alone.
            slide?.finish()
            interruptLanding()
            Motion.spaceHandoff {
                store.spaceDrag = 0
                store.spaceSwiping = false
            }
            guard store.window === window else { return false }
        }
        // The first claimed event is the gesture's beginning as far as the state machine is
        // concerned: the `.began` that opened it carried no deltas and went to the tab list.
        swipe = Spaces.Swipe(startingAt: resumedOffset)
        last = 0
        list = store.strip
        return true
    }

    private func isOverSidebar(_ event: NSEvent, _ store: TabStore) -> Bool {
        guard let window = event.window, window === store.window, !store.libraryOpen,
              store.sidebarShown || (window as? VaneWindow)?.peekingSidebar == true else { return false }
        let inset = store.sidebarShown ? 0 : Look.floatingSidebarGap
        let bounds = window.contentView.map { $0.convert($0.bounds, to: nil) }
            ?? NSRect(origin: .zero, size: window.frame.size)
        return NSRect(x: bounds.minX + inset, y: bounds.minY + inset,
                      width: SidebarWidth.shared.width,
                      height: max(0, bounds.height - 2 * inset)).contains(event.locationInWindow)
    }

    /// Points of travel, in both axes together, before the gesture is given a direction.
    private static let lockDistance: CGFloat = 10
    /// …and points *down* after which it can never be a Space swipe, however far it then
    /// wanders sideways.
    private static let verticalVeto: CGFloat = 6
}

@MainActor final class SpaceLandingFrame: NSObject {
    private var link: CADisplayLink?
    private var completion: (() -> Void)?
    private var timeout: DispatchWorkItem?
    private var frames = 0

    init(window: NSWindow, completion: @escaping () -> Void) {
        self.completion = completion
        super.init()
        guard let screen = window.screen ?? NSScreen.main else {
            DispatchQueue.main.async { self.finish() }
            return
        }
        // A screen link keeps ticking if the window is hidden or detached meanwhile.
        let link = screen.displayLink(target: self, selector: #selector(frame(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
        let timeout = DispatchWorkItem { [weak self] in self?.finish() }
        self.timeout = timeout
        // A disconnected display must not leave a committed Space selection owned forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: timeout)
    }

    @objc private func frame(_ link: CADisplayLink) {
        // A callback runs before presentation. Cross one complete display interval so
        // neither a final sidebar offset nor its replacement can still be one frame old.
        frames += 1
        if frames >= 2 { finish() }
    }

    private func finish() {
        link?.invalidate()
        link = nil
        timeout?.cancel()
        timeout = nil
        let completion = completion
        self.completion = nil
        completion?()
    }
}

// MARK: - Pull to create

/// Arc's plus at the sidebar's edge: a ring that fills as the fingers pull past the last
/// Space, and a form the moment it is full. Overlaid on the sidebar's scroll view, trailing
/// and centred, so it sits where the pull is coming from.
struct PullPlus: View {
    @Environment(\.spaceChromeTheme) private var chromeTheme
    @ObservedObject private var gesture: SpaceGesture

    init(store: TabStore) { gesture = store.spaceGesture }

    var body: some View {
        let pull = gesture.pull
        let ring = min(1, pull)
        let solid = max(0, pull - 1)
        ZStack {
            Circle().fill(chromeTheme.barFill)
            // The second stage: the circle fills from the centre out, and only a full one
            // makes a Space. The plus turns dark against it so it stays a plus.
            Circle().fill(Look.inkPrimary).scaleEffect(solid)
            Circle().stroke(Look.inkTertiary, lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: ring)
                .stroke(Look.inkPrimary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                .foregroundStyle(solid > 0.5 ? chromeTheme.barFill : Look.inkPrimary)
        }
        .frame(width: Look.pullPlus, height: Look.pullPlus)
        // Rides in from the edge with the first stage, and is gone the moment it is over:
        // the ring is the progress, not a control.
        .offset(x: Look.pullPlus / 2 - ring * Look.pullPlus)
        .opacity(pull > 0 ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Arc's Create a Space: the sidebar's sections give way to a name, a profile, a theme and
/// two buttons. Nothing exists until Create Space is pressed; Cancel puts the sections back.
struct CreateSpaceForm: View {
    @Environment(\.spaceChromeTheme) private var chromeTheme
    @ObservedObject var store: TabStore
    @ObservedObject private var profiles = ProfileManager.shared
    @State private var name = ""
    @State private var profile: Profile?
    @State private var colorHex: String?
    @State private var theming = false
    @FocusState private var naming: Bool

    private var chosenProfile: Profile {
        profile ?? profiles.profiles.first { $0.id == store.profileID } ?? profiles.active
    }

    var body: some View {
        VStack(spacing: Look.inset) {
            Spacer(minLength: Look.rowHeight)
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Look.inkSecondary)
                .padding(.bottom, Look.inset)
            Text("Create a Space").font(Look.dialogTitle)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(Look.inkPrimary)
            Text("Separate your tabs for life, work, projects, and more.")
                .font(Look.text).foregroundStyle(Look.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Look.inset * 2)
            field {
                Image(systemName: "plus.square.dashed").frame(width: Look.tileIcon)
                TextField("Space name…", text: $name)
                    .textFieldStyle(.plain)
                    .focused($naming)
                    .onSubmit(create)
            }
            field {
                Image(systemName: "person.crop.square").frame(width: Look.tileIcon)
                Text("Profile")
                Spacer(minLength: 0)
                Menu {
                    ForEach(profiles.profiles) { p in
                        Button(p.name) { profile = p }
                    }
                } label: {
                    Text(chosenProfile.name).lineLimit(1)
                }
                .menuStyle(.borderlessButton).tint(Look.inkSecondary)
            }
            field {
                Image(systemName: "paintbrush").frame(width: Look.tileIcon)
                Button(colorHex == nil ? "Choose a Theme" : "Theme") { theming.toggle() }
                    .buttonStyle(.plain)
                Spacer(minLength: 0)
                if let colorHex, let color = Color(hex: colorHex) {
                    Circle().fill(color).frame(width: 14, height: 14)
                }
            }
            if theming {
                // The first page of the theme editor's own swatches: one tap, one colour.
                // The full editor, with its gradients and grain, is a right-click away once
                // the Space exists.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Look.swatch * 0.6),
                                           spacing: Look.inset / 2)], spacing: Look.inset / 2) {
                    ForEach(Look.themeSwatches.prefix(Look.swatchPage), id: \.self) { hex in
                        Button { colorHex = hex; theming = false } label: {
                            Circle().fill(Color(hex: hex) ?? .clear)
                                .frame(width: Look.swatch * 0.6, height: Look.swatch * 0.6)
                                .overlay(Circle().stroke(Look.inkPrimary,
                                                         lineWidth: colorHex == hex ? 2 : 0))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Theme colour \(hex)")
                    }
                }
                .padding(.vertical, Look.inset / 2)
            }
            Spacer(minLength: 0)
            Button(action: create) {
                Text("Create Space").font(Look.rowTitle).frame(maxWidth: .infinity)
                    .frame(height: Look.rowHeight)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(cleaned == nil)
            Button {
                store.showWorkspaceTemplates(for: chosenProfile.id, creatingSpace: true, creationName: cleaned)
            } label: {
                Label("Use Template", systemImage: "rectangle.stack")
                    .font(Look.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: Look.rowHeight)
                    .contentShape(.rect)
            }
            .buttonStyle(TactileButtonStyle())
            .foregroundStyle(Look.inkSecondary)
            Button("Cancel") { store.cancelCreatingSpace() }
                .buttonStyle(.plain)
                .foregroundStyle(Look.inkSecondary)
                .keyboardShortcut(.cancelAction)
                .padding(.bottom, Look.inset)
        }
        .padding(.horizontal, Look.inset)
        .onAppear { naming = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Create a Space")
    }

    private var cleaned: String? { TabActions.cleanName(name) }

    private func create() {
        guard let cleaned else { return }
        store.createSpace(named: cleaned, in: chosenProfile, colorHex: colorHex)
    }

    @ViewBuilder private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Look.rowSpacing) { content() }
            .font(Look.rowTitle)
            .foregroundStyle(Look.inkPrimary)
            .padding(.horizontal, Look.rowInset)
            .frame(height: Look.rowHeight)
            .background(chromeTheme.selected, in: .rect(cornerRadius: Look.pillRadius))
    }
}
