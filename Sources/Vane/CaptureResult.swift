import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// A transient result lives above its source page, with actions beside the selected region.
/// Copy, PNG export, sharing and Easels reuse the same captured pixels.
@MainActor final class CaptureResultController {
    private let image: NSImage
    private let png: Data
    private let title: String
    private let source: URL?
    private weak var window: NSWindow?
    private weak var store: TabStore?
    private weak var tab: Tab?
    private weak var previousResponder: NSResponder?
    private let overlay = CaptureResultOverlay(frame: .zero)
    private let state = CaptureResultState()
    private var picker: NSSharingServicePicker?
    private var savePanel: NSSavePanel?
    private weak var editorPanel: NSWindow?
    private var subscriptions: Set<AnyCancellable> = []
    private var observations: [NSKeyValueObservation] = []
    private var boards: [EaselBoard] = []
    private var live = true

    init(image: NSImage, png: Data, title: String, source: URL?, window: NSWindow,
         store: TabStore?, tab: Tab?, region: CGRect?) {
        self.image = image; self.png = png; self.title = title; self.source = source
        self.window = window; self.store = store; self.tab = tab
        previousResponder = window.firstResponder
        overlay.image = image
        overlay.region = region
    }

    func begin() {
        guard let window,
              let parent = (tab?.existingWeb as NSView?) ?? window.contentView?.superview ?? window.contentView else {
            close(); return
        }
        overlay.frame = parent.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.cancel = { [weak self] in self?.close() }
        overlay.copyCapture = { [weak self] in self?.perform(.copy) }
        overlay.saveCapture = { [weak self] in self?.perform(.save) }
        overlay.editCapture = { [weak self] in self?.perform(.edit) }
        parent.addSubview(overlay, positioned: .above, relativeTo: nil)
        updateMenu()
        if let store {
            store.$profileVisible.sink { [weak self] visible in
                if !visible { self?.close() }
            }.store(in: &subscriptions)
            ProfileManager.shared.$profiles.dropFirst().sink { [weak self] profiles in
                guard let self, self.store?.isPrivate == false else { return }
                if !profiles.contains(where: { $0.id == store.profileID }) { self.close() }
            }.store(in: &subscriptions)
        }
        guard live else { return }
        window.makeFirstResponder(overlay)
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
            .sink { [weak self] _ in self?.close() }.store(in: &subscriptions)
        if let tab, let web = tab.existingWeb {
            observations = [
                web.observe(\.isLoading) { [weak self] web, _ in
                    MainActor.assumeIsolated { if web.isLoading { self?.close() } }
                },
                web.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.close() } },
                web.observe(\.pageZoom) { [weak self] _, _ in MainActor.assumeIsolated { self?.close() } },
            ]
            store?.$current.sink { [weak self] id in
                if id != tab.id { self?.close() }
            }.store(in: &subscriptions)
            store?.$tabs.sink { [weak self] tabs in
                if !tabs.contains(where: { $0 === tab }) { self?.close() }
            }.store(in: &subscriptions)
        }
        if canAddToEasel, let store {
            let repository = EaselStore.shared(profileID: store.profileID, directory: Store.directory)
            Task { [weak self] in
                await repository.waitUntilReady()
                guard let self, self.live else { return }
                self.boards = repository.boards
                self.updateMenu()
            }
        }
        NSAccessibility.post(element: overlay, notification: .announcementRequested,
            userInfo: [.announcement: "Capture ready. Copy, save, share, or retake. Escape closes.",
                       .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private var canAddToEasel: Bool {
        guard let store, !store.isPrivate, !store.isLittle, let source else { return false }
        return EaselItem.webURL(source.absoluteString) != nil
    }

    private func updateMenu() {
        let theme = store.map { SpaceChromeTheme(space: $0.chromeSpace, fallback: $0.profile.colorHex) } ?? SpaceChromeTheme()
        let view = CaptureActionMenu(state: state, canRetake: tab != nil,
            canSaveToLibrary: store.map { !$0.isPrivate } ?? false, canAddToEasel: canAddToEasel, boards: boards, theme: theme,
            perform: { [weak self] in self?.perform($0) }, close: { [weak self] in self?.close() })
        let host = CaptureMenuHostingView(rootView: view)
        host.sizingOptions = [.intrinsicContentSize]
        overlay.resultState = state
        overlay.showMenu(host)
    }

    private func perform(_ action: CaptureOutputAction) {
        guard live, !state.busy, let window else { return }
        state.error = nil
        switch action {
        case .copy:
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setData(png, forType: .png) { close(); Toasts.show("Copied capture") }
            else { state.error = "Couldn’t copy this capture. Try saving it instead." }
        case .save:
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "Vane Capture.png"
            panel.canCreateDirectories = true
            savePanel = panel
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                self.savePanel = nil
                guard self.live, response == .OK, let url = panel.url else { return }
                let png = self.png
                self.state.busy = true
                Task {
                    do {
                        try await Task.detached(priority: .userInitiated) { try png.write(to: url, options: .atomic) }.value
                        guard self.live else { return }
                        self.state.busy = false
                        self.close()
                    } catch {
                        self.state.busy = false
                        self.state.error = "Couldn’t save the capture: \(error.localizedDescription)"
                    }
                }
            }
        case .share:
            picker = NSSharingServicePicker(items: [image])
            picker?.show(relativeTo: overlay.menuFrame, of: overlay, preferredEdge: .minX)
        case .library:
            guard let store, !store.isPrivate else { return }
            let downloads = Downloads.manager(for: store.profileID)
            state.busy = true
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await downloads.saveCapture(self.png, title: self.title, source: self.source)
                    guard self.live else { return }
                    self.state.busy = false
                    self.state.saved = true
                    Toasts.show("Saved capture to Library → Media")
                } catch {
                    self.state.busy = false
                    self.state.error = error.localizedDescription
                }
            }
        case .edit:
            let image = self.image, title = self.title, source = self.source
            let store = self.store, tab = self.tab
            let region = overlay.region
            CaptureEditorController.present(image: image, in: window) { [weak self, weak window, weak store, weak tab] edited in
                guard let self, self.live, let window, window.isVisible,
                      let png = PageCapture.png(edited) else { return }
                let current = tab.flatMap { store?.active === $0 && PageCapture.available($0) ? $0 : nil }
                self.close()
                PageCapture.present(image: edited, png: png, title: title, source: source,
                    in: window, store: store, tab: current, region: current != nil ? region : nil)
            }
            editorPanel = window.attachedSheet
        case .retake:
            let tab = self.tab
            close()
            PageCapture.start(tab)
        case .easel(let id):
            guard canAddToEasel, let store, let source else { return }
            state.busy = true
            Task { [weak self, weak store] in
                guard let self, let store else { return }
                let added = await EaselWindow.addCapture(self.image, title: self.title,
                    source: source.absoluteString, to: id, in: store)
                guard self.live else { return }
                self.state.busy = false
                if added { self.close() }
                else { self.state.error = "Couldn’t add the capture to that Easel. Try again." }
            }
        }
    }

    func close() {
        guard live else { return }
        live = false
        observations.removeAll(); subscriptions.removeAll()
        if let editorPanel, editorPanel.sheetParent === window {
            window?.endSheet(editorPanel, returnCode: .cancel)
            editorPanel.orderOut(nil)
        }
        editorPanel = nil
        if let savePanel { window?.endSheet(savePanel, returnCode: .cancel); savePanel.orderOut(nil) }
        savePanel = nil
        if let responder = window?.firstResponder,
           responder === overlay || (responder as? NSView).map({ $0.isDescendant(of: overlay) }) == true {
            window?.makeFirstResponder(previousResponder)
        }
        overlay.cancel = nil
        overlay.removeFromSuperview()
        PageCapture.releaseResult(self)
    }
}

@MainActor private final class CaptureResultOverlay: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var image: NSImage?
    var region: CGRect?
    var resultState: CaptureResultState?
    var cancel: (() -> Void)?
    var copyCapture: (() -> Void)?
    var saveCapture: (() -> Void)?
    var editCapture: (() -> Void)?
    private var actionView: NSView?
    private(set) var menuFrame = CGRect.zero
    private var previewFrame = CGRect.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("page-capture-result")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Page capture actions")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showMenu(_ view: NSView) {
        actionView?.removeFromSuperview()
        actionView = view
        addSubview(view)
        needsLayout = true
        if !Motion.reduced {
            view.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                view.animator().alphaValue = 1
            }
        }
    }

    override func layout() {
        super.layout()
        let width = max(0, min(248, bounds.width - 24))
        let available = max(0, bounds.height - 24)
        if resultState?.menuWidth != width { resultState?.menuWidth = width }
        if resultState?.availableHeight != available { resultState?.availableHeight = available }
        let height = min(available, actionView?.fittingSize.height ?? 240)
        let anchor = region ?? CGRect(x: bounds.midX, y: 24, width: 0, height: 0)
        var x = anchor.maxX + 12
        if x + width > bounds.maxX - 12 { x = anchor.minX - width - 12 }
        if x < 12 { x = max(12, bounds.width - width - 12) }
        let y = max(12, min(anchor.minY, bounds.height - height - 12))
        menuFrame = CGRect(x: x, y: y, width: width, height: height)
        actionView?.frame = menuFrame
        if let region, bounds.contains(region), let image {
            let scale = min(region.width / image.size.width, region.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            previewFrame = CGRect(x: region.midX - size.width / 2, y: region.midY - size.height / 2,
                                  width: size.width, height: size.height)
        } else if let image {
            let area = CGRect(x: 16, y: 24, width: max(24, x - 32), height: max(24, bounds.height - 48))
            let scale = min(area.width / image.size.width, area.height / image.size.height, 1)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            previewFrame = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                                  width: size.width, height: size.height)
        }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.48).setFill()
        bounds.fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: previewFrame, xRadius: 8, yRadius: 8).addClip()
        image?.draw(in: previewFrame, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(roundedRect: previewFrame.insetBy(dx: -2, dy: -2), xRadius: 10, yRadius: 10)
        outline.lineWidth = 3
        outline.stroke()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancel?() }
        else if event.keyCode == 36 || event.keyCode == 76 { copyCapture?() }
        else if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "c" { copyCapture?() }
            else if event.charactersIgnoringModifiers == "s" { saveCapture?() }
            else if event.charactersIgnoringModifiers == "e" { editCapture?() }
        }
    }
    override func scrollWheel(with event: NSEvent) {}
    override func mouseDown(with event: NSEvent) { cancel?() }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancel?() }
    }
}
