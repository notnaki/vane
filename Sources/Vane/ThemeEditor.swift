import AppKit
import SwiftUI

/// Arc's Space theme editor: the dot-grid canvas the Space's colours are dragged around on,
/// the preset circles under it, and the intensity slider beside the grain dial along the
/// bottom. It replaces the old panel's swatch grid and `Slider`, which said the same three
/// things in the vocabulary of a settings pane rather than of a theme.
///
/// Everything applies as it is dragged — the Space already exists by the time this is on
/// screen, so there is nothing to cancel and closing the panel is the whole of "done".
///
/// ponytail: one view for both routes into it. The footer's `+` opens it with the name field
/// (a new Space still has to be called something), the dot's "Edit Theme Color…" without;
/// two panels that drift apart is exactly what this file is replacing.
struct ThemeEditor: View {
    let store: TabStore
    /// The Space as the sidebar last read it. Every change goes through `edit`, which re-reads
    /// it from the store first, so a stale copy is never written back over another window's.
    let space: Space
    /// Whether the panel also names the Space. The `+` route does; Arc names a Space in the
    /// sidebar, and so does Vane once it exists.
    var naming = false

    @State private var name = ""
    /// Which page of presets the chevrons have walked to.
    @State private var page = 0
    /// Which colour dot a preset lands on: the last one touched, so tapping a swatch changes
    /// the dot you were just dragging rather than always the first.
    @State private var selected = 0
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private var colors: [String] { Spaces.themeColors(of: space) }

    var body: some View {
        VStack(spacing: Look.inset) {
            if naming { nameRow }
            canvas
            presets
            HStack(spacing: Look.inset * 1.5) {
                WaveSlider(value: space.tint ?? Look.defaultTint) { v in edit { $0.tint = v } }
                GrainDial(value: space.grain ?? 0) { v in edit { $0.grain = v } }
            }
        }
        .padding(Look.inset)
        // Sized here, not by the popover: NSPopover takes the hosting view's first fitting
        // size, which for a flexible canvas plus a slider comes out narrower than the content.
        .frame(width: Look.themeWidth)
        .fixedSize()
        .onAppear { name = space.name; focused = naming }
        // The name is committed on the way out too: a panel dismissed by clicking the page
        // must not throw away what was typed into it.
        .onDisappear { commit() }
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
                Image(systemName: space.icon ?? "cloud").font(Look.spaceIcon)
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
    private var canvas: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                grid
                ForEach(Array(colors.enumerated()), id: \.offset) { i, hex in
                    dot(i, hex, in: geo.size)
                }
            }
            .coordinateSpace(.named(fieldSpace))
        }
        .frame(height: Look.themeCanvas)
        .background(Look.pillFill, in: .rect(cornerRadius: Look.pillRadius))
        .overlay(alignment: .top) { appearance.padding(.top, Look.inset * 1.5) }
        .overlay(alignment: .bottom) { steps.padding(.bottom, Look.inset * 1.5) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Theme colours")
    }

    /// One path for the whole grid, filled once: a thousand separate `fill`s is a thousand
    /// draw calls on every frame of a drag.
    private var grid: some View {
        Canvas { ctx, size in
            var path = Path()
            var x = Look.themeGrid
            while x < size.width {
                var y = Look.themeGrid
                while y < size.height {
                    path.addEllipse(in: CGRect(x: x - Look.themeGridDot / 2,
                                               y: y - Look.themeGridDot / 2,
                                               width: Look.themeGridDot, height: Look.themeGridDot))
                    y += Look.themeGrid
                }
                x += Look.themeGrid
            }
            ctx.fill(path, with: .color(Look.inkQuiet))
        }
        .accessibilityHidden(true)
    }

    private func dot(_ i: Int, _ hex: String, in size: CGSize) -> some View {
        let p = Spaces.themePoint(hex: hex) ?? (x: 0.5, y: 0.5)
        return Circle()
            .fill(Color(hex: hex) ?? .gray)
            .overlay { Circle().strokeBorder(.white, lineWidth: Look.themeRing) }
            .frame(width: Look.themeDot, height: Look.themeDot)
            // Before `.position`, which takes all the space it is offered: a gesture added
            // after it would take the whole canvas with it.
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(fieldSpace))
                .onChanged { drag in
                    selected = i
                    var list = colors
                    guard list.indices.contains(i), size.width > 0, size.height > 0 else { return }
                    list[i] = Spaces.themeHex(x: drag.location.x / size.width,
                                              y: drag.location.y / size.height)
                    edit { Spaces.setThemeColors(list, on: &$0) }
                })
            .position(x: p.x * size.width, y: p.y * size.height)
            .accessibilityLabel("Theme colour \(i + 1)")
            .accessibilityValue(hex)
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
                .background(space.appearance == value ? Look.selected : .clear,
                            in: .rect(cornerRadius: Look.cardRadius))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(space.appearance == value ? Look.inkPrimary : Look.inkTertiary)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(space.appearance == value ? [.isButton, .isSelected] : .isButton)
    }

    /// − and + at the canvas' foot: how many colours the ground is mixed from.
    private var steps: some View {
        HStack(spacing: Look.inset * 4) {
            step("minus", "Remove a colour", enabled: colors.count > 1) {
                edit { Spaces.setThemeColors(colors.dropLast(), on: &$0) }
                selected = max(0, colors.count - 2)
            }
            step("plus", "Add a colour", enabled: colors.count < Spaces.maxThemeColors) {
                edit { Spaces.setThemeColors(colors + [Spaces.nextThemeColor(after: colors)], on: &$0) }
                selected = colors.count
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

    /// Arc's row of ready-made theme colours, a page at a time between two chevrons. The
    /// keyboard and VoiceOver route to a colour: the canvas is a pointer control, these are
    /// real buttons with names.
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
            chevron("chevron.right", "More colours", enabled: start + Look.swatchPage < all.count) {
                page += 1
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preset colours")
    }

    private func swatch(_ hex: String) -> some View {
        Circle()
            .fill(Color(hex: hex) ?? .gray)
            .frame(width: Look.swatch, height: Look.swatch)
            // Arc's ring stands off the swatch rather than lying on its edge, so the chosen
            // colour is still a full disc.
            .overlay {
                Circle().strokeBorder(.primary, lineWidth: 2)
                    .padding(-3)
                    .opacity(colors.contains(hex) ? 1 : 0)
            }
            .contentShape(.circle)
            .onTapGesture { pick(hex) }
            .help(hex)
            .accessibilityLabel("Theme colour \(hex)")
            .accessibilityAddTraits(colors.contains(hex) ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { pick(hex) }
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
        if list.indices.contains(selected) { list[selected] = hex } else { list = [hex] }
        edit {
            Spaces.setThemeColors(list, on: &$0)
            $0.tint = $0.tint ?? Look.defaultTint
        }
    }

    // MARK: Writing it down

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard naming, !trimmed.isEmpty, trimmed != space.name else { return }
        edit { $0.name = trimmed }
        rebuild()                       // the Spaces menu lists the names
    }

    /// ponytail: every drag frame writes spaces.json, the way the old strength slider did.
    /// The file is a few hundred bytes and the alternative is a commit-on-release that leaves
    /// the window wearing a colour nothing has written down. Ceiling: a long drag is a few
    /// hundred small writes.
    private func edit(_ change: (inout Space) -> Void) {
        guard var copy = store.spaces.first(where: { $0.id == space.id }) else { return }
        change(&copy)
        store.update(space: copy)
    }
}

/// The canvas' own coordinate space, so a dot's drag is reported against the field it is
/// being dragged across rather than against the 44pt circle under the pointer.
private let fieldSpace = "vane.theme.field"

// MARK: - The intensity slider

/// How strongly the Space's colour washes over the window — the existing `Space.tint` —
/// drawn as Arc draws it: a sinusoid along the track whose amplitude dies away past the
/// thumb, so the control shows what it does instead of naming it.
private struct WaveSlider: View {
    let value: Double
    let change: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let travel = max(geo.size.width - Look.themeThumb.width, 1)
            let x = Look.themeThumb.width / 2 + CGFloat(value) * travel
            ZStack {
                Capsule().fill(Look.pillFill).frame(height: Look.themeTrack)
                wave
                    .padding(.horizontal, Look.themeThumb.width / 2)
                Capsule()
                    .fill(.white)
                    .frame(width: Look.themeThumb.width, height: Look.themeThumb.height)
                    .position(x: x, y: geo.size.height / 2)
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged {
                change(min(max(($0.location.x - Look.themeThumb.width / 2) / travel, 0), 1))
            })
        }
        .frame(height: Look.themeThumb.height)
        .accessibilityElement()
        .accessibilityLabel("Colour strength")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            change(min(max(value + (direction == .increment ? 0.1 : -0.1), 0), 1))
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
                       style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - The grain dial

/// How much static noise the ground wears, as Arc's knob: a dotted ring that fills up as the
/// knob is turned, and a white pointer on the knob itself. Three quarters of a turn, with the
/// dead quarter at the bottom — see `Spaces.dialValue`.
private struct GrainDial: View {
    let value: Double
    let change: (Double) -> Void

    var body: some View {
        ZStack {
            ring
            Circle().fill(Look.controlFill).frame(width: Look.themeDial, height: Look.themeDial)
            marker
        }
        .frame(width: Look.themeDialRing, height: Look.themeDialRing)
        .contentShape(.circle)
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            let centre = Look.themeDialRing / 2
            change(Spaces.dialValue(dx: Double(drag.location.x - centre),
                                    dy: Double(drag.location.y - centre)))
        })
        .help("Grain")
        .accessibilityElement()
        .accessibilityLabel("Grain")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            change(min(max(value + (direction == .increment ? 0.1 : -0.1), 0), 1))
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

    /// Radially out of the knob's edge, pointing wherever the knob is turned. Drawn due west
    /// and rotated from there, so the one number in it is the dial's own angle.
    private var marker: some View {
        Capsule()
            .fill(.white)
            .frame(width: Look.themeMarker.width, height: Look.themeMarker.height)
            .offset(x: -(Look.themeDial / 2 + Look.themeMarker.width / 2))
            .rotationEffect(.radians(Spaces.dialAngle(value) + .pi / 2))
    }
}
