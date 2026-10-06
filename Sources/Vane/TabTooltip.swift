import AppKit
import SwiftUI

enum TabTooltipLayout {
    static func width(title: String, hint: String? = "Double-click to rename", shortcut: String? = nil,
                      compact: Bool = false) -> CGFloat {
        let titleWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
        let hintWidth = ((hint ?? "") as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
        let shortcutWidth = shortcut.map {
            ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width + 22
        } ?? 0
        return min(compact ? 240 : 300, ceil(max(titleWidth + shortcutWidth, hintWidth)) + 24)
    }

    static func frame(anchor: CGRect, size: CGSize, screen: CGRect, centered: Bool = false) -> CGRect {
        let safe = screen.insetBy(dx: 8, dy: 8)
        let width = min(size.width, safe.width)
        let height = min(size.height, safe.height)
        let below = anchor.minY - height - 4
        let y = below >= safe.minY ? below : anchor.maxY + 4
        let x = centered ? anchor.midX - width / 2 : anchor.minX + 32
        return CGRect(x: min(max(x, safe.minX), safe.maxX - width),
                      y: min(max(y, safe.minY), safe.maxY - height), width: width, height: height)
    }
}

/// A single passive tooltip for tabs and controls, outside clipped scroll views. Its anchor never
/// receives clicks, and its panel never takes focus from a page or an inline rename field.
@MainActor final class TabTooltip {
    static let shared = TabTooltip()
    private weak var anchor: TabTooltipAnchorView?
    private weak var owner: NSWindow?
    private var pending: Task<Void, Never>?
    private var panel: NSPanel?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private let hovered = NSHashTable<TabTooltipAnchorView>.weakObjects()
    var isPending: Bool { pending != nil }
    var isVisible: Bool { panel != nil }

    func schedule(for anchor: TabTooltipAnchorView) {
        guard anchor.enabled else { return }
        dismissPresentation()
        self.anchor = anchor
        owner = anchor.window
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown,
            .otherMouseDown, .leftMouseDragged, .rightMouseDragged, .scrollWheel, .keyDown]) {
                [weak self] event in self?.handle(event) ?? event
            }
        watch(NSApplication.didResignActiveNotification, object: nil)
        if let owner {
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                         NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                watch(name, object: owner)
            }
        }
        pending = Task { [weak self, weak anchor] in
            do { try await Task.sleep(for: .milliseconds(550)) } catch { return }
            guard let self, let anchor, self.anchor === anchor else { return }
            self.pending = nil
            self.show(for: anchor)
        }
    }

    func handle(_ event: NSEvent) -> NSEvent {
        // Keep hover membership so moving off a clicked control can re-arm its row,
        // without reopening a tooltip while the pointer stays still after input.
        dismissPresentation()
        return event
    }

    func enter(for anchor: TabTooltipAnchorView) {
        guard anchor.enabled else { return }
        hovered.add(anchor)
        guard let target = bestHovered(in: anchor.window) else { return }
        if self.anchor === target && (isPending || isVisible) { return }
        schedule(for: target)
    }

    private func bestHovered(in window: NSWindow?) -> TabTooltipAnchorView? {
        // SwiftUI backgrounds are siblings in AppKit's tree. Compare target sizes,
        // rather than ancestry, so a small control wins over its containing row in
        // either tracking-event order.
        hovered.allObjects.filter {
            $0.enabled && $0.window === window && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
        }.min {
            $0.visibleRect.width * $0.visibleRect.height < $1.visibleRect.width * $1.visibleRect.height
        }
    }

    private func watch(_ name: Notification.Name, object: AnyObject?) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object,
            queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } })
    }

    private func show(for anchor: TabTooltipAnchorView) {
        guard anchor.enabled, let owner = anchor.window, owner.isKeyWindow, NSApp.isActive,
              !anchor.isHiddenOrHasHiddenAncestor, !anchor.visibleRect.isEmpty,
              let screen = owner.screen else { dismiss(); return }
        let pointer = anchor.convert(owner.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        guard anchor.visibleRect.contains(pointer) else { dismiss(); return }
        let surface = TabTooltipSurface(title: anchor.title, hint: anchor.hint,
                                        shortcut: anchor.shortcut, compact: anchor.centered)
        let hosting = NSHostingView(rootView: surface)
        let size = hosting.fittingSize
        let rect = owner.convertToScreen(anchor.convert(anchor.visibleRect, to: nil))
        let frame = TabTooltipLayout.frame(anchor: rect, size: size, screen: screen.visibleFrame,
                                           centered: anchor.centered)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.hidesOnDeactivate = true
        panel.contentView = hosting
        self.panel = panel
        panel.alphaValue = Motion.reduced ? 1 : 0
        owner.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        if !Motion.reduced {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Look.appearDuration
                panel.animator().alphaValue = 1
            }
        }
    }

    func refresh(for anchor: TabTooltipAnchorView) {
        guard self.anchor === anchor, let panel, let owner = anchor.window,
              let screen = owner.screen else { return }
        // A page title, copy confirmation, or shortcut can change under a still pointer.
        let hosting = NSHostingView(rootView: TabTooltipSurface(title: anchor.title,
            hint: anchor.hint, shortcut: anchor.shortcut, compact: anchor.centered))
        let rect = owner.convertToScreen(anchor.convert(anchor.visibleRect, to: nil))
        panel.setFrame(TabTooltipLayout.frame(anchor: rect, size: hosting.fittingSize,
                                              screen: screen.visibleFrame, centered: anchor.centered), display: false)
        panel.contentView = hosting
    }

    func dismiss(for anchor: TabTooltipAnchorView) {
        hovered.remove(anchor)
        guard self.anchor === anchor else { return }
        dismissPresentation()
        if let target = bestHovered(in: anchor.window) { schedule(for: target) }
    }

    func exit(for anchor: TabTooltipAnchorView) {
        let wasHovered = hovered.contains(anchor)
        dismiss(for: anchor)
        // Only a pointer exit may re-arm a tooltip canceled by input. Disabled or
        // dismantled sibling controls must not silently undo that cancellation.
        if self.anchor == nil && wasHovered, let target = bestHovered(in: anchor.window) {
            schedule(for: target)
        }
    }

    func dismiss() {
        hovered.removeAllObjects()
        dismissPresentation()
    }

    private func dismissPresentation() {
        pending?.cancel()
        pending = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let panel {
            owner?.removeChildWindow(panel)
            panel.close()
            panel.contentView = nil
        }
        panel = nil
        owner = nil
        anchor = nil
    }
}

private struct TabTooltipSurface: View {
    let title: String
    let hint: String?
    let shortcut: String?
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                if let shortcut {
                    Text(shortcut).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.white.opacity(0.1), in: .rect(cornerRadius: 4))
                        .fixedSize()
                }
            }
            if let hint {
                Text(hint)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(red: 0.66, green: 0.65, blue: 0.83))
                    .lineLimit(compact ? 2 : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: TabTooltipLayout.width(title: title, hint: hint, shortcut: shortcut,
                                             compact: compact), alignment: .leading)
        .background(Color(red: 0.045, green: 0.035, blue: 0.24), in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.14), lineWidth: 1) }
        .accessibilityHidden(true)
    }
}

final class TabTooltipAnchorView: NSView {
    let tooltip: TabTooltip
    private(set) var title = ""
    private(set) var hint: String? = "Double-click to rename"
    private(set) var shortcut: String?
    private(set) var centered = false
    private(set) var enabled = true
    private var tracking: NSTrackingArea?

    init(tooltip: TabTooltip = .shared) {
        self.tooltip = tooltip
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, hint: String? = "Double-click to rename", shortcut: String? = nil,
                   centered: Bool = false, enabled: Bool) {
        let changed = self.title != title || self.hint != hint || self.shortcut != shortcut
            || self.centered != centered
        self.title = title
        self.hint = hint
        self.shortcut = shortcut
        self.centered = centered
        self.enabled = enabled
        if !enabled { tooltip.dismiss(for: self) }
        else if changed { tooltip.refresh(for: self) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        if enabled { tooltip.enter(for: self) }
    }
    override func mouseExited(with event: NSEvent) { tooltip.exit(for: self) }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { tooltip.dismiss(for: self) }
        super.viewWillMove(toWindow: newWindow)
    }
}

private struct TabTooltipAnchor: NSViewRepresentable {
    let title: String
    let hint: String?
    let shortcut: String?
    let centered: Bool
    let enabled: Bool
    func makeNSView(context: Context) -> TabTooltipAnchorView { TabTooltipAnchorView() }
    func updateNSView(_ view: TabTooltipAnchorView, context: Context) {
        view.configure(title: title, hint: hint, shortcut: shortcut, centered: centered, enabled: enabled)
    }
    static func dismantleNSView(_ view: TabTooltipAnchorView, coordinator: ()) {
        view.tooltip.dismiss(for: view)
    }
}

private struct TabTooltipModifier: ViewModifier {
    let title: String
    var hint: String? = "Double-click to rename"
    var shortcut: String? = nil
    var centered = false
    let enabled: Bool
    @Environment(\.isEnabled) private var controlEnabled
    @ObservedObject private var dragging = Dragging.shared
    func body(content: Content) -> some View {
        content.background(TabTooltipAnchor(title: title, hint: hint, shortcut: shortcut, centered: centered,
            enabled: enabled && controlEnabled && dragging.tab == nil && dragging.folder == nil))
    }
}

extension View {
    func tabTooltip(_ title: String, enabled: Bool) -> some View {
        modifier(TabTooltipModifier(title: title, enabled: enabled))
    }

    /// Custom chrome hints share the tabs' passive panel and cancellation rules.
    func vaneTooltip(_ title: String, hint: String? = nil, shortcut: String? = nil,
                     enabled: Bool = true) -> some View {
        let shortcut = shortcut == "" || shortcut == Keybinding.unassigned.display ? nil : shortcut
        return modifier(TabTooltipModifier(title: title, hint: hint,
            shortcut: shortcut,
            centered: true, enabled: enabled))
            .accessibilityHint([title, hint, shortcut].compactMap { $0 }.joined(separator: ". "))
    }
}
