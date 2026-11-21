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

    var body: some View {
        // ponytail: flat order — favourites, pins (folders flattened), then today. No drag
        // reorder here; the sidebar still owns that.
        let visible = store.tabs.filter { !store.isTabLocked($0.id) }
        let icons = visible.filter { $0.kind != .today }
        let today = visible.filter { $0.kind == .today }
        ZStack {
            WindowDragArea()
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(icons) { chip($0, titled: false) }
                        if !icons.isEmpty && !today.isEmpty {
                            Rectangle().fill(Look.hairline).frame(width: 1, height: 14)
                                .padding(.horizontal, 4)
                        }
                        ForEach(today) { chip($0, titled: true) }
                        Button { store.newTab(nil) } label: {
                            Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                                .frame(width: TabStrip.chipHeight, height: TabStrip.chipHeight)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Look.inkSecondary)
                        .vaneTooltip("New Tab", shortcut: Keybindings.binding(for: .newTab).display)
                        .accessibilityLabel("New Tab")
                    }
                    .padding(.trailing, Look.cardGap)
                    .animation(Motion.reduced ? nil : Look.quick, value: store.current)
                }
                .onChange(of: store.current, initial: true) { _, id in
                    guard let id else { return }
                    Motion.animate(Look.quick) { proxy.scrollTo(id) }
                }
            }
        }
        .frame(height: TabStrip.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }

    private func chip(_ tab: Tab, titled: Bool) -> some View {
        StripChip(store: store, tab: tab, titled: titled, selected: store.current == tab.id,
                  pill: pill, theme: theme)
            .id(tab.id)
    }
}

private struct StripChip: View {
    let store: TabStore
    @ObservedObject var tab: Tab
    let titled: Bool
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
        .frame(width: titled ? TabStrip.chipWidth : TabStrip.chipHeight + 4,
               height: TabStrip.chipHeight)
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
