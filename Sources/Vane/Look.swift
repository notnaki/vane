import AppKit
import SwiftUI

/// Vane's look, in one place, so views built in parallel come out matching. Every number a
/// view would otherwise invent lives here. Dark-first, but nothing is hard-coded to dark:
/// semantic colours and materials only, so light mode falls out for free.
enum Look {
    static let sidebarWidth: CGFloat = 250
    /// The web view card, settings cards.
    static let cardRadius: CGFloat = 10
    /// The address pill, favourites tiles, sidebar rows, buttons. The same 10 as the card,
    /// so every rounded thing in the window is one family; only the bar is rounder.
    static let pillRadius: CGFloat = 10
    /// The sidebar's three heights, one family: a row, the address pill above it, and a
    /// favourites tile — Arc's, measured off the reference at 2x (36 on a 40 pitch, 36, 46).
    static let rowHeight: CGFloat = 36
    /// Between rows, so a selected fill never touches its neighbour's. `rowHeight + rowGap`
    /// is the 40pt pitch the whole sidebar is laid out on.
    static let rowGap: CGFloat = 4
    static let pillHeight: CGFloat = 36
    static let tileHeight: CGFloat = 46
    /// Gap between the sidebar and the web card, and around the card.
    static let inset: CGFloat = 8

    // The command bar. The one surface allowed rows taller than `rowHeight`: it is a
    // centred sheet the user is typing into, not a dense list they are scanning. The
    // numbers are Arc's, measured off the reference screenshots at 2x.
    static let barWidth: CGFloat = 760
    static let barRadius: CGFloat = 12
    /// Rows are `barRowHeight` tall on a `barRowHeight + barRowGap` pitch, so a selection
    /// fill has a sliver of ground on every side instead of touching its neighbours.
    static let barRowHeight: CGFloat = 46
    static let barRowGap: CGFloat = 4
    /// The text field's row, which is deliberately taller than any result row.
    static let barFieldHeight: CGFloat = 62
    /// From the bar's edge to a row's fill, and to the ends of the field's divider.
    static let barInset: CGFloat = 10
    /// From a row fill's edge to its icon. `barInset + barRowInset` is where the field's
    /// own icon sits, so the two columns of icons line up.
    static let barRowInset: CGFloat = 12
    /// Favicon / symbol box at the leading edge of a command bar row.
    static let rowIcon: CGFloat = 16
    /// The "→" square on a row that has a trailing label: what Return will press.
    static let chip: CGFloat = 24
    static let chipRadius: CGFloat = 6
    /// The field's type. Larger than body because it is the one thing being typed into.
    static let barFontSize: CGFloat = 18

    // Settings. Rows breathe more than sidebar rows; both numbers stay tied to `rowHeight`
    // and `inset` so there is one rhythm, not three.
    static let settingsRow: CGFloat = rowHeight + inset * 1.5
    /// From a card's edge to its row content, and where its dividers start and stop.
    static let cardInset: CGFloat = inset + 6
    /// A row that is only a title and an arrow ("Your Data and Settings").
    static let linkRow: CGFloat = rowHeight + inset / 2
    /// The coloured glyph square on a link row.
    static let iconTile: CGFloat = 24
    static let iconTileRadius: CGFloat = 6
    /// Side margin of a settings pane, and the Profiles pane's list column.
    static let paneMargin: CGFloat = inset * 4
    static let profileListWidth: CGFloat = 230

    static let text = Font.system(size: 13)
    static let caption = Font.system(size: 11)
    static let heading = Font.system(size: 13, weight: .semibold)
    /// The sidebar's symbol buttons: the top row, the footer, the pill's two glyphs.
    static let icon = Font.system(size: 15, weight: .medium)
    /// Command bar rows: a step heavier than body, the way Arc sets them, so a title reads
    /// at a glance against the grey trailing label.
    static let rowText = Font.system(size: 13, weight: .medium)

    /// The window's ground, over `WindowGlass`. The material alone takes whatever is behind
    /// the window — a white page in another app turns the sidebar milky — so the window's
    /// own background colour is laid over it, most of the way to opaque: dark in dark,
    /// light in light, and the desktop only a hint through it, which is how Arc's reads.
    static let ground = Color(nsColor: .windowBackgroundColor).opacity(0.72)

    /// One surface at graded strengths, so the pill, a tile, a hovered row and a selected row
    /// read as the same material rather than four different greys. Semantic on purpose:
    /// `.primary` is white on dark and black on light.
    static let hovered = Color.primary.opacity(0.05)
    static let pillFill = Color.primary.opacity(0.08)
    static let selected = Color.primary.opacity(0.11)
    /// A selection that belongs to the user's accent rather than to the surface: the
    /// Profiles list, where the selected row is the one whose controls are shown.
    static let accentSelected = Color.accentColor.opacity(0.22)

    /// Command bar row fills. Quieter than `selected`/`hovered`: the bar's ground is
    /// already dark, and a strong grey block there reads as a button, not a highlight.
    static let barSelected = Color.primary.opacity(0.08)
    static let barHovered = Color.primary.opacity(0.05)
    /// The "→" chip. Dim on an ordinary row; brighter on the selected one.
    static let chipFill = Color.primary.opacity(0.08)
    static let chipSelectedFill = Color.primary.opacity(0.16)

    /// The one-pixel lines: card strokes, dividers, field borders.
    static let hairline = Color.primary.opacity(0.08)
    /// Cards sit a step above the window they are in.
    static let cardFill = Color.primary.opacity(0.04)
    /// The bar's inner stroke — a touch brighter than a hairline because it sits on the
    /// darkest surface in the app and has a shadow outside it to hold against.
    static let barStroke = Color.primary.opacity(0.12)

    /// The colours a space can be tinted with. The profile palette first, so a space and its
    /// profile can wear the same colour, then the spread Arc offers.
    /// @MainActor because `ProfileManager.palette` is; every caller is a view anyway.
    @MainActor static let themeSwatches = ProfileManager.palette
        + ["#F2EDE4", "#E48FB1", "#9B6FB0", "#D9564F", "#E08A3C", "#E3C34A", "#4CAF6E", "#5A9BD5"]

    /// Dims the page behind the command bar, so what is being typed reads as the only live
    /// thing on screen. Black rather than a material: it must darken, not blur again.
    /// Light: Arc hardly dims the page, and the bar's own shadow does most of the lifting.
    static let scrim = Color.black.opacity(0.12)
    /// Under a floating surface's glass. Glass alone takes its colour from whatever is
    /// behind it, and a command bar over a white page has to stay dark to stay legible —
    /// so the window's own ground, near-opaque, with the page only a hint through it.
    static let barFill = AnyShapeStyle(WindowBackgroundShapeStyle.windowBackground.opacity(0.92))
    static let barShadow = Color.black.opacity(0.5)
    static let barShadowRadius: CGFloat = 30
    static let barShadowY: CGFloat = 12

    // Motion. Short and easing out: a fill should arrive under the pointer, never chase it.
    /// Hover and selection fills.
    static let quick = Animation.easeOut(duration: 0.12)
    /// A floating surface appearing: scale from `appearScale` and fade, together.
    static let appear = Animation.easeOut(duration: 0.15)
    static let appearScale: CGFloat = 0.97
}

extension Color {
    /// `#RRGGBB` as written in a Profile or a Space. ponytail: no alpha, no short form — the
    /// only producers of these strings are `Look.themeSwatches` and `ProfileManager.palette`.
    init?(hex: String) {
        var v: UInt64 = 0
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, Scanner(string: digits).scanHexInt64(&v) else { return nil }
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

/// Behind-window blur for the window itself — the desktop shows through the sidebar, which
/// is the "transparent glass" of the design. Floating surfaces (command bar, pills) use
/// `.glass()` below instead; this is for the ground they sit on.
struct WindowGlass: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// A one-pixel horizontal rule in the hairline colour. `Divider()` picks its own colour
/// and the card stroke would not match it.
struct Hairline: View {
    var body: some View { Rectangle().fill(Look.hairline).frame(height: 1) }
}

extension View {
    /// Liquid Glass for a floating surface: the command bar, a popover, the address pill.
    /// One call so every surface refracts the same way.
    func glass(radius: CGFloat = Look.cardRadius) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: radius))
    }

    /// The 1px line around a card, a field, the command bar. `strokeBorder` keeps the whole
    /// pixel inside the shape, so it never blurs against the fill's antialiased edge.
    func hairline(radius: CGFloat, _ color: Color = Look.hairline) -> some View {
        overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(color, lineWidth: 1) }
    }
}
