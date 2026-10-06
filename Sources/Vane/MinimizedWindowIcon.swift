import AppKit
import WebKit

/// macOS can keep the shipped icon in native minimized-window badges even after the
/// application icon changes. A window tile with a custom view suppresses that native
/// badge, so draw the selected finish alongside a snapshot of the window instead.
@MainActor enum MinimizedWindowIcon {
    private final class Entry {
        weak var window: NSWindow?
        let preview: Preview
        var pages: [ObjectIdentifier: Page] = [:]
        var protected = false
        init(window: NSWindow, preview: Preview) {
            self.window = window
            self.preview = preview
        }
    }

    private final class Page {
        weak var web: WKWebView?
        let rect: NSRect
        let image: NSImage
        init(web: WKWebView, rect: NSRect, image: NSImage) {
            self.web = web
            self.rect = rect
            self.image = image
        }
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]
    private static var observers: [NSObjectProtocol] = []
    private static var icon: NSImage?

    static func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willMiniaturizeNotification,
                                            object: nil, queue: .main) { notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                capture(window)
                update(window)
            }
        })
        observers.append(center.addObserver(forName: NSWindow.didMiniaturizeNotification,
                                            object: nil, queue: .main) { notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated { update(window) }
        })
        for name in [NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { notification in
                guard let window = notification.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    guard let entry = entries.removeValue(forKey: ObjectIdentifier(window)) else { return }
                    if entry.protected { window.miniwindowImage = nil }
                    if window.dockTile.contentView === entry.preview {
                        window.dockTile.contentView = nil
                        window.dockTile.display()
                    }
                }
            })
        }
    }

    static func apply(_ image: NSImage?) {
        start()
        icon = image
        for window in NSApp.windows where window.isMiniaturized {
            if entries[ObjectIdentifier(window)] == nil { capture(window) }
            update(window)
        }
    }

    /// Replace every retained pixel and reject in-flight WebKit snapshot replies.
    static func protect(_ window: NSWindow) {
        guard let entry = entries[ObjectIdentifier(window)] else { return }
        entry.protected = true
        entry.pages.removeAll()
        let image = NSImage(size: NSSize(width: 320, height: 200))
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: 320, height: 200).fill()
        if let symbol = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil) {
            symbol.draw(in: NSRect(x: 142, y: 78, width: 36, height: 44))
        }
        image.unlockFocus()
        entry.preview.thumbnail = image
        window.miniwindowImage = image
        update(window)
    }

    private static func capture(_ window: NSWindow) {
        let tile = window.dockTile
        guard !(window is NSPanel), tile.showsApplicationBadge, tile.contentView == nil,
              let view = window.contentView?.superview,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        guard let thumbnail = thumbnail(view, rep: rep) else { return }
        let preview = Preview(frame: NSRect(origin: .zero, size: tile.size),
                              thumbnail: window.miniwindowImage ?? thumbnail)
        entries[ObjectIdentifier(window)] = Entry(window: window, preview: preview)
        if window.miniwindowImage == nil {
            capturePages(in: view, root: view, window: window, preview: preview)
        }
    }

    private static func thumbnail(_ view: NSView, rep: NSBitmapImageRep) -> NSImage? {
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let shot = rep.cgImage else { return nil }
        // Retain only a Dock-sized snapshot, rather than a full Retina window bitmap.
        let scale = min(1, 512 / CGFloat(shot.width))
        let width = max(1, Int(CGFloat(shot.width) * scale))
        let height = max(1, Int(CGFloat(shot.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(shot, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return nil }
        return NSImage(cgImage: small, size: view.bounds.size)
    }

    /// AppKit's cached display can omit WebKit's remote surface. Substitute its pixels
    /// only while taking the thumbnail, so AppKit keeps foreground views and clipping.
    private static func capturePages(in view: NSView, root: NSView, window: NSWindow, preview: Preview) {
        guard !view.isHidden else { return }
        if let web = view as? WKWebView {
            let rect = root.convert(web.visibleRect, from: web).intersection(root.bounds)
            guard !rect.isEmpty else { return }
            let pageRect = web.convert(rect, from: root)
            let configuration = WKSnapshotConfiguration()
            configuration.rect = pageRect
            configuration.snapshotWidth = NSNumber(value: Double(512 * rect.width / root.bounds.width))
            configuration.afterScreenUpdates = false
            web.takeSnapshot(with: configuration) { [weak window, weak web, weak root, weak preview] image, _ in
                guard let image, let window, let web, let root, let preview,
                      web.window === window,
                      let entry = entries[ObjectIdentifier(window)], entry.preview === preview, !entry.protected else { return }
                entry.pages[ObjectIdentifier(web)] = Page(web: web, rect: pageRect, image: image)
                compose(entry, root: root, window: window)
            }
            return
        }
        for child in view.subviews { capturePages(in: child, root: root, window: window, preview: preview) }
    }

    private static func compose(_ entry: Entry, root: NSView, window: NSWindow) {
        var substitutes: [NSImageView] = []
        // Add, capture, and remove in one synchronous turn without committing a layer
        // transaction or processing input, so these views never reach the live page.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer {
            substitutes.forEach { $0.removeFromSuperview() }
            CATransaction.commit()
        }
        for page in entry.pages.values {
            guard let web = page.web, web.window === window, !web.isHidden else { continue }
            let substitute = NSImageView(frame: page.rect)
            substitute.image = page.image
            substitute.imageScaling = .scaleAxesIndependently
            substitute.setAccessibilityElement(false)
            web.addSubview(substitute)
            substitutes.append(substitute)
        }
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds),
              let image = thumbnail(root, rep: rep) else { return }
        entry.preview.thumbnail = image
        if window.dockTile.contentView === entry.preview { window.dockTile.display() }
    }

    private static func update(_ window: NSWindow) {
        guard let entry = entries[ObjectIdentifier(window)], entry.window === window else { return }
        let tile = window.dockTile
        guard tile.contentView == nil || tile.contentView === entry.preview else { return }
        if let icon, tile.showsApplicationBadge {
            entry.preview.icon = icon
            tile.contentView = entry.preview
        } else if tile.contentView === entry.preview {
            tile.contentView = nil
        }
        tile.display()
    }

    private final class Preview: NSView {
        var thumbnail: NSImage
        var icon: NSImage?

        init(frame: NSRect, thumbnail: NSImage) {
            self.thumbnail = thumbnail
            super.init(frame: frame)
            autoresizingMask = [.width, .height]
        }
        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            guard thumbnail.size.width > 0, thumbnail.size.height > 0 else { return }
            NSColor.clear.setFill()
            bounds.fill(using: .copy)
            let scale = min(bounds.width / thumbnail.size.width, bounds.height / thumbnail.size.height)
            let size = NSSize(width: thumbnail.size.width * scale, height: thumbnail.size.height * scale)
            let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                              width: size.width, height: size.height)
            thumbnail.draw(in: rect)
            // Icon plates include transparent margins. A 40% plate leaves the
            // visible badge near one third of the tile, matching native Dock badges.
            let badge = min(bounds.width, bounds.height) * 0.40
            icon?.draw(in: NSRect(x: bounds.maxX - badge, y: bounds.minY, width: badge, height: badge))
        }
    }
}
