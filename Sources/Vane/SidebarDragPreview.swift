import AppKit
import Combine
import SwiftUI

enum FavouriteLanding {
    static func isNear(_ point: CGPoint, frame: CGRect) -> Bool {
        frame.width > 0 && frame.insetBy(dx: -14, dy: -18).contains(point)
    }

    static func tileWidth(width: CGFloat, columns: Int) -> CGFloat {
        max(1, (width - CGFloat(max(0, columns - 1)) * Look.inset) / CGFloat(max(1, columns)))
    }

    static func index(at point: CGPoint, frame: CGRect, count: Int, columns: Int) -> Int {
        let columns = max(1, columns)
        let pitch = tileWidth(width: frame.width, columns: columns) + Look.inset
        let row = max(0, Int(floor((point.y - frame.minY) / (Look.tileHeight + Look.inset))))
        let column = max(0, min(columns, Int(floor((point.x - frame.minX + pitch / 2) / pitch))))
        return min(count, row * columns + column)
    }
}

/// Move one noninteractive drag panel with the cursor, even outside Vane. SwiftUI redraws
/// its contents and the favourites only when their shape or landing slot changes.
@MainActor final class SidebarDragPreview: ObservableObject {
    struct Destination: Equatable {
        var index: Int
        var width: CGFloat
    }
    @Published private(set) var destination: Destination?
    weak var root: NSView?
    weak var favourites: NSView?
    weak var pill: NSView?
    weak var store: TabStore?
    private var timer: Timer?
    private var observation: AnyCancellable?
    private var ghost: NSPanel?

    func attach(_ view: NSView, store: TabStore) {
        root = view
        self.store = store
        store.sidebarDragPreview = self
        guard observation == nil else { return }
        observation = Dragging.shared.$tab.sink { [weak self] tab in
            guard let self else { return }
            timer?.invalidate()
            timer = nil
            if tab != nil {
                let next = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.track() }
                }
                timer = next
                RunLoop.main.add(next, forMode: .common)
            } else {
                setDestination(nil)
                hideGhost()
            }
        }
    }

    func detach() {
        timer?.invalidate()
        timer = nil
        observation = nil
        if store?.sidebarDragPreview === self { store?.sidebarDragPreview = nil }
        root = nil
        hideGhost()
        setDestination(nil)
    }

    func setDestination(_ next: Destination?) {
        guard destination != next else { return }
        Dragging.shared.favouriteShape(next?.width, from: self)
        if Motion.reduced { destination = next }
        else { withAnimation(Look.quick) { destination = next } }
    }

    func refresh() { track() }

    private func hideGhost() {
        ghost?.orderOut(nil)
        ghost?.contentView = nil
        ghost?.close()
        ghost = nil
    }

    private func showGhost(at mouse: CGPoint, in window: NSWindow, store: TabStore) {
        if ghost == nil {
            // Only the source window owns the floating picture. Other windows can still
            // calculate their own landing slots for shared tabs.
            guard window.isKeyWindow else { return }
            let panel = DragGhostPanel(contentRect: .zero,
                                       styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
            panel.animationBehavior = .none
            panel.setContentSize(CGSize(width: SidebarWidth.shared.width + 32,
                                        height: Look.tileHeight + 32))
            panel.contentView = NSHostingView(rootView: SidebarTabGhost(preview: self, store: store))
            ghost = panel
        }
        guard let ghost else { return }
        let appearance = Dragging.shared.favouriteTarget?.root?.window?.effectiveAppearance
            ?? window.effectiveAppearance
        if ghost.appearance?.name != appearance.name { ghost.appearance = appearance }
        ghost.setFrameOrigin(CGPoint(x: mouse.x - ghost.frame.width / 2,
                                     y: mouse.y - ghost.frame.height / 2))
        if !ghost.isVisible { ghost.orderFrontRegardless() }
    }

    private func track() {
        guard let root, let window = root.window, let store,
              let id = Dragging.shared.tab, Dragging.shared.tabs.count <= 1,
              store.tabs.contains(where: { $0.id == id }) else {
            setDestination(nil)
            hideGhost()
            return
        }
        let mouse = NSEvent.mouseLocation
        let point = root.convert(window.convertPoint(fromScreen: mouse), from: nil)
        showGhost(at: mouse, in: window, store: store)
        let frame: CGRect
        if let favourites, favourites.window === window {
            frame = root.convert(favourites.bounds, from: favourites)
        } else if let pill, pill.window === window {
            let address = root.convert(pill.bounds, from: pill)
            frame = CGRect(x: address.minX, y: address.maxY + Look.inset,
                           width: address.width, height: Look.tileHeight)
        } else { setDestination(nil); return }
        guard FavouriteLanding.isNear(point, frame: frame) else { setDestination(nil); return }
        let incoming = sidebarMoveTabs([id], in: store)
        let remaining = store.tabs.filter { $0.kind == .favourite && !incoming.contains($0.id) }.count
        let columns = SidebarWidth.favouriteColumns(remaining + incoming.count,
                                                    width: SidebarWidth.shared.width)
        setDestination(Destination(index: FavouriteLanding.index(at: point, frame: frame,
                                                                 count: remaining, columns: columns),
                                   width: FavouriteLanding.tileWidth(width: frame.width, columns: columns)))
    }
}

private final class DragGhostPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct SidebarDragAnchor: NSViewRepresentable {
    enum Region { case root, favourites, pill }
    let preview: SidebarDragPreview
    let store: TabStore
    let region: Region

    final class Anchor: NSView {
        weak var preview: SidebarDragPreview?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.preview = preview
        switch region {
        case .root: preview.attach(view, store: store)
        case .favourites: preview.favourites = view
        case .pill: preview.pill = view
        }
    }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        if view.preview?.root === view { view.preview?.detach() }
    }
}

struct SidebarTabGhost: View {
    @ObservedObject var preview: SidebarDragPreview
    @ObservedObject private var dragging = Dragging.shared
    @ObservedObject private var sidebar = SidebarWidth.shared
    @ObservedObject private var batterySaver = BatterySaver.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: TabStore

    var body: some View {
        if let id = dragging.tab, dragging.tabs.count <= 1,
           let tab = store.tabs.first(where: { $0.id == id }) {
            Ghost(tab: tab, tileWidth: dragging.favouriteGhostWidth,
                  width: sidebar.width - Look.inset * 2,
                  store: store, reduced: reduceMotion || batterySaver.isActive)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private struct Ghost: View {
        @ObservedObject var tab: Tab
        let tileWidth: CGFloat?
        let width: CGFloat
        let store: TabStore
        let reduced: Bool
        private var tile: Bool { tileWidth != nil }

        var body: some View {
            Group {
                if !tile, tab.kind != .favourite, let split = store.split(containing: tab.id) {
                    PaneStrip(store: store, split: split,
                              panes: split.tabs.compactMap { id in store.tabs.first { $0.id == id } },
                              selected: true, ticked: false, live: false)
                } else {
            HStack(spacing: tile ? 0 : Look.rowSpacing) {
                TabIcon(tab: tab, size: tile ? Look.tileIcon : Look.rowIcon)
                Text(TidyTitles.title(for: tab))
                    .font(Look.rowTitle).lineLimit(1)
                    .frame(width: tile ? 0 : max(0, width - Look.rowInset * 2 - Look.rowIcon - Look.rowSpacing),
                           alignment: .leading)
                    .opacity(tile ? 0 : 1)
            }
                }
            }
            .frame(width: tileWidth ?? width, height: tile ? Look.tileHeight : Look.rowHeight)
            .background(Look.barFill, in: .rect(cornerRadius: Look.pillRadius))
            .background(Look.barMaterial, in: .rect(cornerRadius: Look.pillRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Look.pillRadius).strokeBorder(Look.hairline)
            }
            .shadow(color: Look.liftShadow, radius: Look.liftShadowRadius, y: Look.liftShadowY)
            .animation(reduced ? nil : Look.quick, value: tile)
            .animation(reduced ? nil : Look.quick, value: tileWidth)
        }
    }
}

private struct SidebarDragPreviewKey: EnvironmentKey {
    static let defaultValue: SidebarDragPreview? = nil
}

extension EnvironmentValues {
    var sidebarDragPreview: SidebarDragPreview? {
        get { self[SidebarDragPreviewKey.self] }
        set { self[SidebarDragPreviewKey.self] = newValue }
    }
}

extension TabStore {
    func dropInFavourites(_ ids: [Tab.ID], at index: Int) {
        let ids = sidebarMoveTabs(ids, in: self)
        let others = tabs.filter { $0.kind == .favourite && !ids.contains($0.id) }
        let position = min(max(0, index), others.count)
        if position < others.count {
            for id in ids { drop(id, onto: others[position].id, after: false) }
        } else if var anchor = others.last?.id {
            for id in ids { drop(id, onto: anchor, after: true); anchor = id }
        } else {
            for id in ids { move(id, to: .favourite) }
        }
        selectionLanded(ids, in: .favourite)
    }
}
