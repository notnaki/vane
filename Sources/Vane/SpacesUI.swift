import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Spaces chrome: the header row's two clicks, the footer's dots and its `+`, the inline
/// editor Arc's `+` opens, "Move to Space" and the two-finger swipe.
///
/// In its own file so the sidebar's look and the sidebar's Spaces can be worked on at once.
/// The tokens are `Look`'s, extended rather than edited.

extension Look {
    /// The strip sliding sideways as the Space changes. A touch longer than `appear`: it is
    /// the whole column moving, and at 0.15 it read as a flicker rather than as travel.
    static let spaceSlide = Animation.easeOut(duration: 0.24)
    /// The strip finishing a swipe: the rest of the travel after the fingers leave, and the
    /// spring back when they did not go far enough. A spring rather than an ease because the
    /// gesture handed it a velocity and an ease throws that away — the strip has to leave the
    /// fingers at the speed they left it at.
    static let spaceSpring = Animation.spring(response: 0.35, dampingFraction: 0.85)
    /// The dot's hit target — `Look.dot` is 6pt, which is not a thing anyone can hit or
    /// drop a tab onto.
    static let spaceDotHit: CGFloat = 20
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
                .font(Look.text)
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
            Text(space?.name ?? fallback).font(Look.text)
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

/// Left-clicking the Space's name: every Space in the profile, with its icon, the current one
/// ticked — Arc's Space list. An `NSMenu` rather than a SwiftUI `Menu` because the same row
/// also has to take a double-click to rename, and a SwiftUI menu swallows both clicks.
@MainActor func showSpaceList(_ store: TabStore) {
    let menu = NSMenu()
    var keep: [MenuAction] = []
    for (n, space) in store.spaces.enumerated() {
        let item = NSMenuItem(title: space.name, action: #selector(MenuAction.fire), keyEquivalent: "")
        let action = MenuAction { store.switchTo(space: space); rebuild() }
        item.target = action
        item.representedObject = action
        keep.append(action)
        item.state = store.currentSpaceID == space.id ? .on : .off
        item.image = NSImage(systemSymbolName: space.icon ?? "cloud", accessibilityDescription: nil)
        // ⌃1…⌃9 is what these are actually bound to, so the menu says so rather than
        // inventing a second set of numbers.
        if n < 9 {
            item.keyEquivalent = "\(n + 1)"
            item.keyEquivalentModifierMask = .control
        }
        menu.addItem(item)
    }
    // Always a separator: the list above it is never empty. A profile always has at least
    // one Space, and this menu only ever hangs off a window that is showing one.
    menu.addItem(.separator())
    let new = NSMenuItem(title: "New Space", action: #selector(MenuAction.fire), keyEquivalent: "")
    let make = MenuAction { store.newSpace(); rebuild() }
    new.target = make
    new.representedObject = make
    keep.append(make)
    menu.addItem(new)
    // `keep` only exists so the actions outlive this function; `representedObject` is what
    // actually holds them, and an unused-variable warning is not worth a stored property.
    _ = keep
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
}

/// A closure with an `@objc` face, so an `NSMenuItem` can call it. Retained by the item's
/// `representedObject`.
@MainActor final class MenuAction: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

// MARK: - Creating a Space

/// The footer's `+`. Arc does not ask for a name first: the Space appears, and its name,
/// icon and colour are edited in place in a small panel hanging off the button. This is that
/// button and that panel.
struct NewSpaceButton: View {
    @EnvironmentObject var store: TabStore

    var body: some View {
        // Arc’s footer `+` is a menu, not a button. ponytail: two items, not four — Easels
        // and Notes are whole features, and a menu entry that opens an apology is worse than
        // no entry. They belong here on the day they exist.
        Menu {
            Button("New Space") { store.newSpace() }
            Button("New Folder") { store.newFolder() }
        } label: {
            Image(systemName: "plus")
        }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .buttonStyle(.plain)
            .foregroundStyle(Look.inkSecondary)
            .help("New Space or Folder")
            .accessibilityLabel("New Space or Folder")
            .popover(isPresented: Binding(get: { store.editingSpace != nil },
                                          set: { if !$0 { store.editingSpace = nil } }),
                     arrowEdge: .top) {
                if let id = store.editingSpace, let space = store.spaces.first(where: { $0.id == id }) {
                    SpaceEditor(store: store, space: space)
                }
            }
    }
}

/// Name, icon and colour in one panel — the three things Arc's New Space sheet asks for,
/// applied as they are picked rather than on an OK button. The Space already exists by the
/// time this is on screen, so there is nothing to cancel and no half-made Space to leave
/// behind; closing the panel is the whole of "done".
struct SpaceEditor: View {
    let store: TabStore
    let space: Space
    @State private var name = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset * 1.5) {
            HStack(spacing: 10) {
                Image(systemName: space.icon ?? "cloud")
                    .font(Look.icon)
                    .frame(width: Look.rowHeight, height: Look.rowHeight)
                    .background(Look.pillFill, in: .rect(cornerRadius: Look.pillRadius))
                    .accessibilityHidden(true)
                TextField("Space name", text: $name)
                    .textFieldStyle(.plain)
                    .font(Look.text)
                    .focused($focused)
                    .onSubmit { commit(); dismiss() }
                    .accessibilityLabel("Space name")
            }
            .padding(.horizontal, 8)
            .frame(height: Look.tileHeight)
            .background(Look.pillFill, in: .rect(cornerRadius: Look.pillRadius))

            icons
            swatches

            HStack {
                Spacer(minLength: 0)
                Button("Done") { commit(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Look.inset * 2)
        .frame(width: Look.themeWidth)
        .fixedSize()
        .onAppear { name = space.name; focused = true }
        // The name is committed on the way out too: a panel dismissed by clicking the page
        // must not throw away what was typed into it.
        .onDisappear { commit() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New Space")
    }

    private var icons: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(Look.rowHeight), spacing: 6), count: 6),
                  spacing: 6) {
            ForEach(Spaces.icons, id: \.self) { symbol in
                Button { edit { $0.icon = symbol } } label: {
                    Image(systemName: symbol)
                        .font(Look.icon)
                        .frame(width: Look.rowHeight, height: Look.rowHeight)
                        .background((space.icon ?? "cloud") == symbol ? Look.selected : .clear,
                                    in: .rect(cornerRadius: Look.pillRadius))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(symbol)
                .accessibilityAddTraits((space.icon ?? "cloud") == symbol ? [.isButton, .isSelected] : .isButton)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Space icon")
    }

    private var swatches: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(Look.swatch), spacing: Look.inset), count: 7),
                  spacing: Look.inset) {
            ForEach(Look.themeSwatches, id: \.self) { hex in
                Circle()
                    .fill(Color(hex: hex) ?? .gray)
                    .frame(width: Look.swatch, height: Look.swatch)
                    .overlay {
                        Circle().strokeBorder(.primary, lineWidth: 2)
                            .padding(-4)
                            .opacity(space.colorHex == hex ? 1 : 0)
                    }
                    .contentShape(.circle)
                    .onTapGesture { edit { $0.colorHex = hex; $0.tint = $0.tint ?? 0.35 } }
                    .accessibilityLabel("Theme colour \(hex)")
                    .accessibilityAddTraits(space.colorHex == hex ? [.isButton, .isSelected] : .isButton)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Theme colour")
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != space.name else { return }
        edit { $0.name = trimmed }
        rebuild()
    }

    private func edit(_ change: (inout Space) -> Void) {
        guard var copy = store.spaces.first(where: { $0.id == space.id }) else { return }
        change(&copy)
        store.update(space: copy)
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
        if Dragging.shared.tab != nil { return true }
        return SpaceDragging.shared.id.map { $0 != space.id } ?? false
    }
    func dropEntered(info: DropInfo) { over = true }
    func dropExited(info: DropInfo) { over = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        over = false
        if let tab = Dragging.shared.tab {
            Dragging.shared.tab = nil
            Spaces.move(tab, to: space.id, as: .today, from: store)
            axAnnounce("Moved to \(space.name).")
            return true
        }
        guard let dragged = SpaceDragging.shared.id else { return false }
        SpaceDragging.shared.id = nil
        let list = store.spaces
        guard let from = list.firstIndex(where: { $0.id == dragged }),
              let to = list.firstIndex(where: { $0.id == space.id }) else { return false }
        // A dot dropped on a dot means "put it where that one is", so a rightward drag has to
        // land *after* the target — which is what `reordered` reads `to` as.
        store.reorderSpaces(from: from, to: to > from ? to + 1 : to)
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
                        Button("Pinned") { Spaces.move(tab.id, to: space.id, as: .pinned, from: store) }
                        Button("Today") { Spaces.move(tab.id, to: space.id, as: .today, from: store) }
                    }
                }
            }
            .disabled(tab.currentURL?.scheme?.hasPrefix("http") != true)
        }
    }
}

// MARK: - Switching: the slide and the swipe

extension View {
    /// The sidebar's Space-owned sections sliding in from the direction of travel while the
    /// tint cross-fades under them. Favourites are outside it on purpose: they are the same
    /// tiles in every Space, and Arc's grid does not move when you switch.
    func spaceSlide(_ store: TabStore) -> some View { modifier(SpaceSlide(store: store)) }

    /// Two-finger horizontal swipe on the sidebar switches Space.
    func spaceSwipe(_ store: TabStore) -> some View { modifier(SpaceSwipe(store: store)) }
}

private struct SpaceSlide: ViewModifier {
    @ObservedObject var store: TabStore
    @ObservedObject private var sidebar = SidebarWidth.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let forwards = store.spaceDirection > 0
        content
            // The identity is the Space, so a switch is a removal and an insertion rather
            // than a list quietly changing under the pointer — which is the only way SwiftUI
            // will run a transition on it at all.
            .id(store.currentSpaceID)
            .transition(.asymmetric(
                insertion: .move(edge: forwards ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: forwards ? .leading : .trailing).combined(with: .opacity)))
            // A swipe has already carried the sections to where the new Space's preview was
            // standing; letting this run on top would slide the same content a second time.
            .animation(reduceMotion || store.spaceSwiping ? nil : Look.spaceSlide,
                       value: store.currentSpaceID)
            .offset(x: store.spaceDrag)
            // An overlay, not a second row in a stack: the preview must not be allowed to
            // make the scroll view's content taller or wider than the Space's own sections.
            // The scroll view clips it, which is what turns it into a strip coming in from
            // off the sidebar's edge.
            .overlay(alignment: .topLeading) { preview }
    }

    /// The Space the fingers are pulling in, drawn one sidebar width from the current one so
    /// the two move as a single strip. Nothing at either end of the list: the rubber band's
    /// whole point is that there is nothing over there to show.
    @ViewBuilder private var preview: some View {
        let drag = store.spaceDrag
        if drag != 0, let space = neighbour(of: drag) {
            SpacePreviewList(space: space)
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(x: drag + (drag < 0 ? sidebar.width : -sidebar.width))
                .allowsHitTesting(false)
                // Decorative: it is the Space the user is *about* to be in, and VoiceOver
                // announcing a list that may spring straight back is noise.
                .accessibilityHidden(true)
        }
    }

    private func neighbour(of drag: CGFloat) -> Space? {
        let list = store.spaces
        guard let i = list.firstIndex(where: { $0.id == store.currentSpaceID }) else { return nil }
        let n = drag < 0 ? i + 1 : i - 1
        return list.indices.contains(n) ? list[n] : nil
    }
}

/// The neighbouring Space's sidebar, as a ghost, for the width of a swipe: its name, its
/// pinned rows, its tabs.
///
/// ponytail: rows built from the urls in `spaces.json`, not from tabs. A Space that is not on
/// screen has no `Tab` objects and no web views, and making them so the user can glance at
/// them mid-swipe would mean loading another Space's pages in order to slide past them.
/// Ceiling: a site never visited has no cached favicon, and the label is the host rather than
/// the page's own title — a history lookup keyed on the url would fix the second.
private struct SpacePreviewList: View {
    let space: Space

    /// As many rows as a sidebar can show at once. Past that the preview is scrolled-off
    /// content nobody sees, costing a favicon lookup each.
    private static let cap = 16

    var body: some View {
        VStack(alignment: .leading, spacing: Look.rowGap) {
            HStack(spacing: Look.rowSpacing) {
                Image(systemName: space.icon ?? "cloud").font(Look.icon)
                Text(space.name).font(Look.text)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Look.inkSecondary)
            .padding(.horizontal, Look.rowInset)
            .frame(height: Look.rowHeight)
            ForEach(urls, id: \.absoluteString) { row($0) }
            Spacer(minLength: 0)
        }
    }

    private var urls: [URL] {
        Array(((space.pinnedTabURLs ?? []) + space.tabURLs).prefix(Self.cap))
    }

    private func row(_ url: URL) -> some View {
        HStack(spacing: Look.rowSpacing) {
            SiteIcon(icon: Favicons.cache(for: space.profileID).icon(for: url), size: Look.rowIcon)
            Text(url.host()?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString)
                .font(Look.rowTitle).lineLimit(1).foregroundStyle(Look.inkPrimary)
            Spacer(minLength: 0)
        }
        .padding(.leading, Look.rowInset)
        .padding(.trailing, Look.rowTrailingInset)
        .frame(height: Look.rowHeight)
    }
}

private struct SpaceSwipe: ViewModifier {
    let store: TabStore
    @State private var monitor = SwipeMonitor()

    func body(content: Content) -> some View {
        content
            .onAppear { monitor.install(store) }
            .onDisappear { monitor.remove() }
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
    private var monitor: Any?
    private var swipe = Spaces.Swipe()
    /// The previous event's timestamp, for the velocity. 0 means "no gesture in flight".
    private var last: TimeInterval = 0
    /// Whether this gesture belongs to the sidebar. Decided once, at the top of the gesture,
    /// and then kept — see `mine`.
    private var claimed = false

    func install(_ store: TabStore) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak store] event in
            guard let store, self.mine(event, store) else { return event }
            let list = store.spaces
            let index = list.firstIndex { $0.id == store.currentSpaceID } ?? 0
            let width = SidebarWidth.shared.width
            let phase = Self.phase(of: event)
            let dt = self.last > 0 ? event.timestamp - self.last : 0
            self.last = event.timestamp
            let out = self.swipe.feed(dx: event.scrollingDeltaX, dt: dt, phase: phase,
                                      width: width, count: list.count, index: index)
            if let offset = out.offset {
                store.spaceSwiping = true
                store.spaceDrag = offset             // straight on, no animation: it is the fingers
            }
            if let direction = out.commit {
                self.land(direction, from: index, in: list, width: width, store: store)
            } else if phase == .ended {
                self.settle(store)
            }
            return nil              // swallowed, so the tab list does not scroll sideways too
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func phase(of event: NSEvent) -> Spaces.Swipe.Phase {
        if !event.momentumPhase.isEmpty { return .momentum }
        if event.phase.contains(.began) { return .began }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { return .ended }
        return .changed
    }

    /// Over the line: run the rest of the travel out under the spring and swap the Space at
    /// the far end, where the preview is already standing exactly where the real sections
    /// are about to be — which is the whole reason the swap is invisible.
    private func land(_ direction: Int, from index: Int, in list: [Space],
                      width: CGFloat, store: TabStore) {
        guard list.indices.contains(index + direction) else { return settle(store) }
        let target = list[index + direction]
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            store.spaceDrag = 0
            store.spaceSwiping = false          // a cut, not a slide: `SpaceSlide` will not animate
            store.switchTo(space: target)
            rebuild()
            return
        }
        withAnimation(Look.spaceSpring) {
            store.spaceDrag = -CGFloat(direction) * width
        } completion: {
            // `spaceSwiping` is still true here, which is what keeps `SpaceSlide`'s own
            // transition off this update; the offset going back to zero in the same breath
            // lands the incoming sections on the preview they replace.
            store.switchTo(space: target)
            store.spaceDrag = 0
            rebuild()
            DispatchQueue.main.async { store.spaceSwiping = false }
        }
    }

    /// Not far enough, or nowhere to go: the strip goes home.
    private func settle(_ store: TabStore) {
        guard store.spaceDrag != 0 else { store.spaceSwiping = false; return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            store.spaceDrag = 0
            store.spaceSwiping = false
            return
        }
        withAnimation(Look.spaceSpring) { store.spaceDrag = 0 } completion: {
            store.spaceSwiping = false
        }
    }

    /// A horizontal trackpad swipe, over this window's sidebar. Everything else — a mouse
    /// wheel, a vertical scroll, a scroll over the page — is left alone.
    private func mine(_ event: NSEvent, _ store: TabStore) -> Bool {
        guard event.hasPreciseScrollingDeltas, event.window === store.window,
              store.sidebarShown, event.locationInWindow.x < SidebarWidth.shared.width
        else { return false }
        if event.phase.contains(.began) {
            claimed = false
            last = 0
            swipe = Spaces.Swipe()
        }
        // Claimed once and then held for the whole gesture, momentum tail included. The
        // fingers-up event carries no deltas at all, so deciding again on it would answer
        // "not horizontal" and drop the end of every swipe on the floor — which is exactly
        // what left the old monitor stuck after one switch.
        if !claimed {
            // 1.5, not 1: a swipe down a long tab list drifts sideways, and at parity that
            // drift switched Space on the way past.
            claimed = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5
            // The gesture's first horizontal event is also its beginning as far as the state
            // machine is concerned: `.began` itself carries no deltas and was let through.
            if claimed { swipe = Spaces.Swipe(); last = 0 }
        }
        return claimed
    }
}
