import AppKit

/// WebKit's video stays in its native PiP panel, including its protected video layer.
/// A small non-activating panel sits above the system's remote controls while hovered.
///
/// PIPPanel and WebVideoViewContainer are WebKit/PIP implementation details. Discover
/// both defensively; an OS change must leave the ordinary native player intact.
@MainActor enum PiPMinimizeControls {
    @MainActor final class Attachment {
        weak var window: NSWindow?
        let panel: NSPanel
        private var tracking: Task<Void, Never>?

        init(window: NSWindow, tab: Tab) {
            self.window = window
            panel = ControlsPanel(tab: tab)
            tracking = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    guard let window = self.window, window.isVisible else {
                        self.panel.orderOut(nil)
                        return
                    }
                    self.update(pointer: NSEvent.mouseLocation)
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }

        func update(pointer: NSPoint) {
            guard let window, window.isVisible else {
                panel.orderOut(nil)
                return
            }
            // PIPPanel hosts a remotely rendered video; PIPAgent owns the visible window
            // and mouse events. A subview in that host is painted but cannot be clicked.
            let frame = window.frame
            let wanted = NSRect(x: frame.maxX - 84, y: frame.maxY - 40, width: 76, height: 34)
            if panel.frame != wanted { panel.setFrame(wanted, display: true) }
            if frame.contains(pointer) {
                if !panel.isVisible { panel.orderFrontRegardless() }
            } else if panel.isVisible {
                panel.orderOut(nil)
            }
        }

        func remove() {
            tracking?.cancel()
            tracking = nil
            panel.orderOut(nil)
            panel.close()
        }
    }
    private static var attachments: [UUID: Attachment] = [:]
    private static var before: [UUID: Set<ObjectIdentifier>] = [:]
    private static var pending: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]

    private static var panels: [NSWindow] {
        NSApp.windows.filter {
            NSStringFromClass(type(of: $0)) == "PIPPanel" && $0.isVisible
                && $0.contentView?.subviews.contains {
                    NSStringFromClass(type(of: $0)) == "WebVideoViewContainer"
                } == true
        }
    }

    static func prepare(for tab: Tab) {
        if !tab.pictureInPicture {
            before[tab.id] = Set(panels.map(ObjectIdentifier.init))
        }
    }

    static func install(for tab: Tab) {
        guard attachments[tab.id] == nil, pending[tab.id] == nil else { return }
        let token = UUID()
        let task = Task { @MainActor [weak tab] in
            guard let tab else { return }
            defer {
                if pending[tab.id]?.token == token { pending[tab.id] = nil; before[tab.id] = nil }
            }
            for _ in 0..<20 {
                guard !Task.isCancelled, tab.pictureInPicture else { return }
                let used = Set(attachments.values.compactMap(\.window).map(ObjectIdentifier.init))
                let candidates = panels.filter {
                    !used.contains(ObjectIdentifier($0))
                        && !(before[tab.id]?.contains(ObjectIdentifier($0)) ?? false)
                }
                // Never guess which of two simultaneous PiP entries owns a panel.
                if candidates.count == 1, let window = candidates.first {
                    attachments[tab.id] = Attachment(window: window, tab: tab)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        pending[tab.id] = (token, task)
    }

    static func remove(_ id: UUID) {
        pending.removeValue(forKey: id)?.task.cancel()
        before[id] = nil
        attachments.removeValue(forKey: id)?.remove()
    }

    private final class ControlsPanel: NSPanel {
        init(tab: Tab) {
            super.init(contentRect: NSRect(x: 0, y: 0, width: 76, height: 34),
                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            isReleasedWhenClosed = false
            isOpaque = false
            backgroundColor = .clear
            hasShadow = false
            hidesOnDeactivate = false
            // The system PiP chrome is at the utility-window level, above floating panels.
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.utilityWindow)) + 1)
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 76, height: 34))
            contentView = content
            let minimize = ControlButton(symbol: "minus", identifier: "vane.pip.minimize",
                                         label: "Minimize Picture in Picture — keep playing") { [weak tab] in
                guard let tab else { return }
                MediaState.shared.minimize(tab)
            }
            let restore = ControlButton(symbol: "pip.exit", identifier: "vane.pip.restore",
                                        label: "Return Picture in Picture to Tab") { [weak tab] in
                guard let tab else { return }
                PictureInPicture.minimize(tab) { [weak tab] ok in
                    guard ok, let tab else { return }
                    // Minimize suppressed auto-PiP in the page. Returning to an already
                    // selected tab does not produce a selection change to clear it.
                    PictureInPicture.exitIfAuto(tab)
                    MediaState.shared.returned(to: tab)
                    PictureInPicture.returnToTab(tab)
                }
            }
            for (button, x) in [(minimize, CGFloat(0)), (restore, CGFloat(42))] {
                let glass = NSGlassEffectView(frame: NSRect(x: x, y: 0, width: 34, height: 34))
                glass.cornerRadius = 17
                glass.style = .regular
                glass.appearance = NSAppearance(named: .darkAqua)
                button.frame = glass.bounds
                glass.contentView = button
                content.addSubview(glass)
            }
        }

        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class ControlButton: NSButton {
        private let clickedAction: () -> Void

        init(symbol: String, identifier: String, label: String, action: @escaping () -> Void) {
            clickedAction = action
            super.init(frame: .zero)
            self.identifier = NSUserInterfaceItemIdentifier(identifier)
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            imagePosition = .imageOnly
            isBordered = false
            contentTintColor = .white
            toolTip = label
            setAccessibilityLabel(label)
            target = self
            self.action = #selector(clicked)
        }

        required init?(coder: NSCoder) { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        @objc private func clicked() { clickedAction() }
    }
}
