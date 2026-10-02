import AppKit

/// WebKit's video stays in its native PiP panel, including its protected video layer.
/// Only a small AppKit control is added to that panel's local content view.
///
/// PIPPanel and WebVideoViewContainer are WebKit/PIP implementation details. Discover
/// both defensively; an OS change must leave the ordinary native player intact.
@MainActor enum PiPMinimizeControls {
    private struct Attachment {
        weak var window: NSWindow?
        let control: MinimizeButton
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
                if candidates.count == 1, let window = candidates.first, let content = window.contentView {
                    let control = MinimizeButton { [weak tab] in
                        guard let tab else { return }
                        MediaState.shared.minimize(tab)
                    }
                    // Keep WebKit's legacy frame layout intact. Introducing Auto Layout
                    // here freezes the video container at its opening size during resizing.
                    control.frame = NSRect(x: content.bounds.maxX - 84,
                                           y: content.isFlipped ? 12 : content.bounds.maxY - 40,
                                           width: 28, height: 28)
                    control.autoresizingMask = [.minXMargin, content.isFlipped ? .maxYMargin : .minYMargin]
                    content.addSubview(control)
                    attachments[tab.id] = Attachment(window: window, control: control)
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
        attachments.removeValue(forKey: id)?.control.removeFromSuperview()
    }

    private final class MinimizeButton: NSButton {
        private let minimize: () -> Void

        init(_ minimize: @escaping () -> Void) {
            self.minimize = minimize
            super.init(frame: .zero)
            identifier = NSUserInterfaceItemIdentifier("vane.pip.minimize")
            image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Minimize Picture in Picture")
            imagePosition = .imageOnly
            isBordered = false
            contentTintColor = .white
            wantsLayer = true
            layer?.cornerRadius = 14
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
            toolTip = "Minimize Picture in Picture — keep playing"
            setAccessibilityLabel("Minimize Picture in Picture")
            target = self
            action = #selector(clicked)
        }

        required init?(coder: NSCoder) { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        @objc private func clicked() { minimize() }
    }
}
