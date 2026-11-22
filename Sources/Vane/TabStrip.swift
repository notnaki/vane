import AppKit
import SwiftUI

/// Tabs across the top: a compact bar beside the traffic lights that stands in for the
/// sidebar whenever the sidebar is hidden. ⌘S still brings the sidebar back (and the bar
/// steps aside); ⌥⌘S turns the bar on and off for every window.
enum TabStrip {
    static let prefKey = "tabStripLayout"
    /// The whole bar. The lights centre on it, so it is twice their centre line.
    static let height: CGFloat = 34
    static let chipHeight: CGFloat = 24
    /// Titled chips grow into the bar's spare room up to this.
    static let chipWidth: CGFloat = 240
    /// Titled chips shrink to this before the row starts scrolling.
    static let minChipWidth: CGFloat = 44
    static let swipeDistance: CGFloat = 40
    /// Clears the three lights at AppKit's own x, measured from the page's `gap`.
    static let lightsClearance: CGFloat = 76
    /// The page's margin under the bar: tighter than the sidebar's `Look.cardGap`.
    static let gap: CGFloat = 4
    /// Concentric with the window's own corner (about 17pt, measured) at `gap` inside it.
    static let pageRadius: CGFloat = 13
    /// Focus mode: the bar hides until the pointer reaches the window's top edge.
    static let focusKey = "tabStripFocus"
    /// How far the lights rise from the sidebar's row to the bar's centre line.
    static let lightsLift: CGFloat = Look.lightsCentre - height / 2

    static var enabled: Bool { UserDefaults.vane.bool(forKey: prefKey) }
    static func toggle() { UserDefaults.vane.set(!enabled, forKey: prefKey) }
    /// Turning focus on also turns the bar on: hiding a bar that isn't there does nothing.
    static func toggleFocus() {
        let on = !UserDefaults.vane.bool(forKey: focusKey)
        UserDefaults.vane.set(on, forKey: focusKey)
        if on && !enabled { toggle() }
    }
}

struct TabStripBar: View {
    @SidebarObserved var store: TabStore
    @Environment(\.spaceChromeTheme) private var theme
    @Namespace private var pill
    @State private var width: CGFloat = 0
    /// False for the bar's first frame, so its items can cascade in. See `StripCascade`.
    @State private var arrived = false

    var body: some View {
        // ponytail: flat order — favourites, pins (folders flattened), then today. No drag
        // reorder here; the sidebar still owns that.
        let visible = store.tabs.filter { !store.isTabLocked($0.id) }
        let icons = visible.filter { $0.kind != .today }
        let today = visible.filter { $0.kind == .today }
        // Titles shrink before anything scrolls, so a sideways swipe stays free for Spaces.
        // Only past the narrowest chips does the row scroll, and then the swipe is the row's.
        let narrowest = CGFloat(icons.count) * (TabStrip.chipHeight + 6)
            + CGFloat(today.count) * (TabStrip.minChipWidth + 2) + 80
        let fits = width == 0 || narrowest <= width
        HStack(spacing: 4) {
            StripSpaceButton(store: store)
                .modifier(StripCascade(index: 0, arrived: arrived))
            ZStack {
                WindowDragArea()
                if fits {
                    row(icons, today, flexible: true)
                        // A Space change pushes the old row out the way the switch went.
                        .id(store.currentSpaceID)
                        .transition(Motion.reduced ? .opacity
                            : .push(from: store.spaceDirection >= 0 ? .trailing : .leading))
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            row(icons, today, flexible: false)
                        }
                        .onChange(of: store.current, initial: true) { _, id in
                            guard let id else { return }
                            Motion.animate(Look.quick) { proxy.scrollTo(id) }
                        }
                    }
                }
            }
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
        .frame(height: TabStrip.height)
        .animation(Motion.reduced ? nil : Look.appear, value: store.currentSpaceID)
        // Not while the sidebar peeks over the bar: its own swipe has those events.
        .background(StripSwipe(enabled: fits && !store.sidebarPeeking) { [store] step in
            // No wrap: past the ends is the Library's swipe, or nothing.
            let list = store.strip
            guard let i = list.firstIndex(where: { $0.id == store.currentSpaceID }),
                  list.indices.contains(i + step) else { return }
            store.selectSpace(list[i + step])
        })
        .onAppear { DispatchQueue.main.async { arrived = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }

    private func row(_ icons: [Tab], _ today: [Tab], flexible: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(icons.enumerated()), id: \.element.id) { i, tab in
                chip(tab, titled: false, flexible: false).transition(Self.arrival)
                    .modifier(StripCascade(index: i + 1, arrived: arrived))
            }
            if !icons.isEmpty && !today.isEmpty {
                Rectangle().fill(Look.hairline).frame(width: 1, height: 14)
                    .padding(.horizontal, 4)
            }
            ForEach(Array(today.enumerated()), id: \.element.id) { i, tab in
                chip(tab, titled: true, flexible: flexible).transition(Self.arrival)
                    .modifier(StripCascade(index: icons.count + i + 1, arrived: arrived))
            }
            Button { store.newTab(nil) } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                    .frame(width: TabStrip.chipHeight, height: TabStrip.chipHeight)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Look.inkSecondary)
            .vaneTooltip("New Tab", shortcut: Keybindings.binding(for: .newTab).display)
            .accessibilityLabel("New Tab")
            if flexible { Spacer(minLength: 0) }
        }
        .padding(.trailing, TabStrip.gap)
        .animation(Motion.reduced ? nil : Look.quick, value: store.current)
        .animation(Motion.reduced ? nil : Look.quick, value: (icons + today).map(\.id))
    }

    /// Tabs grow in from their own centre and shrink away there; neighbours slide over.
    private static var arrival: AnyTransition {
        Motion.reduced ? .opacity : .scale(scale: 0.6).combined(with: .opacity)
    }

    private func chip(_ tab: Tab, titled: Bool, flexible: Bool) -> some View {
        StripChip(store: store, tab: tab, titled: titled, flexible: flexible,
                  selected: store.current == tab.id, pill: pill,
                  pillID: store.currentSpaceID?.uuidString ?? "", theme: theme)
            .id(tab.id)
    }
}

/// The bar's items settle in left to right when it appears: a short drop and fade, each a
/// beat after the one before. Capped, so a long row is not still arriving a second later.
private struct StripCascade: ViewModifier {
    let index: Int
    let arrived: Bool
    func body(content: Content) -> some View {
        if Motion.reduced {
            content
        } else {
            content
                .opacity(arrived ? 1 : 0)
                .offset(y: arrived ? 0 : -5)
                .animation(.spring(duration: 0.32, bounce: 0.18)
                    .delay(0.06 + Double(min(index, 10)) * 0.018), value: arrived)
        }
    }
}

/// The current Space's icon. Its menu lists every Space, grouped by profile the way the
/// Spaces menu is, so a profile hop is one pick away too.
private struct StripSpaceButton: View {
    let store: TabStore
    @Environment(\.spaceChromeTheme) private var theme
    @State private var hovering = false

    var body: some View {
        let spaces = store.strip
        let profiles = ProfileManager.shared.profiles
        let current = store.currentSpace
        Menu {
            ForEach(profiles, id: \.id) { profile in
                let mine = spaces.filter { $0.profileID == profile.id }
                if !mine.isEmpty {
                    Section(profiles.count > 1 ? profile.name : "") {
                        ForEach(mine) { space in
                            Button { store.selectSpace(space) } label: {
                                if space.id == store.currentSpaceID {
                                    Label(space.name, systemImage: "checkmark")
                                } else { Text(space.name) }
                            }
                        }
                    }
                }
            }
            Divider()
            Button("New Space") { _ = store.newSpace() }
        } label: {
            // A pill of its own, not another tab: the Space's icon and name, with the
            // profile's colour when there is more than one profile to tell apart.
            HStack(spacing: 5) {
                if profiles.count > 1, let profile = profiles.first(where: { $0.id == store.profileID }) {
                    Circle().fill(Color(hex: profile.colorHex) ?? .secondary)
                        .frame(width: 6, height: 6)
                        .help(profile.name)
                }
                SpaceIcon(current?.icon ?? "square.on.square")
                    .font(.system(size: 11, weight: .semibold))
                Text(current?.name ?? "Spaces")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 96, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    .opacity(hovering ? 1 : 0.5)
            }
            .padding(.horizontal, 8)
            .frame(height: TabStrip.chipHeight - 2)
            .background(Capsule().fill(hovering ? theme.barHovered : theme.controlFill))
            .overlay(Capsule().strokeBorder(Look.hairline, lineWidth: 0.5))
            .contentShape(Capsule())
            .contentTransition(Motion.reduced ? .identity : .interpolate)
            .animation(Motion.reduced ? nil : Look.quick, value: current?.id)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .foregroundStyle(.primary)
        .disabled(store.isPrivate)
        .help(current?.name ?? "Spaces")
        .accessibilityLabel("Space: \(current?.name ?? "none")")
    }
}

/// A two-finger sideways swipe over the bar moves one Space, once per gesture — its
/// momentum included, so one flick is never two Spaces.
/// ponytail: no slide, the switch lands at once as ⌥⌘→ does with the sidebar hidden. The
/// sidebar's captured-pixel slide needs its sections on screen.
private struct StripSwipe: NSViewRepresentable {
    let enabled: Bool
    let onSwipe: (Int) -> Void
    func makeNSView(context: Context) -> StripSwipeView { StripSwipeView() }
    func updateNSView(_ view: StripSwipeView, context: Context) {
        view.enabled = enabled
        view.onSwipe = onSwipe
    }
}

private final class StripSwipeView: NSView {
    var enabled = true
    var onSwipe: (Int) -> Void = { _ in }
    private var monitor: Any?
    private var active = false
    private var committed = false
    private var travel: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, event.hasPreciseScrollingDeltas else { return event }
        if event.phase.contains(.began) {
            active = enabled && bounds.contains(convert(event.locationInWindow, from: nil))
            committed = false
            travel = 0
        }
        guard active else { return event }
        if !event.phase.isEmpty, !committed {
            travel += event.scrollingDeltaX
            if abs(travel) > TabStrip.swipeDistance, abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) {
                committed = true
                onSwipe(travel < 0 ? 1 : -1)
            }
        }
        if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)
            || (event.momentumPhase.isEmpty && event.phase.contains(.cancelled)) {
            active = false
        }
        return nil
    }
}

private struct StripChip: View {
    let store: TabStore
    @ObservedObject var tab: Tab
    let titled: Bool
    let flexible: Bool
    let selected: Bool
    let pill: Namespace.ID
    /// Per Space, so the outgoing row's pill and the incoming one's never claim one id.
    let pillID: String
    let theme: SpaceChromeTheme
    @State private var hovering = false

    var body: some View {
        let title = TidyTitles.title(for: tab)
        HStack(spacing: 6) {
            TabIcon(tab: tab, size: 14)
            if titled {
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.primary : Look.inkSecondary)
                Spacer(minLength: 0)
                Button { store.close(tab.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        .frame(width: 16, height: 16).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Look.inkSecondary)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, titled ? 8 : 5)
        .frame(minWidth: titled ? (flexible ? TabStrip.minChipWidth : TabStrip.chipWidth)
                             : TabStrip.chipHeight + 4,
               maxWidth: titled ? TabStrip.chipWidth : TabStrip.chipHeight + 4,
               minHeight: TabStrip.chipHeight, maxHeight: TabStrip.chipHeight)
        .background {
            // The grey slides to the tab you pick.
            if selected {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.selected)
                    .matchedGeometryEffect(id: "selected" + pillID, in: pill)
            } else if hovering {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.hovered)
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            store.selection.clear()
            store.current = tab.id
        }
        .onHover { hovering = $0 }
        .animation(Motion.reduced ? nil : Look.quick, value: hovering)
        .contextMenu { SidebarTabContextMenu(store: store, tab: tab) }
        .help(title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { store.current = tab.id }
        .accessibilityAction(named: "Close") { store.close(tab.id) }
    }
}
