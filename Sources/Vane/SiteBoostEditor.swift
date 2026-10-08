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
    private var undo: [String] = []
    private var subscriptions: Set<AnyCancellable> = []
    private weak var parent: NSWindow?
    private var closed = false

    init(tab: Tab, origin: String, parent: NSWindow) {
        self.tab = tab; self.origin = origin; self.parent = parent
        value = SiteBoosts.value(origin: origin, tab: tab)
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 360, height: 650),
                        styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        panel.title = "Boost This Site"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: BoostEditorView(session: self))
        SiteChanges.shared.$revision.sink { [weak self] _ in
            guard let self, !self.closed else { return }
            self.value = SiteBoosts.value(origin: self.origin, tab: self.tab)
            if !self.value.enabled { self.setZap(false) }
        }.store(in: &subscriptions)
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
        let frame = parent.frame
        panel.setFrameOrigin(CGPoint(x: frame.maxX - panel.frame.width - 24, y: frame.maxY - panel.frame.height - 65))
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
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

private struct BoostEditorView: View {
    @ObservedObject var session: BoostEditorSession
    @ObservedObject private var saver = BatterySaver.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var section = "Style"
    @State private var language = "CSS"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "paintbrush.pointed.fill").font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your corner of the web").font(Look.heading)
                    Text(session.origin).font(Look.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Toggle("Enable Boost", isOn: session.binding(\.enabled)).labelsHidden().toggleStyle(.switch)
            }
            Text(session.tab.isPrivate ? "Temporary in this private tab. Nothing is saved." : "Saved automatically for this origin and profile.")
                .font(Look.caption).foregroundStyle(.secondary)
            Picker("Editor section", selection: $section) {
                Text("Style").tag("Style"); Text("Code").tag("Code")
            }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if section == "Style" { styleControls.transition(.opacity) }
                    else { codeControls.transition(.opacity) }
                }.padding(.vertical, 4)
            }.disabled(!session.value.enabled)
            if !session.status.isEmpty {
                Text(session.status).font(Look.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityLabel(session.status)
            }
            Divider()
            HStack {
                Button("Reset Boost", role: .destructive) { session.reset() }
                Spacer()
                Button("Done") { session.panel.close() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 360, height: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(reduceMotion || saver.isActive ? nil : Look.quick, value: section)
        .animation(reduceMotion || saver.isActive ? nil : Look.quick, value: language)
    }

    private var styleControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("TYPE").font(Look.caption).foregroundStyle(.secondary)
                Picker("Font", selection: session.binding(\.font)) {
                    ForEach(SiteBoost.fonts, id: \.self) { font in
                        Text(font.isEmpty ? "Website default" : font).tag(font)
                    }
                }
                HStack { Text("Text size"); Spacer(); Text("\(Int(session.value.textScale * 100))%").monospacedDigit() }
                Slider(value: session.binding(\.textScale), in: 0.75...2, step: 0.05).accessibilityLabel("Text size")
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("COLOR").font(Look.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    palette("Paper", background: "#f5f1e8", text: "#29251e", link: "#92572b")
                    palette("Dusk", background: "#252333", text: "#e8e4f2", link: "#c6afff")
                    palette("Mint", background: "#e4f1e9", text: "#234537", link: "#277c5d")
                    Button("Default") { session.change { $0.background = ""; $0.textColor = ""; $0.linkColor = "" } }
                        .font(Look.caption)
                }
                color("Background", key: \.background, fallback: "#ffffff")
                color("Text", key: \.textColor, fallback: "#222222")
                color("Links", key: \.linkColor, fallback: "#6255ca")
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("DISTRACTIONS").font(Look.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Undo", systemImage: "arrow.uturn.backward") { SiteBoostEditor.undo(tab: session.tab) }
                        .disabled(session.value.hidden.isEmpty).font(Look.caption)
                }
                Button { SiteBoostEditor.toggleZap(tab: session.tab) } label: {
                    Label(session.zapping ? "Finish Zapping" : "Zap an Element", systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                }.buttonStyle(.borderedProminent)
                Text("Point at anything you want to hide, then click. Changes apply on every visit.")
                    .font(Look.caption).foregroundStyle(.secondary)
                ForEach(session.value.hidden, id: \.self) { selector in
                    HStack {
                        Text(selector).font(.system(size: 11, design: .monospaced)).lineLimit(2)
                        Spacer()
                        Button { session.change { $0.hidden.removeAll { $0 == selector } } } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain).accessibilityLabel("Restore \(selector)")
                    }
                }
            }
        }
    }

    private var codeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Code language", selection: $language) {
                Text("CSS").tag("CSS"); Text("JavaScript").tag("JavaScript")
            }.pickerStyle(.segmented).labelsHidden()
            Text(language == "CSS" ? "CSS previews as you type." : "Scripts run on this origin after loading, once enabled. Use code you trust.")
                .font(Look.caption).foregroundStyle(.secondary)
            TextEditor(text: session.binding(language == "CSS" ? \.css : \.script))
                .font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
                .padding(8).frame(height: 280)
                .background(Look.controlFill, in: .rect(cornerRadius: 8))
                .accessibilityLabel(language == "CSS" ? "Custom CSS" : "User JavaScript")
            if language == "JavaScript" {
                Toggle("Enable JavaScript", isOn: session.binding(\.scriptEnabled)).toggleStyle(.switch)
                Button("Apply Script") { session.run() }.disabled(!session.value.scriptEnabled)
                Text("Turning scripts off prevents future runs. Reload to undo effects on this page.")
                    .font(Look.caption).foregroundStyle(.secondary)
                Button("Reload Page") { session.tab.existingWeb?.reload() }
            }
        }
    }

    private func palette(_ name: String, background: String, text: String, link: String) -> some View {
        Button { session.change { $0.background = background; $0.textColor = text; $0.linkColor = link } } label: {
            VStack(spacing: 4) {
                Text("Aa").font(.system(size: 15, weight: .medium, design: .serif))
                    .foregroundStyle(Self.colorValue(text)).frame(width: 44, height: 36)
                    .background(Self.colorValue(background), in: .rect(cornerRadius: 8))
                Text(name).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.buttonStyle(.plain).accessibilityLabel("\(name) palette")
    }
    private func color(_ label: String, key: WritableKeyPath<SiteBoost, String>, fallback: String) -> some View {
        HStack {
            ColorPicker(label, selection: Binding(get: {
                let hex = session.value[keyPath: key]
                return Self.colorValue(hex.isEmpty ? fallback : hex)
            }, set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                let hex = String(format: "#%02x%02x%02x", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
                session.change { $0[keyPath: key] = hex }
            }), supportsOpacity: false)
            Button { session.change { $0[keyPath: key] = "" } } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.plain).disabled(session.value[keyPath: key].isEmpty)
                .accessibilityLabel("Restore website \(label.lowercased()) color")
        }
    }
    private static func colorValue(_ hex: String) -> Color {
        let raw = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return Color(red: Double((raw >> 16) & 255) / 255, green: Double((raw >> 8) & 255) / 255, blue: Double(raw & 255) / 255)
    }
}
