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
    @State private var wheel: ThemeWheel?
    @State private var hovered: Int?
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
    @State private var held: (index: Int, point: CGPoint)?
    /// Where the knob was when the finger landed on it, so the dial turns by how far the
    /// finger sweeps rather than jumping to wherever it was put down.
    @State private var knob: (angle: Double, value: Double)?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    /// The Space the panel is showing: its own in-flight copy once anything has been touched,
    /// the store's until then.
    private var current: Space { live ?? space }
    private var colors: [String] { Spaces.themeColors(of: current) }
    private var palette: [ThemeColor] { Spaces.palette(of: current) }

    var body: some View {
        VStack(spacing: Look.inset) {
            if naming { nameRow }
            canvas
            presets
            HStack(spacing: Look.inset * 1.5) {
                WaveSlider(value: current.tint ?? Look.defaultTint,
                           change: { v in slide { $0.tint = v } }, end: commitLive)
                    .frame(width: ThemeIntensity.width)
                Spacer(minLength: 0)
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
        .background(Color(white: 0.16))
        .environment(\.colorScheme, .dark)
        .vaneMotionPolicy()
        .onAppear {
            name = space.name
            focused = naming
            page = Self.page(of: colors.first)
            if let primary = palette.first { wheel = ThemeWheel(primary) }
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

    /// The colour field: hue around the centre and lightness along the radius, so it
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

    /// The wheel's square, centred in the canvas and inset by a dot's radius, so a colour on
    /// the rim still draws as a whole dot inside the field rather than half over its edge.
    private func field(_ size: CGSize) -> CGRect {
        let side = max(min(size.width, size.height), 1)
        return CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
    }

    private func dot(_ i: Int, _ hex: String, in size: CGSize) -> some View {
        let box = field(size)
        let p = place(i, hex)
        let diameter: CGFloat = i == 0 ? 44 : 26
        let centre = CGPoint(x: min(max(box.minX + p.x * box.width, diameter / 2), size.width - diameter / 2),
                             y: min(max(box.minY + p.y * box.height, diameter / 2), size.height - diameter / 2))
        return Circle()
            .fill(palette.indices.contains(i) ? palette[i].color : (Color(hex: hex) ?? .gray))
            .overlay { Circle().strokeBorder(.white, lineWidth: i == 0 ? 4 : 3) }
            .frame(width: diameter, height: diameter)
            .scaleEffect(hovered == i ? 1.1 : 1)
            .onHover { inside in Motion.animate(Look.quick) { hovered = inside ? i : nil } }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(fieldSpace))
                .onChanged { drag in
                    let initial = held?.index == i ? held!.point : p
                    held = (i, initial)
                    let point = ThemeWheel.dragPoint(start: drag.startLocation, location: drag.location,
                                                     model: initial, field: box)
                    move(i, to: point)
                }
                .onEnded { _ in held = nil; commitLive() })
            .position(centre)
            .accessibilityLabel(i == 0 ? "Primary theme colour" : "Theme colour \(i + 1)")
            .accessibilityValue(hex)
            .accessibilityAdjustableAction { direction in
                let p = place(i, hex), w = Spaces.wheel(x: p.x, y: p.y)
                let next = Spaces.wheelPoint(r: w.r, a: w.a + (direction == .increment ? 0.05 : -0.05) * 2 * .pi)
                move(i, to: CGPoint(x: next.x, y: next.y)); commitLive()
            }
    }

    private func place(_ i: Int, _ hex: String) -> CGPoint {
        if let point = placed[i] { return point }
        guard let primary = palette.first, palette.indices.contains(i) else { return CGPoint(x: 0.5, y: 0.5) }
        return (wheel ?? ThemeWheel(primary)).point(palette[i])
    }

    private func move(_ i: Int, to point: CGPoint) {
        guard let primary = palette.first else { return }
        let pad = wheel ?? ThemeWheel(primary)
        wheel = pad
        let positions = ThemeWheel.positions(dragged: point, index: i, count: palette.count)
        let color = pad.color(at: positions[0], hueAtCenter: primary.hsl.h)
        let list = ThemeWheel.palette(color, count: palette.count)
        for j in list.indices { placed[j] = positions[j] }
        slide { Spaces.setPalette(list, on: &$0) }
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
            step("minus", colors.count > 1 ? "Remove a colour" : "No theme colour", enabled: !colors.isEmpty) {
                guard let primary = palette.first else { return }
                let list = colors.count > 1 ? ThemeWheel.palette(primary, count: colors.count - 1) : []
                placed = [:]
                Motion.animate(Look.quick) { edit { Spaces.setPalette(list, on: &$0) } }
            }
            step("plus", "Add a colour", enabled: colors.count < Spaces.maxThemeColors) {
                let primary = palette.first ?? ThemeColor(hex: "#808080")!
                if palette.isEmpty || wheel == nil { wheel = ThemeWheel(primary) }
                placed = [:]
                Motion.animate(Look.quick) { edit { Spaces.setPalette(ThemeWheel.palette(primary, count: colors.count + 1), on: &$0) } }
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
                .fill(Look.themePresetColors[hex]?.color ?? Color(hex: hex) ?? Look.inkQuiet)
                .frame(width: Look.swatch, height: Look.swatch)
                .overlay { Circle().strokeBorder(.white.opacity(0.15), lineWidth: 2) }
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

    /// Presets replace the whole palette and calibrate a fresh pad.
    private func pick(_ hex: String) {
        guard let color = Look.themePresetColors[hex] ?? ThemeColor(hex: hex) else { return }
        wheel = ThemeWheel(color)
        placed = [:]

        Motion.animate(Look.quick) {
            edit { Spaces.setPalette([color], on: &$0) }
        }
    }

    private static func page(of hex: String?) -> Int {
        guard let hex, let i = Look.themeSwatches.firstIndex(of: hex) else { return 0 }
        return i / Look.swatchPage
    }

    static func check() -> [(String, Bool)] {
        [("slider travel is independent of the growing thumb", abs(ThemeIntensity.x(value: 0.8, width: 224) - 174.4) < 1e-9),
         ("the intensity endpoints are reachable", ThemeIntensity.value(x: 8, width: 224) == 0 && ThemeIntensity.value(x: 216, width: 224) == 1)]
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
    @State private var grab: Double?

    var body: some View {
        GeometryReader { geo in
            let x = ThemeIntensity.x(value: value, width: geo.size.width)
            let thumb = ThemeIntensity.thumb(value)
            ZStack {
                Capsule().fill(.white.opacity(0.08)).frame(height: 16)
                Canvas { ctx, size in
                    let start: CGFloat = 8, travel = max(size.width - 16, 1)
                    let cut = CGFloat(x), mid = size.height / 2
                    var active = Path(), inactive = Path()
                    var previous: CGPoint?
                    for t in stride(from: start, through: size.width - 8, by: 0.5) {
                        let phase = Double((t - start) / travel) * 5.5 * 2 * Double.pi
                        let point = CGPoint(x: t, y: mid - CGFloat(14 * value * sin(phase)))
                        if t <= cut {
                            if active.isEmpty { active.move(to: point) } else { active.addLine(to: point) }
                        } else {
                            if inactive.isEmpty { inactive.move(to: previous ?? point) }
                            inactive.addLine(to: point)
                        }
                        previous = point
                    }
                    let style = StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                    ctx.stroke(active, with: .color(.white.opacity(0.55)), style: style)
                    ctx.stroke(inactive, with: .color(.white.opacity(0.15)), style: style)
                }
                Capsule().fill(.white)
                    .frame(width: thumb.width, height: thumb.height)
                    .position(x: x, y: geo.size.height / 2)
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if grab == nil {
                        grab = abs(drag.startLocation.x - x) <= thumb.width / 2 ? drag.startLocation.x - x : 0
                    }
                    change(ThemeIntensity.value(x: drag.location.x - (grab ?? 0), width: geo.size.width))
                }
                .onEnded { _ in grab = nil; end() })
        }
        .frame(height: 64)
        .accessibilityElement()
        .accessibilityLabel("Colour strength")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            change(min(max(value + (direction == .increment ? 0.05 : -0.05), 0), 1)); end()
        }
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
