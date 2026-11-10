import AppKit
import SwiftUI

/// Shared chrome geometry for the live browser and the guided sample.
struct SidebarChrome<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: Look.inset) { content }
            .padding(.horizontal, Look.inset)
            .padding(.bottom, Look.footerInset)
            .padding(.top, Look.topInset)
    }
}

/// Draw the sample's resting lights with the same native painter as VaneWindow.
struct BrowserSampleTrafficLights: NSViewRepresentable {
    final class Lights: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsDisplay = true }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
        override func draw(_ dirtyRect: NSRect) {
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window?.standardWindowButton($0) }
            let discs = (0..<3).map { index in
                // Vane keeps AppKit's horizontal positions. Read this host's actual
                // buttons; the documented native positions cover offscreen renderers.
                let left = buttons.count == 3
                    ? buttons[index].convert(buttons[index].bounds, to: nil).midX - Look.lightDisc / 2
                    : 18.75 + CGFloat(index) * 23
                return CGRect(x: left - Look.inset, y: 0, width: Look.lightDisc, height: Look.lightDisc)
            }
            TrafficLightRest.drawDiscs(discs, key: true)
        }
    }
    func makeNSView(context: Context) -> Lights { Lights() }
    func updateNSView(_ view: Lights, context: Context) { view.needsDisplay = true }
}

struct BrowserPageSurface: ViewModifier {
    var radius: CGFloat = Look.pageRadius
    var edgeToEdge = false
    func body(content: Content) -> some View {
        content
            .clipShape(.rect(cornerRadius: radius))
            .background {
                RoundedRectangle(cornerRadius: radius)
                    .stroke(Look.pageShadow, lineWidth: 1)
                    .blur(radius: Look.pageShadowRadius)
                    .offset(y: 1)
                    .opacity(edgeToEdge ? 0 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Look.pageRim, lineWidth: 1)
                    .opacity(edgeToEdge ? 0 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

struct BrowserPaneSurface: ViewModifier {
    @Environment(\.spaceChromeTheme) private var theme
    var active: Bool
    var enabled = true
    func body(content: Content) -> some View {
        content
            .clipShape(.rect(cornerRadius: enabled ? Look.paneRadius : 0))
            .overlay {
                RoundedRectangle(cornerRadius: Look.paneRadius)
                    .strokeBorder(active && enabled ? theme.paneFrame : .clear, lineWidth: Look.paneFrameWidth)
                    .allowsHitTesting(false)
            }
    }
}
