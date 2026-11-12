import SwiftUI

/// Mount on the WebView itself so link coordinates also work in split panes and
/// below the Developer Mode toolbar. This is a passive preview, not another page.
struct LinkPreviewOverlay: View {
    @EnvironmentObject private var store: TabStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var tab: Tab
    @ObservedObject private var previews = Previews.shared
    @AppStorage("linkPreviews", store: .vane) private var enabled = true
    @AppStorage("aiSettingsRevision", store: .vane) private var aiRevision = 0

    private var visiblePage: Bool {
        store.profileVisible && store.ownsPage(tab) && store.onScreenTabs.contains { $0.id == tab.id }
    }

    var body: some View {
        GeometryReader { geometry in
            if enabled, visiblePage, geometry.size.width >= 160, geometry.size.height >= 160,
               let preview = previews.preview(for: tab) {
                let frame = LinkPreviewLayout.frame(link: previews.linkRect, viewport: geometry.size)
                LinkPreviewCard(preview: preview, size: frame.size)
                    .position(x: frame.midX, y: frame.midY)
                    .id(preview.url)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .allowsHitTesting(false)
        .clipped()
        .animation(reduceMotion || Motion.reduced ? nil : Look.quick, value: previews.current?.url)
        .onChange(of: enabled) { _, value in if !value { previews.cancel(from: tab) } }
        .onChange(of: aiRevision) { _, _ in previews.cancel(from: tab) }
        .onChange(of: visiblePage) { _, value in if !value { previews.cancel(from: tab) } }
        .onChange(of: tab.id) { previous, _ in previews.cancel(from: previous) }
        .onDisappear { previews.cancel(from: tab) }
        .vaneMotionPolicy()
    }
}

enum LinkPreviewLayout {
    static func frame(link: CGRect, viewport: CGSize) -> CGRect {
        let inset: CGFloat = 8
        let size = CGSize(width: max(0, min(320, viewport.width - 2 * inset)),
                          height: max(0, min(350, viewport.height - 2 * inset)))
        let x = min(max(inset, link.minX), max(inset, viewport.width - size.width - inset))
        let below = link.maxY + inset
        let desiredY = below + size.height <= viewport.height - inset ? below : link.minY - size.height - inset
        let y = min(max(inset, desiredY), max(inset, viewport.height - size.height - inset))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

struct LinkPreviewCard: View {
    let preview: Previews.Preview
    let size: CGSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                if let image = preview.image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else if preview.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "globe").font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: size.width, height: min(156, size.height * 0.45))
            .clipped()
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if let favicon = preview.favicon {
                        Image(nsImage: favicon).resizable().frame(width: 14, height: 14).accessibilityHidden(true)
                    }
                    Text(preview.url.host ?? "").font(Look.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(preview.title).font(Look.Typography.heading.font).lineLimit(2)
                if !preview.summary.isEmpty {
                    Text(preview.summary).font(Look.text).lineLimit(5)
                } else if !preview.description.isEmpty {
                    Text(preview.description).font(Look.text).foregroundStyle(.secondary).lineLimit(4)
                }
                Spacer(minLength: 0)
                if preview.summarizing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Summarizing…")
                    }.font(Look.caption).foregroundStyle(.secondary)
                } else if preview.loading {
                    Text("Loading preview…").font(Look.caption).foregroundStyle(.secondary)
                } else if preview.image == nil && preview.summary.isEmpty && preview.description.isEmpty {
                    Text("Preview unavailable").font(Look.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: size.width, height: size.height)
        .background(Look.panelFill)
        .clipShape(RoundedRectangle(cornerRadius: Look.pillRadius))
        .shadow(color: Look.pageShadow, radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Link preview")
    }
}
