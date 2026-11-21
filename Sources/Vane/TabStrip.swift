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
    static let chipWidth: CGFloat = 150
    /// Titled chips shrink to this before the row starts scrolling.
    static let minChipWidth: CGFloat = 44
    static let swipeDistance: CGFloat = 40
    /// Clears the three lights at AppKit's own x.
    static let lightsClearance: CGFloat = 78
    /// How far the lights rise from the sidebar's row to the bar's centre line.
    static let lightsLift: CGFloat = Look.lightsCentre - height / 2

    static var enabled: Bool { UserDefaults.vane.bool(forKey: prefKey) }
    static func toggle() { UserDefaults.vane.set(!enabled, forKey: prefKey) }
}

struct TabStripBar: View {
    @SidebarObserved var store: TabStore
    @Environment(\.spaceChromeTheme) private var theme
    @Namespace private var pill
    @State private var width: CGFloat = 0

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
            ZStack {
                WindowDragArea()
                if fits {
                    row(icons, today, flexible: true)
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
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
        .frame(height: TabStrip.height)
        // Not while the sidebar peeks over the bar: its own swipe has those events.
        .background(StripSwipe(enabled: fits && !store.sidebarPeeking) { [store] step in
            // No wrap: past the ends is the Library's swipe, or nothing.
            let list = store.strip
            guard let i = list.firstIndex(where: { $0.id == store.currentSpaceID }),
                  list.indices.contains(i + step) else { return }
            store.selectSpace(list[i + step])
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }

    private func row(_ icons: [Tab], _ today: [Tab], flexible: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(icons) { chip($0, titled: false, flexible: false) }
            if !icons.isEmpty && !today.isEmpty {
                Rectangle().fill(Look.hairline).frame(width: 1, height: 14)
                    .padding(.horizontal, 4)
            }
            ForEach(today) { chip($0, titled: true, flexible: flexible) }
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
        .padding(.trailing, Look.cardGap)
        .animation(Motion.reduced ? nil : Look.quick, value: store.current)
    }

    private func chip(_ tab: Tab, titled: Bool, flexible: Bool) -> some View {
        StripChip(store: store, tab: tab, titled: titled, flexible: flexible,
                  selected: store.current == tab.id, pill: pill, theme: theme)
            .id(tab.id)
    }
}

/// The current Space's icon. Its menu lists every Space, grouped by profile the way the
/// Spaces menu is, so a profile hop is one pick away too.
private struct StripSpaceButton: View {
    let store: TabStore

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
            SpaceIcon(current?.icon ?? "square.on.square")
                .font(.system(size: 13))
                .frame(width: TabStrip.chipHeight + 4, height: TabStrip.chipHeight)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Look.inkSecondary)
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
                    .matchedGeometryEffect(id: "selected", in: pill)
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
        .contextMenu { SidebarTabContextMenu(store: store, tab: tab) }
        .help(title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { store.current = tab.id }
        .accessibilityAction(named: "Close") { store.close(tab.id) }
    }
}
