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
    static let width: CGFloat = 264
    static let rowHeight: CGFloat = 44
    static let inset: CGFloat = 8
    static let groupHeight: CGFloat = 17

    /// Prefer the requested edge, flip when necessary, and stay inside the visible screen.
    static func frame(anchor: CGRect, size: CGSize, screen: CGRect, above: Bool) -> CGRect {
        let safe = screen.insetBy(dx: 8, dy: 8)
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
    @Published var index: Int?
}

/// One transient panel at a time. Every exit removes monitors and releases its actions.
@MainActor final class ChromeMenu {
    static let shared = ChromeMenu()
    private var panel: NSPanel?
    private weak var owner: NSWindow?
    private var items: [ChromeMenuItem] = []
    private var selection = ChromeMenuSelection()
    private var typeahead = ChromeMenuTypeahead()
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    func show(_ items: [ChromeMenuItem], in owner: NSWindow, anchor: CGRect,
              above: Bool = false, title: String) {
        dismiss()
        guard !items.isEmpty, let screen = owner.screen ?? NSScreen.main else { return }
        self.items = items
        self.owner = owner
        selection = ChromeMenuSelection()
        typeahead = ChromeMenuTypeahead()
        let size = CGSize(width: ChromeMenuLayout.width,
                          height: CGFloat(items.count) * ChromeMenuLayout.rowHeight
                            + CGFloat(items.filter(\.startsGroup).count) * ChromeMenuLayout.groupHeight
                            + ChromeMenuLayout.inset * 2)
        let frame = ChromeMenuLayout.frame(anchor: anchor, size: size,
                                           screen: screen.visibleFrame, above: above)
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
            items: items, selection: selection, title: title, choose: { [weak self] in self?.choose($0) }))
        self.panel = panel
        owner.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: {
            [weak self, weak panel] event in
            if event.window !== panel { self?.dismiss() }
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

    private func watch(_ name: Notification.Name, object: AnyObject?) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object,
            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
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
            selection.index = selection.index.map {
                ($0 + (backwards ? -1 : 1) + items.count) % items.count
            } ?? first
        case 36, 76:
            choose(selection.index ?? 0)
        case 49 where !typeahead.isActive(at: event.timestamp):
            choose(selection.index ?? 0)
        default:
            guard let text = event.characters, !text.isEmpty else { return false }
            guard text.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
            }) else { return false }
            selection.index = typeahead.match(text, at: event.timestamp,
                                              titles: items.map(\.title), current: selection.index)
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
    @ObservedObject var selection: ChromeMenuSelection
    let title: String
    let choose: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items.indices, id: \.self) { index in
                        if items[index].startsGroup {
                            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .accessibilityHidden(true)
                        }
                        row(index).id(index)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: selection.index) { _, index in
                if let index { proxy.scrollTo(index) }
            }
        }
        .padding(ChromeMenuLayout.inset)
        .background(Color(red: 0.055, green: 0.055, blue: 0.06),
                    in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.09), lineWidth: 1) }
        .clipShape(.rect(cornerRadius: 16))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func row(_ index: Int) -> some View {
        let item = items[index]
        return Button { choose(index) } label: {
            HStack(spacing: 12) {
                Image(systemName: item.symbol).font(.system(size: 19, weight: .medium))
                    .frame(width: 24).accessibilityHidden(true)
                Text(item.title).font(.system(size: 14, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if item.checked {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                        .accessibilityHidden(true)
                }
                if !item.shortcut.isEmpty {
                    Text(item.shortcut).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42)).accessibilityHidden(true)
                }
            }
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 12)
            .frame(height: ChromeMenuLayout.rowHeight)
            .contentShape(.rect)
            .background(selection.index == index ? .white.opacity(0.10) : .clear,
                        in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { over in
            if over { selection.index = index }
            else if selection.index == index { selection.index = nil }
        }
        .accessibilityLabel(item.title)
        .accessibilityValue(item.checked ? "Selected" : "")
        .accessibilityAddTraits(item.checked ? [.isSelected] : [])
    }
}

/// A noninteractive anchor lets the SwiftUI button retain its normal accessibility.
@MainActor final class ChromeMenuAnchor: ObservableObject {
    fileprivate weak var view: NSView?
    func show(_ items: [ChromeMenuItem], above: Bool = false, title: String) {
        guard let view, let window = view.window else { return }
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        ChromeMenu.shared.show(items, in: window, anchor: rect, above: above, title: title)
    }
}

struct ChromeMenuAnchorView: NSViewRepresentable {
    let anchor: ChromeMenuAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}
