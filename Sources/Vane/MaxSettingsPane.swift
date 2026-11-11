import SwiftUI

/// Max's feature tour uses bundled captures of the real browser, never remote images.
struct MaxPane: View {
    @AppStorage("appleAI", store: .vane) private var enabled = false
    @AppStorage("tidyTabs", store: .vane) private var tabs = true
    @AppStorage("tidyPreview", store: .vane) private var review = true
    @AppStorage("tidyDownloads", store: .vane) private var downloads = false
    @AppStorage("tidyTitles", store: .vane) private var titles = true
    @AppStorage("instantLinks", store: .vane) private var instant = true
    @AppStorage("linkPreviews", store: .vane) private var previews = true
    @AppStorage("aiSettingsRevision", store: .vane) private var revision = 0

    var body: some View {
        VStack(spacing: 0) {
            MaxBanner()
            VStack(alignment: .leading, spacing: 24) {
                Text("Let Vane do a little more, so you can do a little less. Meet Max: helpful tools for your tabs, links, and downloads.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsCard {
                    HStack(spacing: 12) {
                        Image(systemName: "command")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(MaxBanner.coral)
                            .frame(width: 36, height: 36)
                            .background(MaxBanner.blue, in: .rect(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Enable Max").font(.system(size: 15, weight: .semibold))
                            Text(enabled ? "Choose the AI features you want below." : "AI is off. Instant Links and link previews still work.")
                                .contentTransition(.opacity)
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Toggle("Enable Max", isOn: BrowserAI.enabledBinding)
                            .labelsHidden().toggleStyle(.switch).controlSize(.regular)
                    }
                    .padding(16)
                    .animation(Look.quick, value: enabled)
                }

                SettingsCard {
                    MaxFeatureRow(title: "Tidy Tabs", detail: "Group your open tabs into folders by topic. Choose Tidy Tabs in the sidebar when it appears.",
                                  image: "TidyTabs", isOn: $tabs, disabled: unavailable(.tabGroups)) {
                        Toggle("Review groups before tidying", isOn: $review)
                            .toggleStyle(.checkbox).font(.system(size: 12))
                        Text("Turn off to apply groups immediately. You can undo afterward.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    MaxFeatureRow(title: "Instant Links", detail: "Press Shift + Return on a search to open DuckDuckGo’s first result and skip the results page.",
                                  image: "InstantLinks", isOn: $instant)
                    MaxFeatureRow(title: "Link Previews", detail: "Hover over a link to take a look before opening it. Max adds a summary when an AI connection is available.",
                                  image: "LinkPreviews", isOn: $previews)
                    MaxFeatureRow(title: "Tidy Downloads", detail: "Give new downloads clearer, more useful filenames, so they’re easier to find later.",
                                  image: "TidyDownloads", isOn: $downloads, disabled: unavailable(.downloads))
                    MaxFeatureRow(title: "Tidy Tab Titles", detail: "Keep favourite and pinned tab titles short and easy to scan in your sidebar.",
                                  image: "TidyTitles", isOn: $titles, disabled: unavailable(.tabTitles))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Instant Links uses DuckDuckGo regardless of your search engine, and falls back to its results page if needed. Addresses and site searches keep their destinations. It never resolves in private windows or for text that looks like an address.")
                    Text("Loading a link preview visits that website. AI features use their selected connection; cloud AI is never used in private windows.")
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 12) {
                    Text("AI connections").font(.system(size: 17, weight: .semibold))
                    Text("Use Apple Intelligence on this Mac, or connect a service of your choice. Choose a connection for each feature below.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    AIProviderSettings()
                }
            }
            .frame(maxWidth: 632)
            .padding(.horizontal, 40)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity)
        }
    }

    private func unavailable(_ feature: AIFeature) -> Bool {
        _ = revision
        return !enabled || !BrowserAI.ready(for: feature)
    }
}

private struct MaxFeatureRow<Extra: View>: View {
    let title: String
    let detail: String
    let image: String
    @Binding var isOn: Bool
    var disabled = false
    @ViewBuilder var extra: Extra

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            MaxArtwork.image(image)
                .resizable().scaledToFill()
                .frame(width: 112, height: 78)
                .clipped()
                .clipShape(.rect(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.12)) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                extra
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: $isOn).labelsHidden()
                .toggleStyle(.switch).controlSize(.regular)
                .disabled(disabled)
        }
        .padding(16)
        .accessibilityElement(children: .contain)
    }
}

private extension MaxFeatureRow where Extra == EmptyView {
    init(title: String, detail: String, image: String, isOn: Binding<Bool>, disabled: Bool = false) {
        self.init(title: title, detail: detail, image: image, isOn: isOn, disabled: disabled) { EmptyView() }
    }
}

private struct MaxBanner: View {
    static let blue = Color(red: 0.22, green: 0.20, blue: 1)
    static let coral = Color(red: 1, green: 0.60, blue: 0.66)

    var body: some View {
        GeometryReader { geometry in
            MaxArtwork.image("Banner")
                .resizable().scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
        .frame(height: 148)
        .background(Self.blue)
        .clipShape(MaxBannerEdge())
        .accessibilityLabel("Max")
        .accessibilityAddTraits(.isHeader)
    }
}

/// A small scalloped edge echoes the reference without a second image or runtime effects.
private struct MaxBannerEdge: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: rect.maxX, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 5))
        let count = max(1, Int(ceil(rect.width / 22)))
        let step = rect.width / CGFloat(count)
        for index in 0..<count {
            let x = rect.maxX - CGFloat(index) * step
            path.addQuadCurve(to: CGPoint(x: x - step / 2, y: rect.maxY - 5),
                              control: CGPoint(x: x - step / 4, y: rect.maxY + 5))
            path.addQuadCurve(to: CGPoint(x: x - step, y: rect.maxY - 5),
                              control: CGPoint(x: x - step * 0.75, y: rect.maxY - 15))
        }
        path.addLine(to: .zero)
        path.closeSubpath()
        return path
    }
}

private enum MaxArtwork {
    static func image(_ name: String) -> Image {
        if let url = AppResources.bundle.url(forResource: name, withExtension: "png", subdirectory: "MaxAssets"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
        } else {
            Image(systemName: "photo")
        }
    }
}
