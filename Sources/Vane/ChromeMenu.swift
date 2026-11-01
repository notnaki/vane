import AppKit
import SwiftUI

/// In-window chrome menus share a solid surface, independent of the macOS menu theme.
/// The menu bar and WebKit's page menus still belong to their respective responders.
@MainActor struct ChromeMenuItem {
    let title: String
    let symbol: String
    var shortcut: String = ""
    var checked = false
    var startsGroup = false
    let action: () -> Void
}

enum ChromeMenuLayout {
    // Match the default sidebar’s content width; resizing the sidebar only moves the anchor.
    static let width: CGFloat = Look.sidebarWidth - Look.inset * 2
    static let rowHeight: CGFloat = 32
    static let inset: CGFloat = 6
    static let groupHeight: CGFloat = 9
    static let pointerHeight: CGFloat = 8

    /// The highlight lives in the scrolling content, with the same separator pitch
    /// as the rows it follows. Keep this independent of presentation animation.
    static func highlightOffset(index: Int, groupStarts: [Int]) -> CGFloat {
        CGFloat(index) * rowHeight + CGFloat(groupStarts.filter { $0 <= index }.count) * groupHeight
    }

    /// Keep the entire surface inside both the owner's content and the visible screen.
    static func frame(anchor: CGRect, size: CGSize, window: CGRect, screen: CGRect, above: Bool) -> CGRect {
        let bounds = window.intersection(screen)
        guard !bounds.isNull, bounds.width > 16, bounds.height > 16 else { return .zero }
        let safe = bounds.insetBy(dx: 8, dy: 8)
        let height = min(size.height, safe.height)
        let width = min(size.width, safe.width)
        let upper = anchor.maxY + 6
        let lower = anchor.minY - 6 - height
        let preferred = above ? upper : lower
        let alternate = above ? lower : upper
        let y = preferred >= safe.minY && preferred + height <= safe.maxY
            ? preferred : alternate
        return CGRect(x: min(max(anchor.maxX - width, safe.minX), safe.maxX - width),
                      y: min(max(y, safe.minY), safe.maxY - height),
                      width: width, height: height)
    }
}

/// Keep a rapid sequence together; repeated initial letters cycle matching rows.
struct ChromeMenuTypeahead {
    private var prefix = ""
    private var lastTime: TimeInterval = -.infinity

    func isActive(at time: TimeInterval) -> Bool {
        !prefix.isEmpty && time >= lastTime && time - lastTime < 0.8
    }

    mutating func match(_ text: String, at time: TimeInterval, titles: [String], current: Int?) -> Int? {
        guard !titles.isEmpty else { return nil }
        if !isActive(at: time) { prefix = "" }
        let cycling = prefix.count == 1 && prefix.lowercased() == text.lowercased()
        let extending = !prefix.isEmpty && !cycling
        if !cycling { prefix += text }
        lastTime = time
        let start = extending ? (current ?? 0) : (current ?? -1) + 1
        return (0..<titles.count).map { (start + $0) % titles.count }.first {
            titles[$0].range(of: prefix, options: [.anchored, .caseInsensitive], locale: .current) != nil
        } ?? current
    }
}

@MainActor private final class ChromeMenuSelection: ObservableObject {
    @Published private(set) var index: Int?
    private(set) var highlightIndex = 0
    private(set) var fromPointer = false

    func select(_ index: Int?, fromPointer: Bool = false) {
        if let index { highlightIndex = index }
        self.fromPointer = fromPointer
        self.index = index
    }
}

/// One transient panel at a time. Every exit removes monitors and releases its actions.
@MainActor final class ChromeMenu {
    static let shared = ChromeMenu()
    private var panel: NSPanel?
    private weak var owner: NSWindow?
    private weak var source: ChromeMenuAnchor?
    private var items: [ChromeMenuItem] = []
    private var selection = ChromeMenuSelection()
    private var typeahead = ChromeMenuTypeahead()
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    fileprivate func refreshTheme(for source: ChromeMenuAnchor) {
        guard self.source === source,
              let hosting = panel?.contentView as? NSHostingView<ChromeMenuSurface> else { return }
        var surface = hosting.rootView
        surface.theme = source.theme
        hosting.rootView = surface
    }

    func show(_ items: [ChromeMenuItem], in owner: NSWindow, anchor: CGRect,
              above: Bool = false, title: String, source: ChromeMenuAnchor? = nil,
              showsPointer: Bool = false) {
        dismiss()
        TabTooltip.shared.dismiss()
        guard !items.isEmpty, let screen = owner.screen ?? NSScreen.main else { return }
        let size = CGSize(width: ChromeMenuLayout.width,
                          height: CGFloat(items.count) * ChromeMenuLayout.rowHeight
                            + CGFloat(items.filter(\.startsGroup).count) * ChromeMenuLayout.groupHeight
                            + ChromeMenuLayout.inset * 2
                            + (showsPointer ? ChromeMenuLayout.pointerHeight : 0))
        let frame = ChromeMenuLayout.frame(anchor: anchor, size: size,
                                           window: owner.convertToScreen(owner.contentLayoutRect),
                                           screen: screen.visibleFrame, above: above)
        guard !frame.isEmpty else { return }
        self.items = items
        self.owner = owner
        self.source = source
        selection = ChromeMenuSelection()
        typeahead = ChromeMenuTypeahead()
        let panel = ChromeMenuPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.level = .popUpMenu
        panel.title = title
        panel.contentView = NSHostingView(rootView: ChromeMenuSurface(
            items: items, theme: source?.theme ?? SpaceChromeTheme(), selection: selection, title: title,
            revealAnchor: UnitPoint(x: min(max((anchor.midX - frame.minX) / frame.width, 0), 1),
                                    y: frame.minY >= anchor.maxY ? 1 : 0),
            pointerX: showsPointer ? min(max(anchor.midX - frame.minX, 24), frame.width - 24) : nil,
            pointerBelow: frame.minY >= anchor.maxY,
            choose: { [weak self] in self?.choose($0) }))
        self.panel = panel
        owner.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        source?.isPresented = true
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: {
            [weak self, weak panel] event in
            if event.window !== panel {
                // Consume the trigger's mouse-down so its mouse-up cannot reopen the menu.
                let onTrigger = self?.containsTrigger(event) == true
                self?.dismiss()
                if onTrigger { return nil }
            }
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] _ in self?.dismiss() }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: {
            [weak self, weak panel] event in
            guard let self, event.window === panel else { return event }
            return self.key(event) ? nil : event
        }) { monitors.append(monitor) }
        watch(NSApplication.didResignActiveNotification, object: nil)
        watch(NSWindow.didResignKeyNotification, object: panel)
        for name in [NSWindow.willCloseNotification, NSWindow.didMoveNotification,
                     NSWindow.didResizeNotification] { watch(name, object: owner) }
    }

    private func containsTrigger(_ event: NSEvent) -> Bool {
        guard event.window === owner, let view = source?.view, view.window === owner else { return false }
        return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
    }

    private func watch(_ name: Notification.Name, object: AnyObject?) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object,
            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        source?.isPresented = false
        source = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        let restoreKey = panel.isKeyWindow && NSApp.isActive
        owner?.removeChildWindow(panel)
        panel.close()
        panel.contentView = nil
        if restoreKey { owner?.makeKey() }
        owner = nil
        items.removeAll()
    }

    private func choose(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let action = items[index].action
        dismiss()
        // Dismiss before opening the Space editor or command bar on the owner window.
        action()
    }

    private func key(_ event: NSEvent) -> Bool {
        guard !items.isEmpty else { return false }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            dismiss()
            return false
        }
        switch event.keyCode {
        case 53: dismiss()
        case 125, 126, 48:
            typeahead = ChromeMenuTypeahead()
            let backwards = event.keyCode == 126 || event.modifierFlags.contains(.shift)
            let first = backwards ? items.count - 1 : 0
            selection.select(selection.index.map {
                ($0 + (backwards ? -1 : 1) + items.count) % items.count
            } ?? first)
        case 36, 76:
            choose(selection.index ?? 0)
        case 49 where !typeahead.isActive(at: event.timestamp):
            choose(selection.index ?? 0)
        default:
            guard let text = event.characters, !text.isEmpty else { return false }
            guard text.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
            }) else { return false }
            selection.select(typeahead.match(text, at: event.timestamp,
                                              titles: items.map(\.title), current: selection.index))
        }
        return true
    }
}

private final class ChromeMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct ChromeMenuSurface: View {
    let items: [ChromeMenuItem]
    var theme: SpaceChromeTheme
    @ObservedObject var selection: ChromeMenuSelection
    let title: String
    let revealAnchor: UnitPoint
    let pointerX: CGFloat?
    let pointerBelow: Bool
    let choose: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var batterySaver = BatterySaver.shared
    @State private var appeared = false
    @State private var motionSuppressed = false

    private var reduced: Bool { reduceMotion || batterySaver.isActive }

    var body: some View {
        VStack(spacing: 0) {
            if pointerX != nil && !pointerBelow { pointer }
            surface
            if pointerX != nil && pointerBelow { pointer }
        }
        .environment(\.colorScheme, .dark)
        .animation(reduced ? nil : Look.quick, value: theme)
        .modifier(ChromeMenuReveal(progress: appeared ? 1 : 0,
            anchor: revealAnchor,
            reduced: reduced || motionSuppressed))
        .onAppear { withAnimation(reduced ? nil : Look.feedback) { appeared = true } }
        .onChange(of: reduced) { _, reduced in
            if reduced { Motion.instant { motionSuppressed = true; appeared = true } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .vaneMotionPolicy()
    }

    private var pointer: some View {
        ChromeMenuPointer(x: pointerX ?? 0, below: pointerBelow)
            .fill(theme.bubble)
            .frame(height: ChromeMenuLayout.pointerHeight)
            .accessibilityHidden(true)
    }

    private var surface: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items.indices, id: \.self) { index in
                        if items[index].startsGroup {
                            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .accessibilityHidden(true)
                        }
                        row(index).id(index)
                    }
                }
                .background(alignment: .top) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.bubbleHover)
                        .frame(height: ChromeMenuLayout.rowHeight)
                        .offset(y: ChromeMenuLayout.highlightOffset(index: selection.highlightIndex,
                            groupStarts: items.indices.filter { items[$0].startsGroup }))
                        .opacity(selection.index == nil ? 0 : 1)
                        .animation(reduced || !selection.fromPointer ? nil : Look.feedback, value: selection.index)
                        // Only paint is replaced on keyboard handoff or policy changes;
                        // menu buttons, focus, and scroll ownership remain mounted.
                        .id(reduced || !selection.fromPointer)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: selection.index) { _, index in
                if let index { proxy.scrollTo(index) }
            }
        }
        .padding(ChromeMenuLayout.inset)
        .background(theme.bubble, in: .rect(cornerRadius: 10))
        .clipShape(.rect(cornerRadius: 10))
    }

    private func row(_ index: Int) -> some View {
        let item = items[index]
        return Button { choose(index) } label: {
            HStack(spacing: 8) {
                SpaceIcon(item.symbol).font(.system(size: 16, weight: .medium))
                    .frame(width: 20).accessibilityHidden(true)
                    .scaleEffect(selection.index == index && selection.fromPointer && !reduced ? 1.08 : 1)
                    .id(reduced || !selection.fromPointer)
                Text(item.title).font(.system(size: 13, weight: .medium))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if item.checked {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                        .accessibilityHidden(true)
                }
                if !item.shortcut.isEmpty {
                    Text(item.shortcut).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42)).accessibilityHidden(true)
                }
            }
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 10)
            .frame(height: ChromeMenuLayout.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(TactileButtonStyle(scales: false))
        .animation(reduced || !selection.fromPointer ? nil : Look.feedback, value: selection.index == index)
        .onHover { over in
            if over { selection.select(index, fromPointer: true) }
            else if selection.fromPointer && selection.index == index { selection.select(nil, fromPointer: true) }
        }
        .accessibilityLabel(item.title)
        .accessibilityValue(item.checked ? "Selected" : "")
        .accessibilityAddTraits(item.checked ? [.isSelected] : [])
    }
}

/// The policy gate is read outside interpolated progress so it can finish an
/// already-running entrance, even when the animation's target was already 1.
private struct ChromeMenuReveal: ViewModifier, Animatable {
    nonisolated var progress: Double
    let anchor: UnitPoint
    let reduced: Bool

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let progress = reduced ? 1 : progress
        content.scaleEffect(Look.appearScale + (1 - Look.appearScale) * progress, anchor: anchor)
            .opacity(progress)
    }
}

private struct ChromeMenuPointer: Shape {
    let x: CGFloat
    let below: Bool

    func path(in rect: CGRect) -> Path {
        Path { path in
            let base = below ? rect.minY : rect.maxY
            let tip = below ? rect.maxY : rect.minY
            path.move(to: CGPoint(x: x - 8, y: base))
            path.addLine(to: CGPoint(x: x, y: tip))
            path.addLine(to: CGPoint(x: x + 8, y: base))
            path.closeSubpath()
        }
    }
}

/// A noninteractive anchor lets the SwiftUI button retain its normal accessibility.
@MainActor final class ChromeMenuAnchor: ObservableObject {
    fileprivate var theme = SpaceChromeTheme() {
        didSet {
            if theme != oldValue { ChromeMenu.shared.refreshTheme(for: self) }
        }
    }
    fileprivate weak var view: NSView?
    @Published fileprivate(set) var isPresented = false

    func show(_ items: [ChromeMenuItem], above: Bool = false, title: String,
              showsPointer: Bool = false) {
        if isPresented {
            ChromeMenu.shared.dismiss()
            return
        }
        guard let view, let window = view.window else { return }
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        ChromeMenu.shared.show(items, in: window, anchor: rect, above: above, title: title,
                               source: self, showsPointer: showsPointer)
    }
}

struct ChromeMenuAnchorView: NSViewRepresentable {
    let anchor: ChromeMenuAnchor
    @Environment(\.spaceChromeTheme) private var theme
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view; anchor.theme = theme }
}
