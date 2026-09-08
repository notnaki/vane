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
    /// From a row's fill to its trailing edge: the close ×'s target on a tab row, and simply
    /// where the title's box stops on the rows that have no glyph at all — New Tab, and the
    /// Space preview's rows in `SpacesUI`. Left where it was when the × grew a target
    /// (`rowTarget`), which is a square around a much smaller glyph: the × now reads a few
    /// points further in than it did, and buying that back by trimming the inset would move
    /// the trailing edge of every row in the app, including the ones with nothing in it.
    static let rowTrailingInset: CGFloat = 12
    /// A row's trailing glyphs — the speaker and the close × — are pressable squares, not
    /// bare glyphs. `rowGlyph` draws an × 15×13 in a 36pt row: a third of the row's height
    /// to aim at, and a near miss is not nothing, because the row answers a click of its
    /// own by *showing* the tab. Missing the × switches to the tab you were closing, which
    /// is why "the × doesn't really work" is what it feels like. A control's worth of square
    /// is the target; the glyph is only what you can see of it.
    static let rowTarget: CGFloat = control
    /// From the address pill's fill to its host text.
    static let pillInset: CGFloat = 14
    /// Between the pill's glyphs and the host between them. An action badge is sized against
    /// it: a badge wider than its icon plus this gap would touch the glyph beside it.
    static let pillGlyphGap: CGFloat = 8
    /// The Tidy | Clear divider row: a caption's height, butted to the row above it, with
    /// `sectionGap` to the New Tab row below. Arc's label centre sits 6.5pt under the last
    /// pinned row and New Tab's top 22.5pt under that.
    static let tidyRow: CGFloat = 13
    /// How many Today tabs a Space has to hold before Tidy and Clear are offered at all.
    /// Below it there is no pile: five tabs fit in the strip and the one you want is the one
    /// you can already see, so two housekeeping actions over them are noise on every new
    /// Space, every window, every morning. Arc's number, and the same six `TidyTabs`
    /// defaults its own threshold to.
    ///
    /// A count, not a size, but it lives here because it is a rule about what the sidebar
    /// *shows* — the row's height above is meaningless without it.
    static let tidyThreshold = 6
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
    /// The site's initial, standing in a favicon's box while a tab has none — a fraction of
    /// the box rather than a point size, because that box is 16 in a row and 16 in a tile.
    /// Short of the full box, so a letter and an icon read as one size.
    static let letterScale: CGFloat = 0.72
    /// That letter's type, for a box of `box` points. Rounded and semibold: it is standing in
    /// for an icon, so it has to read as a mark rather than as a word that got cut off.
    static func letterFont(box: CGFloat) -> Font {
        .system(size: box * letterScale, weight: .semibold, design: .rounded)
    }
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

    // Split view. Arc's panes are separate sheets inside the one card with a hairline down
    // the gap between them, and the gap is what there is to aim the divider drag at: a 1pt
    // target between two web views is not a target.
    static let splitDivider: CGFloat = 1
    static let splitGap: CGFloat = 9
    /// A pane's own corner: the card's, one step tighter, because it sits inside it.
    static let paneRadius: CGFloat = cardRadius - 2
    /// The frame round the pane the keyboard is in, and the band a drop will land in. The
    /// accent rather than `ink`: it is the one thing on the page that is the app talking.
    static let paneFrame = Color.accentColor.opacity(0.5)
    static let paneFrameWidth: CGFloat = 2
    /// How much of the card's edge takes a dragged tab as a new pane.
    static let splitDropBand: CGFloat = 0.25

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
    /// The saved-account list under a login form's username field, for when the field is
    /// narrower than the usernames it holds.
    static let chooserWidth: CGFloat = 220
    /// The save-password card at the top of the page. Fixed, so a long host does not make
    /// the card breathe in and out between one site and the next.
    static let offerWidth: CGFloat = 340

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
    /// Little Arc: a small floating window with one page and one row of chrome. Arc's is
    /// roughly 1000×700 and it is a size, not a proportion — the point is that it is
    /// obviously not your browser window.
    static let littleWidth: CGFloat = 1000
    static let littleHeight: CGFloat = 700
    /// Above Little Arc's bar. Its row is the address pill's own height rather than the
    /// sidebar's `topRow`, so the padding that puts that row's centre on the traffic
    /// lights' line is a different number — the same line, arrived at from a taller row.
    static let littleTopInset: CGFloat = lightsCentre - pillHeight / 2
    static let footer: CGFloat = 28
    /// Under the footer.
    static let footerInset: CGFloat = 10
    /// A favourite tile's icon: the same 16 as a row's (32px at 2x in ref 1).
    static let tileIcon: CGFloat = 16
    /// A space dot in the footer.
    static let dot: CGFloat = 8
    /// The line a drop will land on: before or after a tile, above or below a row.
    static let dropLine: CGFloat = 2
    /// The half of a row a dropped tab will take when the two go side by side. The same
    /// accent as `paneFrame` and well down from it: this one is painted behind a row's title,
    /// which still has to be readable through it, and the ring round the row is what says
    /// "split" — this only says which half.
    static let dropHalf = Color.accentColor.opacity(0.22)
    /// How far a folder's contents step in from the rows around them. Enough to read as
    /// nesting at a glance, and small enough that three levels still leave a title room in
    /// a 250pt sidebar — which is the same reason `Pins.maxDepth` stops where it does.
    static let folderIndent: CGFloat = 14

    /// The theme editor popover, measured off `arc-ref/arc-theme-editor.png` at 2x: a 350pt
    /// panel over a near-square dot-grid canvas, a row of preset circles under it, and the
    /// intensity slider beside the grain dial along the bottom.
    static let themeWidth: CGFloat = 350
    /// The canvas' height; its width is whatever the panel leaves (690px at 2x = 345).
    static let themeCanvas: CGFloat = 300
    /// The fine grid printed on it: pitch and dot.
    static let themeGrid: CGFloat = 10
    static let themeGridDot: CGFloat = 1
    /// A draggable colour dot and the ring round it (90px at 2x).
    static let themeDot: CGFloat = 44
    static let themeRing: CGFloat = 3
    /// The ring on the chosen preset, and how far it stands off the swatch.
    static let themeSelectRing: CGFloat = 2
    static let themeRingGap: CGFloat = 3
    /// A preset circle (58px at 2x) and how many fit a page between the two chevrons.
    static let swatch: CGFloat = 30
    static let swatchPage = 8
    /// The intensity slider: a `themeTrack`-tall pill with a sinusoid along it and a thumb
    /// standing proud of it, the way Arc's does.
    static let themeTrack: CGFloat = 30
    static let themeThumb = CGSize(width: 24, height: 46)
    /// The sinusoid's amplitude at full intensity, how many waves fit the track, and what is
    /// left of the amplitude past the thumb.
    static let themeWave: CGFloat = 11
    static let themeWaves: Double = 8
    /// Past the thumb the sinusoid flattens out entirely, the way Arc's does: the wave is
    /// the strength, so there is nothing left of it past where the strength stops.
    static let themeWaveRest: CGFloat = 0
    static let themeWaveWidth: CGFloat = 4
    /// The grain dial: the knob, the dotted ring round it, and how many dots the ring has.
    static let themeDial: CGFloat = 46
    static let themeDialRing: CGFloat = 74
    static let themeDialDots = 32
    /// Its pointer: a pill out on the dotted ring, at the angle the knob is turned to.
    static let themeMarker = CGSize(width: 14, height: 7)
    /// The slider's thumb and the dial's pointer. `ink`, not white: Arc's popover is
    /// always dark, and a white pill on a Space pinned to light is a thumb nobody can see.
    static let themeThumbInk = ink(0.9)
    /// A popover's own ground. NSPopover hands its content a translucent material, so a panel
    /// that draws nothing of its own has the window's wash streaking through it. Opaque and
    /// appearance-following, which no `ink` alpha over nothing can be.
    static let panelFill = Color(nsColor: .windowBackgroundColor)

    /// The card that asks whether a link may leave for another app: “Open “Zoom”?”.
    /// Wide enough for Cancel, Always Allow and Allow on one line beside a `paneMargin`
    /// on each side, which is what stops the three buttons stacking.
    static let appPrompt: CGFloat = 400
    /// The handler’s icon on it, at the size macOS draws an app icon in a dialog of its own.
    static let appIcon: CGFloat = 48
    /// What AppKit's bezel adds around a push button's title. Nothing is drawn with it —
    /// the card's buttons are system buttons and AppKit sizes them — it is what `check`
    /// needs in order to say whether a row of them fits `appPrompt` before anyone has to
    /// look at a screenshot of them stacked into a column.
    static let buttonPadding: CGFloat = 26

    /// The Site Control Center popover. Wide enough for "Picture in Picture" and its switch
    /// on one line, and no wider — it hangs off the address pill, not off the window.
    static let siteWidth: CGFloat = 300
    /// The mark on the pill's site glyph when the site holds a permission, and how far
    /// outside the glyph's box it sits: a badge on the lock, not a second glyph beside it.
    static let badge: CGFloat = 5
    static let badgeOffset: CGFloat = 3
    /// An extension action's badge — a count drawn *on* its icon rather than a glyph beside
    /// it, so a pinned extension costs the pill one glyph's width and not two. Never taller
    /// than `rowIcon` and never wider than the gap to the next glyph, so "99+" cannot reach
    /// its neighbour; the type shrinks inside that width instead of the capsule growing.
    static let badgeHeight: CGFloat = 11
    static let badgeInset: CGFloat = 3
    static let badgeWidth: CGFloat = 20
    static let badgeShrink: Double = 0.6
    /// What a button that is drawn but cannot be pressed fades to: an extension action its
    /// own extension has disabled for this page, or a pinned glyph on a pill with no tab.
    static let dimmed: Double = 0.4
    /// Between a title and the caption under it — a site row and the popover's header.
    static let captionGap: CGFloat = 2
    /// A site row's vertical padding. Derived so a row with one line of title is exactly
    /// `rowHeight` tall with a `control` in it, and a row with a caption grows from there.
    static let rowPadding: CGFloat = (rowHeight - control) / 2
    /// The zoom stepper: a square −/+ a step inside `control` so it is never taller than
    /// the popup buttons beside it, the gap around the label, and the label's own width,
    /// fixed at "100%" so stepping does not shift the buttons under the pointer.
    static let step: CGFloat = control - 4
    static let stepGap: CGFloat = 2
    static let stepLabel: CGFloat = 38

    static let text = Font.system(size: 13)
    /// A sidebar row's title, the space's name, New Tab: Arc sets these a point larger than
    /// body ("Vesta macOS Terminal" is 288px wide at 2x — 14 regular to the pixel).
    static let rowTitle = Font.system(size: 14)
    static let caption = Font.system(size: 11)
    /// A mark in the corner of another glyph — a live folder's source. Small enough that
    /// the glyph it sits on still reads as itself.
    static let badgeGlyph = Font.system(size: 9, weight: .semibold)
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
    /// A split's row: one row-height container with a pill per pane in it. The inset is what
    /// makes the pills read as things *in* a row rather than rows of their own, and the
    /// nested radius follows from it — a corner inside a corner is the outer one less the
    /// gap between them, or the two curves fight.
    static let paneInset: CGFloat = 4
    static let paneGap: CGFloat = 6
    static var panePillRadius: CGFloat { pillRadius - paneInset }

    /// The space's icon at the head of the list (cloud 32×22px).
    static let spaceIcon = Font.system(size: 14)
    /// A symbol standing in a `rowIcon` box where a favicon would be: bar rows, pickers.
    static let symbol = Font.system(size: 13)
    /// The digits in an extension action's badge. Small enough that "99+" still leaves the
    /// icon under it recognisable.
    static let badgeText = Font.system(size: 8, weight: .semibold)
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
    /// Multi-select: every ticked row wears `selected`, so the one actually being shown
    /// needs something the others do not have. A hairline in the accent rather than a
    /// brighter fill — a third step of grey between `selected` and white would read as a
    /// different material, while the accent is already the window's word for "this one".
    static let selectedEdge = Color.accentColor.opacity(0.55)

    /// Something is wrong with the page rather than with the chrome: a connection that is
    /// not secure. The one colour in the window that is not `ink` or the user's accent,
    /// because a warning set in the same grey as everything else is not a warning.
    static let warning = Color.orange

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

    /// Two grounds mixed, `fraction` of the way from the first to the second. Straight linear
    /// interpolation in sRGB rather than through hue: the two washes are both nearly black
    /// (or nearly white), so the arc a hue interpolation takes between them is a detour
    /// through colours neither Space wears.
    /// Pure, so `selfcheck --pure` can prove the ends and the middle.
    nonisolated static func mixed(_ a: (r: Double, g: Double, b: Double),
                                  _ b: (r: Double, g: Double, b: Double),
                                  _ fraction: Double) -> (r: Double, g: Double, b: Double) {
        let f = min(max(fraction, 0), 1)
        return (a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f)
    }

    /// The window's ground part-way between two Spaces, for the tint cross-fade under a live
    /// swipe: the sidebar has to already be wearing some of the Space the fingers are pulling
    /// in, or the colour arrives after the content and the switch reads as two events.
    /// At `fraction` 0 this is exactly `groundColor(hex:dark:strength:)`.
    static func groundColor(hex: String, towards other: String, fraction: Double,
                            dark: Bool, strength: Double) -> Color {
        guard let a = ground(hex: hex, dark: dark, strength: strength),
              let b = ground(hex: other, dark: dark, strength: strength)
        else { return groundColor(hex: hex, dark: dark, strength: strength) }
        let c = mixed(a, b, fraction)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b)
    }

    /// A Space's ground as gradient stops. One colour is one stop — a flat wash, bit for bit
    /// what every Space had before the editor could hold more than one — and several are the
    /// diagonal Arc mixes across the window. Pure.
    nonisolated static func stops(_ colors: [String], dark: Bool, strength: Double = defaultTint)
        -> [(r: Double, g: Double, b: Double)] {
        colors.compactMap { ground(hex: $0, dark: dark, strength: strength) }
    }

    /// The same, dragged `fraction` of the way towards the Space a swipe is pulling in. The
    /// shorter palette repeats its last colour rather than losing a stop: a two-colour Space
    /// swiped into a one-colour one arrives as a flat wash, instead of the gradient
    /// collapsing to half its length halfway through the gesture.
    nonisolated static func stops(_ a: [String], towards b: [String], fraction: Double,
                                  dark: Bool, strength: Double)
        -> [(r: Double, g: Double, b: Double)] {
        let from = stops(a, dark: dark, strength: strength)
        let to = stops(b, dark: dark, strength: strength)
        guard !from.isEmpty, !to.isEmpty, fraction != 0 else { return from }
        let f = min(max(fraction, 0), 1)
        return (0..<max(from.count, to.count)).map {
            mixed(from[min($0, from.count - 1)], to[min($0, to.count - 1)], f)
        }
    }

    /// `stops`, as colours a gradient can be built from.
    static func groundStops(_ a: [String], towards b: [String], fraction: Double,
                            dark: Bool, strength: Double) -> [Color] {
        stops(a, towards: b, fraction: fraction, dark: dark, strength: strength)
            .map { Color(.sRGB, red: $0.r, green: $0.g, blue: $0.b) }
    }

    /// A tile of static noise, laid over the ground at `grain` × `grainMax`. Arc's themes
    /// have a faint film grain over the wash; this is that, and nothing else.
    ///
    /// ponytail: one 64pt tile of white pixels at a fixed pseudo-random alpha, generated
    /// once and tiled by the image view. Deliberately *static* — a per-frame shader would be
    /// a real graphics project, and grain that crawls is a distraction rather than a texture.
    /// Ceiling: the tile repeats every 64pt, which at these opacities is invisible.
    @MainActor static let grain: NSImage = {
        let n = 64
        // The context owns its own buffer: a Swift array's pointer is only valid inside
        // `withUnsafeMutableBytes`, and `makeImage()` reads it after that closure returns.
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = ctx.data?.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * n)
        else { return NSImage() }
        // A fixed seed, so the tile is the same every launch and never flickers between two
        // windows drawing it at once.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for y in 0..<n {
            for x in 0..<n {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let v = UInt8(truncatingIfNeeded: seed >> 33)
                // Premultiplied white: the alpha is the noise, so the tile lightens the
                // ground where it is bright and leaves it alone where it is not.
                for c in 0..<4 { pixels[y * ctx.bytesPerRow + x * 4 + c] = v }
            }
        }
        guard let image = ctx.makeImage() else { return NSImage() }
        return NSImage(cgImage: image, size: CGSize(width: n, height: n))
    }()

    /// How much of the noise a `grain` of 1 actually shows. Past this it stops reading as a
    /// texture on the wash and starts reading as a broken screen.
    static let grainMax: Double = 0.09

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
    /// A row picked up out of the list: a shade bigger with a shadow under it, so it reads
    /// as held above the sidebar rather than sliding along it. Tighter than `floatShadow` —
    /// the row is a finger's width off the list, not a window over the page.
    static let liftScale: CGFloat = 1.04
    static let liftShadow = Color.black.opacity(0.35)
    static let liftShadowRadius: CGFloat = 8
    static let liftShadowY: CGFloat = 3
    /// How far down the slot a lifted row leaves goes: still a row, plainly not the one in
    /// your hand.
    static let lifted: Double = 0.3

    // Motion. Short and easing out: a fill should arrive under the pointer, never chase it.
    /// Hover and selection fills.
    static let quick = Animation.easeOut(duration: 0.15)
    /// A floating surface appearing: scale from `appearScale` and fade, together. The
    /// duration is spelled out because a surface that is a *window* of its own — a Peek —
    /// has to stay alive for exactly as long as its own fade, and `Animation` will not say.
    static let appearDuration: Double = 0.15
    static let appear = Animation.easeOut(duration: appearDuration)
    static let appearScale: CGFloat = 0.97
    /// The tab list changing shape: a row arriving, leaving, or moving between sections. A
    /// touch of spring, the way Arc's rows settle, but short enough that ⌘W ⌘W ⌘W never
    /// queues up behind itself.
    /// The duration is spelled out because the row you are dragging glides into its slot
    /// when you let go, and the real row can only come back once it has arrived.
    static let listSeconds: Double = 0.28
    static let list = Animation.spring(duration: listSeconds, bounce: 0.12)
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
    /// A press held this long on back or forward opens that direction's history instead of
    /// stepping once. Long enough that an ordinary click never opens a menu, short enough
    /// that holding does not feel like waiting for something broken.
    static let holdDelay: Double = 0.4

    // The mini audio player: a pill above the sidebar's footer, a shade taller than a row
    // so the artwork and the transport glyphs sit in it without crowding.
    static let trayHeight: CGFloat = 40
    /// Its transport glyphs — a step under a row's, because there are three of them in a
    /// strip the width of a sidebar.
    static let trayGlyph = Font.system(size: 12, weight: .semibold)
    /// A title too long for the tray scrolls: points per second, and how long it rests at
    /// each end before turning round.
    static let marqueeSpeed: Double = 22
    static let marqueePause: Double = 1.2
    /// Smaller than this on screen and a video is a thumbnail, a hero loop or an ad, not
    /// what the user was watching: auto picture-in-picture leaves those alone rather than
    /// filling the corner of the screen with junk on every tab switch. Arc's rule by eye.
    static let minAutoPiP = CGSize(width: 200, height: 120)

    // Toasts: a pill above the sidebar's footer, gone after `toastDuration` unless hovered.
    static let toastHeight: CGFloat = 32
    static let toastDuration: Double = 3
    /// Arc's "Quit Vane?" card: the least it is wide (three buttons in a row make it wider
    /// when they need to) and the icon in its corner.
    static let quitDialogWidth: CGFloat = 440
    static let quitDialogIcon: CGFloat = 56
    /// How much of the space's colour washes over the pill's dark ground.
    static let toastTint: Double = 0.45

    // Peek: a link out of a Favourite or a Pinned tab, floating over the window it came
    // from. Its corner and its shadow are the command bar's — both are surfaces over the
    // whole window — so the only numbers of its own are how big it is and how long the
    // offer to bring the last one back stands.
    /// Of the window, each way. Arc's Peek leaves enough of the sidebar showing that it is
    /// obviously a page *over* your window rather than a window of its own.
    static let peekFraction: CGFloat = 0.8
    /// Its scrim. Deliberately not `Look.scrim`: that one sits under a 760pt bar in the
    /// middle of the window, where the page around it is plainly still there. A Peek covers
    /// four fifths of the window, so the strip left over has to read as *behind* on its own,
    /// and at 0.12 it read as a page that had simply gone a shade darker.
    static let peekScrim = Color.black.opacity(0.3)
    /// How long after a Peek closes Archive ▸ Reopen Last Peek still offers it. Long
    /// enough for the Escape you did not mean, short enough that it is never a surprise.
    static let peekReopen: Double = 8
}

extension Look {
    /// The chrome's geometry and the ground derivation, proved offline. These are the
    /// numbers a screenshot is measured against, so a change to one of them should fail
    /// here before anyone has to look.
    nonisolated static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        out.append(("the lights' centre line is the sidebar top row's centre line",
                    lightsCentre == topInset + topRow / 2))

        // The external-app card's three buttons on one line. Measured rather than
        // eyeballed: the strings are ours, the metrics are the system's, and a row that
        // does not fit does not overflow — AppKit stacks it into a column and the card
        // stops looking like a card. Text measurement needs fonts, not a window server, so
        // it is fair game in the pure pass.
        let titles = ["Cancel", "Always Allow", "Allow"]
        let font = NSFont.systemFont(ofSize: 13)          // `Look.text`
        let words = titles.reduce(0 as CGFloat) {
            $0 + NSAttributedString(string: $1, attributes: [.font: font]).size().width
        }
        let row = words + CGFloat(titles.count) * buttonPadding
            + CGFloat(titles.count - 1) * inset
        out.append(("Cancel, Always Allow and Allow fit the app-prompt card on one line",
                    row <= appPrompt - paneMargin * 2))
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
        out.append(("Little Arc's bar puts its pill on the same lights' line as the sidebar",
                    littleTopInset + pillHeight / 2 == lightsCentre))
        out.append(("…so its whole bar is 41pt, the sidebar's row pitch",
                    littleTopInset + pillHeight == rowHeight + rowGap))
        out.append(("the sidebar is laid out on Arc's 41pt row pitch", rowHeight + rowGap == 41))
        out.append(("the top strip is Arc's 45pt", topInset + topRow + inset == 45))
        out.append(("the Tidy row and New Tab are Arc's 31pt apart",
                    tidyRow + sectionGap == 31))
        out.append(("the footer glyphs sit 24pt above the window's bottom edge",
                    footer / 2 + footerInset == 24))
        out.append(("rows and the bar share one radius", pillRadius == barRadius))
        out.append(("a stand-in letter fills a favicon's box without touching its edges",
                    letterScale > 0.5 && letterScale < 1))
        out.append(("housekeeping waits for a pile: more tabs than fit in a glance, "
                    + "fewer than a window nobody could work in",
                    tidyThreshold >= 4 && tidyThreshold <= 12))
        // An extension action's badge, which is drawn over the 16pt icon it belongs to.
        out.append(("an action badge is shorter than the icon it sits on", badgeHeight < rowIcon))
        out.append(("…and a full one cannot reach the glyph beside it",
                    badgeWidth + badgeOffset < rowIcon + pillGlyphGap))
        out.append(("…so its widest is still narrower than a chip", badgeWidth < chip))
        out.append(("…and it has room for a digit inside its own height",
                    badgeWidth > badgeHeight && badgeInset * 2 < badgeHeight))
        out.append(("badge type is the smallest in the app, and shrinks rather than clipping",
                    badgeShrink > 0 && badgeShrink < 1))
        out.append(("a button that cannot be pressed fades without disappearing",
                    dimmed > 0 && dimmed < 1))
        out.append(("a pane's pill has room for a favicon and a corner of its own",
                    panePillRadius > 0 && rowHeight - paneInset * 2 > rowIcon))
        // A row's × is a button sitting inside a bigger button: the row itself. Anything
        // smaller than a control is a glyph you have to aim at, and the row catches the miss
        // by *showing* the tab you were trying to close.
        out.append(("a row's × is something to aim at: a control, not a bare glyph",
                    rowTarget >= control && rowTarget < rowHeight))
        // Two `rowSpacing` gaps sit between a row's title and its trailing glyphs — the
        // label, the Spacer that can go to nothing, and the glyphs — so a title that
        // truncates stops clear of the × rather than running under it.
        out.append(("a long row title stops clear of the ×, not under it",
                    rowSpacing * 2 >= rowInset
                        && rowTarget + rowSpacing * 2 + rowTrailingInset < sidebarWidth))
        out.append(("the quit card starts wider than its margins and shows a real icon",
                    quitDialogWidth > paneMargin * 4 && quitDialogIcon >= control * 2))
        // Toasts say the whole thing or take another line and say the whole thing — never
        // "Archived hello world -…". One row when the sentence and its verb fit side by
        // side; otherwise the sentence gets the pill's full width to itself and the verb
        // and × drop underneath. These are the two widths that has to be true at.
        let face = NSFont.systemFont(ofSize: 13, weight: .medium)     // == `rowText`
        func measure(_ s: String) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: face]).width
        }
        /// The sentence's own column once the pill has paid for its padding. In the stacked
        /// form the verb and × are on the row below, so they cost the text nothing.
        let column = sidebarWidth - inset * 2 - pillInset - inset / 2
        out.append(("a stacked toast's text gets most of the sidebar's width",
                    column > sidebarWidth * 0.8))
        for sentence in ["Vane v10.10.100 is available", "Restart to update", "Update failed",
                         "Couldn't move Vane to Applications",
                         "This copy isn't signed for updates",
                         "Archived hello world - a long page title"] {
            out.append(("two lines is enough for “\(sentence)”", column * 2 >= measure(sentence)))
        }
        // ...and the one-row form still exists, for the short ones Arc actually shows.
        let oneRow = pillInset + measure("Copied URL") + inset + measure("Undo") + inset * 2
            + inset / 2
        out.append(("a short toast and its verb still share one row",
                    oneRow <= sidebarWidth - inset * 2))
        out.append(("a held back button opens its history well after an ordinary click ends",
                    holdDelay > switcherDelay && holdDelay <= 0.5))
        out.append(("a dragged row settles in about the time the list takes to reshape",
                    listSeconds > 0 && listSeconds <= 0.4))
        out.append(("a lifted row is a shade bigger, not a different size",
                    liftScale > 1 && liftScale < 1.1))
        out.append(("its shadow is tighter than a floating surface's",
                    liftShadowRadius < floatShadowRadius && liftShadowY < floatShadowY))
        out.append(("the slot it left is dimmed, not emptied — the list keeps its shape",
                    lifted > 0 && lifted < 0.5))
        out.append(("the command bar's rows keep Arc's 50pt pitch", barRowHeight + barRowGap == 50))
        // The mini audio player. It sits above the footer inside the sidebar's own padding,
        // so its height is what decides whether the list is ever covered by it.
        out.append(("the media tray is taller than a row but shorter than a tile",
                    trayHeight > rowHeight && trayHeight < tileHeight))
        out.append(("the tray and the footer both fit above the window's bottom edge",
                    trayHeight + footer + footerInset * 2 + inset < 120))
        out.append(("a title scrolls at a readable pace and rests at each end",
                    marqueeSpeed > 10 && marqueeSpeed < 60 && marqueePause >= 1))
        out.append(("a thumbnail video is below the auto picture-in-picture floor",
                    minAutoPiP.width >= 200 && minAutoPiP.height >= 120))
        out.append(("the bar's icon column is centred at 30",
                    barInset + barRowInset + rowIcon / 2 == 30))
        // The Library's pane runs to the window's top edge, so its search field's centre is
        // its own top padding plus half its height — and that has to be the lights' line, or
        // the top of the window reads as two rows that nearly agree.
        out.append(("the Library's search field is centred on the traffic lights' line",
                    libraryHead + libraryField / 2 == lightsCentre))
        out.append(("…with room above it, so the field is not pushed off the top",
                    libraryHead > 0))
        out.append(("a Library row holds its thumbnail with air around it",
                    libraryRow - libraryThumb >= inset * 2))
        out.append(("the panel is the sidebar's width and a bit, not the whole window",
                    libraryRail + libraryList > sidebarWidth
                        && libraryRail + libraryList < sidebarWidth * 2))
        out.append(("a Space's card is narrower than the list column beside the rail",
                    spaceCard < libraryList))
        out.append(("the media masonry's two columns and their gaps fill the list column",
                    mediaColumn * CGFloat(mediaColumns) + inset * 3 == libraryList))
        out.append(("a rail tile fits inside the rail with its margins",
                    libraryTile + inset * 2 <= libraryRail))

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

        // The tint cross-fade a live Space swipe drags the ground through.
        let red = ground(hex: "#D9564F", dark: true), green = ground(hex: "#4CAF6E", dark: true)
        /// The two grounds and a fraction, or false if either colour failed to resolve —
        /// which is itself worth failing on, and beats a force-unwrap in a check.
        func mixing(_ f: Double, _ ok: (_ m: (r: Double, g: Double, b: Double),
                                        _ a: (r: Double, g: Double, b: Double),
                                        _ b: (r: Double, g: Double, b: Double)) -> Bool) -> Bool {
            red.map { a in green.map { b in ok(mixed(a, b, f), a, b) } == true } == true
        }
        func same(_ a: (r: Double, g: Double, b: Double),
                  _ b: (r: Double, g: Double, b: Double)) -> Bool {
            near(a.r, b.r * 255) && near(a.g, b.g * 255) && near(a.b, b.b * 255)
        }
        out.append(("no swipe means the space's own ground, untouched",
                    mixing(0) { m, a, _ in m == a }))
        out.append(("a completed swipe means the neighbour's",
                    mixing(1) { m, _, b in same(m, b) }))
        out.append(("half way is half way on every channel", mixing(0.5) { m, a, b in
            near(m.r, (a.r + b.r) / 2 * 255) && near(m.g, (a.g + b.g) / 2 * 255)
                && near(m.b, (a.b + b.b) / 2 * 255)
        }))
        out.append(("a rubber band past the end cannot push the ground past the neighbour",
                    mixing(4) { m, _, b in same(m, b) } && mixing(-4) { m, a, _ in m == a }))
        // Several colours: the gradient the theme editor's extra dots make.
        out.append(("one colour is one stop, and it is the flat wash it always was",
                    stops(["#5A9BD5"], dark: true).count == 1
                        && stops(["#5A9BD5"], dark: true).first.map { s in
                            blue.map { same(s, $0) } == true } == true))
        out.append(("each colour brings its own stop, in the order they were picked",
                    stops(["#D9564F", "#4CAF6E"], dark: true).count == 2
                        && red.map { a in same(stops(["#D9564F", "#4CAF6E"], dark: true)[0], a) } == true))
        out.append(("a colour that is not #RRGGBB is not a stop",
                    stops(["#4CAF6E", "sky"], dark: true).count == 1))
        out.append(("a space with no colours has no stops and so no ground",
                    stops([], dark: true).isEmpty))
        out.append(("no swipe leaves every stop exactly where it was",
                    stops(["#D9564F", "#4CAF6E"], towards: ["#5A9BD5"], fraction: 0,
                          dark: true, strength: defaultTint).count == 2))
        out.append(("a completed swipe into a one-colour space is that one colour, twice",
                    blue.map { b in
                        let s = stops(["#D9564F", "#4CAF6E"], towards: ["#5A9BD5"], fraction: 1,
                                      dark: true, strength: defaultTint)
                        return s.count == 2 && same(s[0], b) && same(s[1], b)
                    } == true))
        out.append(("swiping the other way pads the short palette rather than dropping a stop",
                    stops(["#5A9BD5"], towards: ["#D9564F", "#4CAF6E"], fraction: 0.5,
                          dark: true, strength: defaultTint).count == 2))
        out.append(("half a swipe is half way on every stop",
                    red.map { a in blue.map { b in
                        let s = stops(["#D9564F"], towards: ["#5A9BD5"], fraction: 0.5,
                                      dark: true, strength: defaultTint)
                        return s.count == 1 && near(s[0].r, (a.r + b.r) / 2 * 255)
                    } == true } == true))
        out.append(("a rubber band past the end cannot push the stops past the neighbour",
                    blue.map { b in
                        let s = stops(["#D9564F"], towards: ["#5A9BD5"], fraction: 9,
                                      dark: true, strength: defaultTint)
                        return s.count == 1 && same(s[0], b)
                    } == true))
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
