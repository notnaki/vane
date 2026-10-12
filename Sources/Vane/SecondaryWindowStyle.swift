import AppKit
import SwiftUI

/// Secondary windows use the same quiet chrome and content hierarchy as Tidy preview.
@MainActor enum SecondaryWindowStyle {
    /// Keep resize limits in the hosted layout, so async content cannot replace them
    /// with an inferred zero minimum. Heights are content heights, independent of chrome.
    static func host<Content: View>(_ content: Content,
                                   minimumSize: NSSize = .zero) -> NSHostingView<some View> {
        let host = NSHostingView(rootView: content
            .frame(minWidth: minimumSize.width, minHeight: minimumSize.height)
            .background(Look.panelFill.ignoresSafeArea()))
        // Preserve the window’s chosen/autosaved frame while tracking only its minimum.
        host.sizingOptions = [.minSize]
        return host
    }

    static func apply(to window: NSWindow) {
        // Draw one surface behind both content and transparent native titlebar chrome.
        let frame = window.frame
        window.styleMask.insert(.fullSizeContentView)
        window.setFrame(frame, display: false)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .windowBackgroundColor
    }
}

struct SecondaryWindowHeader: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(alignment: .top, spacing: Look.cardInset) {
            Image(systemName: icon)
                .font(Look.icon)
                .foregroundStyle(Look.inkSecondary)
                .frame(width: Look.pillHeight, height: Look.pillHeight)
                .background(Look.controlFill, in: .rect(cornerRadius: Look.pillRadius))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Look.rowGap) {
                Text(title).font(Look.dialogTitle).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(Look.footnote).foregroundStyle(Look.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

struct SecondaryWindowEmptyState: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        VStack(spacing: Look.cardInset) {
            Image(systemName: icon).font(Look.icon).foregroundStyle(Look.inkTertiary)
                .frame(width: Look.tileHeight, height: Look.tileHeight)
                .background(Look.controlFill, in: .rect(cornerRadius: Look.pillRadius))
                .accessibilityHidden(true)
            VStack(spacing: Look.rowGap) {
                Text(title).font(Look.heading)
                Text(subtitle).font(Look.footnote).foregroundStyle(Look.inkSecondary)
            }
            .multilineTextAlignment(.center)
        }
        .padding(Look.cardInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    func secondaryWindowCard() -> some View {
        background(Look.cardFill)
            .clipShape(.rect(cornerRadius: Look.pillRadius))
            .hairline(radius: Look.pillRadius)
    }

    func secondaryWindowSearchField() -> some View {
        padding(.horizontal, Look.pillInset)
            .frame(height: Look.pillHeight)
            .background(Look.controlFill, in: .rect(cornerRadius: Look.pillRadius))
    }
}
