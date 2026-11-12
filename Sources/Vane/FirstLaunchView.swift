import AppKit
import SwiftUI

/// A centered, interactive introduction in the browser's own window.
struct FirstLaunchView: View {
    @ObservedObject var setup: FirstLaunchSetup
    @ObservedObject private var store: TabStore
    @ObservedObject private var importer: OnboardingImport

    init(setup: FirstLaunchSetup) {
        self.setup = setup
        store = setup.store
        importer = setup.importer
    }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var saver = BatterySaver.shared
    @State private var sample = WelcomeBrowserSample()
    @State private var query = "architecture"
    @AccessibilityFocusState private var titleFocused: Bool

    private var reduced: Bool { reduceMotion || saver.isActive }
    private var palette: WelcomePalette { WelcomePalette(dark: scheme == .dark) }
    private var tint: Color {
        Color(nsColor: (Look.themePresetColors[setup.color] ?? ThemeColor(hex: setup.color)
            ?? ThemeColor(red: 0.6, green: 0.7, blue: 0.6)).nsColor)
    }
    private let colors = [("#F2EAE4", "Linen"), ("#6CBAD9", "Tide"), ("#A6729D", "Iris"), ("#7AA982", "Sage"), ("#FF8558", "Ember")]

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 650 || geometry.size.width < 900
            let inset: CGFloat = 24
            let viewport = geometry.size.height - inset * 2 - 72
            let previewHeight: CGFloat = max(330, min(550, viewport - (setup.step == .search ? 184 : 156)))
            let contentWidth = min(1200, max(0, geometry.size.width - inset * 2))
            VStack(spacing: 0) {
                header.frame(height: 28)
                ScrollView {
                    content(compact: compact, previewHeight: previewHeight)
                        .id(setup.step)
                        .transition(reduced ? .identity : .opacity.combined(with: .offset(y: 10)))
                        .padding(.vertical, 8)
                        .frame(width: contentWidth)
                        .frame(maxWidth: .infinity, minHeight: max(0, viewport))
                }
                .scrollIndicators(.hidden)
                footer.frame(height: 44)
            }
            .padding(inset)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .foregroundStyle(palette.ink)
            .background(palette.paper)
        }
        .ignoresSafeArea()
        .vaneMotionPolicy()
        .task(id: setup.step) {
            if setup.step == .bringBrowser && importer.phase == .idle { await importer.scan() }
        }
        .onChange(of: setup.step) { _, step in
            if step != .bringBrowser { importer.cancelScan() }
        }
    }

    @ViewBuilder private var header: some View {
        if setup.showsSetupControls {
            ZStack {
                HStack(spacing: 6) {
                    Image(nsImage: WelcomeArtwork.icon).resizable().scaledToFit().frame(width: 26, height: 26)
                        .accessibilityHidden(true)
                    Text("Vane").font(.system(size: 15, weight: .semibold))
                }
                HStack {
                    Spacer()
                    Button("Skip setup", action: setup.skip)
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(palette.muted)
                        .padding(8).disabled(importer.phase == .importing)
                }
            }.transition(.opacity)
        } else {
            Color.clear.accessibilityHidden(true)
        }
    }

    @ViewBuilder private func content(compact: Bool, previewHeight: CGFloat) -> some View {
        switch setup.step {
        case .welcome:
            WelcomeIntro(compact: compact, palette: palette, reduced: reduced, titleFocus: $titleFocused) {
                move(setup.advance)
            }
        case .tabs:
            VStack(spacing: 14) {
                copy("Everything has its place.", detail: "Keep your tabs in the sidebar. Put two pages side by side when you need them.", compact: compact)
                preview(height: previewHeight)
                HStack(spacing: 14) {
                    Button(sample.split ? "Close Split View" : "Try Split View") {
                        animate { sample.split.toggle() }
                    }.buttonStyle(WelcomeButtonStyle(palette: palette, primary: false, reduced: reduced))
                    caption("Try a tab in the sidebar.")
                }
            }
        case .theme:
            VStack(spacing: 14) {
                copy("A space that feels like you.", detail: "Make it yours with the same color controls you’ll find in every Space.", compact: compact)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 24) {
                        preview(height: max(425, previewHeight)).frame(width: 680)
                        themeChoices
                    }
                    VStack(spacing: 18) {
                        preview(height: previewHeight)
                        themeChoices
                    }
                }
            }
        case .search:
            VStack(spacing: 14) {
                copy("Follow your curiosity.", detail: "One bar for searches, websites, and the tabs you already have open.", compact: compact)
                preview(height: previewHeight, search: true)
                searchChoices
                caption("Choose your search engine. You can change it anytime in Settings.")
            }
        case .bringBrowser:
            VStack(spacing: compact ? 22 : 28) {
                copy("Bring the familiar with you.", detail: "We’ll find your browsers. Review what comes over, then make yourself at home.", compact: compact)
                OnboardingImportView(flow: importer, palette: palette)
            }
        case .ai:
            VStack(spacing: compact ? 18 : 24) {
                copy("A little help, when you want it.", detail: "Summarize pages, group tabs, and give titles and downloads clearer names. AI stays off until you turn it on.", compact: compact)
                OnboardingAIChoices().frame(maxWidth: 620)
                caption("You can change these choices anytime in Settings → Max.")
            }
        case .ready:
            VStack(spacing: compact ? 24 : 32) {
                Image(systemName: "checkmark").font(.system(size: 26, weight: .light))
                    .frame(width: 64, height: 64).overlay(Circle().stroke(palette.line, lineWidth: 1))
                    .accessibilityHidden(true)
                copy("The internet is yours from here.", detail: "Open a new tab. See where it takes you.", compact: compact)
                HStack(spacing: 8) { key("⌘"); key("T") }
                    .accessibilityElement(children: .ignore).accessibilityLabel("Command T opens a new tab")
                Text("\(colors.first { $0.0 == setup.color }?.1 ?? "Your") Space · \(setup.engine.name) search")
                    .font(.system(size: 12)).foregroundStyle(palette.muted)
            }
        }
    }

    private func preview(height: CGFloat, search: Bool = false) -> some View {
        WelcomeBrowserPreview(sample: $sample, query: $query, store: store, tint: tint, palette: palette,
                              showsSplit: setup.step == .tabs && sample.split,
                              showsSearch: search, engine: setup.engine.name, reduced: reduced)
            .aspectRatio(WelcomePreviewLayout.ratio, contentMode: .fit)
            .frame(maxWidth: min(880, height * WelcomePreviewLayout.ratio))
            .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder private var themeChoices: some View {
        if let space = store.currentSpace {
            ThemeEditor(store: store, space: space, saveSpace: { setup.applySpace($0) })
                .spaceChrome(store)
                .clipShape(.rect(cornerRadius: 16))
        }
    }

    private var searchChoices: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { engineButtons }.fixedSize(horizontal: true, vertical: false)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 8) { engineButtons }
                .frame(maxWidth: 500)
        }.frame(maxWidth: .infinity, alignment: .center)
    }

    private var engineButtons: some View {
        ForEach(Search.builtIn) { engine in
            Button { animate { setup.chooseEngine(engine) } } label: {
                HStack(spacing: 8) {
                    Image(nsImage: WelcomeArtwork.engineIcon(engine)).resizable().scaledToFit().frame(width: 18, height: 18)
                    Text(engine.name)
                }
            }
                .buttonStyle(WelcomeButtonStyle(palette: palette, primary: false, reduced: reduced,
                                               selected: setup.engine.id == engine.id, radius: 22))
                .accessibilityAddTraits(setup.engine.id == engine.id ? .isSelected : [])
        }
    }

    @ViewBuilder private var footer: some View {
        if setup.showsSetupControls {
            HStack(spacing: 16) {
                Button { move(setup.back) } label: { Image(systemName: "chevron.left").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).accessibilityLabel("Back").disabled(importer.phase == .importing)
                HStack(spacing: 5) {
                    ForEach(WelcomeStep.allCases.filter { $0 != .welcome }, id: \.rawValue) { item in
                        Capsule().fill(palette.ink.opacity(item == setup.step ? 1 : item.rawValue < setup.step.rawValue ? 0.45 : 0.18))
                            .frame(width: item == setup.step ? 23 : 13, height: 3)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Setup, step \(setup.step.rawValue) of \(WelcomeStep.allCases.count - 1): \(setup.step.label)")
                Spacer(minLength: 12)
                if setup.step == .bringBrowser {
                    if importer.phase == .complete {
                        primary("Continue") { move(setup.advance) }
                    } else {
                        Button("Start fresh") { move(setup.advance) }.buttonStyle(.plain)
                            .font(.system(size: 12)).foregroundStyle(palette.muted).padding(8)
                            .disabled(importer.phase == .importing)
                        primary(importer.phase == .importing ? "Importing…" : "Confirm import") {
                            Task { await importer.confirm() }
                        }.disabled(!importer.canConfirm)
                    }
                } else {
                    primary(setup.step == .ready ? "Start browsing" : "Continue") { move(setup.advance) }
                }
            }.transition(.opacity)
        } else {
            Color.clear.accessibilityHidden(true)
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Text(title)
                Image(systemName: "return").font(.system(size: 10)).opacity(0.55).accessibilityHidden(true)
            }
        }
        .buttonStyle(WelcomeButtonStyle(palette: palette, primary: setup.step == .welcome || setup.step == .ready, reduced: reduced))
        .keyboardShortcut(.defaultAction).accessibilityLabel(title)
    }
    private func heading(_ title: String, size: CGFloat) -> some View {
        Text(title).font(.system(size: size, weight: .medium)).tracking(-size * 0.025)
            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader).accessibilityFocused($titleFocused)
    }
    private func copy(_ title: String, detail: String, compact: Bool) -> some View {
        VStack(spacing: 10) {
            heading(title, size: compact ? 27 : 34)
            Text(detail).font(.system(size: compact ? 13 : 14)).foregroundStyle(palette.muted)
                .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }.multilineTextAlignment(.center).frame(maxWidth: 780)
    }
    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(palette.muted).multilineTextAlignment(.center)
    }
    private func key(_ value: String) -> some View {
        Text(value).font(.system(size: 25)).frame(width: 54, height: 52)
            .background(palette.surface, in: .rect(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(palette.line, lineWidth: 1))
    }
    private func animate(_ action: () -> Void) {
        withAnimation(reduced ? nil : .easeInOut(duration: 0.22), action)
    }
    private func move(_ action: () -> Void) { animate(action); titleFocused = true }
}

struct WelcomeButtonStyle: ButtonStyle {
    let palette: WelcomePalette
    let primary: Bool
    let reduced: Bool
    var selected = false
    var radius: CGFloat = 10
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 15).padding(.vertical, 10)
            .foregroundStyle(primary ? palette.paper : palette.ink)
            .background((primary ? palette.ink : palette.surface).opacity(configuration.isPressed ? 0.8 : 1), in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(primary ? .clear : selected ? palette.ink.opacity(0.6) : palette.line, lineWidth: 1))
            .scaleEffect(configuration.isPressed && !reduced ? 0.98 : 1)
            .animation(reduced ? nil : Look.quick, value: configuration.isPressed)
    }
}

/// An owned entrance state prevents an outgoing welcome from hiding a newly
/// mounted welcome when Back is pressed during the preceding transition.
private struct WelcomeIntro: View {
    let compact: Bool
    let palette: WelcomePalette
    let reduced: Bool
    let titleFocus: AccessibilityFocusState<Bool>.Binding
    let start: () -> Void
    @State private var appeared = false
    private var visible: Bool { appeared || reduced }

    var body: some View {
        VStack(spacing: compact ? 14 : 18) {
            Image(nsImage: WelcomeArtwork.icon).resizable().scaledToFit()
                .frame(width: compact ? 88 : 104, height: compact ? 88 : 104)
                .accessibilityLabel("Vane")
                .opacity(visible ? 1 : 0).scaleEffect(visible ? 1 : 0.94)
                .blur(radius: visible ? 0 : 5)
            Text("A little more room\nfor the web.")
                .font(.system(size: compact ? 36 : 44, weight: .medium)).tracking(compact ? -0.9 : -1.1)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader).accessibilityFocused(titleFocus)
                .opacity(visible ? 1 : 0).offset(y: visible ? 0 : 10)
                .animation(reduced ? nil : .easeOut(duration: 0.5).delay(0.08), value: appeared)
            Button(action: start) {
                HStack(spacing: 18) {
                    Text("Make yourself at home")
                    Image(systemName: "return").font(.system(size: 10)).opacity(0.55).accessibilityHidden(true)
                }
            }
            .buttonStyle(WelcomeButtonStyle(palette: palette, primary: true, reduced: reduced))
            .keyboardShortcut(.defaultAction).accessibilityLabel("Make yourself at home")
            .opacity(visible ? 1 : 0)
            .animation(reduced ? nil : .easeOut(duration: 0.4).delay(0.16), value: appeared)
        }.multilineTextAlignment(.center)
            .onAppear { withAnimation(reduced ? nil : .easeOut(duration: 0.55)) { appeared = true } }
    }
}
