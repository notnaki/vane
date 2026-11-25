import SwiftUI

/// First launch, after the Mac's FirstLaunchView: the same paper, ink and words, one step at a
/// time, in a column sized for a phone. Every step can be skipped; all of it is in Settings.
struct Onboarding: View {
    @Environment(Library.self) private var library
    @Environment(Browser.self) private var browser
    @Environment(Sync.self) private var sync
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let done: () -> Void
    @State private var step = Step.welcome
    @State private var color: String?
    @State private var appeared = false

    enum Step: Int, CaseIterable { case welcome, theme, search, mac, ready }
    /// The Mac's welcome colours, in its order.
    private let colors = [("#F2EAE4", "Linen"), ("#6CBAD9", "Tide"), ("#A6729D", "Iris"), ("#7AA982", "Sage"), ("#FF8558", "Ember")]

    // The Mac's WelcomePalette.
    private var dark: Bool { scheme == .dark }
    private var ink: Color { dark ? Color(white: 0.94) : Color(red: 0.15, green: 0.17, blue: 0.15) }
    private var muted: Color { dark ? Color(red: 0.66, green: 0.69, blue: 0.67) : Color(red: 0.36, green: 0.40, blue: 0.37) }
    private var paper: Color { dark ? Color(white: 0.035) : Color(red: 0.96, green: 0.96, blue: 0.94) }
    private var surface: Color { dark ? Color(white: 0.09) : Color(red: 0.91, green: 0.93, blue: 0.90) }
    private var line: Color { ink.opacity(dark ? 0.15 : 0.18) }

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: 44)
            ScrollView {
                content
                    .id(step)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 10)))
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.center)
            if step != .welcome { footer }
        }
        .foregroundStyle(ink)
        .background(paper.ignoresSafeArea())
        .tint(ink)
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.55)) { appeared = true } }
    }

    private var header: some View {
        ZStack {
            if step != .welcome {
                HStack(spacing: 6) {
                    Image("Preview-AppIcon").resizable().frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text("Vane").font(.system(size: 15, weight: .semibold))
                }
                .accessibilityHidden(true)
            }
            HStack {
                Spacer()
                Button("Skip setup", action: done).font(.footnote).foregroundStyle(muted).padding(.horizontal, 20)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            VStack(spacing: 20) {
                Image("Preview-AppIcon").resizable().frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .opacity(appeared ? 1 : 0).scaleEffect(appeared ? 1 : 0.94).blur(radius: appeared ? 0 : 5)
                    .accessibilityLabel("Vane")
                Text("A little more room\nfor the web.")
                    .font(.system(size: 34, weight: .medium)).tracking(-0.9).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 10)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.5).delay(0.08), value: appeared)
                Button("Make yourself at home") { move(.theme) }
                    .buttonStyle(Ink(primary: true, ink: ink, paper: paper, surface: surface, line: line))
                    .padding(.top, 8)
                    .opacity(appeared ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.4).delay(0.16), value: appeared)
            }
            .padding(.vertical, 40)
        case .theme:
            page("A space that feels like you.", "Pick a colour for your first Space. Every Space can have its own.") {
                let chosen = color ?? library.spaces.first?.palette.first ?? "#6E7DD2"
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Wash.ground(Color(hex: chosen) ?? Look.vane, dark: dark, tint: Look.defaultTint).opacity(Wash.opacity(dark: dark, tint: Look.defaultTint)))
                    .overlay(alignment: .bottom) {
                        Capsule().fill(.white.opacity(dark ? 0.09 : 0.42)).frame(height: 30).padding(14)
                    }
                    .frame(height: 150)
                    .animation(.easeOut(duration: 0.3), value: chosen)
                HStack(spacing: 14) {
                    ForEach(colors, id: \.0) { hex, name in
                        Button { color = hex } label: {
                            Circle().fill(Color(hex: hex)!).frame(width: 40, height: 40)
                                .overlay(Circle().strokeBorder(line, lineWidth: 1))
                                .padding(3)
                                .overlay(Circle().strokeBorder(ink, lineWidth: chosen == hex ? 1.6 : 0))
                        }
                        .accessibilityLabel(name)
                        .accessibilityAddTraits(chosen == hex ? .isSelected : [])
                    }
                }
            }
        case .search:
            page("Follow your curiosity.", "One bar for searches and websites. Choose your search engine; you can change it anytime in Settings.") {
                VStack(spacing: 8) {
                    ForEach(SearchEngine.allCases) { engine in
                        Button(engine.name) { browser.engine = engine }
                            .buttonStyle(Ink(primary: false, ink: ink, paper: paper, surface: surface, line: line, selected: browser.engine == engine))
                            .accessibilityAddTraits(browser.engine == engine ? .isSelected : [])
                    }
                }
            }
        case .mac:
            page("Bring the familiar with you.",
                 sync.available ? "Your Spaces, favourites, pinned tabs and bookmarks from Vane on your Mac, through your own iCloud."
                                : "Sign in to iCloud in the Settings app, then turn on sync in Vane's Settings.") {
                if sync.available {
                    Toggle("Sync with iCloud", isOn: Binding(get: { sync.enabled }, set: { on in
                        sync.enabled = on
                        if on { Task { await sync.run() } }
                    }))
                    .fontWeight(.medium)
                    .padding(.horizontal, 16).frame(height: 52)
                    .background(surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        case .ready:
            VStack(spacing: 24) {
                Image(systemName: "checkmark").font(.system(size: 26, weight: .light))
                    .frame(width: 64, height: 64).overlay(Circle().stroke(line, lineWidth: 1))
                    .accessibilityHidden(true)
                copy("The internet is yours from here.", "Open links from other apps in Vane by making it your default browser.")
                Button("Choose Default Browser") {
                    if let url = URL(string: UIApplication.openDefaultApplicationsSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(Ink(primary: false, ink: ink, paper: paper, surface: surface, line: line))
            }
            .padding(.vertical, 40)
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button { move(Step(rawValue: step.rawValue - 1)!) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel("Back")
            HStack(spacing: 5) {
                ForEach(Step.allCases.dropFirst(), id: \.self) { item in
                    Capsule().fill(ink.opacity(item == step ? 1 : item.rawValue < step.rawValue ? 0.45 : 0.18))
                        .frame(width: item == step ? 23 : 13, height: 3)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step.rawValue) of \(Step.allCases.count - 1)")
            Spacer(minLength: 12)
            Button(step == .ready ? "Start browsing" : "Continue") {
                if let next = Step(rawValue: step.rawValue + 1) { move(next) } else { finish() }
            }
            .buttonStyle(Ink(primary: step == .ready, ink: ink, paper: paper, surface: surface, line: line))
        }
        .padding(.horizontal, 20).padding(.bottom, 8)
        .frame(maxWidth: 520)
    }

    private func page(_ title: String, _ detail: String, @ViewBuilder _ body: () -> some View) -> some View {
        VStack(spacing: 28) {
            copy(title, detail)
            body()
        }
        .padding(.vertical, 32)
    }

    private func copy(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: 28, weight: .medium)).tracking(-0.7).accessibilityAddTraits(.isHeader)
            Text(detail).font(.subheadline).foregroundStyle(muted).lineSpacing(3)
        }
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }

    private func move(_ next: Step) {
        if step == .theme, let color, var space = library.spaces.first, space.palette.first != color {
            space.colors = [color]; library.setTheme(space)
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { step = next }
    }

    private func finish() { done() }
}

/// The Mac's WelcomeButtonStyle: ink on paper for the main action, a quiet surface otherwise.
private struct Ink: ButtonStyle {
    let primary: Bool
    let ink: Color, paper: Color, surface: Color, line: Color
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.medium))
            .padding(.horizontal, 18).frame(minWidth: primary ? 0 : nil, maxWidth: selected || !primary ? .infinity : nil).frame(height: 44)
            .foregroundStyle(primary ? paper : ink)
            .background((primary ? ink : surface).opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .overlay(Capsule().strokeBorder(primary ? .clear : selected ? ink.opacity(0.6) : line, lineWidth: selected ? 1.4 : 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
