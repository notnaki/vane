import AppKit
import Combine
import SwiftUI

@MainActor enum SiteBoostEditor {
    private static var sessions: [UUID: BoostEditorSession] = [:]

    static func open(tab: Tab) {
        if let session = sessions[tab.id] { session.panel.makeKeyAndOrderFront(nil); return }
        guard let url = tab.currentURL, let origin = SiteBoosts.origin(url),
              let window = tab.existingWeb?.window else { Toasts.show("Load a website before creating a Boost."); return }
        let session = BoostEditorSession(tab: tab, origin: origin, parent: window)
        sessions[tab.id] = session
        session.show()
    }
    static func close(tab: Tab) { sessions[tab.id]?.panel.close() }
    fileprivate static func remove(_ session: BoostEditorSession) {
        if sessions[session.tab.id] === session { sessions.removeValue(forKey: session.tab.id) }
    }
    static func toggleZap(tab: Tab) { if let session = sessions[tab.id] { session.setZap(!session.zapping) } }
    static func undo(tab: Tab) { sessions[tab.id]?.undoPick() }
    static func acceptsPick(tab: Tab) -> Bool { sessions[tab.id]?.zapping == true }
    static func pick(_ selector: String, tab: Tab) { sessions[tab.id]?.pick(selector) }
    static func stopZap(tab: Tab) { sessions[tab.id]?.setZap(false) }
    static func report(_ result: String, tab: Tab) { sessions[tab.id]?.status = result }
}

@MainActor fileprivate final class BoostEditorSession: NSObject, ObservableObject, NSWindowDelegate {
    let tab: Tab
    let origin: String
    let panel: NSPanel
    @Published var value: SiteBoost
    @Published var zapping = false
    @Published var status = ""
    @Published var coding = false { didSet { if coding != oldValue { place(keepingRightEdge: true) } } }
    static let width: CGFloat = 228, codeWidth: CGFloat = 340, height: CGFloat = 600
    private var undo: [String] = []
    private var subscriptions: Set<AnyCancellable> = []
    private weak var parent: NSWindow?
    private var closed = false

    init(tab: Tab, origin: String, parent: NSWindow) {
        self.tab = tab; self.origin = origin; self.parent = parent
        value = SiteBoosts.value(origin: origin, tab: tab)
        // Borderless overlay inside the window instead of a titled utility window.
        panel = BoostOverlayPanel(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: Self.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        panel.title = "Boost This Site"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        (panel as? BoostOverlayPanel)?.onUndo = { [weak self] in self?.undoPick() }
        if let store = TabStore.all.first(where: { $0.window === parent && $0.active === tab }) {
            panel.contentView = NSHostingView(rootView: BoostEditorView(session: self).spaceChrome(store))
        } else {
            panel.contentView = NSHostingView(rootView: BoostEditorView(session: self))
        }
        SiteChanges.shared.$revision.sink { [weak self] _ in
            guard let self, !self.closed else { return }
            self.value = SiteBoosts.value(origin: self.origin, tab: self.tab)
            if !self.value.enabled { self.setZap(false) }
        }.store(in: &subscriptions)
        // Light or dark follows the browser window, including its Space's appearance.
        parent.publisher(for: \.effectiveAppearance).sink { [weak self] in self?.panel.appearance = $0 }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: parent)
            .sink { [weak self] _ in self?.panel.close() }.store(in: &subscriptions)
        if let store = TabStore.all.first(where: { $0.window === parent && $0.active === tab }) {
            store.$current.sink { [weak self] id in
                guard let self else { return }
                if id != self.tab.id { self.panel.close() }
            }.store(in: &subscriptions)
        }
    }
    func show() {
        guard let parent else { return }
        place()
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
    }
    /// Opens against the window's right edge, vertically centred; as a child window it then rides along with the window.
    private func place(keepingRightEdge: Bool = false) {
        guard let frame = parent?.frame else { return }
        let width = coding ? Self.codeWidth : Self.width
        if keepingRightEdge {
            // Code widens the panel leftward from wherever it was dragged.
            panel.setFrame(CGRect(x: panel.frame.maxX - width, y: panel.frame.minY, width: width, height: panel.frame.height), display: true)
            return
        }
        let height = min(Self.height, frame.height - 32)
        panel.setFrame(CGRect(x: frame.maxX - width - 12, y: frame.midY - height / 2, width: width, height: height), display: true)
    }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }; closed = true
        setZap(false)
        subscriptions.removeAll()
        parent?.removeChildWindow(panel)
        panel.contentView = nil
        SiteBoostEditor.remove(self)
    }
    func change(_ body: (inout SiteBoost) -> Void) {
        guard !closed, tab.currentURL.flatMap(SiteBoosts.origin) == origin else { return }
        Motion.list { body(&value) }
        if !value.enabled { setZap(false) }
        SiteBoosts.set(value, origin: origin, tab: tab)
    }
    func binding<T>(_ key: WritableKeyPath<SiteBoost, T>) -> Binding<T> {
        Binding(get: { self.value[keyPath: key] }, set: { new in self.change { $0[keyPath: key] = new } })
    }
    func setZap(_ on: Bool) {
        let on = on && value.enabled && !closed
        Motion.list { zapping = on }
        SiteBoosts.zap(on, tab: tab)
        if on {
            parent?.makeKeyAndOrderFront(nil)
            parent?.makeFirstResponder(tab.existingWeb)
            status = "Click distractions to hide them. Escape finishes."
            axAnnounce(status)
        }
    }
    func pick(_ selector: String) {
        guard zapping, !value.hidden.contains(selector) else { return }
        undo.append(selector)
        change { $0.hidden.append(selector) }
        status = "Hidden \(value.hidden.count) element\(value.hidden.count == 1 ? "" : "s")."
    }
    func undoPick() {
        guard let selector = undo.popLast() ?? value.hidden.last else { return }
        change { $0.hidden.removeAll { $0 == selector } }
    }
    func toggleDark() {
        var tint = BoostTint(value) ?? BoostTint(hue: 0.75, intensity: 0.15, dark: false)
        tint.dark.toggle()
        change { tint.apply(to: &$0) }
    }
    func clearColors() { change { $0.background = ""; $0.textColor = ""; $0.linkColor = "" } }
    func cycleSize() {
        let steps = [1.0, 1.25, 1.5, 0.9]
        let next = steps[((steps.firstIndex(of: value.textScale) ?? 0) + 1) % steps.count]
        change { $0.textScale = next }
    }
    func cycleCase() {
        let cases = SiteBoost.cases
        change { $0.textCase = cases[((cases.firstIndex(of: $0.textCase) ?? 0) + 1) % cases.count] }
    }
    func reset() {
        setZap(false); undo = []
        change { $0 = SiteBoost() }
        status = "Boost reset. Reload to remove any script effects."
    }
    func run() {
        status = "Applying script…"
        Task { [weak self] in
            guard let self else { return }
            let result = await SiteBoosts.runScript(tab: tab)
            if !self.closed { self.status = result }
        }
    }
}

private final class BoostOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }  // borderless panels refuse key by default; the CSS/JS editors need it
    var onUndo: (() -> Void)?
    // ⌘Z undoes the last Zap, except while a text editor owns its own undo.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "z",
           !(firstResponder is NSTextView), let onUndo { onUndo(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

private struct BoostEditorView: View {
    @ObservedObject var session: BoostEditorSession
    @ObservedObject private var saver = BatterySaver.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var adjusting = false
    @State private var language = "CSS"

    static let content = BoostEditorSession.width - 28  // panel width minus padding: the pad matches the button row
    private var animation: Animation? { reduceMotion || saver.isActive ? nil : Look.quick }
    private var boost: SiteBoost { session.value }

    var body: some View {
        Group {
            if session.coding { code } else { main }
        }
        .frame(width: session.coding ? BoostEditorSession.codeWidth : BoostEditorSession.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 14))
        .clipShape(.rect(cornerRadius: 14))
        .animation(animation, value: session.coding)
    }

    // MARK: Main

    private var main: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(spacing: 12) {
                BoostColorPad(session: session).disabled(!boost.enabled)
                    .frame(width: Self.content, height: Self.content)
                HStack(spacing: 8) {
                    tile(systemImage: "lightbulb", label: BoostTint(boost)?.dark == true ? "Light background" : "Dark background",
                         on: BoostTint(boost)?.dark == true) { session.toggleDark() }
                    tile(systemImage: "slider.horizontal.3", label: "Contrast, brightness and saturation", on: adjusting) { adjusting.toggle() }
                        .popover(isPresented: $adjusting, arrowEdge: .bottom) { adjustments }
                    tile(systemImage: "nosign", label: "Website colors", on: false) { session.clearColors() }
                        .disabled(boost.background.isEmpty && boost.textColor.isEmpty && boost.linkColor.isEmpty)
                }
                fonts
                HStack(spacing: 8) {
                    pill(sizeLabel, fill: sizeFill) { session.cycleSize() }.accessibilityLabel("Text size \(Int((boost.textScale * 100).rounded()))%")
                    pill(caseLabel, fill: boost.textCase.isEmpty ? nil : .orange) { session.cycleCase() }.accessibilityLabel("Letter case")
                }
                row("Zap", trailing: AnyView(zapTrailing), inverted: session.zapping) { SiteBoostEditor.toggleZap(tab: session.tab) }
                    .contextMenu {
                        Button("Undo Last Zap") { session.undoPick() }.keyboardShortcut("z").disabled(boost.hidden.isEmpty)
                        Button("Restore All Zapped Elements") { session.change { $0.hidden = [] } }.disabled(boost.hidden.isEmpty)
                    }
                    .accessibilityLabel(session.zapping ? "Finish zapping" : "Zap elements")
                row("Code", trailing: AnyView(Text("{ }").font(.system(size: 13, weight: .semibold, design: .monospaced)))) {
                    session.setZap(false); session.coding = true
                }
                if !session.status.isEmpty {
                    Text(session.status).font(Look.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!boost.enabled)
            .opacity(boost.enabled ? 1 : 0.5)
            .padding(14)
        }
    }

    private var header: some View {
        HStack {
            Button { session.panel.close() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Close Boost")
            Spacer()
            Menu {
                Toggle("Boost On", isOn: session.binding(\.enabled))
                Text(session.origin)
                if session.tab.isPrivate { Text("Temporary in this private tab") }
            } label: {
                Text("My Boost  \(Image(systemName: "chevron.down"))").font(Look.heading)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Spacer()
            Button { session.reset() } label: {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).accessibilityLabel("Reset Boost")
        }
        .padding(.horizontal, 12).frame(height: 38)
        .contentShape(.rect)
        .gesture(WindowDragGesture())  // move the overlay by its header; the color pad keeps its own drag
    }

    private var adjustments: some View {
        VStack(alignment: .leading, spacing: 14) {
            slider("Contrast", \.contrast, 0.5...1.5)
            slider("Brightness", \.brightness, 0.5...1.5)
            slider("Saturation", \.saturation, 0...2)
        }.padding(16).frame(width: 220)
    }
    private func slider(_ label: String, _ key: WritableKeyPath<SiteBoost, Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Look.heading).foregroundStyle(.secondary)
            Slider(value: session.binding(key), in: range).accessibilityLabel(label)
        }
    }

    private var fonts: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 5), spacing: 4) {
            ForEach(SiteBoost.fonts.dropFirst(), id: \.self) { font in
                let chosen = boost.font == font
                Button { session.change { $0.font = chosen ? "" : font } } label: {
                    Text("Aa").font(.custom(font, size: 13)).foregroundStyle(chosen ? .primary : .secondary)
                        .frame(width: 28, height: 26)
                        .background(chosen ? Color.primary.opacity(0.12) : .clear, in: .circle)
                        .contentShape(.rect)
                }.buttonStyle(.plain).accessibilityLabel(font).accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06)))
    }

    private var sizeLabel: String { boost.textScale == 1 ? "Size" : "%\(Int((boost.textScale * 100).rounded()))" }
    private var sizeFill: Color? {
        boost.textScale == 1 ? nil : boost.textScale < 1 ? .blue : boost.textScale < 1.4 ? .orange : .red
    }
    private var caseLabel: String {
        switch boost.textCase { case "lowercase": "aa"; case "uppercase": "AA"; case "capitalize": "Aa"; default: "Case" }
    }
    @ViewBuilder private var zapTrailing: some View {
        if boost.hidden.isEmpty { Image(systemName: "bolt.fill").fontWeight(.bold) }
        else { Text("\(boost.hidden.count)").monospacedDigit() }
    }

    private func tile(systemImage: String, label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 16, weight: .bold))
                .frame(maxWidth: .infinity).frame(height: 36)
                .foregroundStyle(on ? Color(nsColor: .windowBackgroundColor) : .primary)
                .background(on ? Color.primary.opacity(0.8) : Color.primary.opacity(0.07), in: .rect(cornerRadius: 9))
                .contentShape(.rect)
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
    private func pill(_ title: String, fill: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 34)
                .foregroundStyle(fill == nil ? Color.primary : .white)
                .background(fill ?? Color.primary.opacity(0.07), in: .rect(cornerRadius: 9))
                .contentShape(.rect)
        }.buttonStyle(.plain)
    }
    private func row(_ title: String, trailing: AnyView, inverted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Text(title).font(.system(size: 13, weight: .semibold)); Spacer(); trailing.font(.system(size: 13, weight: .semibold)) }
                .padding(.horizontal, 12).frame(height: 34)
                .foregroundStyle(inverted ? Color(nsColor: .windowBackgroundColor) : .primary)
                .background(inverted ? Color.primary.opacity(0.85) : Color.primary.opacity(0.07), in: .rect(cornerRadius: 9))
                .contentShape(.rect)
        }.buttonStyle(.plain)
    }

    // MARK: Code

    private var code: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack {
                    Button { session.coding = false } label: { Label("Back", systemImage: "arrow.left").font(Look.caption.weight(.semibold)) }
                        .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    Spacer()
                }
                Picker("Code language", selection: $language) { Text("CSS").tag("CSS"); Text("JS").tag("JS") }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            .padding(.horizontal, 12).frame(height: 38)
            TextEditor(text: session.binding(language == "CSS" ? \.css : \.script))
                .font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
                .foregroundStyle(.white).padding(8)
                .background(Color(white: 0.08))
                .accessibilityLabel(language == "CSS" ? "Custom CSS" : "User JavaScript")
            if language == "JS" {
                Text("Scripts run on this site after it loads. Use code you trust. Reload to undo their effects.")
                    .font(Look.caption.weight(.medium)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.red.opacity(0.75))
            }
            HStack {
                if language == "JS" {
                    Toggle("Run JavaScript", isOn: session.binding(\.scriptEnabled)).toggleStyle(.switch).controlSize(.small)
                    Spacer()
                    Button("Run") { session.run() }.disabled(!boost.scriptEnabled)
                    Button { session.tab.existingWeb?.reload() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Reload Page")
                } else {
                    Text("CSS previews as you type.").font(Look.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(.horizontal, 12).frame(height: 44)
            if !session.status.isEmpty, language == "JS" {
                Text(session.status).font(Look.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .bottom], 12)
            }
        }
        .disabled(!boost.enabled)
    }
}

/// Page colors chosen on the Boost pad: hue and intensity from the dot's angle and distance, plus a light or dark scheme.
/// Stored as the plain background/text/link colors, so sync and rendering stay unchanged; the pad reads them back.
private struct BoostTint {
    var hue: Double, intensity: Double, dark: Bool

    init(hue: Double, intensity: Double, dark: Bool) { self.hue = hue; self.intensity = intensity; self.dark = dark }
    init?(_ boost: SiteBoost) {
        guard let raw = UInt32(boost.background.dropFirst(), radix: 16), boost.background.count == 7 else { return nil }
        let color = NSColor(srgbRed: CGFloat((raw >> 16) & 255) / 255, green: CGFloat((raw >> 8) & 255) / 255, blue: CGFloat(raw & 255) / 255, alpha: 1)
        dark = color.brightnessComponent < 0.5
        hue = color.hueComponent
        intensity = min(1, max(0, dark ? (color.saturationComponent - 0.2) / 0.5 : (color.saturationComponent - 0.04) / 0.4))
    }
    func apply(to boost: inout SiteBoost) {
        let s = intensity
        boost.background = Self.hex(hue, dark ? 0.2 + 0.5 * s : 0.04 + 0.4 * s, dark ? 0.16 + 0.12 * s : 0.98 - 0.06 * s)
        boost.textColor = Self.hex(hue, dark ? 0.12 : 0.3 + 0.3 * s, dark ? 0.94 : 0.18)
        boost.linkColor = Self.hex(hue, dark ? 0.45 : 0.85, dark ? 1 : 0.5)
    }
    static func hex(_ h: Double, _ s: Double, _ b: Double) -> String {
        let c = NSColor(hue: h, saturation: s, brightness: b, alpha: 1).usingColorSpace(.sRGB)!
        return String(format: "#%02x%02x%02x", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}

private struct BoostColorPad: View {
    @ObservedObject var session: BoostEditorSession
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tint = BoostTint(session.value)
        GeometryReader { geo in
            let size = geo.size.width, inset: CGFloat = 8, field = size - inset * 2
            let center = CGPoint(x: size / 2, y: size / 2)
            let main = tint.map { t in
                CGPoint(x: center.x + cos(t.hue * 2 * .pi) * t.intensity * field / 2 * 0.8,
                        y: center.y + sin(t.hue * 2 * .pi) * t.intensity * field / 2 * 0.8)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(tint == nil
                          ? AnyShapeStyle(LinearGradient(colors: [.gray, Color(white: scheme == .dark ? 0.4 : 0.92), .gray], startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center, angle: .degrees(0))))
                RoundedRectangle(cornerRadius: 9).fill(Color(white: scheme == .dark ? 0.14 : 0.97)).padding(inset)
                if let main, let tint {
                    Circle().fill(Color(nsColor: NSColor(hue: tint.hue, saturation: 0.7, brightness: 0.85, alpha: 1)))
                        .overlay(Circle().stroke(.white, lineWidth: 3)).frame(width: 34, height: 34)
                        .shadow(color: .black.opacity(0.2), radius: 3).position(main)
                    Circle().fill(tint.dark ? Color(white: 0.12) : .white)
                        .overlay(Circle().stroke(tint.dark ? .white : Color(white: 0.7), lineWidth: 2)).frame(width: 18, height: 18)
                        .position(x: main.x + 14, y: main.y + 18)
                } else {
                    Circle().fill(Color(white: scheme == .dark ? 0.35 : 0.85)).overlay(Circle().stroke(.white, lineWidth: 3))
                        .frame(width: 28, height: 28).shadow(color: .black.opacity(0.15), radius: 3).position(center)
                }
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let dx = drag.location.x - center.x, dy = drag.location.y - center.y
                var hue = atan2(dy, dx) / (2 * .pi); if hue < 0 { hue += 1 }
                let intensity = min(1, max(0.05, hypot(dx, dy) / (field / 2 * 0.8)))
                session.change { BoostTint(hue: hue, intensity: intensity, dark: tint?.dark ?? false).apply(to: &$0) }
            })
        }
        .aspectRatio(1, contentMode: .fit)
        .saturation(isEnabled ? 1 : 0)
        .accessibilityElement()
        .accessibilityLabel("Page color")
        .accessibilityValue(tint.map { "Hue \(Int($0.hue * 360)) degrees, \($0.dark ? "dark" : "light")" } ?? "Website colors")
        .accessibilityAdjustableAction { direction in
            let t = tint ?? BoostTint(hue: 0.75, intensity: 0.5, dark: false)
            let step = direction == .increment ? 1.0 / 24 : -1.0 / 24
            session.change { BoostTint(hue: (t.hue + step + 1).truncatingRemainder(dividingBy: 1), intensity: t.intensity, dark: t.dark).apply(to: &$0) }
        }
    }
}
