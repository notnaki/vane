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
    static let rowHeight: CGFloat = 30
    /// Gap between the sidebar and the web card, and around the card.
    static let inset: CGFloat = 8

    static let text = Font.system(size: 13)
    static let caption = Font.system(size: 11)
    static let heading = Font.system(size: 13, weight: .semibold)

    /// Row fills. Semantic on purpose: `.primary` is white on dark and black on light.
    static let selected = Color.primary.opacity(0.14)
    static let hovered = Color.primary.opacity(0.07)
    static let pillFill = Color.primary.opacity(0.06)
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
