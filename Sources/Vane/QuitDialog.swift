import SwiftUI

/// Arc's "Quit Arc?": a card over the window with the app's icon, the question, and three
/// answers — Quit (⏎), Cancel (⎋), and Quit without being asked again. It replaces the
/// hold-⌘Q toast, which asked for a gesture nobody could see and quit on a clock nobody
/// could trust; a question with a default button is answered by the same ⌘Q-then-⏎ people
/// already do, and cannot be missed.
///
/// The card sits *in* the window that asked, on a scrim that dims the page and blurs it a
/// little — Arc's own treatment — so the question reads as part of the window rather than a
/// second one floating over it. No sheet: a sheet hangs off a title bar and Vane's windows
/// have none to hang it from. When no window is up (the Dock's menu with everything closed)
/// a plain borderless panel stands in.
///
/// ponytail: `runModal(for:)` on the host window, so the answer comes back as a value and
/// `applicationShouldTerminate` stays a straight line. The scrim swallows every click and
/// key that is not one of the three answers.
@MainActor enum QuitDialog {
    enum Answer { case quit, quitForever, cancel }

    static func ask(over host: NSWindow?) -> Answer {
        if let host, let content = host.contentView { return ask(in: host, content: content) }
        var answer = Answer.cancel
        let panel = Panel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "Quit Vane?"            // what VoiceOver says when the card takes key
        panel.answer = { answer = $0; NSApp.stopModal() }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        // Weak: the card lives inside the panel, so a strong capture here would be a cycle
        // (panel → hosting view → card → closure → panel) and every Cancel would strand a
        // window for the life of the process.
        panel.contentView = NSHostingView(rootView: Card { [weak panel] in panel?.answer?($0) })
        panel.setContentSize(panel.contentView!.fittingSize)
        // Centred over the window that asked, or the screen when none did (the Dock's menu).
        let anchor = host?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: anchor.midX - panel.frame.width / 2,
                                     y: anchor.midY - panel.frame.height / 2))
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        panel.answer = nil
        return answer
    }

    private static func ask(in host: NSWindow, content: NSView) -> Answer {
        var answer = Answer.cancel
        let scrim = Scrim(frame: content.bounds)
        scrim.answer = { answer = $0; NSApp.stopModal() }
        // Weak for the same reason as the panel's: scrim → hosting view → card → closure.
        let card = NSHostingView(rootView: Card { [weak scrim] in scrim?.answer?($0) })
        card.translatesAutoresizingMaskIntoConstraints = false
        scrim.addSubview(card)
        NSLayoutConstraint.activate([card.centerXAnchor.constraint(equalTo: scrim.centerXAnchor),
                                     card.centerYAnchor.constraint(equalTo: scrim.centerYAnchor)])
        let was = host.firstResponder
        content.addSubview(scrim)
        NSApp.activate()
        host.makeKeyAndOrderFront(nil)
        host.makeFirstResponder(scrim)
        NSApp.runModal(for: host)
        scrim.removeFromSuperview()
        scrim.answer = nil
        host.makeFirstResponder(was)
        return answer
    }

    /// The dimmed, faintly blurred layer over the page. Layer-backed so it can carry a
    /// Core Image background filter — the blur is of what the window draws under it, and
    /// `Look.quitBlur` is its radius, which a material would not let us choose.
    private final class Scrim: NSView {
        var answer: ((Answer) -> Void)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            autoresizingMask = [.width, .height]
            wantsLayer = true
            layerUsesCoreImageFilters = true
            layer?.backgroundColor = NSColor.black.withAlphaComponent(Look.quitScrim).cgColor
            if let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(Look.quitBlur, forKey: kCIInputRadiusKey)
                layer?.backgroundFilters = [blur]
            }
            setAccessibilityElement(true)
            setAccessibilityRole(.sheet)
            setAccessibilityLabel("Quit Vane?")
        }
        required init?(coder: NSCoder) { fatalError() }

        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) {}      // the page under it is not there
        override func cancelOperation(_ sender: Any?) { answer?(.cancel) }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 36, 76: answer?(.quit)          // return, enter
            case 53: answer?(.cancel)            // escape
            default: break
            }
        }
    }

    /// Borderless windows refuse key status by default, and a dialog that cannot take ⏎
    /// and ⎋ is a picture of a dialog. The two keys are answered here as well as by the
    /// buttons' own shortcuts, so the card can always be left from the keyboard even if
    /// SwiftUI's key-equivalent routing inside a modal borderless window ever does not fire.
    private final class Panel: NSWindow {
        var answer: ((Answer) -> Void)?
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { answer?(.cancel) }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 36, 76: answer?(.quit)          // return, enter
            case 53: answer?(.cancel)            // escape
            default: super.keyDown(with: event)
            }
        }
    }

    private struct Card: View {
        let answer: (Answer) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: Look.inset * 2) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: Look.quitDialogIcon, height: Look.quitDialogIcon)
                Text("Quit Vane?").font(Look.heading.weight(.bold)).foregroundStyle(Look.inkPrimary)
                HStack(spacing: Look.inset) {
                    Choice("Quit, and don’t ask again") { answer(.quitForever) }
                    Spacer(minLength: Look.inset)
                    Choice("Cancel", key: "ESC") { answer(.cancel) }
                        .keyboardShortcut(.cancelAction)
                    Choice("Quit", key: "⏎", primary: true) { answer(.quit) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(Look.paneMargin)
            .frame(minWidth: Look.quitDialogWidth)
            .fixedSize()
            .background(Look.panelFill, in: .rect(cornerRadius: Look.cardRadius * 2))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Quit Vane?")
        }
    }

    /// A button in the card: its title and, where a key answers it, that key as a small
    /// badge — the way Arc prints ESC and ⏎ on its own.
    private struct Choice: View {
        let title: String
        var key: String? = nil
        var primary = false
        let action: () -> Void

        init(_ title: String, key: String? = nil, primary: Bool = false, action: @escaping () -> Void) {
            self.title = title; self.key = key; self.primary = primary; self.action = action
        }

        var body: some View {
            Button(action: action) {
                HStack(spacing: Look.inset) {
                    Text(title).font(Look.text)
                    if let key {
                        Text(key).font(Look.footnote.weight(.semibold))
                            .padding(.horizontal, Look.inset / 2).padding(.vertical, 1)
                            .background(Look.ink(0.12), in: .rect(cornerRadius: Look.cardRadius - 2))
                            .accessibilityHidden(true)   // the button's own shortcut says it
                    }
                }
                .padding(.horizontal, Look.inset * 2).padding(.vertical, Look.inset)
                .frame(minHeight: Look.control + Look.inset)
                .background(primary ? Color.accentColor : Look.selected,
                            in: .rect(cornerRadius: Look.cardRadius))
                .foregroundStyle(primary ? Color.white : Look.inkPrimary)
            }
            .buttonStyle(.plain)
        }
    }
}
