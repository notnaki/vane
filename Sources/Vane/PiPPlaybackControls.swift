import AppKit

/// Input belongs to Vane's panel; media commands still reach the site's original video.
@MainActor final class PiPPlaybackControls: NSView {
    private weak var tab: Tab?
    private let back: PiPButton
    private let minimize: PiPButton
    private let close: PiPButton
    private let play: PiPButton
    private let backward: PiPButton
    private let forward: PiPButton
    private let seek = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let hostname = NSTextField(labelWithString: "")
    private var header: [NSGlassEffectView] = []
    private var tracking: NSTrackingArea?
    private var keyboardInteraction = false
    private var controlsVisible = true
    private var visibilityGeneration = 0

    init(tab: Tab, returnToTab: @escaping () -> Void, minimize: @escaping () -> Void, close: @escaping () -> Void) {
        self.tab = tab
        back = PiPButton(symbol: "arrow.up.left", id: "restore", label: "Back to Tab", action: returnToTab)
        self.minimize = PiPButton(symbol: "minus", id: "minimize", label: "Minimize — keep playing", action: minimize)
        self.close = PiPButton(symbol: "xmark", id: "close", label: "Close Picture in Picture and pause", action: close)
        play = PiPButton(symbol: "pause.fill", id: "playpause", label: "Play or pause") { [weak tab] in
            guard let tab else { return }; PictureInPicture.control(.playpause, tab: tab)
        }
        backward = PiPButton(symbol: "gobackward.15", id: "backward", label: "Back 15 seconds") { [weak tab] in
            guard let tab else { return }; PictureInPicture.control(.skip(-15), tab: tab)
        }
        forward = PiPButton(symbol: "goforward.15", id: "forward", label: "Forward 15 seconds") { [weak tab] in
            guard let tab else { return }; PictureInPicture.control(.skip(15), tab: tab)
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        appearance = NSAppearance(named: .darkAqua)
        for button in [back, self.minimize, self.close] {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 10
            glass.style = .regular
            glass.contentView = button
            addSubview(glass)
            header.append(glass)
        }
        for button in [backward, play, forward] { addSubview(button) }
        hostname.stringValue = MediaTray.clean(tab.currentURL?.host ?? "")
        hostname.font = .systemFont(ofSize: 13, weight: .semibold)
        hostname.textColor = .white
        hostname.alignment = .center
        hostname.lineBreakMode = .byTruncatingMiddle
        addSubview(hostname)
        seek.identifier = NSUserInterfaceItemIdentifier("vane.pip.seek")
        seek.cell = PiPSeekCell()
        seek.minValue = 0
        seek.maxValue = 1
        seek.setAccessibilityLabel("Video playback position")
        seek.isContinuous = true
        seek.target = self
        seek.action = #selector(seekChanged)
        seek.isEnabled = false
        addSubview(seek)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let compact = bounds.width < 480
        let inset: CGFloat = 14
        let height: CGFloat = 32
        let widths: [CGFloat] = compact ? [32, 32, 32] : [128, 104, 84]
        let x = [inset, bounds.width - inset - widths[2] - 8 - widths[1], bounds.width - inset - widths[2]]
        for (i, button) in [back, minimize, close].enumerated() {
            header[i].frame = NSRect(x: x[i], y: bounds.height - inset - height, width: widths[i], height: height)
            button.frame = header[i].bounds
            button.title = compact ? "" : ["Back to Tab", "Minimize", "Close"][i]
            button.imagePosition = compact ? .imageOnly : .imageLeading
            button.setSymbolSize(14)
        }
        let titleStart = header[0].frame.maxX + 8
        let titleWidth = max(0, header[1].frame.minX - titleStart - 8)
        hostname.frame = NSRect(x: titleStart, y: bounds.height - inset - height, width: titleWidth, height: height)
        hostname.isHidden = titleWidth < 90
        let playSize = min(90, max(42, bounds.height * 0.22))
        let skipSize = playSize * 0.65
        play.frame = NSRect(x: bounds.midX - playSize / 2, y: bounds.midY - playSize / 2, width: playSize, height: playSize)
        backward.frame = NSRect(x: play.frame.minX - skipSize - 20, y: bounds.midY - skipSize / 2, width: skipSize, height: skipSize)
        forward.frame = NSRect(x: play.frame.maxX + 20, y: bounds.midY - skipSize / 2, width: skipSize, height: skipSize)
        play.setSymbolSize(playSize * 0.7)
        backward.setSymbolSize(skipSize * 0.8)
        forward.setSymbolSize(skipSize * 0.8)
        seek.frame = NSRect(x: inset, y: 10, width: max(0, bounds.width - inset * 2), height: 20)
    }

    func update(_ state: PictureInPicture.Playback) {
        play.symbol = state.playing ? "pause.fill" : "play.fill"
        play.setAccessibilityLabel(state.playing ? "Pause video" : "Play video")
        let first = state.ranges.first?.lowerBound
        let last = state.ranges.last?.upperBound
        let seekable = first != nil && last != nil && last! > first!
        seek.isEnabled = seekable
        backward.isEnabled = seekable
        forward.isEnabled = seekable
        if let first, let last, seekable {
            seek.minValue = first
            seek.maxValue = last
            // Do not overwrite the user's drag with periodic playback reports.
            if !(NSApp.currentEvent?.type == .leftMouseDragged) { seek.doubleValue = state.position }
        }
    }

    func updateVisibility(pointer: NSPoint) {
        if window?.isKeyWindow != true { keyboardInteraction = false }
        let hovered = window?.frame.contains(pointer) == true
        let focusedControl = window?.isKeyWindow == true && window?.firstResponder is NSControl
        setControlsVisible(hovered || focusedControl || keyboardInteraction)
    }

    private func setControlsVisible(_ visible: Bool) {
        guard controlsVisible != visible else { return }
        controlsVisible = visible
        visibilityGeneration += 1
        let generation = visibilityGeneration
        if visible { isHidden = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.visibilityGeneration == generation else { return }
                self.isHidden = !visible
            }
        }
    }

    func showForKeyboard() { keyboardInteraction = true; setControlsVisible(true) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { setControlsVisible(true) }
    override func mouseExited(with event: NSEvent) { keyboardInteraction = false }

    @objc private func seekChanged() {
        guard let tab else { return }
        PictureInPicture.control(.seek(seek.doubleValue), tab: tab)
    }
}

private final class PiPSeekCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        NSColor.white.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let fraction = maxValue > minValue ? min(1, max(0, (doubleValue - minValue) / (maxValue - minValue))) : 0
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height),
                     xRadius: 2, yRadius: 2).fill()
    }
    override func drawKnob(_ knobRect: NSRect) {
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: knobRect.midX - 4, y: knobRect.midY - 4, width: 8, height: 8)).fill()
    }
}

@MainActor private final class PiPButton: NSButton {
    private let clickedAction: () -> Void
    private var symbolSize: CGFloat = 16
    var symbol: String { didSet { setSymbolSize(symbolSize) } }

    init(symbol: String, id: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol
        clickedAction = action
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("vane.pip.\(id)")
        isBordered = false
        font = .systemFont(ofSize: 13, weight: .semibold)
        contentTintColor = .white
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        toolTip = label
        setAccessibilityLabel(label)
        setButtonType(.momentaryChange)
        target = self
        self.action = #selector(clicked)
        setSymbolSize(16)
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setSymbolSize(_ size: CGFloat) {
        symbolSize = size
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
    }

    @objc private func clicked() { clickedAction() }
}
