import AppKit
import SwiftUI

/// Arc's Space theme editor: the dot-grid canvas the Space's colours are dragged around on,
/// the preset circles under it, and the intensity slider beside the grain dial along the
/// bottom. It replaces the old panel's swatch grid and `Slider`, which said the same three
/// things in the vocabulary of a settings pane rather than of a theme.
///
/// Everything applies as it is dragged — the Space already exists by the time this is on
/// screen, so there is nothing to cancel and closing the panel is the whole of "done". What a
/// finger is still holding lives in `live` and on `store.previewSpace`; only a finger leaving
/// writes spaces.json.
///
/// ponytail: one view for both routes into it. The footer's `+` opens it with the name field
/// (a new Space still has to be called something), the dot's "Edit Theme Color…" without;
/// two panels that drift apart is exactly what this file is replacing.
struct ThemeEditor: View {
    let store: TabStore
    /// The Space as the sidebar last read it, and what the panel starts from.
    let space: Space
    /// Whether the panel also names the Space. The `+` route does; Arc names a Space in the
    /// sidebar, and so does Vane once it exists.
    var naming = false

    @State private var name = ""
    /// Which page of presets the chevrons have walked to.
    @State private var page = 0
    /// Which colour a preset, or `−`, acts on: the last dot touched.
    @State private var selected = 0
    /// The Space as this panel has it, including edits a finger has not let go of yet.
    @State private var live: Space?
    /// Whether `live` holds anything the file does not.
    @State private var dirty = false
    /// Where each dot has been *put*, for as long as this panel is open.
    ///
    /// Kept here rather than re-derived from the hex the dot writes, because the canvas is a
    /// lossy view of a colour: both ends of the hue axis are the same red, and an unsaturated
    /// colour has no hue at all (see `Spaces.themePoint`). A dot positioned from its own
    /// colour teleports to an edge the moment a drag reaches one, and again when the finger
    /// lets go. Cleared whenever the colour comes from somewhere else — a preset, `±` — since
    /// then the canvas *should* read the new colour back.
    @State private var placed: [Int: CGPoint] = [:]
    /// The dot under the finger and where inside it the finger took hold, so the dot does not
    /// jump its own radius on the first frame.
    @State private var held: (index: Int, grab: CGSize)?
    /// Where the knob was when the finger landed on it, so the dial turns by how far the
    /// finger sweeps rather than jumping to wherever it was put down.
    @State private var knob: (angle: Double, value: Double)?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    /// The Space the panel is showing: its own in-flight copy once anything has been touched,
    /// the store's until then.
    private var current: Space { live ?? space }
    private var colors: [String] { Spaces.themeColors(of: current) }

    var body: some View {
        VStack(spacing: Look.inset) {
            if naming { nameRow }
            canvas
            presets
            HStack(spacing: Look.inset * 1.5) {
                WaveSlider(value: current.tint ?? Look.defaultTint,
                           change: { v in slide { $0.tint = v } }, end: commitLive)
                GrainDial(value: current.grain ?? 0, knob: $knob,
                          change: { v in slide { $0.grain = v } }, end: commitLive)
            }
        }
        .padding(Look.inset)
        // Sized here, not by the popover: NSPopover takes the hosting view's first fitting
        // size, which for a flexible canvas plus a slider comes out narrower than the content.
        .frame(width: Look.themeWidth)
        .fixedSize()
        // An opaque ground of its own. Without it NSPopover's translucent material lets the
        // window's own wash streak through the panel that is editing it.
        .background(Look.panelFill)
        .onAppear {
            name = space.name
            focused = naming
            page = Self.page(of: colors.first)
        }
        // Committed on the way out too: a panel dismissed by clicking the page must not throw
        // away what was typed into it, nor leave a preview on the store with nothing showing
        // it.
        .onDisappear {
            commit()
            commitLive()
            store.previewSpace = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(naming ? "New Space" : "Space theme")
    }

    // MARK: The name

    /// Arc names a Space elsewhere, so this is Vane's own row and it stays compact: one
    /// pill, the icon on the left as a menu, the field filling the rest.
    private var nameRow: some View {
        HStack(spacing: Look.rowSpacing) {
            Menu {
                ForEach(Spaces.icons, id: \.self) { symbol in
                    Button { edit { $0.icon = symbol } } label: { Label(symbol, systemImage: symbol) }
                }
            } label: {
                Image(systemName: current.icon ?? "cloud").font(Look.spaceIcon)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Look.inkSecondary)
            .help("Space icon")
            .accessibilityLabel("Space icon")

            TextField("Space name", text: $name)
                .textFieldStyle(.plain)
                .font(Look.text)
                .focused($focused)
                .onSubmit { commit(); dismiss() }
                .accessibilityLabel("Space name")
        }
        .padding(.horizontal, Look.rowInset)
        .frame(height: Look.rowHeight)
        .background(Look.pillFill, in: .rect(cornerRadius: Look.pillRadius))
    }

    // MARK: The canvas

    /// The colour field: hue across, saturation down, printed with Arc's fine dot grid so it
    /// reads as a surface a dot has been *put on* rather than as an empty panel.
    ///
    /// The dots are the last overlay on purpose: the appearance row and the `−`/`+` sit over
    /// the field, and layered the other way round they would swallow the drag of a dot parked
    /// underneath one of them.
    private var canvas: some View {
        ThemeGrid()
            .equatable()
            .frame(height: Look.themeCanvas)
            .background(Look.pillFill, in: .rect(cornerRadius: Look.pillRadius))
            .overlay(alignment: .top) { appearance.padding(.top, Look.inset * 1.5) }
            .overlay(alignment: .bottom) { steps.padding(.bottom, Look.inset * 1.5) }
            .overlay {
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(colors.enumerated()), id: \.offset) { i, hex in
                            dot(i, hex, in: geo.size)
                        }
                    }
                    .coordinateSpace(.named(fieldSpace))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Theme colours")
    }

    /// A dot's travel is the canvas inset by its own radius, so a colour at either end of a
    /// channel still draws as a whole dot inside the field rather than half over its edge.
    private func field(_ size: CGSize) -> CGSize {
        CGSize(width: max(size.width - Look.themeDot, 1),
               height: max(size.height - Look.themeDot, 1))
    }

    private func dot(_ i: Int, _ hex: String, in size: CGSize) -> some View {
        let travel = field(size)
        let p = place(i, hex)
        let centre = CGPoint(x: Look.themeDot / 2 + p.x * travel.width,
                             y: Look.themeDot / 2 + p.y * travel.height)
        return Circle()
            .fill(Color(hex: hex) ?? Look.inkQuiet)
            .overlay { Circle().strokeBorder(Look.themeThumbInk, lineWidth: Look.themeRing) }
            .frame(width: Look.themeDot, height: Look.themeDot)
            // Before `.position`, which takes all the space it is offered: a gesture added
            // after it would take the whole canvas with it.
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(fieldSpace))
                .onChanged { drag in
                    selected = i
                    let grab = held?.index == i ? held!.grab
                        : CGSize(width: drag.startLocation.x - centre.x,
                                 height: drag.startLocation.y - centre.y)
                    let point = CGPoint(
                        x: clamp((drag.location.x - grab.width - Look.themeDot / 2) / travel.width),
                        y: clamp((drag.location.y - grab.height - Look.themeDot / 2) / travel.height))
                    held = (i, grab)
                    placed[i] = point
                    write(i, Spaces.themeHex(x: point.x, y: point.y))
                }
                .onEnded { _ in held = nil; commitLive() })
            .position(centre)
            .accessibilityLabel("Theme colour \(i + 1)")
            .accessibilityValue(hex)
            .accessibilityHint("Drag to change the colour; adjust to walk it round the hue.")
            .accessibilityAdjustableAction { direction in
                selected = i
                let step = direction == .increment ? Self.hueStep : -Self.hueStep
                let next = CGPoint(x: (p.x + step + 1).truncatingRemainder(dividingBy: 1), y: p.y)
                placed[i] = next
                write(i, Spaces.themeHex(x: next.x, y: next.y))
                commitLive()
            }
    }

    /// Where dot `i` sits: where it was put if it has been, and what its colour reads back as
    /// if it has not.
    private func place(_ i: Int, _ hex: String) -> CGPoint {
        if let point = placed[i] { return point }
        guard let p = Spaces.themePoint(hex: hex) else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: p.x, y: p.y)
    }

    /// The three appearance toggles across the canvas' top: automatic, light, dark.
    private var appearance: some View {
        HStack(spacing: Look.inset) {
            mode(nil, "sparkles", "Automatic")
            mode("light", "sun.max", "Light")
            mode("dark", "moon", "Dark")
        }
    }

    private func mode(_ value: String?, _ symbol: String, _ label: String) -> some View {
        Button { edit { $0.appearance = value } } label: {
            Image(systemName: symbol)
                .font(Look.symbol)
                .frame(width: Look.control + Look.inset, height: Look.control + Look.inset)
                .background(current.appearance == value ? Look.selected : .clear,
                            in: .rect(cornerRadius: Look.cardRadius))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(current.appearance == value ? Look.inkPrimary : Look.inkTertiary)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(current.appearance == value ? [.isButton, .isSelected] : .isButton)
    }

    /// − and + at the canvas' foot: how many colours the ground is mixed from. `−` on the last
    /// one clears the theme rather than being dead — the Space then wears its profile's
    /// colour, which is what the old panel's "None" button did.
    private var steps: some View {
        HStack(spacing: Look.inset * 4) {
            step("minus", colors.count > 1 ? "Remove this colour" : "No theme colour",
                 enabled: !colors.isEmpty) {
                var list = colors
                list.remove(at: min(selected, list.count - 1))
                selected = max(0, min(selected, list.count - 1))
                placed = [:]            // the indices have shifted under every remembered place
                edit { Spaces.setThemeColors(list, on: &$0) }
            }
            step("plus", "Add a colour", enabled: colors.count < Spaces.maxThemeColors) {
                selected = colors.count
                placed[colors.count] = nil
                edit { Spaces.setThemeColors(colors + [Spaces.nextThemeColor(after: colors)],
                                             on: &$0) }
            }
        }
    }

    private func step(_ symbol: String, _ label: String,
                      enabled: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(Look.icon)
                .frame(width: Look.control, height: Look.control)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(enabled ? Look.inkSecondary : Look.inkDisabled)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: The presets

    /// Arc's row of ready-made theme colours, a page at a time between two chevrons. Buttons,
    /// not tap gestures: these are the keyboard's and VoiceOver's route to a colour, because
    /// the canvas above them is a pointer control.
    private var presets: some View {
        let all = Look.themeSwatches
        let pages = max(1, (all.count + Look.swatchPage - 1) / Look.swatchPage)
        let start = min(max(page, 0), pages - 1) * Look.swatchPage
        return HStack(spacing: Look.inset / 2) {
            chevron("chevron.left", "Previous colours", enabled: start > 0) { page -= 1 }
            // A short last page keeps its swatches under the first page's rather than
            // spreading them across the row.
            ForEach(0..<Look.swatchPage, id: \.self) { i in
                if start + i < all.count {
                    swatch(all[start + i])
                } else {
                    Color.clear.frame(width: Look.swatch, height: Look.swatch)
                }
            }
            chevron("chevron.right", "More colours",
                    enabled: start + Look.swatchPage < all.count) { page += 1 }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preset colours")
    }

    private func swatch(_ hex: String) -> some View {
        Button { pick(hex) } label: {
            Circle()
                .fill(Color(hex: hex) ?? Look.inkQuiet)
                .frame(width: Look.swatch, height: Look.swatch)
                // Arc's ring stands off the swatch rather than lying on its edge, so the
                // chosen colour is still a full disc.
                .overlay {
                    Circle().strokeBorder(.primary, lineWidth: Look.themeSelectRing)
                        .padding(-Look.themeRingGap)
                        .opacity(colors.contains(hex) ? 1 : 0)
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(hex)
        .accessibilityLabel("Theme colour \(hex)")
        .accessibilityAddTraits(colors.contains(hex) ? [.isButton, .isSelected] : .isButton)
    }

    private func chevron(_ symbol: String, _ label: String,
                         enabled: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(Look.symbol)
                .frame(width: Look.control, height: Look.control)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(enabled ? Look.inkSecondary : Look.inkDisabled)
        .accessibilityLabel(label)
    }

    /// A preset lands on the dot last touched, so a two-colour gradient can be built out of
    /// two presets rather than only by dragging.
    private func pick(_ hex: String) {
        var list = colors
        if list.indices.contains(selected) { list[selected] = hex } else { list.append(hex) }
        // The colour came from a preset, not from the canvas, so the dot goes where the new
        // colour reads back to rather than staying where the last drag left it.
        placed[selected] = nil
        edit {
            Spaces.setThemeColors(list, on: &$0)
            $0.tint = $0.tint ?? Look.defaultTint
        }
    }

    /// Which page of presets a colour is on, so the row opens showing the Space's own.
    private static func page(of hex: String?) -> Int {
        guard let hex, let i = Look.themeSwatches.firstIndex(of: hex) else { return 0 }
        return i / Look.swatchPage
    }

    /// How far one VoiceOver adjustment walks a dot round the hue wheel.
    private static let hueStep = 0.05

    // MARK: Writing it down

    private func clamp(_ v: CGFloat) -> Double { Double(min(max(v, 0), 1)) }

    private func write(_ i: Int, _ hex: String) {
        var list = colors
        guard list.indices.contains(i) else { return }
        list[i] = hex
        slide { Spaces.setThemeColors(list, on: &$0) }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard naming, !trimmed.isEmpty, trimmed != current.name else { return }
        edit { $0.name = trimmed }
        rebuild()                       // the Spaces menu lists the names
    }

    /// An edit that is over the moment it happens — a tap on a preset, a toggle, `±`.
    private func edit(_ change: (inout Space) -> Void) {
        slide(change)
        commitLive()
    }

    /// An edit a finger is still holding: the panel and the window's ground both follow it,
    /// and nothing reaches the disk until the finger leaves.
    private func slide(_ change: (inout Space) -> Void) {
        var copy = current
        change(&copy)
        live = copy
        dirty = true
        store.previewSpace = copy
    }

    /// The finger has left, or the panel has: write, once.
    private func commitLive() {
        guard dirty, let copy = live else { return }
        dirty = false
        store.update(space: copy)       // which clears the preview it was showing
    }
}

/// The canvas' own coordinate space, so a dot's drag is reported against the field it is
/// being dragged across rather than against the 44pt circle under the pointer.
private let fieldSpace = "vane.theme.field"

/// The fine grid printed on the canvas. `Equatable` and always equal: nothing about it ever
/// changes, and without that its several hundred dots are rebuilt on every frame of a drag.
private struct ThemeGrid: View, Equatable {
    nonisolated static func == (_: ThemeGrid, _: ThemeGrid) -> Bool { true }

    var body: some View {
        // One path for the whole grid, filled once: a thousand separate `fill`s is a thousand
        // draw calls.
        Canvas { ctx, size in
            var path = Path()
            var x = Look.themeGrid
            while x < size.width {
                var y = Look.themeGrid
                while y < size.height {
                    path.addEllipse(in: CGRect(x: x - Look.themeGridDot / 2,
                                               y: y - Look.themeGridDot / 2,
                                               width: Look.themeGridDot,
                                               height: Look.themeGridDot))
                    y += Look.themeGrid
                }
                x += Look.themeGrid
            }
            ctx.fill(path, with: .color(Look.inkQuiet))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - The intensity slider

/// How strongly the Space's colour washes over the window — the existing `Space.tint` —
/// drawn as Arc draws it: a sinusoid along the track that flattens to a straight line past
/// the thumb, so the control shows what it does instead of naming it.
private struct WaveSlider: View {
    let value: Double
    let change: (Double) -> Void
    let end: () -> Void

    var body: some View {
        GeometryReader { geo in
            let travel = max(geo.size.width - Look.themeThumb.width, 1)
            let x = Look.themeThumb.width / 2 + CGFloat(value) * travel
            ZStack {
                Capsule().fill(Look.pillFill).frame(height: Look.themeTrack)
                wave
                    .padding(.horizontal, Look.themeThumb.width / 2)
                Capsule()
                    .fill(Look.themeThumbInk)
                    .frame(width: Look.themeThumb.width, height: Look.themeThumb.height)
                    .position(x: x, y: geo.size.height / 2)
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged {
                    change(min(max(($0.location.x - Look.themeThumb.width / 2) / travel, 0), 1))
                }
                .onEnded { _ in end() })
        }
        .frame(height: Look.themeThumb.height)
        .accessibilityElement()
        .accessibilityLabel("Colour strength")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            change(min(max(value + (direction == .increment ? 0.1 : -0.1), 0), 1))
            end()
        }
    }

    private var wave: some View {
        Canvas { ctx, size in
            let cut = CGFloat(value) * size.width
            let mid = size.height / 2
            var path = Path()
            var t: CGFloat = 0
            while t <= size.width {
                let phase = Double(t / max(size.width, 1)) * Look.themeWaves * 2 * .pi
                let amplitude = Look.themeWave * (t < cut ? 1 : Look.themeWaveRest)
                let point = CGPoint(x: t, y: mid - amplitude * CGFloat(sin(phase)))
                if t == 0 { path.move(to: point) } else { path.addLine(to: point) }
                t += 1
            }
            ctx.stroke(path, with: .color(Look.inkSecondary),
                       style: StrokeStyle(lineWidth: Look.themeWaveWidth,
                                          lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - The grain dial

/// How much static noise the ground wears, as Arc's knob: a dotted ring that fills up as the
/// knob is turned, and a pill out on the ring at the angle it is turned to. Three quarters of
/// a turn, and turned by how far the finger sweeps — see `Spaces.dialTurn`, which is also why
/// a click on the dial moves nothing.
private struct GrainDial: View {
    let value: Double
    /// Where the finger took hold, and what the knob read then. On the editor rather than
    /// here so the gesture survives the panel redrawing under it.
    @Binding var knob: (angle: Double, value: Double)?
    let change: (Double) -> Void
    let end: () -> Void

    var body: some View {
        ZStack {
            ring
            Circle().fill(Look.controlFill).frame(width: Look.themeDial, height: Look.themeDial)
            marker
        }
        .frame(width: Look.themeDialRing, height: Look.themeDialRing)
        .contentShape(.circle)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let centre = Look.themeDialRing / 2
                let now = Spaces.dialRadians(dx: Double(drag.location.x - centre),
                                             dy: Double(drag.location.y - centre))
                let from = knob ?? (angle: now, value: value)
                let next = Spaces.dialTurn(from: from.angle, to: now, value: from.value)
                knob = (now, next)
                change(next)
            }
            .onEnded { _ in knob = nil; end() })
        .help("Grain")
        .accessibilityElement()
        .accessibilityLabel("Grain")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            change(min(max(value + (direction == .increment ? 0.1 : -0.1), 0), 1))
            end()
        }
    }

    private var ring: some View {
        ForEach(0..<Look.themeDialDots, id: \.self) { i in
            let turn = Double(i) / Double(Look.themeDialDots)
            Circle()
                .fill(lit(turn) ? Look.inkSecondary : Look.inkQuiet)
                .frame(width: Look.themeGridDot * 3, height: Look.themeGridDot * 3)
                // Offset then rotated: `offset` leaves the layout frame at the ring's centre,
                // which is what `rotationEffect` then turns the dot around.
                .offset(y: -Look.themeDialRing / 2 + Look.themeGridDot * 1.5)
                .rotationEffect(.radians(turn * 2 * .pi))
        }
    }

    /// A ring dot is lit once the knob has been turned past it. The dots outside the sweep —
    /// the dead quarter along the bottom — never light, which is what says the knob stops.
    private func lit(_ turn: Double) -> Bool {
        let a = turn * 2 * .pi
        let signed = a > .pi ? a - 2 * .pi : a
        return signed >= Spaces.dialAngle(0) && signed <= Spaces.dialAngle(value)
    }

    /// A pill out on the dotted ring, pointing wherever the knob is turned. Drawn straight up
    /// and rotated from there, so the one number in it is the dial's own angle.
    private var marker: some View {
        ZStack {
            Capsule()
                .fill(Look.themeThumbInk)
                .frame(width: Look.themeMarker.height, height: Look.themeMarker.width)
                .offset(y: -(Look.themeDialRing / 2 - Look.themeMarker.width / 2))
        }
        .frame(width: Look.themeDialRing, height: Look.themeDialRing)
        .rotationEffect(.radians(Spaces.dialAngle(value)))
    }
}
