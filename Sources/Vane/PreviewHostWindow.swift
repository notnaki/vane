import AppKit

/// WebKit needs an ordered host to render previews. Offscreen placement alone is
/// insufficient: macOS can relocate windows when the display arrangement changes.
@MainActor final class PreviewHostWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(content: NSView) {
        super.init(contentRect: content.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isRestorable = false
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.transient, .ignoresCycle]
        hidesOnDeactivate = false
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        alphaValue = 0
        ignoresMouseEvents = true
        contentView = content
        setFrameOrigin(NSPoint(x: -12_000, y: -12_000))
        orderFront(nil)
    }
}
