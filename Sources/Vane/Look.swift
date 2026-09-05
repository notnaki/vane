import AppKit
import SwiftUI

/// Vane's look, in one place, so views built in parallel come out matching. Every number a
/// view would otherwise invent lives here. The numbers are Arc's, measured off the reference
/// screenshots at 2x (scratchpad `ARC-LOOK.md`): fills are white-over-ground alphas, type
/// sizes were matched by rendering the same strings with SF and comparing widths.
enum Look {
    static let sidebarWidth: CGFloat = 250
    /// The web view card, settings cards. Arc's card corner is tight — 5–6pt fitted to the
    /// 2x corner profile — while its rows are round; they are not one family.
    static let cardRadius: CGFloat = 6
    /// The address pill, favourites tiles, sidebar rows, buttons. Fitted at 12 (a 24px arc
    /// at 2x); 10 undershot every sample.
    static let pillRadius: CGFloat = 12
    /// The sidebar's three heights, one family: a row, the address pill above it, and a
    /// favourites tile — Arc's, measured off the reference at 2x (36 on a 41 pitch, 36, 46).
    static let rowHeight: CGFloat = 36
    /// Between rows, so a selected fill never touches its neighbour's. `rowHeight + rowGap`
    /// is the 41pt pitch the whole sidebar is laid out on (Vesta 474 → NoNote 556 → … every
    /// row 82px apart in ref 1).
    static let rowGap: CGFloat = 5
    static let pillHeight: CGFloat = 36
    static let tileHeight: CGFloat = 46
    /// The sidebar's side padding, and the gap between a pill's edge and the card.
    static let inset: CGFloat = 8
    /// Around the page card on its top, trailing and bottom edges — a point more than the
    /// sidebar's own padding, which is how Arc's reads (18px at 2x on every side but the
    /// sidebar's).
    static let cardGap: CGFloat = 9
    /// Inside a row: from its fill to the favicon, and from the favicon to the title.
    static let rowInset: CGFloat = 10
    static let rowSpacing: CGFloat = 11
    /// From a row's fill to its trailing glyph (the close ×).
    static let rowTrailingInset: CGFloat = 12
    /// From the address pill's fill to its host text.
    static let pillInset: CGFloat = 14
    /// The Tidy | Clear divider row: a caption's height, butted to the row above it, with
    /// `sectionGap` to the New Tab row below. Arc's label centre sits 6.5pt under the last
    /// pinned row and New Tab's top 22.5pt under that.
    static let tidyRow: CGFloat = 13
    static let sectionGap: CGFloat = 18

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
    static let barInset: CGFloat = 9
    /// From a row fill's edge to its icon. `barInset + barRowInset + rowIcon / 2` is the
    /// icon column's centre line (30), which the field's own icon sits on too.
    static let barRowInset: CGFloat = 13
    /// From a bar row's icon to its title.
    static let barRowSpacing: CGFloat = 13
    /// Favicon / symbol box at the leading edge of a command bar row. Arc draws bar favicons
    /// at 14 and the selected row's on a 24pt plate; 16 is the sidebar's, kept for one
    /// favicon cache.
    static let rowIcon: CGFloat = 16
    /// The "→" square on a row that has a trailing label: what Return will press.
    static let chip: CGFloat = 24
    static let chipRadius: CGFloat = 6
    /// The field's type. Larger than body because it is the one thing being typed into.
    static let barFontSize: CGFloat = 18
    /// The magnifying glass beside it, and the symbols standing in for favicons on rows —
    /// Arc's are small (24px at 2x) and regular weight.
    static let fieldIcon = Font.system(size: 13)

    // Find bar. A strip over the page card rather than a sheet: small type, a field wide
    // enough for a phrase, and a fixed slot for "128 of 250" so stepping through the
    // matches never shuffles the buttons beside it a pixel at a time.
    static let findFontSize: CGFloat = 12
    static let findFieldWidth: CGFloat = 180
    static let findCountWidth: CGFloat = 64

    // Settings. Arc's rows are 43 (86px), its link rows 34, its list rows 32 on a 40 pitch.
    static let settingsRow: CGFloat = 43
    /// From a card's edge to its row content, and where its dividers start and stop.
    static let cardInset: CGFloat = inset + 6
    /// A row that is only a title and an arrow ("Your Data and Settings").
    static let linkRow: CGFloat = 34
    /// A row of the Profiles list: its fill, and the vertical margin that makes the pitch.
    static let listRow: CGFloat = 32
    static let listRowGap: CGFloat = 4
    /// The coloured glyph square on a link row.
    static let iconTile: CGFloat = 24
    static let iconTileRadius: CGFloat = 6
    /// Side margin of a settings pane, and the Profiles pane's list column.
    static let paneMargin: CGFloat = inset * 4
    static let profileListWidth: CGFloat = 230

    /// The sidebar's two fixed strips: traffic lights and navigation above, library and
    /// spaces below. Arc's top strip is 45 tall with the lights and glyphs centred at 22.5;
    /// its footer glyphs sit 24 above the window's bottom edge.
    static let topRow: CGFloat = 28
    /// Above the top row, so its centre line is `lightsCentre` below the window's edge — the
    /// line the traffic lights are brought down to in `VaneWindow`. The lights move to the
    /// row, not the row to the lights.
    static let topInset: CGFloat = 9
    /// The traffic lights' centre line, and so the top row's.
    static let lightsCentre: CGFloat = 23
    static let footer: CGFloat = 28
    /// Under the footer.
    static let footerInset: CGFloat = 10
    /// A favourite tile's icon: the same 16 as a row's (32px at 2x in ref 1).
    static let tileIcon: CGFloat = 16
    /// A space dot in the footer.
    static let dot: CGFloat = 8
    /// The line a drop will land on: before or after a tile, above or below a row.
    static let dropLine: CGFloat = 2

    /// The theme editor popover: seven swatches an `inset` apart, plus its margins. A swatch
    /// is Arc's, measured off ref 8 at 2x.
    static let swatch: CGFloat = 24
    static let themeWidth: CGFloat = swatch * 7 + inset * 6 + inset * 4

    static let text = Font.system(size: 13)
    /// A sidebar row's title, the space's name, New Tab: Arc sets these a point larger than
    /// body ("Vesta macOS Terminal" is 288px wide at 2x — 14 regular to the pixel).
    static let rowTitle = Font.system(size: 14)
    static let caption = Font.system(size: 11)
    /// Tidy | Clear: caption-sized but heavy, the way Arc sets them.
    static let sectionCaption = Font.system(size: 11, weight: .semibold)
    /// A settings footnote. Arc's are 12, a step under the rows they explain.
    static let footnote = Font.system(size: 12)
    static let heading = Font.system(size: 13, weight: .semibold)
    /// Secondary type: the find field, a download's name, the current space's dot.
    static let small = Font.system(size: 12)
    /// The sidebar's symbol buttons: the top row and the footer (16 medium: sidebar.left
    /// 37×29px, arrow.left 30×24, plus 28×28).
    static let icon = Font.system(size: 16, weight: .medium)
    /// The address pill's two glyphs, a step smaller than the top row's (link 29×29px).
    static let pillGlyph = Font.system(size: 14, weight: .medium)
    /// The space's icon at the head of the list (cloud 32×22px).
    static let spaceIcon = Font.system(size: 14)
    /// A symbol standing in a `rowIcon` box where a favicon would be: bar rows, pickers.
    static let symbol = Font.system(size: 13)
    /// A glyph inside a small tile: a link row's coloured square.
    static let glyph = Font.system(size: 12, weight: .semibold)
    /// The "→" in a chip.
    static let chipGlyph = Font.system(size: 13, weight: .medium)
    /// The glyphs a row grows on hover — the close "×", the speaker (xmark 20×20px = 13).
    static let rowGlyph = Font.system(size: 13)
    /// Command bar rows: a step heavier than body, the way Arc sets them, so a title reads
    /// at a glance against the grey trailing label.
    static let rowText = Font.system(size: 13, weight: .medium)

    /// White in dark, black in light, at one strength. Keyed off the *window's* appearance
    /// rather than SwiftUI's colour scheme, so a space pinned to dark gets white ink even
    /// when the system is light. `Color.primary.opacity(x)` was not this: primary is itself
    /// 85 % white, so every fill came out 15 % weaker than its number said.
    static func ink(_ alpha: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: dark ? 1 : 0, alpha: alpha)
        })
    }

    /// Arc's four strengths of type on the sidebar: a tab title (#D4D5D4 on its ground),
    /// the glyphs and the host, the space name and New Tab, and Tidy | Clear.
    static let inkPrimary = ink(0.80)
    static let inkSecondary = ink(0.60)
    static let inkTertiary = ink(0.45)
    static let inkQuiet = ink(0.30)
    /// A disabled glyph (Arc's forward arrow with nowhere to go: 115 on 66).
    static let inkDisabled = ink(0.26)

    /// One surface at graded strengths, so the pill, a tile, a hovered row and a selected row
    /// read as the same material rather than four different greys. Arc: rest and hover are
    /// one step (84 on 66), the selection two (102 on 66), and a hovered pill or tile takes
    /// the selection's step because it is a button, not a row among rows.
    static let hovered = ink(0.10)
    static let pillFill = ink(0.10)
    static let selected = ink(0.19)
    /// A selection that belongs to the user's accent rather than to the surface: the
    /// Profiles list, where the selected row is the one whose controls are shown. Arc's is
    /// a whisper of blue (29,34,46 on 27).
    static let accentSelected = Color.accentColor.opacity(0.10)

    /// The one-pixel lines: dividers, field borders.
    static let hairline = ink(0.08)
    /// Settings cards: barely lifted from the window (30 on 27), with a stroke that does the
    /// separating (52 on 27).
    static let cardFill = ink(0.015)
    static let cardStroke = ink(0.11)
    /// A settings button or popup's fill (45 on 30), 24 tall.
    static let controlFill = ink(0.08)
    static let control: CGFloat = 24
    /// A footer dot for a space that is not the current one (101 on 66, 16px).
    static let dotFill = ink(0.20)

    /// The colours a space can be tinted with. The profile palette first, so a space and its
    /// profile can wear the same colour, then the spread Arc offers.
    /// @MainActor because `ProfileManager.palette` is; every caller is a view anyway.
    @MainActor static let themeSwatches = ProfileManager.palette
        + ["#F2EDE4", "#E48FB1", "#9B6FB0", "#D9564F", "#E08A3C", "#E3C34A", "#4CAF6E", "#5A9BD5"]

    /// The strength a space's colour has before anyone touches the slider.
    static let defaultTint = 0.35

    // MARK: The ground

    /// How much of the derived ground colour sits over the blurred desktop. Arc's black
    /// theme reads 33–36 over a dark wallpaper and 66–73 over a bright one; at 0.62 over
    /// `WindowGlass` (`.fullScreenUI`, itself ~44 % opaque) ours spans 30 over black to 84
    /// over white, a fifth of the backdrop showing through. Light is laid on heavier: a
    /// pale ground a fifth wallpaper turns to mud over a dark desktop.
    static func groundOpacity(dark: Bool) -> Double { dark ? 0.62 : 0.78 }

    /// The sidebar's colour for a space, the way Arc derives it: the hue is kept, dark takes
    /// the colour down to ~14 % brightness with its saturation *raised* (Arc's green space
    /// has a `#001E15` background), light takes it up to 96 % with most of the saturation
    /// gone. `strength` is the space's `tint` slider, 0…1, and scales the saturation: at the
    /// default 0.35 dark is ×1.44 and light ×0.24. A grey colour stays grey — Arc's black
    /// "sky" theme is (36,36,36) with nothing behind it.
    /// Pure, so `selfcheck --pure` can prove it; `groundColor` wraps it for views.
    nonisolated static func ground(hex: String, dark: Bool, strength: Double = defaultTint)
        -> (r: Double, g: Double, b: Double)? {
        guard let (h, s, _) = hsb(hex: hex) else { return nil }
        let k = 0.5 + 2 * min(max(strength, 0), 1)
        let sat = dark ? min(1, s * 1.2 * k) : min(1, s * 0.2 * k)
        let bri = dark ? 0.14 : 0.96
        return rgb(h: h, s: sat, b: bri)
    }

    static func groundColor(hex: String, dark: Bool, strength: Double) -> Color {
        guard let c = ground(hex: hex, dark: dark, strength: strength) else { return .clear }
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b)
    }

    /// `#RRGGBB` → hue (0…1), saturation, brightness. Nil for anything else.
    nonisolated static func hsb(hex: String) -> (h: Double, s: Double, b: Double)? {
        var v: UInt64 = 0
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, Scanner(string: digits).scanHexInt64(&v) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255, g = Double((v >> 8) & 0xFF) / 255, b = Double(v & 0xFF) / 255
        let hi = max(r, g, b), lo = min(r, g, b), d = hi - lo
        guard hi > 0, d > 0 else { return (0, 0, hi) }
        var h: Double
        if hi == r { h = (g - b) / d } else if hi == g { h = 2 + (b - r) / d } else { h = 4 + (r - g) / d }
        h /= 6
        if h < 0 { h += 1 }
        return (h, d / hi, hi)
    }

    nonisolated static func rgb(h: Double, s: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = b * (1 - s), q = b * (1 - s * f), t = b * (1 - s * (1 - f))
        switch i {
        case 0: return (b, t, p)
        case 1: return (q, b, p)
        case 2: return (p, b, t)
        case 3: return (p, q, b)
        case 4: return (t, p, b)
        default: return (b, p, q)
        }
    }

    // MARK: Floating surfaces

    /// Dims the page behind the command bar, so what is being typed reads as the only live
    /// thing on screen. Black rather than a material: it must darken, not blur again.
    /// Light: Arc hardly dims the page, and the bar's own shadow does most of the lifting.
    static let scrim = Color.black.opacity(0.12)
    /// The bar's ground: Arc's is #141414 and all but opaque (20 over a black page, 23 over
    /// a (22,22,24) one). Always dark, whatever the appearance — the bar forces its colour
    /// scheme — so these are plain white alphas, not `ink`.
    static let barFill = Color(white: 0.08).opacity(0.96)
    /// The one blur allowed on a floating surface, *under* `barFill`. Arc's bar is flat —
    /// no Liquid Glass, no specular rim, no refraction — but the page behind it is still
    /// softened rather than merely dimmed, which is what this does and all it does.
    static let barMaterial = AnyShapeStyle(Material.regular)
    /// The bar's stroke (74 on 20): brighter than a hairline because it sits on the darkest
    /// surface in the app and has a shadow outside it to hold against.
    static let barStroke = Color.white.opacity(0.22)
    /// Command bar row fills (42 on 20). Quieter than the sidebar's: the bar's ground is
    /// already dark, and a strong grey block there reads as a button, not a highlight.
    static let barSelected = Color.white.opacity(0.10)
    static let barHovered = Color.white.opacity(0.05)
    /// The "→" chip (32 on 20). On the selected row Arc's chip is the row's own fill; one
    /// step over whatever it sits on says the same thing.
    static let chipFill = Color.white.opacity(0.05)
    /// The bar's type: a title (208 on 20), the placeholder (149), a trailing verb (97), and
    /// the selected row's, which is white.
    static let barText = Color.white.opacity(0.80)
    static let barPlaceholder = Color.white.opacity(0.55)
    static let barTrailing = Color.white.opacity(0.33)
    static let barGlyph = Color.white.opacity(0.68)
    static let barSelectedText = Color.white
    static let barShadow = Color.black.opacity(0.5)
    static let barShadowRadius: CGFloat = 30
    static let barShadowY: CGFloat = 12
    /// The small floaters inside the card — find, the save-password prompt. Lighter and
    /// tighter than the bar's: they sit on the page, not over the whole window.
    static let floatShadow = Color.black.opacity(0.3)
    static let floatShadowRadius: CGFloat = 12
    static let floatShadowY: CGFloat = 4

    // Motion. Short and easing out: a fill should arrive under the pointer, never chase it.
    /// Hover and selection fills.
    static let quick = Animation.easeOut(duration: 0.15)
    /// A floating surface appearing: scale from `appearScale` and fade, together.
    static let appear = Animation.easeOut(duration: 0.15)
    static let appearScale: CGFloat = 0.97
    /// The tab list changing shape: a row arriving, leaving, or moving between sections. A
    /// touch of spring, the way Arc's rows settle, but short enough that ⌘W ⌘W ⌘W never
    /// queues up behind itself.
    static let list = Animation.spring(duration: 0.28, bounce: 0.12)
    /// Clear sweeps Today's rows out one after another: each row leaves this much after the
    /// one above it, and a long list stops staggering past `sweepCap` so forty tabs do not
    /// take two seconds to go.
    static let sweepStagger: Double = 0.045
    static let sweepCap: Double = 0.4
    /// The status bar: how long a link is hovered before its url appears, and how fast the
    /// capsule fades either way.
    static let statusDelay: Double = 1.5
    static let statusFade = Animation.easeOut(duration: 0.18)
    /// The status capsule's inset from the card's corner, its height, and the longest url it
    /// shows before the middle is elided.
    static let statusInset: CGFloat = 8
    static let statusHeight: CGFloat = 24
    static let statusMaxChars = 72
    /// A favourite tile appearing or leaving the grid grows in place rather than sliding.
    static let tileAppearScale: CGFloat = 0.6

    // The recent tab switcher (⌃⇥): up to five cards in a row over the page, a favicon
    // over two lines of title each.
    static let switcherCard: CGFloat = 120
    static let switcherCardHeight: CGFloat = 92
    static let switcherIcon: CGFloat = 24
    /// ⌃ held shorter than this is a tap — switch, but never draw the row.
    static let switcherDelay: Double = 0.15

    // Toasts: a pill above the sidebar's footer, gone after `toastDuration` unless hovered.
    static let toastHeight: CGFloat = 32
    static let toastDuration: Double = 3
    /// How much of the space's colour washes over the pill's dark ground.
    static let toastTint: Double = 0.45
}

extension Look {
    /// The chrome's geometry and the ground derivation, proved offline. These are the
    /// numbers a screenshot is measured against, so a change to one of them should fail
    /// here before anyone has to look.
    nonisolated static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        out.append(("the lights' centre line is the sidebar top row's centre line",
                    lightsCentre == topInset + topRow / 2))
        // 800 stands for the window's top edge wherever AppKit parented the buttons; only
        // the offset from it matters, which is what makes the arithmetic testable at all.
        out.append(("a 14pt light's origin puts its centre on that line",
                    VaneWindow.lightOriginY(windowTop: 800, buttonHeight: 14) == 800 - lightsCentre - 7))
        out.append(("the offset is from the top edge, not from the window's height",
                    VaneWindow.lightOriginY(windowTop: 100, buttonHeight: 14)
                        == VaneWindow.lightOriginY(windowTop: 800, buttonHeight: 14) - 700))
        out.append(("a bigger light still centres on the same line",
                    VaneWindow.lightOriginY(windowTop: 800, buttonHeight: 20)
                        == VaneWindow.lightOriginY(windowTop: 800, buttonHeight: 14) - 3))
        out.append(("the sidebar is laid out on Arc's 41pt row pitch", rowHeight + rowGap == 41))
        out.append(("the top strip is Arc's 45pt", topInset + topRow + inset == 45))
        out.append(("the Tidy row and New Tab are Arc's 31pt apart",
                    tidyRow + sectionGap == 31))
        out.append(("the footer glyphs sit 24pt above the window's bottom edge",
                    footer / 2 + footerInset == 24))
        out.append(("rows and the bar share one radius", pillRadius == barRadius))
        out.append(("the command bar's rows keep Arc's 50pt pitch", barRowHeight + barRowGap == 50))
        out.append(("the bar's icon column is centred at 30",
                    barInset + barRowInset + rowIcon / 2 == 30))

        // The ground. Tolerances are ±2/255: what a screenshot can be measured to.
        func near(_ v: Double, _ want: Double) -> Bool { abs(v * 255 - want) <= 2 }
        let black = ground(hex: "#000000", dark: true)
        out.append(("a black space is a dark neutral grey (36,36,36), not black and not blue",
                    black.map { near($0.r, 36) && near($0.g, 36) && near($0.b, 36) } == true))
        let blue = ground(hex: "#5A9BD5", dark: true)
        out.append(("a blue space's dark ground keeps its hue: blue leads, red trails",
                    blue.map { $0.b > $0.g && $0.g > $0.r } == true))
        out.append(("a blue space's dark ground is as deep as the black one (14 % brightness)",
                    blue.map { near(max($0.r, $0.g, $0.b), 36) } == true))
        out.append(("dark raises the saturation: the ground is more saturated than the swatch",
                    blue.map { hsbOf($0).s > hsb(hex: "#5A9BD5")!.s } == true))
        let light = ground(hex: "#5A9BD5", dark: false)
        out.append(("a blue space's light ground is a pale tint (96 % brightness, still blue-led)",
                    light.map { near(max($0.r, $0.g, $0.b), 245) && $0.b > $0.r } == true))
        out.append(("light keeps only a hint of the saturation",
                    light.map { hsbOf($0).s < 0.2 } == true))
        let strong = ground(hex: "#5A9BD5", dark: true, strength: 1)
        let weak = ground(hex: "#5A9BD5", dark: true, strength: 0)
        out.append(("the tint slider scales saturation, brightness untouched",
                    strong.map { s in weak.map { w in hsbOf(s).s > hsbOf(w).s
                        && near(max(s.r, s.g, s.b), 36) && near(max(w.r, w.g, w.b), 36) } } == true))
        out.append(("Arc's default lavender resolves in both appearances",
                    ground(hex: "#6E7DD2", dark: true) != nil && ground(hex: "#6E7DD2", dark: false) != nil))
        out.append(("a colour that is not #RRGGBB has no ground", ground(hex: "sky", dark: true) == nil))
        out.append(("hsb round-trips a pure red", {
            guard let h = hsb(hex: "#FF0000") else { return false }
            let c = rgb(h: h.h, s: h.s, b: h.b)
            return near(c.r, 255) && near(c.g, 0) && near(c.b, 0)
        }()))
        return out
    }

    /// The saturation of an rgb triple, for the checks above.
    nonisolated private static func hsbOf(_ c: (r: Double, g: Double, b: Double)) -> (s: Double, b: Double) {
        let hi = max(c.r, c.g, c.b), lo = min(c.r, c.g, c.b)
        return (hi > 0 ? (hi - lo) / hi : 0, hi)
    }
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
/// is the "transparent glass" of the design. This is the *only* blur in the window chrome:
/// every control on top of it is a flat fill from `Look`, the way Arc's are. Floating
/// surfaces add `Look.barMaterial` under `Look.barFill`, never Liquid Glass.
/// `.fullScreenUI` because it is the most transparent material AppKit has (44 % opaque in a
/// probe over white and black; `.underWindowBackground` read as good as opaque), and the
/// whole point is the wallpaper reading through `Look.groundColor` on top of it.
struct WindowGlass: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .fullScreenUI
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
    /// The 1px line around a card, a field, the command bar. `strokeBorder` keeps the whole
    /// pixel inside the shape, so it never blurs against the fill's antialiased edge.
    func hairline(radius: CGFloat, _ color: Color = Look.hairline) -> some View {
        overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(color, lineWidth: 1) }
    }
}
