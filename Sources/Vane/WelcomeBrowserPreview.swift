import SwiftUI

/// Illustrative data only: switching a preview never touches TabStore or opens a URL.
struct WelcomeBrowserSample {
    var work = false
    var selected = 0
    var split = false
    var searchOpen = false
    var titles: [String] { work ? ["Project notes", "Design references", "Reading list"] : ["A quieter corner", "Weekend reading", "Places to go"] }
    var headline: String {
        let headings = work ? ["Room for the\nnext good idea.", "Good things\nto build on.", "Pick up where\nyou left off."]
            : ["A quieter corner\nof the internet.", "Something worth\nslowing down for.", "Take the\nscenic route."]
        return headings[selected]
    }
    var detail: String {
        let details = work ? ["Keep your thoughts and references together. Get back into the flow.", "A detail worth remembering. An approach worth trying.", "Save the ideas you want to spend a little more time with."]
            : ["The long reads, the loose ideas, the next place to go.", "Keep a few good stories close. Pick up where you left off.", "A tiny bookshop. A path by the water. Somewhere new."]
        return details[selected]
    }
}

struct WelcomeBrowserPreview: View {
    @Binding var sample: WelcomeBrowserSample
    @Binding var query: String
    @ObservedObject var store: TabStore
    @ObservedObject private var profiles = ProfileManager.shared
    let tint: Color
    let palette: WelcomePalette
    let showsSplit: Bool
    let showsSearch: Bool
    let engine: String
    let reduced: Bool
    @StateObject private var favicons = Favicons(profileID: UUID(), fetch: { _ in nil })
    @StateObject private var downloadFeedback = DownloadFeedback()
    @State private var selectedResult = 0
    private var sidebarInk: Color { Color.white.opacity(0.92) }
    private var background: Color { Color(white: palette.dark ? 0.13 : 0.85) }

    var body: some View {
        GeometryReader { geometry in
            let size = WelcomePreviewLayout.canvas
            let scale = WelcomePreviewLayout.scale(in: geometry.size)
            ZStack {
                HStack(spacing: 0) {
                    sidebar.frame(width: Look.sidebarWidth)
                    documents
                        .modifier(BrowserPageSurface())
                        .padding([.top, .trailing, .bottom], Look.cardGap)
                }
                .background {
                    ThemeWashView(wash: ThemeWash.space(store.currentSpace, fallback: store.profile,
                        profiles: profiles.profiles, systemDark: palette.dark))
                        .background { WindowGlass().background(background) }
                        .clipShape(.rect(cornerRadius: Look.pageRadius))
                }
                if showsSearch || sample.searchOpen {
                    searchPalette(compact: false)
                        .frame(width: min(Look.barWidth, size.width - Look.inset * 2))
                        .position(x: size.width / 2, y: size.height / 2)
                }
            }
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
        }
        .shadow(color: .black.opacity(palette.dark ? 0.18 : 0.08), radius: 24, x: 0, y: 12)
        .accessibilityElement(children: .contain).accessibilityLabel("Guided sample browser preview")
    }

    private var sidebar: some View {
        SidebarChrome {
            TopRow(layoutWidth: Look.sidebarWidth).environmentObject(store).disabled(true).allowsHitTesting(false)
                .overlay(alignment: .leading) {
                    BrowserSampleTrafficLights().frame(maxWidth: .infinity).frame(height: Look.lightDisc)
                        .opacity(Look.lightHoverAlpha).allowsHitTesting(false)
                }.accessibilityHidden(true)
            AddressPill(tab: nil, displayAddress: "\(sample.work ? "notes" : "fieldnotes").example", layoutWidth: Look.sidebarWidth)
                .environmentObject(store).disabled(true).allowsHitTesting(false).accessibilityHidden(true)
                .overlay {
                    Button { animate { sample.searchOpen.toggle() } } label: { Color.clear.contentShape(.rect) }
                        .buttonStyle(.plain).accessibilityLabel("Try a sample search")
                }
            VStack(spacing: Look.rowGap) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Look.inset),
                    count: SidebarWidth.favouriteColumns(4, width: Look.sidebarWidth)), spacing: Look.inset) {
                    ForEach(Array(Search.builtIn.prefix(4))) { engine in
                        SiteIcon(icon: WelcomeArtwork.engineIcon(engine), size: Look.tileIcon)
                            .frame(maxWidth: .infinity).frame(height: Look.tileHeight)
                            .background { FavoriteTileBackground(selected: false, hovering: false, icon: nil) }
                    }
                }.padding(.bottom, Look.inset - Look.rowGap).accessibilityHidden(true)
                SpaceSectionsLayout(animatesCutoffs: !reduced, allowsWindowDrag: false) {
                    HStack(spacing: Look.rowSpacing) {
                        SpaceIcon(sample.work ? "briefcase" : "cloud", filledCloud: true)
                            .font(Look.spaceIcon).foregroundStyle(Look.inkPrimary).frame(width: Look.tileIcon)
                        Text(sample.work ? "Work" : "Personal").font(Look.spaceTitle)
                        Spacer(minLength: 0)
                    }.foregroundStyle(Look.inkTertiary)
                        .padding(.horizontal, Look.rowInset).frame(height: Look.rowHeight)
                        .padding(.bottom, Look.sectionGap / 2 - Look.rowGap)
                } rows: {
                    ForEach(0..<3, id: \.self) { index in
                        SidebarRow(selected: sample.selected == index, trailingInset: Look.tabRowTrailingInset, action: {
                            animate { sample.selected = index }
                        }) {
                            SiteIcon(icon: nil, size: Look.rowIcon)
                        } label: {
                            Text(sample.titles[index])
                        } trailing: {
                            EmptyView()
                        }.accessibilityLabel("Preview: \(sample.titles[index])")
                    }
                    SidebarRow(icon: "plus", title: "New Tab", selected: false, dimmed: true) {
                        animate { sample.searchOpen = true }
                    }
                }
            }
            HStack(spacing: Look.inset) {
                LibraryDownloadGlyph(filled: false, hovered: false).offset(y: -4)
                    .environmentObject(downloadFeedback)
                    .frame(width: Look.footerControl, height: Look.footerControl).accessibilityHidden(true)
                HStack(spacing: 0) {
                    spaceButton("Personal", work: false)
                    spaceButton("Work", work: true)
                }.frame(maxWidth: .infinity)
                Image(systemName: "plus")
                    .frame(width: Look.footerControl, height: Look.footerControl).accessibilityHidden(true)
            }.font(.system(size: 17, weight: .medium)).foregroundStyle(Look.inkSecondary).frame(height: Look.footer)
        }.foregroundStyle(sidebarInk)
            .environment(\.colorScheme, .dark).spaceChrome(store)
    }

    private func spaceButton(_ label: String, work: Bool) -> some View {
        Button { animate { sample.work = work; sample.selected = 0 } } label: {
            let layout = SpaceStripLayout(count: 2, availableWidth: 90)
            SpaceFooterMarker(icon: work ? "briefcase" : "cloud", layout: layout,
                emphasis: sample.work == work ? 1 : 0, selected: sample.work == work, reducedMotion: reduced)
                .frame(width: layout.itemWidth, height: Look.spaceDotHit)
        }.buttonStyle(.plain).accessibilityLabel("Preview \(label) Space")
            .accessibilityAddTraits(sample.work == work ? .isSelected : [])
    }

    private var documents: some View {
        HStack(spacing: 0) {
            page
                .modifier(BrowserPaneSurface(active: true, enabled: showsSplit))
            if showsSplit {
                Rectangle().fill(Look.hairline).frame(width: Look.splitDivider)
                    .frame(width: Look.splitGap)
                notes(compact: false)
                    .modifier(BrowserPaneSurface(active: false))
                    .transition(reduced ? .identity : .opacity.combined(with: .move(edge: .trailing)))
            }
        }.spaceChrome(store)
    }

    private var page: some View {
            GeometryReader { geometry in
                let tight = geometry.size.height < 240
                VStack(alignment: .leading, spacing: tight ? 10 : 13) {
                    if !tight {
                    Text(sample.work ? "Project notes" : "Field notes")
                        .font(.system(size: 10)).foregroundStyle(palette.muted)
                    }
                    Text(sample.headline).font(.system(size: tight ? 24 : showsSplit ? 25 : 32, design: .serif))
                        .tracking(-0.6).fixedSize(horizontal: false, vertical: true)
                    Text(sample.detail).font(.system(size: 12, design: .serif)).foregroundStyle(palette.muted)
                        .lineSpacing(tight ? 2 : 4).lineLimit(tight ? 2 : 3)
                    if geometry.size.height > 240 {
                        Rectangle().fill(palette.line).frame(width: 35, height: 1).padding(.vertical, 2)
                        Text("A little space to follow your curiosity.")
                            .font(.system(size: 12, design: .serif)).foregroundStyle(palette.muted)
                    }
                    Spacer(minLength: 0)
                }.padding(tight ? 16 : showsSplit ? 18 : 24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(palette.ink).background(palette.paper)
            .clipped()
    }

    private func notes(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 18) {
            Text("A few things for later").font(.system(size: compact ? 12 : 14, weight: .medium))
            ForEach(["Find a new weekend read.", "Make room for the next idea.", "Keep the good things close."], id: \.self) { note in
                Text(note).font(.system(size: 11)).foregroundStyle(palette.muted)
                Rectangle().fill(palette.line).frame(height: 1)
            }
            Spacer(minLength: 0)
        }.padding(compact ? 12 : 20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(palette.ink).background(palette.paper)
            .accessibilityLabel("Sample second page")
    }

    private func searchPalette(compact: Bool) -> some View {
        let rows = [
            PaletteRow(id: "search", icon: "magnifyingglass", title: query.isEmpty ? "Search the web" : query,
                       trailing: "Search \(engine)", kind: "Search", run: { _ in }),
            PaletteRow(id: "article", icon: "globe", title: "Architecture — Wikipedia", trailing: "Open", kind: "Sample tab", run: { _ in }),
            PaletteRow(id: "design", icon: "doc.text", title: "Design references", trailing: "Switch to Tab", kind: "Sample tab", run: { _ in })
        ]
        let count = compact ? 2 : 3
        return VStack(spacing: Look.barRowGap) {
            HStack(spacing: Look.barRowSpacing) {
                Image(systemName: "magnifyingglass").foregroundStyle(Look.barGlyph)
                CommandField(text: $query, prompt: "Search websites and tabs", selectAll: false,
                    label: "Try a sample search", hint: "Sample content only", canFocus: { false }, onKey: { key in
                        switch key {
                        case .up: selectedResult = max(0, selectedResult - 1); return true
                        case .down: selectedResult = min(count - 1, selectedResult + 1); return true
                        case .enter: return true
                        case .escape: sample.searchOpen = false; return true
                        default: return false
                        }
                    })
            }.padding(.horizontal, Look.barInset + Look.barRowInset).frame(height: Look.barFieldHeight)
            Rectangle().fill(palette.line).frame(height: 1).padding(.horizontal, Look.barInset)
            ForEach(0..<count, id: \.self) { index in
                PaletteResultRow(row: rows[index], index: index, rowCount: count, selected: selectedResult == index,
                    selectionColor: Look.barSelected, favicons: favicons, animations: !reduced,
                    activate: { animate { selectedResult = index } }, forget: {})
            }
        }.padding(.vertical, Look.barInset)
            .background(SpaceChromeTheme(space: store.currentSpace, fallback: store.profile.colorHex).barFill,
                        in: .rect(cornerRadius: Look.barRadius))
            .overlay(RoundedRectangle(cornerRadius: Look.barRadius).strokeBorder(palette.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.24), radius: 20, x: 0, y: 10)
            .environment(\.colorScheme, .dark).spaceChrome(store)
    }
    private func animate(_ action: () -> Void) {
        withAnimation(reduced ? nil : .easeInOut(duration: 0.22), action)
    }
}

/// Production controls keep their native geometry; the demonstration scales as one
/// browser window instead of squeezing rows, split panes, and the command bar separately.
enum WelcomePreviewLayout {
    static let canvas = CGSize(width: 880, height: 550)
    static let ratio = canvas.width / canvas.height
    static func scale(in size: CGSize) -> CGFloat {
        max(0, min(size.width / canvas.width, size.height / canvas.height))
    }
}
