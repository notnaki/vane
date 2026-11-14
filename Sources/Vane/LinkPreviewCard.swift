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
            LinkPreviewPlacement(link: previews.linkRect, viewport: geometry.size) {
                if enabled, visiblePage, geometry.size.width >= 160, geometry.size.height >= 160,
                   let preview = previews.preview(for: tab) {
                    LinkPreviewAnimatedCard(preview: preview, size: CGSize(
                        width: min(320, geometry.size.width - 16), height: geometry.size.height - 16))
                        .id(preview.url)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading))
                            .combined(with: .offset(y: 4)))
                }
            }
        }
        .allowsHitTesting(false)
        .clipped()
        .animation(reduceMotion || Motion.reduced ? nil : Look.appear, value: previews.preview(for: tab)?.url)
        .onChange(of: enabled) { _, value in if !value { previews.cancel(from: tab) } }
        .onChange(of: aiRevision) { _, _ in previews.cancel(from: tab) }
        .onChange(of: visiblePage) { _, value in if !value { previews.cancel(from: tab) } }
        .onChange(of: tab.id) { previous, _ in previews.cancel(from: previous) }
        .onDisappear { previews.cancel(from: tab) }
        .vaneMotionPolicy()
    }
}

enum LinkPreviewLayout {
    static let cornerRadius: CGFloat = 12

    static func hasTitle(_ preview: Previews.Preview) -> Bool {
        !preview.title.isEmpty && preview.title != preview.url.host
    }

    static func frame(link: CGRect, viewport: CGSize, height: CGFloat = 280) -> CGRect {
        let inset: CGFloat = 8
        let size = CGSize(width: max(0, min(320, viewport.width - 2 * inset)),
                          height: max(0, min(height, viewport.height - 2 * inset)))
        let x = min(max(inset, link.minX), max(inset, viewport.width - size.width - inset))
        let below = link.maxY + inset
        let desiredY = below + size.height <= viewport.height - inset ? below : link.minY - size.height - inset
        let y = min(max(inset, desiredY), max(inset, viewport.height - size.height - inset))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

/// Measure the visible text, then anchor that actual height inside the source pane.
/// No reserved lines, phase heights, or measurement feedback loop.
struct LinkPreviewPlacement: Layout {
    var link: CGRect
    var viewport: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { viewport }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = max(0, min(320, viewport.width - 16))
        for card in subviews {
            let measured = card.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let frame = LinkPreviewLayout.frame(link: link, viewport: viewport, height: measured.height)
            card.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}

struct LinkPreviewCard: View {
    let preview: Previews.Preview
    let size: CGSize
    var revealedText: String? = nil

    private var fullText: String { preview.summary.isEmpty ? preview.description : preview.summary }
    private var text: String { revealedText ?? fullText }
    private var hasText: Bool { !text.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image = preview.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: min(144, size.height * 0.52), alignment: .top)
                    .clipped()
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    if let favicon = preview.favicon {
                        Image(nsImage: favicon).resizable().frame(width: 14, height: 14).accessibilityHidden(true)
                    } else {
                        Image(systemName: "globe").font(Look.caption).accessibilityHidden(true)
                    }
                    Text(preview.url.host ?? "").font(Look.caption).lineLimit(1)
                    Spacer(minLength: 0)
                    if preview.loading || preview.summarizing {
                        ProgressView().controlSize(.mini)
                            .accessibilityLabel(preview.loading ? "Loading preview" : "Summarizing")
                    }
                }
                .foregroundStyle(.secondary)

                if hasText || preview.image != nil || LinkPreviewLayout.hasTitle(preview) {
                    Text(preview.title).font(Look.heading).lineLimit(2)
                    if hasText {
                        Text(text)
                            .font(Look.text)
                            .foregroundStyle(preview.summary.isEmpty ? .secondary : .primary)
                            .lineLimit(6)
                            .accessibilityLabel(fullText)
                    } else if preview.image == nil {
                        Text(!fullText.isEmpty ? " " : preview.loading ? "Loading preview…" : "Preview unavailable")
                            .font(Look.text).foregroundStyle(.secondary)
                    }
                } else {
                    Text(!fullText.isEmpty ? " " : preview.loading ? "Loading preview…" : "Preview unavailable")
                        .font(Look.text).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
        .frame(width: size.width, alignment: .topLeading)
        .background(Look.panelFill)
        .clipShape(RoundedRectangle(cornerRadius: LinkPreviewLayout.cornerRadius))
        .shadow(color: Look.pageShadow, radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Link preview")
    }
}
