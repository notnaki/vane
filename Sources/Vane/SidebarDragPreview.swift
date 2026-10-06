import AppKit
import Combine
import SwiftUI

enum FavouriteLanding {
    static func emptyFrame(below pill: CGRect, revealed: Bool) -> CGRect {
        CGRect(x: pill.minX, y: pill.maxY + Look.inset, width: pill.width,
               height: revealed ? Look.tileHeight : Look.inset)
    }

    /// Only a presentation order. The store and all actual tab kinds stay unchanged.
    static func previewIDs(favourites: [Tab.ID], incoming: [Tab.ID], index: Int?) -> [Tab.ID] {
        guard let index else { return favourites }
        let moving = Set(incoming)
        var ids = favourites.filter { !moving.contains($0) }
        ids.insert(contentsOf: incoming, at: min(max(0, index), ids.count))
        return ids
    }

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

    /// Convert a gap in the fixed on-screen grid to an index after the dragged tiles leave.
    static func remainingIndex(gap: Int, favourites: [Tab.ID], moving: Set<Tab.ID>) -> Int {
        let gap = min(max(0, gap), favourites.count)
        return favourites.prefix(gap).filter { !moving.contains($0) }.count
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
              let id = Dragging.shared.tab,
              store.tabs.contains(where: { $0.id == id }) else {
            setDestination(nil)
            hideGhost()
            return
        }
        let mouse = NSEvent.mouseLocation
        let point = root.convert(window.convertPoint(fromScreen: mouse), from: nil)
        if Dragging.shared.tabs.count <= 1 { showGhost(at: mouse, in: window, store: store) }
        else { hideGhost() }
        let frame: CGRect
        let favouriteIDs = store.tabs.filter { $0.kind == .favourite }.map(\.id)
        if let favourites, favourites.window === window,
           !favouriteIDs.isEmpty || destination != nil {
            frame = root.convert(favourites.bounds, from: favourites)
        } else if let pill, pill.window === window {
            let address = root.convert(pill.bounds, from: pill)
            frame = FavouriteLanding.emptyFrame(below: address, revealed: destination != nil)
        } else { setDestination(nil); return }
        guard FavouriteLanding.isNear(point, frame: frame) else { setDestination(nil); return }
        let rows = Dragging.shared.tabs.isEmpty ? [id] : Dragging.shared.tabs
        let incoming = sidebarMoveTabs(rows, in: store)
        let favourites = favouriteIDs
        let moving = Set(incoming)
        let remaining = favourites.filter { !moving.contains($0) }.count
        let displayed = FavouriteLanding.previewIDs(favourites: favourites, incoming: incoming,
                                                    index: destination?.index)
        let physicalColumns = SidebarWidth.favouriteColumns(max(1, displayed.count),
                                                             width: SidebarWidth.shared.width)
        let gap = FavouriteLanding.index(at: point, frame: frame, count: displayed.count,
                                         columns: physicalColumns)
        let index = FavouriteLanding.remainingIndex(gap: gap, favourites: displayed,
                                                     moving: moving)
        let finalColumns = SidebarWidth.favouriteColumns(remaining + incoming.count,
                                                         width: SidebarWidth.shared.width)
        setDestination(Destination(index: index,
                                   width: FavouriteLanding.tileWidth(width: frame.width,
                                                                     columns: finalColumns)))
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
                  width: dragging.rowGhostWidth ?? (sidebar.width - Look.inset * 2),
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
        @State private var lastTileWidth: CGFloat = Look.tileHeight
        private var tile: Bool { tileWidth != nil }

        var body: some View {
            Group {
                if tab.kind != .favourite, let held = Dragging.shared.rowGhost {
                    // One mounted source surface throughout: its icon moves to the tile's
                    // centre as the rectangle changes size, without swapping pictures.
                    held.modifier(GhostTileTransform(progress: tile ? 1 : 0,
                                                     rowWidth: width,
                                                     tileWidth: tileWidth ?? lastTileWidth))
                } else if tile {
                    if tab.kind == .favourite, let held = Dragging.shared.rowGhost {
                        held
                    } else {
                        TabIcon(tab: tab, size: Look.tileIcon)
                            .scaleEffect(reduced ? 1 : 1.07)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background {
                                FavoriteTileBackground(selected: store.current == tab.id,
                                                       hovering: true, icon: tab.favicon)
                            }
                    }
                } else {
                    SidebarTabSurface(store: store, tab: tab, held: true,
                                      returnHovering: .constant(false), pr: nil, action: {})
                }
            }
            .frame(width: tileWidth ?? width, height: tile ? Look.tileHeight : Look.rowHeight)
            .clipShape(.rect(cornerRadius: Look.pillRadius))
            .animation(reduced ? nil : Look.quick, value: tile)
            .animation(reduced ? nil : Look.quick, value: tileWidth)
            .onChange(of: tileWidth, initial: true) { _, next in
                if let next { lastTileWidth = next }
            }
        }
    }
}

struct GhostTileMorph {
    var progress: CGFloat
    var rowWidth: CGFloat
    var tileWidth: CGFloat
    var width: CGFloat { rowWidth + (tileWidth - rowWidth) * progress }
    var height: CGFloat { Look.rowHeight + (Look.tileHeight - Look.rowHeight) * progress }
    var iconX: CGFloat {
        let start = Look.rowInset + Look.rowIcon / 2
        return start + (tileWidth / 2 - start) * progress
    }
}

private struct GhostTileMorphKey: EnvironmentKey {
    static let defaultValue: GhostTileMorph? = nil
}
extension EnvironmentValues {
    var ghostTileMorph: GhostTileMorph? {
        get { self[GhostTileMorphKey.self] }
        set { self[GhostTileMorphKey.self] = newValue }
    }
}

private struct GhostTileTransform: AnimatableModifier {
    nonisolated var progress: CGFloat
    nonisolated let rowWidth: CGFloat
    nonisolated var tileWidth: CGFloat
    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, tileWidth) }
        set { progress = newValue.first; tileWidth = newValue.second }
    }
    func body(content: Content) -> some View {
        let morph = GhostTileMorph(progress: progress, rowWidth: rowWidth, tileWidth: tileWidth)
        content.environment(\.ghostTileMorph, morph)
            .frame(width: morph.width, height: morph.height, alignment: .leading)
            .clipped()
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
