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

    /// Whether the question is on screen right now. `applicationShouldTerminate` asks this
    /// before anything else, because every other way out of it ends in a terminate — see
    /// `QuitAsk.refuses`.
    private(set) static var isUp = false

    static func ask(over host: NSWindow?) -> Answer {
        isUp = true
        defer { isUp = false }
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
        // On the view *around* the content view, not inside it. The content view is a
        // SwiftUI hosting view, and SwiftUI keeps its own drawing above any AppKit subview
        // added to it, so a scrim parented there sits behind the page it is meant to cover
        // and nothing of the question is ever seen. The traffic-light overlay hangs off an
        // AppKit superview for the same reason; see `VaneWindow.dressTrafficLights`.
        let over = content.superview ?? content
        let scrim = Scrim(frame: over.bounds, showing: blurred(over))
        scrim.answer = { answer = $0; NSApp.stopModal() }
        // Weak for the same reason as the panel's: scrim → hosting view → card → closure.
        let card = NSHostingView(rootView: Card { [weak scrim] in scrim?.answer?($0) })
        card.translatesAutoresizingMaskIntoConstraints = false
        scrim.addSubview(card)
        NSLayoutConstraint.activate([card.centerXAnchor.constraint(equalTo: scrim.centerXAnchor),
                                     card.centerYAnchor.constraint(equalTo: scrim.centerYAnchor)])
        let was = host.firstResponder
        over.addSubview(scrim, positioned: .above, relativeTo: nil)
        NSApp.activate()
        host.makeKeyAndOrderFront(nil)
        host.makeFirstResponder(scrim)
        NSApp.runModal(for: host)
        scrim.removeFromSuperview()
        scrim.answer = nil
        host.makeFirstResponder(was)
        return answer
    }

    /// A picture of the window, blurred and dimmed, taken the moment the question is asked.
    ///
    /// This used to be a `CIGaussianBlur` in the layer's `backgroundFilters`, which dimmed
    /// the page but never blurred it: a background filter samples the layers this process
    /// composites, and a page is drawn by WebKit's own, out of process. A bitmap of the
    /// content view does include the page, so the blur is of a still rather than of a live
    /// layer — which is all a modal needs, since nothing under it can move.
    ///
    /// Taken once, at `Look.quitBlurScale` smaller than the window, because the blur hides
    /// everything that shrinking loses. `Look.quitBlur` is the radius, in points, which a
    /// material would not let us choose. Nothing to photograph (an off-screen window, a
    /// window the backing store cannot give up) leaves it dimmed but sharp, as it was.
    private static func blurred(_ content: NSView) -> CGImage? {
        guard content.bounds.width > 0, content.bounds.height > 0,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        else { return nil }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let shot = rep.cgImage else { return nil }
        // One unit of the shrunken picture is `Look.quitBlurScale` points of the window,
        // whatever the screen's backing scale, so the radius below stays in points.
        let shrink = content.bounds.width / CGFloat(shot.width) / Look.quitBlurScale
        let small = CIImage(cgImage: shot).transformed(by: .init(scaleX: shrink, y: shrink))
        // Clamped first, or the blur drags transparency in from past the edges and the
        // scrim fades out at its border; cropped after, because a clamped image is endless.
        let blur = small.clampedToExtent()
            .applyingGaussianBlur(sigma: Look.quitBlur / Look.quitBlurScale)
            .cropped(to: small.extent)
        // The dim is painted into the picture, which leaves the scrim's own background
        // colour standing as exactly the old, dim-only scrim for when there is no picture.
        let dimmed = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: Look.quitScrim))
            .cropped(to: blur.extent).composited(over: blur)
        return CIContext().createCGImage(dimmed, from: dimmed.extent)
    }

    /// The layer over the page: the blurred picture where there is one, and the dim alone
    /// where there is not.
    private final class Scrim: NSView {
        var answer: ((Answer) -> Void)?

        init(frame: NSRect, showing picture: CGImage?) {
            super.init(frame: frame)
            autoresizingMask = [.width, .height]
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.withAlphaComponent(Look.quitScrim).cgColor
            layer?.contents = picture           // nil leaves the dim alone, as it was
            layer?.contentsGravity = .resize
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
