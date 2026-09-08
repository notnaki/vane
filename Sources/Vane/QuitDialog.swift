import SwiftUI

/// Arc's "Quit Arc?": a card over the window with the app's icon, the question, and three
/// answers — Quit (⏎), Cancel (⎋), and Quit without being asked again. It replaces the
/// hold-⌘Q toast, which asked for a gesture nobody could see and quit on a clock nobody
/// could trust; a question with a default button is answered by the same ⌘Q-then-⏎ people
/// already do, and cannot be missed.
///
/// ponytail: one modal borderless panel run with `runModal`, so the answer comes back as a
/// value and `applicationShouldTerminate` stays a straight line. No sheet: a sheet hangs off
/// a title bar and Vane's windows have none to hang it from.
@MainActor enum QuitDialog {
    enum Answer { case quit, quitForever, cancel }

    static func ask(over host: NSWindow?) -> Answer {
        var answer = Answer.cancel
        let panel = Panel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: Card { answer = $0; NSApp.stopModal() })
        panel.setContentSize(panel.contentView!.fittingSize)
        // Centred over the window that asked, or the screen when none did (the Dock's menu).
        let anchor = host?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: anchor.midX - panel.frame.width / 2,
                                     y: anchor.midY - panel.frame.height / 2))
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return answer
    }

    /// Borderless windows refuse key status by default, and a dialog that cannot take ⏎
    /// and ⎋ is a picture of a dialog.
    private final class Panel: NSWindow {
        override var canBecomeKey: Bool { true }
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
            .frame(width: Look.quitDialogWidth)
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
