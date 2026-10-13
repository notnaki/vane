import AppKit
import SwiftUI
import QuartzCore

/// An owned child panel keeps a hover passive and allows a keyboard-opened card to
/// become key. SwiftUI's transient popover otherwise dismisses on focus traversal.
struct FavouritePreviewPanel: NSViewRepresentable {
    let visible: Bool
    let keyboard: Bool
    let content: AnyView
    let dismiss: @MainActor () -> Void

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.configure(visible: visible, keyboard: keyboard, content: content, dismiss: dismiss)
    }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.hide() }

    final class Panel: NSPanel {
        var interactive = true
        override var canBecomeKey: Bool { interactive }
        override var canBecomeMain: Bool { false }
        override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.12 }
    }

    final class Anchor: NSView {
        private var panel: Panel?
        private var host: NSHostingView<AnyView>?
        private var visible = false
        private var keyboard = false
        private var focusPending = false
        private var content = AnyView(EmptyView())
        private var dismiss: (@MainActor () -> Void)?
        private var outsideMonitor: Any?
        private var deactivation: NSObjectProtocol?
        private var dismissal: Task<Void, Never>?
        private var targetFrame: NSRect?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { hide() } else { updatePanel() }
        }
        func configure(visible: Bool, keyboard: Bool, content: AnyView, dismiss: @escaping @MainActor () -> Void) {
            if keyboard && !self.keyboard { focusPending = true }
            self.visible = visible; self.keyboard = keyboard; self.content = content; self.dismiss = dismiss
            updatePanel()
        }
        private func updatePanel() {
            guard visible else { dismissPanel(); return }
            guard let owner = window, let screen = owner.screen else { hide(); return }
            // Retire a departing panel before reopening. Its completion cannot touch the new one.
            if dismissal != nil { hide() }
            let isNew = panel == nil
            let panel = panel ?? Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            if isNew {
                panel.title = "Favourite Preview"
                panel.animationBehavior = .none
                panel.isRestorable = false
                panel.collectionBehavior = [.transient, .ignoresCycle]
                panel.isReleasedWhenClosed = false
                panel.isFloatingPanel = false
                panel.hidesOnDeactivate = true
                panel.hasShadow = true
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.isExcludedFromWindowsMenu = true
                let host = NSHostingView(rootView: AnyView(content.clipShape(RoundedRectangle(cornerRadius: 16))))
                self.host = host; panel.contentView = host; self.panel = panel
                owner.addChildWindow(panel, ordered: .above)
                outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                    MainActor.assumeIsolated {
                        guard let self, let panel = self.panel else { return }
                        if event.window !== panel, event.window !== self.window { self.dismiss?() }
                        else if event.window === self.window,
                                !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.dismiss?() }
                    }
                    return event
                }
                deactivation = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                    object: nil, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.dismiss?() }
                    }
            } else { host?.rootView = AnyView(content.clipShape(RoundedRectangle(cornerRadius: 16))) }
            guard let host else { return }
            host.layoutSubtreeIfNeeded()
            let size = NSSize(width: 370, height: max(150, min(host.fittingSize.height, screen.visibleFrame.height - 24)))
            let tile = owner.convertToScreen(convert(bounds, to: nil))
            let ground = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            let preferredX = tile.maxX + 8
            let x = min(max(preferredX, ground.minX), ground.maxX - size.width)
            let y = min(max(tile.maxY - size.height, ground.minY), ground.maxY - size.height)
            let frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
            // Metadata updates must not snap an in-progress anchored arrival to its end.
            if targetFrame != frame || Motion.reduced { panel.setFrame(frame, display: true) }
            targetFrame = frame
            if Motion.reduced { panel.alphaValue = 1 }
            if isNew && !Motion.reduced {
                panel.alphaValue = 0
                panel.setFrameOrigin(NSPoint(x: x - 4, y: y))
            }
            panel.orderFront(nil)
            if isNew && !Motion.reduced {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1
                    panel.animator().setFrame(frame, display: true)
                }
            }
            if keyboard && (isNew || focusPending) {
                panel.makeKey()
                panel.makeFirstResponder(host)
                focusPending = false
            }
        }
        private func dismissPanel() {
            guard let panel else { return }
            guard !Motion.reduced, window != nil else { hide(); return }
            guard dismissal == nil else { return }
            // The fading surface is visual only. Return key ownership immediately, before
            // Open Site can focus its destination, and remove all interactive affordances.
            panel.interactive = false
            panel.ignoresMouseEvents = true
            host?.setAccessibilityHidden(true)
            if panel.isKeyWindow { panel.parent?.makeKey() }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
                panel.animator().setFrameOrigin(NSPoint(x: panel.frame.minX - 4, y: panel.frame.minY))
            }
            dismissal = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
                self?.hide()
            }
        }
        func hide() {
            dismissal?.cancel(); dismissal = nil
            if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }; outsideMonitor = nil
            if let deactivation { NotificationCenter.default.removeObserver(deactivation) }; deactivation = nil
            if let panel {
                let owner = panel.parent
                let restoreKey = panel.isKeyWindow
                owner?.removeChildWindow(panel)
                panel.orderOut(nil); panel.contentView = nil; panel.close()
                if restoreKey { owner?.makeKey() }
            }
            panel = nil; host = nil; targetFrame = nil
        }
    }
}
