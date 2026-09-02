import AppKit
import SwiftUI

/// Vane's look, in one place, so views built in parallel come out matching. Every number a
/// view would otherwise invent lives here. Dark-first, but nothing is hard-coded to dark:
/// semantic colours and materials only, so light mode falls out for free.
enum Look {
    static let sidebarWidth: CGFloat = 250
    /// The web view card, the command bar, settings cards.
    static let cardRadius: CGFloat = 10
    /// The address pill, favourites tiles, sidebar rows, buttons.
    static let pillRadius: CGFloat = 8
    /// The sidebar's three heights, one family: a row, the address pill above it, and a
    /// favourites tile. They step 34 → 36 → 52 so the sidebar reads as one rhythm rather
    /// than three unrelated controls.
    static let rowHeight: CGFloat = 34
    static let pillHeight: CGFloat = 36
    static let tileHeight: CGFloat = 52
    /// Gap between the sidebar and the web card, and around the card.
    static let inset: CGFloat = 8

    static let text = Font.system(size: 13)
    static let caption = Font.system(size: 11)
    static let heading = Font.system(size: 13, weight: .semibold)

    /// One surface at four strengths, so the pill, a tile, a hovered row and a selected row
    /// read as the same material rather than four different greys. Semantic on purpose:
    /// `.primary` is white on dark and black on light.
    static let hovered = Color.primary.opacity(0.05)
    static let pillFill = Color.primary.opacity(0.08)
    static let selected = Color.primary.opacity(0.11)

    /// The colours a space can be tinted with. The profile palette first, so a space and its
    /// profile can wear the same colour, then the spread Arc offers.
    /// @MainActor because `ProfileManager.palette` is; every caller is a view anyway.
    @MainActor static let themeSwatches = ProfileManager.palette
        + ["#F2EDE4", "#E48FB1", "#9B6FB0", "#D9564F", "#E08A3C", "#E3C34A", "#4CAF6E", "#5A9BD5"]
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
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

extension View {
    /// Liquid Glass for a floating surface: the command bar, a popover, the address pill.
    /// One call so every surface refracts the same way.
    func glass(radius: CGFloat = Look.cardRadius) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: radius))
    }
}
