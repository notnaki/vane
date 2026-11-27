import SwiftUI
import UIKit

/// Vane's look on iPhone: the Mac's, scaled for touch. The Space's colour washes the whole
/// ground, the page floats on it as a card, and every row and tile is white laid over that
/// ground rather than a grey of its own (Sources/Vane/Look.swift, ThemeWash.swift).
enum Look {
    /// The default profile colour on the Mac, and the ink of the sail-V icon.
    static let vane = Color(hex: "#6E7DD2")!
    static let pageRadius: CGFloat = 22
    static let pageGap: CGFloat = 6
    static let pillRadius: CGFloat = 14
    /// The floating bar's height over a page; pages scroll their last line above it.
    static let barHeight: CGFloat = 42
    /// Phones with a home indicator have a strip under the bar the buttons can sit down into.
    @MainActor static var homeStrip: Bool {
        ((UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom ?? 0) > 0
    }
    /// How far the bar's buttons sit down into the home-indicator strip, as in Arc Search.
    @MainActor static var barSink: CGFloat { homeStrip ? 9 : 0 }
    /// The room a page leaves at its foot for the bar.
    @MainActor static var barRoom: CGFloat { barHeight - (homeStrip ? 4 : 0) }
    static let rowRadius: CGFloat = 12
    /// "Streamlined" is the Mac's denser interface style; read at launch, as there.
    static let streamlined = UserDefaults.standard.string(forKey: "interfaceStyle") == "streamlined"
    static let rowHeight: CGFloat = streamlined ? 38 : 46
    static let tileHeight: CGFloat = streamlined ? 50 : 58
    static let defaultTint = 0.8
    /// ponytail: flip to true together with com.apple.developer.web-browser in project.yml once
    /// Apple grants it; until then iOS never lists Vane as a browser, so offering it would mislead.
    static let canBeDefaultBrowser = false
    /// The Mac's swatches (Look.themeSwatches), in its order.
    static let swatches = [
        "#F2EAE4", "#F29BBB", "#A6729D", "#F25E6B", "#FF8558", "#F8D558", "#34E895", "#6CBAD9", "#666789",
        "#FEFBFA", "#FFE9F3", "#F1D1EC", "#FFCBD1", "#FFE0D3", "#FFF9E5", "#DEFDEB", "#DCF3FC", "#C5C6E5",
        "#4E3A5A", "#693558", "#8F4042", "#B16D40", "#D7B35D", "#CDCCA4", "#7AA982", "#226149", "#26456B",
        "#FFFFFF", "#E6E6E6", "#CCCCCC", "#B2B2B2", "#808080", "#666666", "#333333", "#1A1A1A", "#000000",
    ]
    /// The Mac's Space icon picker (Spaces.pickerIcons).
    static let spaceIcons = [
        "star.fill", "bookmark.fill", "heart.fill", "flag.fill", "bolt.fill", "triangle.fill", "asterisk", "bell.fill",
        "lightbulb.fill", "square.grid.2x2.fill", "circle.grid.3x3.fill", "square.3.layers.3d", "cylinder.fill", "archivebox.fill",
        "folder.fill", "tray.fill", "calendar", "envelope.fill", "checkmark.square.fill", "doc.fill", "book.fill", "message.fill",
        "person.2.fill", "terminal.fill", "wrench.and.screwdriver.fill", "moon.fill", "sun.max.fill", "globe.americas.fill",
        "leaf.fill", "cloud.fill", "pawprint.fill", "basket.fill", "gift.fill", "fork.knife", "dumbbell.fill", "airplane",
        "music.note", "paintpalette.fill", "video.fill", "chevron.left.forwardslash.chevron.right", "map.fill", "bird.fill",
        "cup.and.saucer.fill", "flame.fill", "scroll.fill", "tram.fill",
    ]
    static let inset: CGFloat = 14
}

extension Color {
    init?(hex: String?) {
        guard let hex, let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return nil }
        self.init(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

/// A Space's theme over the ground, as `ThemeWash` paints it on the Mac: each colour pulled
/// toward grey by the Space's intensity, laid over the window at the Mac's glass opacity,
/// spread evenly corner to corner, with the Space's film grain on top.
struct Wash: View {
    let space: SpaceRow?
    /// The Mac's full-strength wash, for previews of a theme. Everywhere else the Space's
    /// colour is only a light tint over the system background, the way Arc Search keeps it plain.
    var full = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let dark = scheme == .dark
        let tint = space?.tint ?? Look.defaultTint
        let palette = space?.palette.compactMap { Color(hex: $0) } ?? []
        let colors = (palette.isEmpty ? [Look.vane] : palette).map { Self.ground($0, dark: dark, tint: tint) }
        ZStack {
            if full { Color(dark ? .black : .white) } else { Color(.systemBackground) }
            LinearGradient(colors: colors.count == 1 ? [colors[0], colors[0].mix(with: dark ? .black : .white, by: 0.12)] : colors,
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(full ? Self.opacity(dark: dark, tint: tint) : dark ? 0.16 : 0.12)
            // The Mac's grain: white noise (stronger than the Mac's 0.05, as the phone's wash is lighter), plain blend (overlay vanished on dark grounds).
            if let grain = space?.grain, grain > 0 {
                Image(uiImage: Grain.tile).resizable(resizingMode: .tile).interpolation(.none).opacity(grain * (full ? 0.22 : 0.14))
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.35), value: space)
    }
    /// Whether the full wash comes out dark (a near-black theme in light mode, say), so what
    /// sits on it should switch to light text.
    static func isDark(_ space: SpaceRow?, dark: Bool) -> Bool {
        guard !dark else { return true }
        let tint = space?.tint ?? Look.defaultTint
        let palette = space?.palette.compactMap { Color(hex: $0) } ?? []
        let grounds = (palette.isEmpty ? [Look.vane] : palette).map { ground($0, dark: false, tint: tint) }
        let luma = grounds.map { color -> Double in
            let c = UIColor(color).cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [1, 1, 1]
            return 0.2126 * Double(c[0]) + 0.7152 * Double(c[1]) + 0.0722 * Double(c[2])
        }.reduce(0, +) / Double(grounds.count)
        let opacity = Self.opacity(dark: false, tint: tint)
        return (1 - opacity) + opacity * luma < 0.5
    }
    static func boost(_ value: Double) -> Double { let t = min(max((value - 0.8) / 0.2, 0), 1); return t * t * (3 - 2 * t) }
    static func opacity(dark: Bool, tint: Double) -> Double { let base = dark ? 0.62 : 0.78; return base + (0.9 - base) * boost(tint) }
    static func ground(_ color: Color, dark: Bool, tint: Double) -> Color {
        let c = UIColor(color).cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0.5, 0.5, 0.5]
        let v = min(max(tint, 0), 1), shade = dark ? 1 - 0.075 * boost(v) : 1
        func mix(_ x: CGFloat) -> Double { (0.5 + (Double(x) - 0.5) * v) * shade }
        return Color(.sRGB, red: mix(c[0]), green: mix(c[1]), blue: mix(c[2]))
    }
}

/// Text and controls on a Space's full wash: light when the wash is dark.
struct OnWash: ViewModifier {
    let space: SpaceRow?
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.environment(\.colorScheme, Wash.isDark(space, dark: scheme == .dark) ? .dark : scheme)
    }
}

/// The Mac's film grain: one static tile of white noise, made once.
enum Grain {
    @MainActor static let tile: UIImage = {
        let size = 256
        var generator = SystemRandomNumberGenerator()
        // Scale 1: one noise pixel per point, as on the Mac.
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
        return renderer.image { context in
            for x in 0..<size { for y in 0..<size {
                UIColor(white: 1, alpha: CGFloat.random(in: 0...1, using: &generator)).setFill()
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            } }
        }
    }()
}

/// White over the wash, the Mac's fill for rows, tiles and the address pill.
struct GroundFill: ShapeStyle {
    var strength = 1.0
    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        // A plain system grey, as in Safari and Arc Search.
        (environment.colorScheme == .dark ? Color.white.opacity(0.1 * strength) : Color.black.opacity(0.05 * strength)).resolve(in: environment)
    }
}

/// A site's own icon (its apple-touch-icon, then favicon.ico), fetched from the site itself;
/// its initial on a tile while there is none.
struct SiteIcon: View {
    let url: URL
    var size: CGFloat = 20
    @State private var image: UIImage?
    var body: some View {
        let host = url.host() ?? ""
        Group {
            if let image {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            } else {
                Text(String(host.replacingOccurrences(of: "www.", with: "").prefix(1)).uppercased())
                    .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
                    .frame(width: size, height: size)
                    .background(GroundFill(strength: 1.6), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            }
        }
        .frame(width: size, height: size)
        .task(id: host) { image = await SiteIcons.icon(for: host) }
    }
}

@MainActor enum SiteIcons {
    // ponytail: in-memory only, refetched each launch; persist (outside Incognito) if it shows.
    /// Ephemeral, so an Incognito page's icon never reaches the disk cache.
    private static let session = URLSession(configuration: .ephemeral)
    private static var cache: [String: UIImage] = [:]
    private static var missing: Set<String> = []
    static func icon(for host: String) async -> UIImage? {
        if let hit = cache[host] { return hit }
        guard !host.isEmpty, !missing.contains(host) else { return nil }
        for path in ["/apple-touch-icon.png", "/favicon.ico"] {
            guard let url = URL(string: "https://\(host)\(path)"),
                  let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data), image.size.width >= 16 else { continue }
            cache[host] = image
            return image
        }
        missing.insert(host)
        return nil
    }
}

/// A Space's own mark: its SF Symbol or emoji from the Mac, else a dot in its colour.
struct SpaceMark: View {
    let space: SpaceRow
    var size: CGFloat = 16
    var body: some View {
        if let icon = space.icon, UIImage(systemName: icon) != nil {
            Image(systemName: icon).font(.system(size: size, weight: .medium))
        } else if let icon = space.icon, !icon.isEmpty {
            Text(icon).font(.system(size: size))
        } else {
            Circle().fill(Color(hex: space.palette.first) ?? Look.vane).frame(width: size * 0.62, height: size * 0.62)
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
        }
    }
}

/// A row in the Space column: icon, title, and the white fill when it is the current tab.
struct Row<Trailing: View>: View {
    let title: String
    var selected = false
    let icon: AnyView
    let action: () -> Void
    @ViewBuilder var trailing: Trailing
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon.frame(width: 22)
                Text(title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .font(.body.weight(selected ? .medium : .regular))
            .padding(.horizontal, 12).frame(height: Look.rowHeight)
            .background(selected ? AnyShapeStyle(GroundFill(strength: 1.5)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: Look.rowRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Look.rowRadius, style: .continuous))
        }
        .buttonStyle(PressFill())
    }
}
extension Row where Trailing == EmptyView {
    init(title: String, selected: Bool = false, icon: AnyView, action: @escaping () -> Void) {
        self.init(title: title, selected: selected, icon: icon, action: action) { EmptyView() }
    }
}

/// Pressing a row or tile lays the white fill down at once and lifts it slowly, like the Mac.
struct PressFill: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(GroundFill(strength: configuration.isPressed ? 1.2 : 0),
                        in: RoundedRectangle(cornerRadius: Look.rowRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(configuration.isPressed ? nil : .easeOut(duration: 0.25), value: configuration.isPressed)
    }
}

/// While a sheet is up, what's behind it frosts over, so the sheet reads as the one thing
/// in front. Sheets opt in with `.frostsBehind()`; the root view reads the count.
@MainActor @Observable final class Frost {
    static let shared = Frost()
    var sheets = 0
}
extension View {
    func frostsBehind() -> some View {
        onAppear { Frost.shared.sheets += 1 }.onDisappear { Frost.shared.sheets = max(0, Frost.shared.sheets - 1) }
    }
}
