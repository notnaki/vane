import SwiftUI

/// A Space's theme and icon, edited live: up to three colours from the Mac's swatches or any
/// colour, intensity, grain, appearance, and an SF Symbol or emoji. Saved fields sync to the Mac.
struct ThemeEditor: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SpaceRow
    @State private var slot = 0
    @State private var emoji = ""

    init(space: SpaceRow) {
        var space = space
        if space.palette.isEmpty { space.colors = ["#666789"] }
        _draft = State(initialValue: space)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    preview
                    colours
                    sliders
                    appearance
                    icons
                }
                .padding(Look.inset).padding(.bottom, 20)
            }
            .navigationTitle("Theme").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { library.setTheme(draft); dismiss() }.fontWeight(.semibold) }
            }
        }
        .tint(.primary)
        .presentationBackground { Wash(space: draft) }
        .preferredColorScheme(draft.appearance == "dark" ? .dark : draft.appearance == "light" ? .light : nil)
    }

    /// The Space as it will look: its mark and name on its own ground, with a page card.
    private var preview: some View {
        ZStack(alignment: .topLeading) {
            Wash(space: draft).clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SpaceMark(space: draft, size: 18)
                    TextField("Name", text: $draft.name).font(.title3.weight(.semibold))
                }
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(GroundFill()).frame(height: 34)
                    }
                }
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.14), radius: 6, y: 2).frame(height: 70)
            }
            .padding(14)
        }
        .frame(height: 190)
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.4), lineWidth: 1))
    }

    private var colours: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Colours").font(.headline)
                Spacer()
                // One to three colours, like the Mac's gradient themes.
                ForEach(0..<3, id: \.self) { index in
                    let colors = draft.palette
                    Button {
                        if index < colors.count { slot = index }
                        else { draft.colors = colors + [colors.last ?? "#666789"]; slot = colors.count }
                    } label: {
                        Circle().fill(index < colors.count ? (Color(hex: colors[index]) ?? .gray) : .clear)
                            .overlay(Circle().strokeBorder(index == slot ? Color.primary : .primary.opacity(0.25), lineWidth: index == slot ? 2 : 1))
                            .overlay { if index >= colors.count { Image(systemName: "plus").font(.caption.weight(.bold)) } }
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(index < colors.count ? "Colour \(index + 1)" : "Add colour")
                    .contextMenu {
                        if index < colors.count, colors.count > 1 {
                            Button("Remove Colour", systemImage: "minus.circle", role: .destructive) {
                                draft.colors = colors.enumerated().filter { $0.offset != index }.map(\.element); slot = 0
                            }
                        }
                    }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 9), spacing: 8) {
                ForEach(Look.swatches, id: \.self) { hex in
                    Button { set(hex) } label: {
                        Circle().fill(Color(hex: hex)!)
                            .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1))
                            .overlay { if draft.palette.indices.contains(slot), draft.palette[slot] == hex { Circle().strokeBorder(.primary, lineWidth: 2).padding(-3) } }
                            .aspectRatio(1, contentMode: .fit)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Colour \(hex)")
                }
            }
            ColorPicker("Any colour", selection: Binding(
                get: { Color(hex: draft.palette.indices.contains(slot) ? draft.palette[slot] : nil) ?? .gray },
                set: { set($0.hex) }), supportsOpacity: false)
        }
    }

    private var sliders: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Intensity").font(.headline)
                Slider(value: Binding(get: { draft.tint ?? Look.defaultTint }, set: { draft.tint = $0 }), in: 0...1)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Grain").font(.headline)
                Slider(value: Binding(get: { draft.grain ?? 0 }, set: { draft.grain = $0 > 0.01 ? $0 : nil }), in: 0...1)
            }
        }
    }

    private var appearance: some View {
        Picker("Appearance", selection: $draft.appearance) {
            Text("Automatic").tag(String?.none)
            Text("Light").tag(String?.some("light"))
            Text("Dark").tag(String?.some("dark"))
        }
        .pickerStyle(.segmented)
    }

    private var icons: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Icon").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                Button { draft.icon = nil } label: { iconTile(selected: draft.icon == nil) { Circle().fill(Color(hex: draft.palette.first) ?? Look.vane).frame(width: 10, height: 10) } }
                    .accessibilityLabel("Colour dot")
                ForEach(Look.spaceIcons, id: \.self) { name in
                    Button { draft.icon = name } label: { iconTile(selected: draft.icon == name) { Image(systemName: name) } }
                        .accessibilityLabel(name)
                }
            }
            .buttonStyle(.plain)
            HStack {
                Text("Or an emoji")
                TextField("🙂", text: $emoji).multilineTextAlignment(.trailing)
                    .onChange(of: emoji) { _, value in
                        if let first = value.last, first.unicodeScalars.first?.properties.isEmojiPresentation == true || first.unicodeScalars.count > 1 {
                            draft.icon = String(first)
                        }
                        if value.count > 1 { emoji = String(value.suffix(1)) }
                    }
            }
            .padding(.horizontal, 12).frame(height: 44)
            .background(GroundFill(), in: RoundedRectangle(cornerRadius: Look.rowRadius, style: .continuous))
        }
    }

    private func iconTile<Content: View>(selected: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        content().font(.system(size: 16, weight: .medium)).frame(maxWidth: .infinity).frame(height: 38)
            .background(GroundFill(strength: selected ? 2.4 : 0.8), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func set(_ hex: String) {
        var colors = draft.palette
        if colors.indices.contains(slot) { colors[slot] = hex } else { colors = [hex] }
        draft.colors = colors
        draft.colorHex = colors.first
    }
}

extension Color {
    var hex: String {
        let c = UIColor(self).cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0]
        return String(format: "#%02X%02X%02X", Int(round(c[0] * 255)), Int(round(c[1] * 255)), Int(round(c[2] * 255)))
    }
}

/// The Mac's alternate app icons, from the same Icon Composer files.
struct AppIconPicker: View {
    static let icons: [(name: String?, title: String)] = [
        (nil, "Vane"), ("AppIcon-FlutedGlass", "Fluted Glass"), ("AppIcon-FlutedGlassDark", "Fluted Glass Dark"),
        ("AppIcon-Galaxy", "Galaxy"), ("AppIcon-Luminous", "Luminous"), ("AppIcon-Neon", "Neon"),
        ("AppIcon-Candy", "Candy"), ("AppIcon-Schoolbook", "Schoolbook"),
    ]
    @State private var current = UIApplication.shared.alternateIconName
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(Self.icons, id: \.title) { icon in
                    Button {
                        UIApplication.shared.setAlternateIconName(icon.name) { error in
                            if error == nil { Task { @MainActor in current = icon.name } }
                        }
                    } label: {
                        VStack(spacing: 6) {
                            Image("Preview-" + (icon.name ?? "AppIcon")).resizable().scaledToFit().frame(width: 60, height: 60)
                                .overlay { if current == icon.name { RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(.tint, lineWidth: 2.5).padding(-4) } }
                            Text(icon.title).font(.caption2).lineLimit(1)
                        }
                        .frame(width: 76)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(icon.title)
                    .accessibilityAddTraits(current == icon.name ? .isSelected : [])
                }
            }
            .padding(.vertical, 6)
        }
    }
}
